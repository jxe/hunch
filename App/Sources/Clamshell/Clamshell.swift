import Foundation
import CryptoKit
import Editor

/// Hunch's persistent markdown format and its API.
///
/// On disk, a Clamshell is a folder:
///
///     <clamshell-root>/
///       *.md                                       live pages
///       Trash/<relpath>.md                         soft-deleted pages (mirrors source structure)
///       .history/<relpath>/<device-id>.jsonl       per-(device, page) append-only recovery log
///       .clamshell.json                            format metadata (home page pointer)
///
/// Located at relaunch via a security-scoped URL bookmark (see `WorkspaceBookmark`).
/// The home page pointer travels with the folder — copy or sync the folder and the
/// home page comes with it.
///
/// One Clamshell per open directory; constructed with the root URL and never
/// reconfigured — when the user switches workspaces, throw away the existing
/// instance and build a new one.
@MainActor
@Observable
final class Clamshell {
    @ObservationIgnored nonisolated let root: URL

    /// Path (relative to `root`) of the page designated as "home", or nil if unset.
    /// Persisted to `.clamshell.json` at the root; written atomically on every change.
    /// Cleared automatically when the home page is moved to trash. Read-only
    /// to outside callers; mutate via `setHome(relativePath:)`.
    private(set) var homeRelativePath: String? {
        didSet {
            guard oldValue != homeRelativePath else { return }
            persistMetadata()
        }
    }

    /// File URL of the home page, or nil if unset or not present on disk.
    var homeURL: URL? {
        guard let homeRelativePath else { return nil }
        return entry(at: homeRelativePath)?.url
    }

    /// True when `relativePath` is the workspace's current home page.
    func isHome(relativePath: String) -> Bool {
        homeRelativePath == relativePath
    }

    /// Set the home page to `relativePath`, or clear it with `nil`. Idempotent
    /// on the same value; the new value is persisted to `.clamshell.json`.
    func setHome(relativePath: String?) {
        homeRelativePath = relativePath
    }

    /// Scope for `listLostBlocks(filter:)`.
    enum LostBlocksFilter: Sendable {
        /// Every page in the workspace, including trashed ones.
        case all
        /// One specific page only.
        case page(relativePath: String)
    }

    @ObservationIgnored nonisolated let files: FileStore
    @ObservationIgnored nonisolated let trash: TrashStore
    @ObservationIgnored nonisolated let log: RecoveryLog
    // Composed pieces are intentionally `internal` — outside callers go
    // through the Clamshell wrappers (`listLostBlocks`, `restorePage`,
    // etc.) so the composition stays an implementation detail. Tests
    // can still reach them via `@testable import Hunch` where the
    // alternative would be uglier.

    /// Latest `files.scan()` result. Titles here are filename-derived
    /// fallbacks; the live title overlay lives in `titleCache`.
    /// Use `entries` for the user-facing list — it merges these.
    private var scanResult: [WorkspaceEntry] = []

    private struct CachedTitle {
        var title: String
        var modificationDate: Date?
    }

    /// Per-URL title overlay, keyed by mtime so a stale entry is detected
    /// at access time (cached entry whose mtime no longer matches the file
    /// falls back to the filename-derived title). Populated on-demand by
    /// `lookupPage` cache misses — never eagerly on rescan, because on
    /// iCloud each cold-cache read costs ~1s and 50× that would block the
    /// home page open for the better part of a minute.
    private var titleCache: [URL: CachedTitle] = [:]

    /// Dedupe set for in-flight title warm tasks. Without this, every
    /// SwiftUI re-render that calls `lookupPage` for a cold-cache URL
    /// would fire another fetch.
    @ObservationIgnored private var pendingTitleWarms: Set<URL> = []

    /// Per-URL save chain head. Each `commit(_:to:)` spawns a Task that
    /// awaits the previous chain entry for that URL before running its own
    /// log apply + .md write, so concurrent commits land in order. The
    /// chain head is the *latest* enqueued task; `commit` awaits its own
    /// task before returning, so callers get durability-on-return. The
    /// `id` lets a finishing commit recognize whether it's still the head
    /// (newer commit may have replaced it) and only clear its own slot.
    /// Absent ⇒ no work pending (i.e. `isQuiescent(at:)`).
    ///
    /// Why a hand-rolled chain rather than `actor PageWriter`: actor
    /// reentrancy lets a second `commit` start during the first's `await
    /// log.apply` suspension, which could let its `files.write` interleave
    /// with the first's — breaking the per-commit "log before file"
    /// ordering at the filesystem level. The chain's explicit
    /// `await previous?.value` forecloses that.
    ///
    /// `pendingLogEntries` is mutable so an arriving `commit` whose
    /// predecessor hasn't started yet can fold its work in instead of
    /// chaining another full save. The task body snapshots the field
    /// after flipping `started` on MainActor — no other MainActor work
    /// can interleave between those two statements, so the read is
    /// race-free.
    @MainActor
    private final class ChainEntry {
        let id: UUID
        let doc: Document
        var pendingLogEntries: [Patch.Entry]
        var started: Bool = false
        var task: Task<Void, Error>!

        init(id: UUID, doc: Document, pendingLogEntries: [Patch.Entry]) {
            self.id = id
            self.doc = doc
            self.pendingLogEntries = pendingLogEntries
        }
    }
    @ObservationIgnored private var saveChain: [URL: ChainEntry] = [:]

    @MainActor
    final class LivePage {
        let url: URL
        let document: Document
        let presenter: PresenterHandle
        var subscribers: [UUID: @MainActor (PresenterEvent) -> Void]

        init(
            url: URL,
            document: Document,
            presenter: PresenterHandle,
            firstSubscriberID: UUID,
            onEvent: @escaping @MainActor (PresenterEvent) -> Void
        ) {
            self.url = url
            self.document = document
            self.presenter = presenter
            self.subscribers = [firstSubscriberID: onEvent]
        }
    }

    /// One live `Document` per open page URL. Multiple windows may hold
    /// `OpenPage` handles for the same URL, but they all render/mutate this
    /// shared document instance so per-URL saves do not serialize stale
    /// snapshots from independent in-memory trees.
    @ObservationIgnored var livePages: [URL: LivePage] = [:]

    init(root: URL) {
        let total = perfStart()
        self.root = root
        let files = FileStore()
        self.files = files
        self.trash = TrashStore(workspaceRoot: root)
        self.log = RecoveryLog(workspaceRoot: root, store: files)

        let metadataURL = Clamshell.metadataURL(forRoot: root)
        let metaT = perfStart()
        let metadata = Clamshell.readMetadata(at: metadataURL)
        perfEnd(metaT, "Clamshell.init.readMetadata")
        if let metadata {
            self.homeRelativePath = metadata.homeRelativePath
        } else if let legacy = UserDefaults.standard.string(forKey: WorkspaceBookmark.legacyHomePathDefaultsKey) {
            // One-time migration: pre-Clamshell builds stored the home page in
            // UserDefaults. Move it onto the filesystem so it travels with the
            // folder, then clear the legacy key.
            self.homeRelativePath = legacy
            persistMetadata()
            UserDefaults.standard.removeObject(forKey: WorkspaceBookmark.legacyHomePathDefaultsKey)
        } else {
            self.homeRelativePath = nil
        }

        // Lazy migration: the previous (one-commit-old) build wrote per-block
        // pool files to `.blocks/`. The recovery log replaces that — drop the
        // pool dir on first open by a log-aware build.
        let blocksDir = root.appendingPathComponent(".blocks")
        let probeT = perfStart()
        let blocksExists = FileManager.default.fileExists(atPath: blocksDir.path)
        perfEnd(probeT, "Clamshell.init.probeBlocksDir")
        if blocksExists {
            try? FileManager.default.removeItem(at: blocksDir)
        }
        perfEnd(total, "Clamshell.init")
    }

    // MARK: - Path conversions

    nonisolated func relativePath(of url: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        if filePath.hasPrefix(rootPath + "/") {
            return String(filePath.dropFirst(rootPath.count + 1))
        }
        return url.lastPathComponent
    }

    nonisolated func url(for relativePath: String) -> URL {
        root.appendingPathComponent(relativePath).standardizedFileURL
    }

    enum CloudSyncTargetKind: String, Sendable {
        case page
        case thisDeviceLog
    }

    struct CloudSyncTarget: Identifiable, Equatable, Sendable {
        let kind: CloudSyncTargetKind
        let url: URL
        let displayName: String

        var id: CloudSyncTargetKind { kind }
    }

    enum CloudSyncItemStatus: Equatable, Sendable {
        case synced
        case syncing
        case waiting
        case error
        case local
        case missingNeutral
    }

    enum CloudSyncState: Equatable, Sendable {
        case synced
        case syncing
        case waiting
        case error
        case local
    }

    struct CloudSyncItemSnapshot: Identifiable, Equatable, Sendable {
        let target: CloudSyncTarget
        let exists: Bool
        let status: CloudSyncItemStatus
        let detail: String?

        var id: CloudSyncTargetKind { target.kind }
        var url: URL { target.url }
    }

    struct CloudSyncSnapshot: Equatable, Sendable {
        let items: [CloudSyncItemSnapshot]
        let state: CloudSyncState

        init(items: [CloudSyncItemSnapshot]) {
            self.items = items
            self.state = Self.deriveState(from: items)
        }

        static func deriveState(from items: [CloudSyncItemSnapshot]) -> CloudSyncState {
            let tracked = items.filter { $0.status != .missingNeutral }
            guard !tracked.isEmpty else { return .local }

            if tracked.contains(where: { $0.status == .error }) { return .error }
            if tracked.contains(where: { $0.status == .syncing }) { return .syncing }
            if tracked.contains(where: { $0.status == .waiting }) { return .waiting }
            if tracked.allSatisfy({ $0.status == .synced }) { return .synced }
            if tracked.allSatisfy({ $0.status == .local }) { return .local }

            // Mixed iCloud/local coverage is neither fully uploaded nor wholly
            // local, so surface it as pending rather than silently green.
            return .waiting
        }
    }

    func cloudSyncTargets(for doc: Document) -> [CloudSyncTarget] {
        let pageURL = doc.url.standardizedFileURL
        let relativePath = relativePath(of: pageURL)
        let logURL = root
            .appendingPathComponent(RecoveryLog.directoryName, isDirectory: true)
            .appendingPathComponent(relativePath, isDirectory: true)
            .appendingPathComponent("\(DeviceID.current).jsonl")
            .standardizedFileURL

        return [
            CloudSyncTarget(kind: .page, url: pageURL, displayName: pageURL.lastPathComponent),
            CloudSyncTarget(kind: .thisDeviceLog, url: logURL, displayName: "This device log")
        ]
    }

    func cloudSyncSnapshot(for doc: Document) -> CloudSyncSnapshot {
        CloudSyncSnapshot(items: cloudSyncTargets(for: doc).map { snapshot(for: $0) })
    }

    private func snapshot(for target: CloudSyncTarget) -> CloudSyncItemSnapshot {
        let exists = FileManager.default.fileExists(atPath: target.url.path)
        guard exists else {
            if target.kind == .thisDeviceLog {
                return CloudSyncItemSnapshot(
                    target: target,
                    exists: false,
                    status: .missingNeutral,
                    detail: "No local log yet"
                )
            }
            return CloudSyncItemSnapshot(
                target: target,
                exists: false,
                status: .error,
                detail: "File missing"
            )
        }

        do {
            let values = try target.url.resourceValues(forKeys: [
                .isUbiquitousItemKey,
                .ubiquitousItemIsUploadedKey,
                .ubiquitousItemIsUploadingKey,
                .ubiquitousItemUploadingErrorKey,
                .ubiquitousItemDownloadingErrorKey,
                .ubiquitousItemIsExcludedFromSyncKey,
                .ubiquitousItemHasUnresolvedConflictsKey
            ])

            guard values.isUbiquitousItem == true else {
                return CloudSyncItemSnapshot(target: target, exists: true, status: .local, detail: nil)
            }

            if values.ubiquitousItemIsExcludedFromSync == true {
                return CloudSyncItemSnapshot(target: target, exists: true, status: .error, detail: "Excluded from iCloud sync")
            }
            if values.ubiquitousItemHasUnresolvedConflicts == true {
                return CloudSyncItemSnapshot(target: target, exists: true, status: .error, detail: "Unresolved iCloud conflict")
            }
            if let error = values.ubiquitousItemUploadingError ?? values.ubiquitousItemDownloadingError {
                return CloudSyncItemSnapshot(target: target, exists: true, status: .error, detail: error.localizedDescription)
            }
            if values.ubiquitousItemIsUploading == true {
                return CloudSyncItemSnapshot(target: target, exists: true, status: .syncing, detail: nil)
            }
            if values.ubiquitousItemIsUploaded == true {
                return CloudSyncItemSnapshot(target: target, exists: true, status: .synced, detail: nil)
            }

            return CloudSyncItemSnapshot(target: target, exists: true, status: .waiting, detail: nil)
        } catch {
            return CloudSyncItemSnapshot(
                target: target,
                exists: true,
                status: .error,
                detail: error.localizedDescription
            )
        }
    }

    /// Classify a URL from an inline `[text](url)` link as an internal-page
    /// reference. Returns the workspace-relative pageID (path) when the URL
    /// names a `.md` file inside this Clamshell; nil for external schemes,
    /// non-`.md` targets, and anything resolving outside the root. Resolves
    /// relative URLs against `currentDocURL?.deletingLastPathComponent()`
    /// when provided, otherwise against the workspace root.
    nonisolated func pageID(for url: URL, relativeTo currentDocURL: URL? = nil) -> String? {
        if let scheme = url.scheme?.lowercased(), scheme != "file" { return nil }

        let resolvedURL: URL
        if url.scheme == "file" {
            resolvedURL = url.standardizedFileURL
        } else {
            let baseDir = currentDocURL?.deletingLastPathComponent() ?? root
            guard let resolved = URL(string: url.relativeString, relativeTo: baseDir) else {
                return nil
            }
            resolvedURL = resolved.absoluteURL.standardizedFileURL
        }

        guard resolvedURL.pathExtension.lowercased() == "md" else { return nil }

        let rootPath = root.standardizedFileURL.path
        let resolvedPath = resolvedURL.path
        guard resolvedPath.hasPrefix(rootPath + "/") else { return nil }
        return String(resolvedPath.dropFirst(rootPath.count + 1))
    }

    // MARK: - Pages: read

    /// Page list with the live title overlay applied. Computed from
    /// the raw scan result and the title cache so the two never drift —
    /// mutating either invalidates Observation subscribers automatically.
    /// SwiftUI views observe this directly; the scan runs eagerly on
    /// workspace open and rescans fire on page-set changes. Title cache
    /// is populated on-demand (see `lookupPage` / `requestTitleWarm`),
    /// not at scan time, so entries for un-warmed pages carry the
    /// filename-derived fallback title.
    var entries: [WorkspaceEntry] {
        scanResult.map { entry in
            let title: String
            if let cached = titleCache[entry.url], cached.modificationDate == entry.modificationDate {
                title = cached.title
            } else {
                title = entry.title
            }
            return WorkspaceEntry(
                url: entry.url,
                relativePath: entry.relativePath,
                title: title,
                modificationDate: entry.modificationDate
            )
        }
    }

    /// Walk the workspace folder and refresh `entries`. Idempotent — safe
    /// to call on any page-set change (create / trash / restore / external
    /// add). Does **not** warm the title cache: doing that eagerly on an
    /// iCloud workspace costs ~1s/file of cold-cache materialization, and
    /// 50× of that on MainActor stalls the home page open for the better
    /// part of a minute. Titles populate lazily through `lookupPage`
    /// cache misses as subpage rows render. Result lands on the observable
    /// `entries` property — callers should react there.
    func rescan() throws {
        let scanT = perfStart()
        let result = try files.scan(workspaceRoot: root)
        perfEnd(scanT, "Clamshell.rescan.scan", "count=\(result.count)")
        scanResult = result
    }

    /// Look up the `WorkspaceEntry` for a workspace-relative path, with the
    /// live title overlay applied. Returns nil when no scanned page matches.
    func entry(at relativePath: String) -> WorkspaceEntry? {
        entries.first { $0.relativePath == relativePath }
    }

    /// Existence + cached title for a `*.md` page id. `.missing` when the
    /// file isn't on disk; `.present(title: nil)` when the title cache
    /// hasn't been warmed for the URL yet — that case kicks an off-main
    /// warm so the next render returns the cached title via @Observable.
    /// Safe to call from a SwiftUI body: warm requests are deduped by URL.
    func lookupPage(_ relativePath: String) -> PageLookup {
        guard relativePath.hasSuffix(".md") else { return .missing }
        let url = self.url(for: relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        if let cached = titleCache[url], cached.modificationDate == mtime {
            return .present(title: cached.title)
        }
        requestTitleWarm(at: url, mtime: mtime)
        return .present(title: nil)
    }

    /// Filter + rank `entries` for any page-picker surface (search sheet,
    /// @-mention popover, move-to, jump-to). Title-prefix beats
    /// title-substring beats path-substring; mtime breaks ties. Empty
    /// query returns the full pool in mtime-descending order.
    /// `excluding` omits a specific URL — typically the currently-open
    /// document (move-to / mention / jump-to). Pass nil to include it.
    func pages(matching query: String, excluding: URL? = nil) -> [MentionItem] {
        let q = query.lowercased()
        let pool = entries
            .filter { $0.url != excluding }
            .sorted { $0.modificationDate > $1.modificationDate }
        let chosen: [WorkspaceEntry]
        if q.isEmpty {
            chosen = pool
        } else {
            let ranked = pool.compactMap { entry -> (WorkspaceEntry, Int)? in
                let title = entry.title.lowercased()
                if title.hasPrefix(q) { return (entry, 0) }
                if title.contains(q) { return (entry, 1) }
                if entry.relativePath.lowercased().contains(q) { return (entry, 2) }
                return nil
            }
            chosen = ranked.sorted { $0.1 < $1.1 }.map(\.0)
        }
        let home = homeRelativePath
        return chosen.map { entry in
            let subtitle = entry.relativePath != entry.title + ".md" ? entry.relativePath : nil
            return MentionItem(
                id: entry.relativePath,
                title: entry.title,
                subtitle: subtitle,
                isHome: entry.relativePath == home
            )
        }
    }

    /// Read + parse the `.md` at `url` and return a live `Document` ready to
    /// host an editor session. Seeds the iCloud disk-content ring buffer so
    /// subsequent presenter wakeups can classify the file against what we last
    /// read or wrote. Use `readBlocks(at:)` for one-off reads that won't open
    /// a session — those must not seed history or a future wakeup may
    /// misclassify as `.echo`. Disk read + parse run off-MainActor; hops back
    /// only to touch the ring buffer and build the `Document`.
    func loadDocument(at url: URL) async throws -> Document {
        let files = self.files
        let raw: String = try await Task.detached(priority: .userInitiated) {
            try files.read(url)
        }.value
        let blocks = BlockParser.parse(raw)
        let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        recordDiskContent(raw, at: url)
        return Document(url: url, children: blocks, modificationDate: mtime)
    }

    /// One-shot read of `url`'s blocks for callers that won't open an editor
    /// session against the file (e.g. the inline-expand flow that reads a
    /// subpage's body, splices it into the parent, then trashes the source).
    /// Does **not** seed the disk-content ring buffer — seeding from a stale
    /// non-session read can later misclassify a presenter wakeup as `.echo`.
    /// Disk read + parse run off-MainActor.
    func readBlocks(at url: URL) async throws -> [Block] {
        let files = self.files
        let raw: String = try await Task.detached(priority: .userInitiated) {
            try files.read(url)
        }.value
        return BlockParser.parse(raw)
    }

    // MARK: - Title cache

    /// Update the cache with this document's title + mtime. Returns true
    /// when the cached title for the URL actually changed (so
    /// `postSaveBookkeeping` knows when to fire a rescan).
    @discardableResult
    private func refreshTitleCache(from document: Document) -> Bool {
        let previous = titleCache[document.url]
        let titleChanged = previous?.title != document.title
        if titleChanged || previous?.modificationDate != document.modificationDate {
            titleCache[document.url] = CachedTitle(title: document.title, modificationDate: document.modificationDate)
        }
        return titleChanged
    }

    /// Fire-and-forget single-URL title warm. Reads + parses off MainActor
    /// (`loadDocumentTitle` is nonisolated); hops back only to write the
    /// cache. Deduped on `pendingTitleWarms` so multiple SwiftUI body calls
    /// for the same URL collapse to one fetch. mtime-guarded on the way in
    /// AND out — if a save lands a fresh title (via `postSaveBookkeeping`)
    /// between fetch start and finish, we don't clobber it.
    private func requestTitleWarm(at url: URL, mtime: Date?) {
        guard !pendingTitleWarms.contains(url) else { return }
        pendingTitleWarms.insert(url)
        let files = self.files
        let started = perfStart()
        Task.detached(priority: .utility) { [weak self, files, url, mtime] in
            let title = try? files.loadDocumentTitle(at: url)
            await MainActor.run {
                guard let self else { return }
                self.pendingTitleWarms.remove(url)
                guard let title else { return }
                let currentMtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                guard currentMtime == mtime else { return }
                self.titleCache[url] = CachedTitle(title: title, modificationDate: mtime)
                perfEnd(started, "titleWarm", "url=\(url.lastPathComponent)")
            }
        }
    }

    /// Drop title cache entry for `url`. Called on trash so a future page
    /// at the same path starts fresh.
    private func forgetTitle(at url: URL) {
        titleCache.removeValue(forKey: url)
    }


    // MARK: - Disk-content classification (iCloud-stomp / echo defense)

    /// Ring buffer of recent on-disk content hashes per URL. Seeded by every
    /// load/save/write that goes through Clamshell; consulted by
    /// `classifyDiskContent` so the presenter callback can distinguish
    /// "our own write echoed back" / "iCloud rolled us back" / "an external
    /// editor changed the file". Hash is a SHA-256 prefix of UTF-8 bytes —
    /// stable across launches (Swift's `String.hashValue` is per-process
    /// randomized and would misclassify on a presenter wakeup that races a
    /// reseed after relaunch).
    @ObservationIgnored private var contentHistory: [URL: [String]] = [:]
    private static let historyDepth = 5

    private static func stableHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
    }

    func recordDiskContent(_ text: String, at url: URL) {
        var history = contentHistory[url] ?? []
        let hash = Self.stableHash(text)
        if history.first == hash { return }
        history.insert(hash, at: 0)
        if history.count > Self.historyDepth { history.removeLast(history.count - Self.historyDepth) }
        contentHistory[url] = history
    }

    enum DiskClassification: Equatable, Sendable {
        /// mtime matches the open document's snapshot — nothing happened.
        case unchanged
        /// Disk content matches the most-recent hash we wrote/loaded —
        /// wakeup is our own write echoing back.
        case echo
        /// Disk content matches an older hash we've seen (iCloud rollback).
        /// Caller should re-save the authoritative in-memory copy.
        case stomp
        /// Disk content is unfamiliar — external edit. Caller should reload.
        case external
        /// File couldn't be read.
        case unreadable
    }

    /// Classify the current on-disk content for `url` against the running
    /// content-history ring buffer. `expectingModificationDate` is a fast-path
    /// check; pass the open document's `modificationDate` to short-circuit
    /// when the file's mtime hasn't moved since we last touched it.
    @MainActor
    func classifyDiskContent(at url: URL, expectingModificationDate: Date? = nil) -> DiskClassification {
        if let expected = expectingModificationDate {
            let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if mtime == expected { return .unchanged }
        }
        guard let text = try? files.read(url) else { return .unreadable }
        let hash = Self.stableHash(text)
        let history = contentHistory[url] ?? []
        if history.first == hash { return .echo }
        if history.contains(hash) { return .stomp }
        return .external
    }

    /// Drop ring-buffer history for `url`. Called when a page is moved to
    /// trash so a future page at the same path starts fresh.
    private func forgetDiskContent(at url: URL) {
        contentHistory.removeValue(forKey: url)
    }

    // MARK: - Pages: write
    //
    // Save model is commit-time atomic: every `commit(_:to:)` applies its
    // log entries to the recovery log and writes the .md file as one
    // awaited sequence, log strictly before file. Concurrent calls for the
    // same URL are chained on `saveChain[url]` — each spawned Task awaits
    // the previous before its own log + .md write, so a fast burst of
    // commits (typing → focus blur → navigation) lands in order, and the
    // top-level `await` in `commit` propagates errors back to the caller.
    // When a new commit arrives and the tail's task hasn't started its
    // body yet, the new commit's log entries are folded into the tail and
    // the new caller awaits the tail — N rapid presses collapse into one
    // serialize + one .md write. No debounce, no separate per-op log
    // task: every `Document.transaction` (typing via `commitLiveText`,
    // structural via `mutate(_:_:)`, undo, redo) emits its pre→post diff
    // through `Document.didCommitTransaction` → host bridge →
    // `commit(_:to:)`.
    //
    // Heavy lifting hops off MainActor: serialize + `NSFileCoordinator`
    // write run on a detached task at `.userInitiated` so they don't
    // contend with the UI work the edit burst is driving. See `save(_:)`.

    /// Persist a commit for `doc`. Awaits durability end-to-end: log
    /// entries (if any) are applied to the recovery log strictly before
    /// `.md` is serialized and written. Concurrent commits for the same
    /// URL chain on `saveChain[url]` — each new task awaits the previous
    /// before its own work, so a typing burst → blur → navigate sequence
    /// lands in order. The caller's `await` returns only after this
    /// commit's bytes are on disk; errors propagate.
    ///
    /// Caller is responsible for the in-memory state of `doc.children`:
    /// editor mutations go through `Document.transaction` (which fires
    /// `didCommitTransaction` → host bridge → here); reconcile mutates
    /// via `PatchEngine.apply` before calling `commit`; conflict merge
    /// builds a fresh `Document` with the merged tree.
    @MainActor
    func commit(_ commit: Commit, to doc: Document) async throws {
        let url = doc.url
        let rel = relativePath(of: url)

        // Coalesce: if the tail's task hasn't started its body yet (still
        // suspended awaiting its predecessor), fold this commit's log
        // entries into it instead of spawning a second full save. The
        // tail's body re-reads `pendingLogEntries` when it starts, so the
        // merged entries land in one log apply + one .md write. Awaiting
        // the tail's task value gives us the same durability guarantee
        // the original caller had. Only coalesce on the same Document
        // instance — a fresh Document for the same URL (e.g. conflict
        // merge) needs its own commit so its block snapshot is the one
        // serialized.
        if let tail = saveChain[url], !tail.started, tail.doc === doc {
            tail.pendingLogEntries.append(contentsOf: commit.logEntries)
            try await tail.task.value
            // Cleanup is owned by the originating commit call — don't
            // touch saveChain here.
            return
        }

        let previous = saveChain[url]?.task
        let id = UUID()
        let entry = ChainEntry(id: id, doc: doc, pendingLogEntries: commit.logEntries)
        entry.task = Task<Void, Error> { @MainActor [weak self, weak entry] in
            _ = try? await previous?.value
            guard let self, let entry else { return }
            // From here on, no more coalescing into this entry: subsequent
            // commits will spawn their own chained task. Snapshot the
            // merged log entries on the same MainActor tick (no
            // suspension between `started = true` and the read).
            entry.started = true
            let logEntries = entry.pendingLogEntries
            if !logEntries.isEmpty {
                try await self.log.apply(Patch(entries: logEntries), to: rel)
            }
            _ = try await self.save(entry.doc)
            self.postSaveBookkeeping(entry.doc)
        }
        saveChain[url] = entry
        do {
            try await entry.task.value
            // Only clear the slot when we're still the head — a newer commit
            // may have replaced us mid-flight; that one owns the cleanup.
            if saveChain[url]?.id == id {
                saveChain.removeValue(forKey: url)
            }
        } catch {
            if saveChain[url]?.id == id {
                saveChain.removeValue(forKey: url)
            }
            Diag.log.error("commit failed url=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Await durability of any commits already in flight for `doc`. Does
    /// not trigger a save — that's what `commit(_:to:)` is for. Used on
    /// navigation / blur / scenePhase / close to make sure the bytes for
    /// the just-fired commit are on disk before the editor unmounts.
    func flush(_ doc: Document) async throws {
        guard let pending = saveChain[doc.url] else { return }
        try await pending.task.value
    }

    /// True when no work is pending for `url`. The engine's reconcile and
    /// presenter paths gate on this — they assume
    /// `doc.children == parsed(.md)`, which is only true on a settled page.
    func isQuiescent(at url: URL) -> Bool {
        saveChain[url] == nil
    }

    /// The actual on-disk write. Serializes `document.children` and writes
    /// the bytes through `FileStore` (which wraps `NSFileCoordinator` to
    /// avoid racing with iCloud sync). Does NOT touch the recovery log —
    /// `commit(_:to:)` owns the log durability invariant (log entries
    /// land first, then this runs).
    ///
    /// Snapshot reads happen on MainActor (Document is MainActor-isolated;
    /// `titleCache` is private to this class) and then the heavy lifting
    /// — `MarkupFormatter` serialize + `NSFileCoordinator`-coordinated
    /// atomic write — runs off MainActor on a detached task. For large
    /// docs the serialize alone is tens of ms and the iCloud-coordinated
    /// write routinely hits 50–200ms; doing either on MainActor stalls
    /// the very UI a typing/move burst is trying to drive.
    @MainActor
    @discardableResult
    private func save(_ document: Document) async throws -> String {
        let children = document.children
        let url = document.url
        let titleMap = buildSubpageTitleMap(referencedBy: children)
        let files = self.files

        let newText = try await Task.detached(priority: .userInitiated) {
            let text = BlockSerializer.serialize(children, resolvingSubpageTitle: { rel in
                titleMap[rel]
            })
            try files.write(text, to: url)
            return text
        }.value

        recordDiskContent(newText, at: url)
        return newText
    }

    /// Resolve every `.subpage` page-ID referenced anywhere in `roots` to
    /// the live title overlay (or filename fallback). Used to feed the
    /// serializer a fully-snapshotted `[String: String]` map so the
    /// off-actor serialize doesn't have to hop back here for each
    /// subpage block.
    @MainActor
    private func buildSubpageTitleMap(referencedBy roots: [Block]) -> [String: String] {
        var map: [String: String] = [:]
        func walk(_ blocks: [Block]) {
            for block in blocks {
                if case .subpage(_, let pageID) = block.kind {
                    if map[pageID] == nil, let title = entry(at: pageID)?.title {
                        map[pageID] = title
                    }
                }
                if !block.children.isEmpty { walk(block.children) }
            }
        }
        walk(roots)
        return map
    }

    /// Post-save hygiene: refresh the document's mtime from disk, update
    /// the title cache, refresh the reconcile watermark, and rescan the
    /// workspace if the entries surface needs it. Called from every
    /// successful save path (chain task via `enqueueSave`,
    /// `writeClosedPage(_:patch:)`, `append(_:toPage:)`).
    @MainActor
    private func postSaveBookkeeping(_ document: Document) {
        document.modificationDate = (try? document.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let titleChanged = refreshTitleCache(from: document)
        // Refresh the reconcile watermark so this save (new `.md` mtime,
        // grown own-log) doesn't trigger a useless refold on next open.
        // We logged the records via `apply(_:to:)` and just wrote the
        // `.md` — the journal and the doc are consistent by construction.
        let rel = relativePath(of: document.url)
        let mtime = document.modificationDate
        Task { [log, rel, mtime] in
            await log.recordOwnSave(page: rel, mdMtime: mtime)
        }
        if titleChanged {
            // Title overlay changed → entries' surface mtime is now stale.
            // A scan picks up the new mtime for this URL; subscribers
            // re-render through the entries computed.
            try? rescan()
        }
    }


    // MARK: - iCloud conflict resolution

    /// Outcome of a conflict-resolution pass. `salvaged` counts block-hashes
    /// pulled in from alternates that weren't already in the survivor;
    /// `liveDocumentMutated` is true exactly when the live `Document` passed
    /// in was rewritten in place — the caller's signal to reseed mtime, the
    /// disk-content history, the title cache, and to show a banner.
    struct ConflictResolution: Equatable, Sendable {
        let salvaged: Int
        let liveDocumentMutated: Bool
        static let none = ConflictResolution(salvaged: 0, liveDocumentMutated: false)
    }

    /// If `url` has any unresolved `NSFileVersion` conflict alternates,
    /// merge their blocks into the survivor (in-memory `doc` if provided,
    /// otherwise the on-disk text), apply the salvaged blocks to the log
    /// then write the merged document to disk, and mark each alternate
    /// version resolved.
    ///
    /// Open-page callers: pass the live `Document`. When the return value's
    /// `liveDocumentMutated` is true, the live doc's `children` was rewritten
    /// in place and the caller must reseed its per-URL bookkeeping (mtime,
    /// disk-hash, title cache, banner).
    ///
    /// Closed-page callers: pass `nil`. The merged result is written
    /// straight to disk; `liveDocumentMutated` is always false.
    @MainActor
    func resolveConflictVersions(
        at url: URL,
        againstLive doc: Document? = nil
    ) async throws -> ConflictResolution {
        let nsfvT = perfStart()
        let alternates = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
        perfEnd(nsfvT, "NSFileVersion.unresolved", "url=\(url.lastPathComponent) count=\(alternates.count)")
        guard !alternates.isEmpty else { return .none }

        var alternateBlockLists: [[Block]] = []
        for version in alternates {
            guard let text = Clamshell.readCoordinated(version.url) else { continue }
            alternateBlockLists.append(BlockParser.parse(text))
        }

        let survivorBlocks: [Block]
        if let doc {
            survivorBlocks = doc.children
        } else {
            let raw = try files.read(url)
            survivorBlocks = BlockParser.parse(raw)
        }

        let rel = relativePath(of: url)
        let intent = PatchEngine.intent(from: log.readJournal(page: rel))

        let result = PatchEngine.mergeConflict(
            survivor: survivorBlocks,
            alternates: alternateBlockLists,
            intent: intent
        )

        Diag.merge.log("resolve url=\(url.lastPathComponent, privacy: .public) alternates=\(alternates.count, privacy: .public) salvaged=\(result.salvagedHashes.count, privacy: .public)")

        if result.salvagedHashes.isEmpty {
            Clamshell.markAlternatesResolved(alternates)
            return .none
        }

        let merged = Document(url: url, children: result.merged)
        let mergeCommit = Commit(
            logEntries: Patch.observations(from: merged.children).entries
        )
        try await commit(mergeCommit, to: merged)

        let mutated: Bool
        if let doc {
            doc.replaceChildrenFromConflictResolution(result.merged)
            mutated = true
        } else {
            mutated = false
        }

        Clamshell.markAlternatesResolved(alternates)
        return ConflictResolution(salvaged: result.salvagedHashes.count, liveDocumentMutated: mutated)
    }

    nonisolated private static func readCoordinated(_ url: URL) -> String? {
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        var out: String?
        coordinator.coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordError) { coordinatedURL in
            out = try? String(contentsOf: coordinatedURL, encoding: .utf8)
        }
        return out
    }

    nonisolated private static func markAlternatesResolved(_ alternates: [NSFileVersion]) {
        for version in alternates {
            version.isResolved = true
            try? version.remove()
        }
    }

    // MARK: - Pages: create

    /// Creates a new page with `# title` followed by the serialized
    /// `initialContent` (or just the title if `initialContent` is nil).
    /// Returns the workspace-relative path of the created page.
    ///
    /// `requestedPath: nil` derives a slug from `title` and disambiguates with
    /// `-2`, `-3`, etc. against existing files. A non-nil `requestedPath` is
    /// honored as-is — used by the editor for deterministic-id cases (redo,
    /// preserved-id mention create).
    ///
    /// No-op if the resolved file already exists. Intermediate directories
    /// are created as needed. Refreshes `entries` and seeds the title
    /// cache so the new page shows up immediately in pickers / sidebar.
    @discardableResult
    func createPage(
        title: String,
        requestedPath: String?,
        initialContent: [Block]?
    ) throws -> String {
        let path = requestedPath ?? availablePagePath(for: title)
        let url = self.url(for: path)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: url.path) else { return path }
        let body: String
        if let initialContent {
            body = "# \(title)\n\n" + BlockSerializer.serialize(initialContent)
        } else {
            body = "# \(title)\n"
        }
        try body.write(to: url, atomically: true, encoding: .utf8)
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        titleCache[url] = CachedTitle(title: title, modificationDate: mtime)
        try? rescan()
        return path
    }

    /// Workspace-relative slug for a new page titled `title`, suffixed with
    /// `-2`, `-3`, etc. to avoid collision with existing files.
    private func availablePagePath(for title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let chars = title.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(chars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        let stem = collapsed.isEmpty ? "Untitled" : collapsed

        var candidate = stem + ".md"
        var suffix = 2
        while FileManager.default.fileExists(atPath: root.appendingPathComponent(candidate).path) {
            candidate = "\(stem)-\(suffix).md"
            suffix += 1
        }
        return candidate
    }

    // MARK: - Trash (soft-deleted pages)

    /// Drain `parent`'s pending writes, then move the page at `pageID` to
    /// Trash. Used by the editor's inline-expand flow: the editor has just
    /// spliced the subpage's blocks into the parent, and the source file
    /// must only go away once that splice is durable — a crash between
    /// flush and trash would otherwise leave the source gone and the
    /// inlined copy unpersisted. No-op when the source file is already
    /// missing.
    func inlineAndTrash(pageID: String, parent: Document) async throws {
        let target = url(for: pageID)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        try await flush(parent)
        _ = try moveToTrash(at: target)
    }

    /// Move a page to `Trash/`. If the page is the current home page, also clears
    /// `homeRelativePath` (the home pointer can't reference a trashed page).
    /// The page's recovery log dir travels with it so restoration brings the
    /// per-block log entries back too.
    @discardableResult
    func moveToTrash(at url: URL) throws -> String {
        let rel = relativePath(of: url)
        let result = try files.moveToTrash(relativePath: rel, workspaceRoot: root)
        if homeRelativePath == rel {
            homeRelativePath = nil
        }
        forgetDiskContent(at: url)
        forgetTitle(at: url)
        try? rescan()
        Task { [log, rel, result] in
            do {
                try await log.move(fromPage: rel, toPage: result)
            } catch {
                Diag.log.error("log move (trash) failed from=\(rel, privacy: .public) to=\(result, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
        return result
    }

    nonisolated func listTrashedPages() async throws -> [TrashEntry] {
        try await trash.listEntries()
    }

    @discardableResult
    func restorePage(_ entry: TrashEntry) async throws -> URL {
        let restoredURL = try await trash.restorePage(entry)
        let restoredRel = relativePath(of: restoredURL)
        do {
            try await log.move(fromPage: entry.trashRelativePath, toPage: restoredRel)
        } catch {
            Diag.log.error("log move (restore) failed from=\(entry.trashRelativePath, privacy: .public) to=\(restoredRel, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
        try? rescan()
        return restoredURL
    }

    // MARK: - Lost blocks (recovery-log-backed)

    /// Atomic blocks that were once recorded for a page but aren't in its
    /// live `.md` right now (and aren't tombstoned). Each entry arrives
    /// fully populated — JSONL gives us hash, parent hash, atomic
    /// markdown, and timestamp per line. Sorted by recordedAt descending.
    func listLostBlocks(filter: LostBlocksFilter = .all) async -> [LostBlock] {
        switch filter {
        case .page(let rel):
            return await log.enumerate(page: rel)
        case .all:
            return await log.enumerateAll()
        }
    }


    /// Blocks deleted via the editor's op stream or a manual Recover-sheet
    /// dismiss: the log union's latest record is a `purge`, but a prior
    /// `add` carries the markdown + parent metadata so we can reconstruct
    /// them. `since` caps the result to recent purges (default: last 30
    /// days). Pass `since: nil` to disable the cap.
    func listPurgedBlocks(
        filter: LostBlocksFilter = .all,
        since: Date? = Date().addingTimeInterval(-30 * 86_400)
    ) async -> [PurgedBlock] {
        switch filter {
        case .page(let rel):
            return await log.enumeratePurged(page: rel, since: since)
        case .all:
            return await log.enumerateAllPurged(since: since)
        }
    }


    // MARK: - Assets (pasted images)

    nonisolated private static let assetsFolderName = "Assets"

    /// Persist `data` to `Assets/<unique-name>.<ext>` and return the relative
    /// path suitable for an image block's `source` field. The `Assets/` folder
    /// is visible (Notion / Obsidian convention) so the same file opens cleanly
    /// in any other markdown app.
    ///
    /// One-shot, content-immutable writes — no need to chain through `saveChain`.
    nonisolated func writeImage(_ image: PastedImage) throws -> String {
        let safeExt = sanitizeImageExtension(image.ext)
        let filename = pastedImageFilename(ext: safeExt)
        let assetsURL = root.appendingPathComponent(Clamshell.assetsFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        let dest = assetsURL.appendingPathComponent(filename)
        try image.data.write(to: dest, options: [.atomic])
        return Clamshell.assetsFolderName + "/" + filename
    }

    /// Resolve an image block's `source` field to a file URL the renderer can
    /// load. Returns nil if the source has a scheme we don't handle, escapes
    /// the workspace, or the file is missing — the renderer shows a placeholder.
    nonisolated func resolveImage(source: String) -> URL? {
        guard !source.isEmpty else { return nil }
        // `http://...` etc. — let it pass through to the renderer (which
        // currently doesn't load remote URLs). For now treat as missing.
        if source.contains("://") { return nil }
        let url = root.appendingPathComponent(source).standardizedFileURL
        // Guard against `..` traversal: the resolved path must still sit under
        // the workspace root.
        guard url.path.hasPrefix(root.standardizedFileURL.path + "/") else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    nonisolated private func pastedImageFilename(ext: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = formatter.string(from: Date())
        let suffix = randomFilenameSuffix(length: 4)
        return "pasted-\(stamp)-\(suffix).\(ext)"
    }

    nonisolated private func randomFilenameSuffix(length: Int) -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<length).map { _ in chars.randomElement()! })
    }

    nonisolated private func sanitizeImageExtension(_ raw: String) -> String {
        let lower = raw.lowercased()
        let allowed = CharacterSet.alphanumerics
        let scrubbed = lower.unicodeScalars.filter { allowed.contains($0) }
        let result = String(String.UnicodeScalarView(scrubbed))
        return result.isEmpty ? "bin" : result
    }

    // MARK: - .clamshell.json

    private static let metadataFilename = ".clamshell.json"

    private struct Metadata: Codable, Sendable {
        var homeRelativePath: String?

        private enum CodingKeys: String, CodingKey {
            case homeRelativePath
        }

        // Decode tolerates unknown keys (older builds wrote
        // `autoTombstoneMigrationDone`; it's harmless to ignore now).
    }

    private static func metadataURL(forRoot root: URL) -> URL {
        root.appendingPathComponent(metadataFilename)
    }

    private static func readMetadata(at url: URL) -> Metadata? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Metadata.self, from: data)
    }

    private func persistMetadata() {
        let url = Clamshell.metadataURL(forRoot: root)
        var metadata = Clamshell.readMetadata(at: url) ?? Metadata()
        metadata.homeRelativePath = homeRelativePath
        Clamshell.writeMetadata(metadata, to: url)
    }

    nonisolated private static func writeMetadata(_ metadata: Metadata, to url: URL) {
        // If everything's empty, prefer removing the file over leaving `{}` behind.
        if metadata.homeRelativePath == nil {
            try? FileManager.default.removeItem(at: url)
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(metadata) else { return }

        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        coordinator.coordinate(writingItemAt: url, options: [.forReplacing], error: &coordError) { coordinatedURL in
            try? data.write(to: coordinatedURL, options: [.atomic])
        }
    }
}
