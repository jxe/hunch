import Foundation
import CryptoKit
import Synchronization
import Quagmire

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

    enum PageFilter: Sendable, Equatable {
        case locallyAvailableForWrite
    }

    enum AppendBlocksError: Error, LocalizedError {
        case empty
        case pageMissing(String)

        var errorDescription: String? {
            switch self {
            case .empty:
                return "No blocks to move."
            case .pageMissing(let relativePath):
                return "Couldn't find destination page \(relativePath)."
            }
        }
    }

    @ObservationIgnored nonisolated let files: FileStore
    @ObservationIgnored nonisolated let trash: TrashStore
    @ObservationIgnored nonisolated let log: RecoveryLog
    @ObservationIgnored let searchIndex: PageSearchIndex
    // Composed pieces are intentionally `internal` — outside callers go
    // through the Clamshell wrappers (`listLostBlocks`, `restorePage`,
    // etc.) so the composition stays an implementation detail. Tests
    // can still reach them via `@testable import Hunch` where the
    // alternative would be uglier.

    /// Latest `files.scan()` result. Titles here are filename-derived
    /// fallbacks; the live title overlay lives in `titleCache`.
    /// Use `entries` for the user-facing list — it merges these.
    private var scanResult: [WorkspaceEntry] = [] {
        didSet { invalidateEntriesCache() }
    }

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
    private var titleCache: [URL: CachedTitle] = [:] {
        didSet { invalidateEntriesCache() }
    }

    /// Derived cache for `entries` / `entry(at:)` — the merged overlay
    /// array used to be rebuilt on every access (and `entry(at:)` did a
    /// linear scan per call; `buildSubpageTitleMap` calls it once per
    /// subpage block on every save). `@ObservationIgnored` because these
    /// are pure functions of `scanResult` + `titleCache`, which are the
    /// tracked properties; every mutation flows through their setters, so
    /// the `didSet`s above cover all invalidation points.
    @ObservationIgnored private var entriesCache: [WorkspaceEntry]?
    @ObservationIgnored private var entryIndex: [String: WorkspaceEntry]?

    private func invalidateEntriesCache() {
        entriesCache = nil
        entryIndex = nil
    }

    /// Dedupe set for in-flight title warm tasks. Without this, every
    /// SwiftUI re-render that calls `lookupPage` for a cold-cache URL
    /// would fire another fetch.
    @ObservationIgnored private var pendingTitleWarms: Set<URL> = []

    /// Derived backlinks + orphan-reachability graph over the workspace.
    /// `nil` means "not built yet / invalidated"; a lazy off-main build (or an
    /// in-memory save patch) lands the value here. Tracked, so the search-row
    /// orphan badge and the per-page backlinks footer re-render when it lands.
    /// Mirrors the title-cache warm: deduped on `isBuildingLinkGraph`,
    /// generation-guarded and cancelled when an invalidation makes it stale.
    private(set) var linkGraph: LinkGraph?
    @ObservationIgnored private var isBuildingLinkGraph = false
    @ObservationIgnored private var linkGraphBuildGeneration = 0
    @ObservationIgnored var linkGraphBuildTask: Task<Void, Never>?

    /// Persistent per-page `(mtime, title, outbound targets)` mirror, loaded
    /// from `UserDefaults` at init and rewritten after each full
    /// `buildLinkGraph`. Lets a launch reuse titles + links for pages whose
    /// mtime is unchanged, skipping their (expensive on iCloud) content reads —
    /// the same mtime-keyed fast-path the reconcile watermark uses, but for the
    /// link graph. Per-install (never travels with the folder).
    @ObservationIgnored private var linkCacheEntries: [String: LinkCacheEntry] = [:]
    @ObservationIgnored private let linkCacheDefaultsKey: String

    /// Page-ID → workspace-relative path, for resolving `page.md#<id>` link
    /// fragments. Derived state: rebuilt from the persisted link cache at
    /// init and on every graph build, patched on save/load via
    /// `rememberEnvelope`. Behind a `Mutex` because `pagePath` (nonisolated,
    /// called from the off-main link-graph classify closures) consults it.
    @ObservationIgnored nonisolated private let pageIDIndexStore = Mutex<[String: String]>([:])

    /// User frontmatter + Clamshell stamp trust for pages we've loaded in
    /// this process. `Quagmire.Document` remains pure block content; Clamshell
    /// reattaches/updates the envelope only when it writes markdown.
    @ObservationIgnored private var pageFrontmatter: [URL: [String]?] = [:]
    @ObservationIgnored private var pageStampTrust: [URL: ClamshellPageEnvelope.StampTrust] = [:]

    /// One coordinator per URL that currently has an editor subscriber,
    /// pending persistence/synchronization work, or a transient closed-page
    /// operation. The coordinator owns the canonical in-memory `Document`
    /// and all sequencing for that page.
    @ObservationIgnored var pageCoordinators: [URL: PageCoordinator] = [:]

    init(root: URL) {
        let total = perfStart()
        self.root = root
        let files = FileStore()
        self.files = files
        self.trash = TrashStore(workspaceRoot: root)
        self.log = RecoveryLog(workspaceRoot: root, store: files)
        self.searchIndex = PageSearchIndex(workspaceRoot: root)

        let cacheHash = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        self.linkCacheDefaultsKey = "hunch.linkCache.\(cacheHash)"

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

        // Seed titles from the persisted link cache so they're correct on the
        // first frame (the entries-merge mtime guard rejects any stale entry).
        self.linkCacheEntries = Clamshell.loadPersistedLinkCache(key: linkCacheDefaultsKey)
        seedTitleCacheFromLinkCache()
        rebuildPageIDIndex(from: linkCacheEntries)

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

    func page(at url: URL) -> Page {
        Page(owner: self, url: url)
    }

    func page(atPath relativePath: String) -> Page {
        page(at: url(for: relativePath))
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
        let byteCount: Int64?

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

    private func cloudSyncTargets(for pageURL: URL) -> [CloudSyncTarget] {
        let pageURL = pageURL.standardizedFileURL
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

    private func cloudSyncSnapshot(for pageURL: URL) -> CloudSyncSnapshot {
        CloudSyncSnapshot(items: cloudSyncTargets(for: pageURL).map { snapshot(for: $0) })
    }

    private func compactThisDeviceLog(for coordinator: PageCoordinator) async throws -> LogCompactionResult {
        let relativePath = relativePath(of: coordinator.url)
        return try await log.compactOwnLog(
            page: relativePath,
            mdMtime: coordinator.modificationDate,
            trustedFrontier: trustedFrontierForPage(at: coordinator.url)
        )
    }

    private func snapshot(for target: CloudSyncTarget) -> CloudSyncItemSnapshot {
        let exists = FileManager.default.fileExists(atPath: target.url.path)
        guard exists else {
            if target.kind == .thisDeviceLog {
                return CloudSyncItemSnapshot(
                    target: target,
                    exists: false,
                    status: .missingNeutral,
                    detail: "No local log yet",
                    byteCount: nil
                )
            }
            return CloudSyncItemSnapshot(
                target: target,
                exists: false,
                status: .error,
                detail: "File missing",
                byteCount: nil
            )
        }

        do {
            let values = try target.url.resourceValues(forKeys: [
                .fileSizeKey,
                .isUbiquitousItemKey,
                .ubiquitousItemIsUploadedKey,
                .ubiquitousItemIsUploadingKey,
                .ubiquitousItemUploadingErrorKey,
                .ubiquitousItemDownloadingErrorKey,
                .ubiquitousItemIsExcludedFromSyncKey,
                .ubiquitousItemHasUnresolvedConflictsKey
            ])
            let byteCount = values.fileSize.map(Int64.init)

            guard values.isUbiquitousItem == true else {
                return CloudSyncItemSnapshot(target: target, exists: true, status: .local, detail: nil, byteCount: byteCount)
            }

            if values.ubiquitousItemIsExcludedFromSync == true {
                return CloudSyncItemSnapshot(target: target, exists: true, status: .error, detail: "Excluded from iCloud sync", byteCount: byteCount)
            }
            if values.ubiquitousItemHasUnresolvedConflicts == true {
                return CloudSyncItemSnapshot(target: target, exists: true, status: .error, detail: "Unresolved iCloud conflict", byteCount: byteCount)
            }
            if let error = values.ubiquitousItemUploadingError ?? values.ubiquitousItemDownloadingError {
                return CloudSyncItemSnapshot(target: target, exists: true, status: .error, detail: error.localizedDescription, byteCount: byteCount)
            }
            if values.ubiquitousItemIsUploading == true {
                return CloudSyncItemSnapshot(target: target, exists: true, status: .syncing, detail: nil, byteCount: byteCount)
            }
            if values.ubiquitousItemIsUploaded == true {
                return CloudSyncItemSnapshot(target: target, exists: true, status: .synced, detail: nil, byteCount: byteCount)
            }

            return CloudSyncItemSnapshot(target: target, exists: true, status: .waiting, detail: nil, byteCount: byteCount)
        } catch {
            return CloudSyncItemSnapshot(
                target: target,
                exists: true,
                status: .error,
                detail: error.localizedDescription,
                byteCount: nil
            )
        }
    }

    /// Classify a URL from an inline `[text](url)` link as an internal-page
    /// reference. Returns the workspace-relative page path when the URL
    /// names a `.md` file inside this Clamshell; nil for external schemes,
    /// non-`.md` targets, and anything resolving outside the root. Resolves
    /// relative URLs against `currentDocURL?.deletingLastPathComponent()`
    /// when provided, otherwise against the workspace root.
    nonisolated func pagePath(for url: URL, relativeTo currentDocURL: URL? = nil) -> String? {
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

        // `URL.path` / `pathExtension` already exclude any `#fragment`, so
        // the syntactic path resolution below is fragment-transparent.
        guard resolvedURL.pathExtension.lowercased() == "md" else { return nil }

        let rootPath = root.standardizedFileURL.path
        let resolvedPath = resolvedURL.path
        guard resolvedPath.hasPrefix(rootPath + "/") else { return nil }
        let pathRel = String(resolvedPath.dropFirst(rootPath.count + 1))
        let id = url.fragment.flatMap { ClamshellPageEnvelope.isValidPageID($0) ? $0 : nil }
        return resolve(pathRel: pathRel, id: id)
    }

    // MARK: - Link-target resolution (page-ID fragments + title fallback)

    /// Resolve a subpage destination string (verbatim from the `.md`) to a
    /// workspace-relative page path. Nonisolated so the off-main link-graph
    /// classify pass can call it.
    nonisolated func resolveSubpageTarget(_ dest: String) -> String? {
        let (rawPath, id) = ClamshellPageEnvelope.splitPageFragment(dest)
        let path = rawPath.removingPercentEncoding ?? rawPath
        guard path.hasSuffix(".md") else { return nil }
        return resolve(pathRel: path, id: id)
    }

    /// Core identity rule shared by both link flavors. Fragment-less
    /// destinations keep the historical purely-syntactic behavior (no
    /// stat). With a fragment, the ID is authoritative: when the index
    /// knows the ID and its page exists, that page wins even if the path
    /// part names a different (newer) file — the author linked *this*
    /// page, whatever it's called now. A cold index or a vanished ID
    /// target falls back to the path.
    nonisolated private func resolve(pathRel: String?, id: String?) -> String? {
        guard let id else { return pathRel }
        if let idRel = pageIDIndexStore.withLock({ $0[id] }),
           FileManager.default.fileExists(atPath: url(for: idRel).path) {
            return idRel
        }
        return pathRel
    }

    /// Full resolution for one subpage destination, adding the title
    /// fallback for fragment-less links whose path went stale: when the
    /// resolved target is missing on disk and exactly one live page's
    /// title equals the link's display text, that page wins. Used where
    /// display text is available (subpage opens, healing).
    func resolvePageTarget(_ dest: String, displayText: String? = nil) -> String? {
        let resolved = resolveSubpageTarget(dest)
        if let resolved, FileManager.default.fileExists(atPath: url(for: resolved).path) {
            return resolved
        }
        guard let displayText, !displayText.isEmpty else { return resolved }
        let matches = entries.filter { $0.title == displayText }
        guard matches.count == 1 else { return resolved }
        return matches[0].relativePath
    }

    /// Document-relative URL for an inline link from `baseDirectory` to a
    /// page at `target`, percent-encoded per component. The inverse of
    /// `pagePath(for:relativeTo:)` — kept next to it so the URL ↔ pageID
    /// conventions share one home. Pass `fragment` to append a page-ID
    /// fragment (`page.md#x7f3q2`).
    nonisolated func relativeMarkdownURL(from baseDirectory: URL, to target: URL, fragment: String? = nil) -> URL? {
        let baseComponents = baseDirectory.standardizedFileURL.pathComponents
        let targetComponents = target.standardizedFileURL.pathComponents
        var commonCount = 0
        while commonCount < baseComponents.count,
              commonCount < targetComponents.count,
              baseComponents[commonCount] == targetComponents[commonCount] {
            commonCount += 1
        }

        let up = Array(repeating: "..", count: baseComponents.count - commonCount)
        let down = Array(targetComponents.dropFirst(commonCount))
        let components = up + down
        guard !components.isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var encoded = components
            .map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }
            .joined(separator: "/")
        if let fragment {
            encoded += "#\(fragment)"
        }
        return URL(string: encoded)
    }

    // MARK: - Page-ID index maintenance

    nonisolated func pageIDIndexHit(_ id: String) -> String? {
        pageIDIndexStore.withLock { $0[id] }
    }

    /// Reverse index lookup: the ID currently claimed by the page at `rel`,
    /// when the index knows one.
    nonisolated func knownPageID(forRel rel: String) -> String? {
        pageIDIndexStore.withLock { index in
            index.first(where: { $0.value == rel })?.key
        }
    }

    /// Make sure the page at `rel` has a durable ID. Loading the page
    /// registers any on-disk ID via `rememberEnvelope`; when there is
    /// none, an empty commit runs the save path, whose legacy-mint step
    /// adds the `clamshell-id` line. Returns the ID, or nil when the
    /// page is unreadable.
    @discardableResult
    func ensurePageID(forRel rel: String) async -> String? {
        if let known = knownPageID(forRel: rel) { return known }
        let url = self.url(for: rel)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            try await coordinator(for: url).withTransientDocument { doc in
                if knownPageID(forRel: rel) == nil {
                    try await commit(Commit(logEntries: []), to: doc, at: url)
                }
            }
        } catch {
            return nil
        }
        return knownPageID(forRel: rel)
    }

    /// Record `id → rel`, dropping any prior claim the rel held under a
    /// different ID (a page has exactly one ID at a time).
    func registerPageID(_ id: String?, forRel rel: String) {
        guard let id else { return }
        pageIDIndexStore.withLock { index in
            for (key, value) in index where value == rel && key != id {
                index[key] = nil
            }
            index[id] = rel
        }
    }

    func unregisterPageIDs(forRel rel: String) {
        pageIDIndexStore.withLock { index in
            index = index.filter { $0.value != rel }
        }
    }

    private func rebuildPageIDIndex(from entries: [String: LinkCacheEntry]) {
        var index: [String: String] = [:]
        for (rel, entry) in entries {
            if let id = entry.pageID { index[id] = rel }
        }
        pageIDIndexStore.withLock { $0 = index }
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
        // Read the tracked properties FIRST so Observation registers
        // access even on a cache hit — skip this and SwiftUI stops
        // re-rendering after the first cached read. Load-bearing.
        let scan = scanResult
        let titles = titleCache
        if let entriesCache { return entriesCache }
        let merged = scan.map { entry in
            let title: String
            if let cached = titles[entry.url], cached.modificationDate == entry.modificationDate {
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
        entriesCache = merged
        entryIndex = Dictionary(merged.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        return merged
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
        invalidateLinkGraph()
        let livePaths = Set(result.map(\.relativePath))
        Task { [searchIndex] in await searchIndex.prune(keeping: livePaths) }
    }

    /// Look up the `WorkspaceEntry` for a workspace-relative path, with the
    /// live title overlay applied. Returns nil when no scanned page matches.
    /// Indexed — touching `entries` first populates the cache and registers
    /// the Observation access.
    func entry(at relativePath: String) -> WorkspaceEntry? {
        _ = entries
        return entryIndex?[relativePath]
    }

    /// What is currently known about a `*.md` page id.
    ///
    /// `.missing` when the file isn't on disk. `.unavailable` when it exists in
    /// the workspace but can't be written right now — an iCloud page that
    /// hasn't been downloaded, or one we lack permission for. That distinction
    /// is load-bearing: an undownloaded page is not gone, so the row must not
    /// read as broken and nothing should offer to trash it, but the actions
    /// that would write to it have to be off before the user tries. Without
    /// this they failed at write time with an error banner instead.
    ///
    /// `.present(title: nil)` when the file is fine but the title cache hasn't
    /// been warmed for it yet — that case kicks an off-main warm so the next
    /// render returns the cached title through `@Observable`.
    ///
    /// Synchronous by contract (see `EditorHost.lookupPage`): it is called
    /// while building rows. Safe from a SwiftUI body because warm requests are
    /// deduped by URL.
    func lookupPage(_ relativePath: String) -> PageLookup {
        guard let resolved = resolveSubpageTarget(relativePath) else { return .missing }
        let url = self.url(for: resolved)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard files.isLocallyWritable(url) else { return .unavailable }

        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let title: String?
        if let cached = titleCache[url], cached.modificationDate == mtime {
            title = cached.title
        } else {
            requestTitleWarm(at: url, mtime: mtime)
            title = nil
        }
        // Every locally-writable Markdown page in the workspace supports every
        // action. Hunch has one kind of target; the capability set exists for
        // hosts that don't. The row icon is derived from the title's leading
        // emoji rather than stored, so no `icon` is supplied here.
        return .present(PagePresentation(title: title, capabilities: .all))
    }

    /// Filter + rank `entries` for any page-picker surface (search sheet,
    /// @-mention popover, move-to, jump-to). Title-prefix beats
    /// title-substring; mtime breaks ties. Empty
    /// query returns the full pool in mtime-descending order.
    /// `excluding` omits a specific URL — typically the currently-open
    /// document (move-to / mention / jump-to). Pass nil to include it.
    /// Returns ranked `WorkspaceEntry`s — translation into the editor's
    /// `MentionItem` happens at the app boundary
    /// (`WorkspaceEntry.asMentionItem(homeRelativePath:)`).
    func pages(matching query: String, excluding: URL? = nil, filter: PageFilter? = nil) -> [WorkspaceEntry] {
        let q = query.lowercased()
        let pool = entries
            .filter { $0.url != excluding }
            .filter { entry in
                switch filter {
                case nil:
                    return true
                case .some(.locallyAvailableForWrite):
                    return files.isLocallyWritable(entry.url)
                }
            }
            .sorted { $0.modificationDate > $1.modificationDate }
        if q.isEmpty {
            return pool
        }
        let ranked = pool.compactMap { entry -> (WorkspaceEntry, Int)? in
            let title = entry.title.lowercased()
            if title.hasPrefix(q) { return (entry, 0) }
            if title.contains(q) { return (entry, 1) }
            return nil
        }
        return ranked.sorted { $0.1 < $1.1 }.map(\.0)
    }

    /// Full-text page search for the global search sheet. The FTS index is
    /// derived and may still be warming, so merge current title hits behind
    /// indexed results. Opening the sheet also requests the shared page scan;
    /// when it lands, `linkGraph` observation makes the picker rerun this query.
    func searchPages(matching query: String, limit: Int = 100) async -> [PageSearchResult] {
        let effectiveLimit = min(100, max(1, limit))
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return entries.prefix(effectiveLimit).map {
                PageSearchResult(
                    relativePath: $0.relativePath,
                    title: $0.title,
                    snippet: nil,
                    modificationDate: $0.modificationDate,
                    score: 0
                )
            }
        }

        _ = linkGraphOrBuild()
        let indexed = await searchIndex.search(trimmed, limit: effectiveLimit)
        var seen: Set<String> = []
        var results: [PageSearchResult] = []
        for hit in indexed {
            guard let entry = entry(at: hit.relativePath) else { continue }
            seen.insert(hit.relativePath)
            results.append(PageSearchResult(
                relativePath: hit.relativePath,
                title: entry.title,
                snippet: hit.snippet,
                modificationDate: entry.modificationDate,
                score: hit.score
            ))
        }

        for entry in pages(matching: trimmed) where !seen.contains(entry.relativePath) {
            results.append(PageSearchResult(
                relativePath: entry.relativePath,
                title: entry.title,
                snippet: nil,
                modificationDate: entry.modificationDate,
                score: .infinity
            ))
            if results.count == effectiveLimit { break }
        }
        return results
    }

    /// Engine-internal single read path: read **and parse** inside one
    /// detached task so neither lands on MainActor (the parse alone is
    /// tens of ms for large docs). Canonical coordinator materialization,
    /// one-shot block reads, and link-graph scans funnel through here; they
    /// differ only in what bookkeeping they seed afterward.
    nonisolated func readEnvelope(at url: URL) async throws -> (raw: String, parsed: ClamshellPageEnvelope.Parsed) {
        let files = self.files
        return try await Task.detached(priority: .userInitiated) {
            let raw = try files.read(url)
            return (raw, ClamshellPageEnvelope.parse(raw))
        }.value
    }

    // MARK: - Title cache

    /// Update the cache with this document's title + mtime. Returns true
    /// when the cached title for the URL actually changed (so
    /// `postSaveBookkeeping` knows when to fire a rescan).
    @discardableResult
    private func refreshTitleCache(url: URL, title: String, modificationDate: Date?) -> Bool {
        let previous = titleCache[url]
        let titleChanged = previous?.title != title
        if titleChanged || previous?.modificationDate != modificationDate {
            titleCache[url] = CachedTitle(title: title, modificationDate: modificationDate)
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

    /// Bulk-seed the title cache from titles derived during a full read pass
    /// (the link-graph build parses every page anyway, so this warms every
    /// title in one background pass instead of lazily one row at a time).
    /// mtime-guarded like `requestTitleWarm`: re-stat each file and only store
    /// when it hasn't changed since the read, so a concurrent save's fresher
    /// title is never clobbered. One coalesced assignment to limit churn.
    func applyWarmedTitles(_ warmed: [(url: URL, title: String, mtime: Date)]) {
        var updated = titleCache
        var changed = false
        for entry in warmed {
            let currentMtime = try? entry.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            guard currentMtime == entry.mtime else { continue }
            let cached = updated[entry.url]
            if cached?.title == entry.title, cached?.modificationDate == entry.mtime { continue }
            updated[entry.url] = CachedTitle(title: entry.title, modificationDate: entry.mtime)
            changed = true
        }
        if changed { titleCache = updated }
    }

    // MARK: - Link cache (persistent, per-install)

    private static func loadPersistedLinkCache(key: String) -> [String: LinkCacheEntry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: LinkCacheEntry].self, from: data)
        else { return [:] }
        return decoded
    }

    /// The in-memory mirror of the persisted link cache. Read by
    /// `buildLinkGraph` to reuse unchanged pages.
    func cachedLinkEntries() -> [String: LinkCacheEntry] { linkCacheEntries }

    /// Replace the cache (memory + `UserDefaults`) after a full build. The new
    /// map is the current page set, so pages that vanished drop out.
    func storeLinkEntries(_ entries: [String: LinkCacheEntry]) {
        linkCacheEntries = entries
        rebuildPageIDIndex(from: entries)
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: linkCacheDefaultsKey)
        }
    }

    /// Seed the title cache from the persisted link cache so titles are correct
    /// on launch with no content reads. The entries-merge mtime guard rejects
    /// any entry whose page changed since it was cached, so a stale seed
    /// self-heals on the next build.
    private func seedTitleCacheFromLinkCache() {
        guard !linkCacheEntries.isEmpty else { return }
        var seeded = titleCache
        for (pageID, entry) in linkCacheEntries {
            seeded[url(for: pageID)] = CachedTitle(title: entry.title, modificationDate: entry.mtime)
        }
        titleCache = seeded
    }

    // MARK: - Link graph

    /// Cached graph if present; otherwise kick a deduped off-main build whose
    /// result lands on the tracked `linkGraph`. Call this from a SwiftUI body so
    /// the `linkGraph` read registers Observation and the surface re-renders when
    /// the build completes. Returns nil until the first build lands — a nil graph
    /// just means "no badges/backlinks yet," never blocks the surface.
    @discardableResult
    func linkGraphOrBuild() -> LinkGraph? {
        if let linkGraph { return linkGraph }
        guard !isBuildingLinkGraph else { return nil }
        isBuildingLinkGraph = true
        let generation = linkGraphBuildGeneration
        linkGraphBuildTask = Task { [weak self] in
            guard let self else { return }
            let built = await self.buildLinkGraph()
            guard !Task.isCancelled,
                  self.linkGraphBuildGeneration == generation else { return }
            self.isBuildingLinkGraph = false
            self.linkGraphBuildTask = nil
            self.linkGraph = built
        }
        return nil
    }

    /// Drop the cached graph, cancel any in-flight build, and bump the
    /// generation so stale work cannot publish. Called on `rescan()`.
    private func invalidateLinkGraph() {
        linkGraphBuildTask?.cancel()
        linkGraphBuildTask = nil
        isBuildingLinkGraph = false
        linkGraphBuildGeneration += 1
        linkGraph = nil
    }

    /// Patch the cached graph for a just-saved page from its in-memory blocks —
    /// no disk read, no full rebuild. Skips when the graph isn't built yet (a
    /// lazy build picks up the new state) or when the page's outbound links are
    /// unchanged (the common keystroke case). Called from `postSaveBookkeeping`.
    private func refreshLinkGraph(forSavedURL url: URL, children: [Block]) {
        guard let current = linkGraph else { return }
        let rel = relativePath(of: url)
        let classify: @Sendable (URL, URL) -> String? = { [self] url, base in
            self.pagePath(for: url, relativeTo: base)
        }
        let classifySubpage: @Sendable (String) -> String? = { [self] dest in
            self.resolveSubpageTarget(dest)
        }
        let targets = outboundLinks(in: children, pageURL: url, classify: classify, classifySubpage: classifySubpage)
            .intersection(current.allPageIDs)
        guard targets != (current.outbound[rel] ?? []) else { return }
        linkGraph = current.replacingOutbound(of: rel, with: targets, home: homeRelativePath)
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
        // Sync stamps legitimately differ by device even when the markdown
        // body is identical. Classifying the whole envelope makes a peer's
        // frontier update look like an external content edit and can replace
        // the live editor tree with the same (or stale) body. Compare only
        // user-visible block content; the journal handles frontier changes.
        let body = ClamshellPageEnvelope.parse(text).body
        return SHA256.hash(data: Data(body.utf8)).prefix(8)
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
    // Save model is commit-time atomic: every commit applies its log
    // entries to the recovery log and writes the .md file as one coordinator
    // generation, log strictly before file. `PageSession.enqueueEditorChanges(_:)`
    // installs editor generations synchronously; internal `commit(_:to:)`
    // awaits coordinator durability. Concurrent commits for the same URL run
    // in order through its `PageCoordinator`; rapid commits whose predecessor
    // hasn't started yet coalesce into one serialize + one .md write. No
    // debounce or separate per-op log task: every `Document.transaction` (typing via
    // `commitLiveText`, structural via `mutate(_:_:)`, undo, redo) emits
    // its pre→post diff through `Document.didCommitTransaction` → host
    // bridge → `PageSession.enqueueEditorChanges(_:)`.
    //
    // Heavy lifting hops off MainActor: serialize + `NSFileCoordinator`
    // write run on a detached task at `.userInitiated` so they don't
    // contend with the UI work the edit burst is driving. See `save(_:)`.

    /// Persist a commit for `doc`, awaiting durability end-to-end: log
    /// entries (if any) are applied to the recovery log strictly before
    /// the `.md` is serialized and written. Concurrent commits for the
    /// same URL run in order; the `await` returns only after this
    /// commit's bytes are on disk, and errors propagate.
    func commit(_ commit: Commit, to doc: Document, at url: URL) async throws {
        try await coordinator(for: url).enqueue(commit, for: doc).value
    }

    func coordinator(for url: URL) -> PageCoordinator {
        let key = url.standardizedFileURL
        if let existing = pageCoordinators[key] { return existing }
        let coordinator = PageCoordinator(owner: self, url: key)
        pageCoordinators[key] = coordinator
        return coordinator
    }

    func coordinator(owning document: Document) -> PageCoordinator? {
        pageCoordinators.values.first { $0.document === document }
    }

    func removeCoordinatorIfIdle(_ coordinator: PageCoordinator) {
        let key = coordinator.url.standardizedFileURL
        guard pageCoordinators[key] === coordinator,
              !coordinator.hasEditorSubscribers,
              !coordinator.hasPendingWrite else { return }
        pageCoordinators.removeValue(forKey: key)
    }

    /// The coordinator's one durable write effect. Keeping log application
    /// and Markdown serialization in the same awaited body makes the
    /// log-before-file invariant structural.
    @discardableResult
    func persist(
        url: URL,
        children: [Block],
        previousModificationDate: Date?,
        logEntries: [Patch.Entry]
    ) async throws -> Date? {
        let rel = relativePath(of: url)
        if !logEntries.isEmpty {
            try await log.apply(Patch(entries: logEntries), to: rel)
        }
        let frontier = await log.frontierForStampAfterOwnSave(page: rel)
        _ = try await save(children: children, at: url, logFrontier: frontier)
        let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        postSaveBookkeeping(
            url: url,
            children: children,
            modificationDate: mtime ?? previousModificationDate
        )
        return mtime
    }

    func rememberEnvelope(_ parsed: ClamshellPageEnvelope.Parsed, for url: URL) {
        let key = url.standardizedFileURL
        pageFrontmatter[key] = parsed.frontmatterLines
        pageStampTrust[key] = parsed.stampTrust
        registerPageID(parsed.pageID, forRel: relativePath(of: key))
    }

    private func frontmatterForSave(at url: URL) -> [String]? {
        pageFrontmatter[url.standardizedFileURL] ?? nil
    }

    private func currentStampTrustForPage(at url: URL) -> ClamshellPageEnvelope.StampTrust? {
        let key = url.standardizedFileURL
        guard let raw = try? files.read(key) else {
            pageStampTrust.removeValue(forKey: key)
            return nil
        }
        let parsed = ClamshellPageEnvelope.parse(raw)
        rememberEnvelope(parsed, for: key)
        return parsed.stampTrust
    }

    private func trustedFrontierForPage(at url: URL) -> [String: UInt64]? {
        currentStampTrustForPage(at: url)?.trustedFrontier
    }

    private func trustedFrontierForPage(relativePath: String) -> [String: UInt64]? {
        let url = self.url(for: relativePath).standardizedFileURL
        return trustedFrontierForPage(at: url)
    }

    func reconcileInputs(at url: URL) -> (trustedFrontier: [String: UInt64]?, allowJournalMutations: Bool) {
        switch currentStampTrustForPage(at: url) {
        case .trusted(let frontier):
            return (frontier, true)
        case .invalid:
            return (nil, false)
        case .some(.none), nil:
            return (nil, true)
        }
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
    private func save(
        children: [Block],
        at url: URL,
        logFrontier: [String: UInt64]
    ) async throws -> String {
        let titleMap = buildSubpageTitleMap(referencedBy: children)
        let files = self.files
        var frontmatter = frontmatterForSave(at: url)
        // Legacy pages gain their durable page ID on first save; every
        // later save carries the line through untouched.
        if ClamshellPageEnvelope.pageID(in: frontmatter) == nil {
            frontmatter = ClamshellPageEnvelope.addingPageID(mintUniquePageID(), to: frontmatter)
            pageFrontmatter[url.standardizedFileURL] = frontmatter
        }

        let newText = try await Task.detached(priority: .userInitiated) {
            let text = ClamshellPageEnvelope.serialize(
                blocks: children,
                existingFrontmatterLines: frontmatter,
                logFrontier: logFrontier,
                resolvingSubpageTitle: { rel in titleMap[rel] }
            )
            try files.write(text, to: url)
            return text
        }.value

        recordDiskContent(newText, at: url)
        rememberEnvelope(ClamshellPageEnvelope.parse(newText), for: url)
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
                    if map[pageID] == nil,
                       let rel = resolveSubpageTarget(pageID),
                       let title = entry(at: rel)?.title {
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
    /// workspace if the entries surface needs it. Runs at the end of
    /// every successfully persisted coordinator generation.
    @MainActor
    private func postSaveBookkeeping(url: URL, children: [Block], modificationDate: Date?) {
        let title = Document.deriveTitle(
            from: children,
            fallback: url.deletingPathExtension().lastPathComponent
        )
        let titleChanged = refreshTitleCache(url: url, title: title, modificationDate: modificationDate)
        // Refresh the reconcile watermark so this save (new `.md` mtime,
        // grown own-log) doesn't trigger a useless refold on next open.
        // We logged the records via `apply(_:to:)` and just wrote the
        // `.md` — the journal and the doc are consistent by construction.
        let rel = relativePath(of: url)
        let mtime = modificationDate
        Task { [log, rel, mtime] in
            await log.recordOwnSave(page: rel, mdMtime: mtime)
        }
        let indexedPage = SearchIndexedPage(
            relativePath: rel,
            modificationDate: mtime ?? .distantPast,
            title: title,
            body: searchableText(in: children)
        )
        Task { [searchIndex] in await searchIndex.upsert(indexedPage) }
        if titleChanged {
            // Title overlay changed → entries' surface mtime is now stale.
            // A scan picks up the new mtime for this URL; subscribers
            // re-render through the entries computed.
            try? rescan()
        }
        // Patch the link graph from the saved page's in-memory blocks (cheap,
        // no disk read). When `titleChanged` already invalidated via rescan,
        // this no-ops; otherwise it keeps backlinks/orphans current after a
        // link edit without a full re-read.
        refreshLinkGraph(forSavedURL: url, children: children)
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
        let blocks: [Block]
        if let initialContent {
            blocks = [.heading(level: .h1, text: AttributedString(title), children: initialContent)]
        } else {
            blocks = [.heading(level: .h1, text: AttributedString(title))]
        }
        let body = ClamshellPageEnvelope.serialize(
            blocks: blocks,
            existingFrontmatterLines: ClamshellPageEnvelope.addingPageID(mintUniquePageID(), to: nil),
            logFrontier: [:]
        )
        // Coordinated write like every other .md — an uncoordinated write
        // can race iCloud sync on cloud-hosted workspaces.
        try files.write(body, to: url)
        rememberEnvelope(ClamshellPageEnvelope.parse(body), for: url)
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        titleCache[url] = CachedTitle(title: title, modificationDate: mtime)
        let indexedPage = SearchIndexedPage(
            relativePath: path,
            modificationDate: mtime ?? .distantPast,
            title: title,
            body: searchableText(in: blocks)
        )
        Task { [searchIndex] in await searchIndex.upsert(indexedPage) }
        try? rescan()
        return path
    }

    /// Mint a page ID no live page already claims. Collisions are ~1 in 2
    /// billion per pair, but the index check is free.
    func mintUniquePageID() -> String {
        for _ in 0..<8 {
            let id = ClamshellPageEnvelope.mintPageID()
            if pageIDIndexHit(id) == nil { return id }
        }
        return ClamshellPageEnvelope.mintPageID()
    }

    /// Workspace-relative slug for a page titled `title`, suffixed with
    /// `-2`, `-3`, etc. to avoid collision with existing files.
    ///
    /// `excludingCurrent` is the renaming page's own relative path: a
    /// candidate equal to it (case-insensitively — APFS is case-insensitive
    /// by default) is returned directly rather than treated as a collision,
    /// which covers case-only renames and pages already sitting on a `-N`
    /// disambiguated name. The candidate keeps `excludingCurrent`'s
    /// directory so renaming never moves a page between folders.
    func availablePagePath(for title: String, excludingCurrent currentRel: String? = nil) -> String {
        let stem = Clamshell.slugStem(for: title)
        let dir = currentRel.flatMap { rel -> String? in
            guard let slash = rel.lastIndex(of: "/") else { return nil }
            return String(rel[...slash])
        } ?? ""

        var candidate = dir + stem + ".md"
        var suffix = 2
        while FileManager.default.fileExists(atPath: root.appendingPathComponent(candidate).path) {
            if let currentRel, candidate.caseInsensitiveCompare(currentRel) == .orderedSame {
                return candidate
            }
            candidate = "\(dir)\(stem)-\(suffix).md"
            suffix += 1
        }
        return candidate
    }

    /// The filename stem a title slugifies to. Shared by `availablePagePath`
    /// and `filenameMatchesTitle` so the two can never drift. Emoji are
    /// omitted when the title has other slug-worthy text; an emoji-only title
    /// is transliterated to a Unicode name (🎉 → `party-popper`) rather
    /// than falling back to `Untitled`.
    nonisolated static func slugStem(for title: String) -> String {
        let textOnly = String(title.filter { !isEmojiCluster($0) })
        let textSlug = slugCharacters(in: textOnly)
        if !textSlug.isEmpty { return textSlug }
        let emojiSlug = slugCharacters(in: expandingEmoji(in: title))
        return emojiSlug.isEmpty ? "Untitled" : emojiSlug
    }

    private nonisolated static func slugCharacters(in value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let chars = value.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        return String(chars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
    }

    /// Replace each emoji grapheme cluster with its lowercased Unicode
    /// name(s), leaving everything else untouched. The name transform
    /// (`.toUnicodeName`, ICU "Any-Name") also renames accented Latin
    /// letters, so it's applied *only* to clusters detected as emoji —
    /// otherwise `café` would expand to `latin small letter e with acute`.
    private nonisolated static func expandingEmoji(in title: String) -> String {
        var out = ""
        for cluster in title {
            if let name = emojiName(cluster) {
                out += " \(name) "
            } else {
                out.append(cluster)
            }
        }
        return out
    }

    private nonisolated static func emojiName(_ cluster: Character) -> String? {
        // ASCII digits / `#` / `*` report `isEmoji` (they're keycap bases);
        // gate on emoji-presentation or a non-ASCII emoji scalar so those
        // and plain text are left alone.
        guard isEmojiCluster(cluster),
              let named = String(cluster).applyingTransform(.toUnicodeName, reverse: false) else {
            return nil
        }
        // `named` is one or more `\N{UNICODE NAME}` groups. Keep the
        // human-meaningful ones; drop combining scaffolding (skin-tone
        // modifiers, joiners, variation selectors) and flag halves.
        var words: [String] = []
        var rest = Substring(named)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            let name = rest[rest.index(after: open)..<close]
            let upper = name.uppercased()
            let isScaffolding = upper.contains("VARIATION SELECTOR")
                || upper.contains("ZERO WIDTH")
                || upper.contains("EMOJI MODIFIER")
                || upper.contains("REGIONAL INDICATOR")
            if !isScaffolding {
                words.append(name.lowercased())
            }
            rest = rest[rest.index(after: close)...]
        }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    private nonisolated static func isEmojiCluster(_ cluster: Character) -> Bool {
        let scalars = cluster.unicodeScalars
        if scalars.contains(where: {
            $0.properties.isEmojiPresentation || ($0.properties.isEmoji && !$0.isASCII)
        }) {
            return true
        }

        // Keycaps are an ASCII emoji base followed by a variation selector
        // and/or the combining enclosing keycap scalar.
        return scalars.contains { $0.value == 0xFE0F || $0.value == 0x20E3 }
            && scalars.contains { $0.properties.isEmoji }
    }

    /// True when the page's filename is already the title's slug — either
    /// exactly or with a `-N` disambiguation suffix (a page living at
    /// `Title-2.md` because `Title.md` was taken should not prompt for a
    /// rename it can't have). Case-insensitive, matching the filesystem.
    nonisolated static func filenameMatchesTitle(relativePath: String, title: String) -> Bool {
        guard relativePath.hasSuffix(".md") else { return false }
        let filename = relativePath.split(separator: "/").last.map(String.init) ?? relativePath
        let stem = String(filename.dropLast(3))
        let slug = slugStem(for: title)
        if stem.caseInsensitiveCompare(slug) == .orderedSame { return true }
        guard stem.count > slug.count + 1,
              stem.lowercased().hasPrefix(slug.lowercased() + "-") else { return false }
        return stem.dropFirst(slug.count + 1).allSatisfy(\.isNumber)
    }

    // MARK: - Rename

    enum RenameError: Error, Equatable {
        /// The page still has an attached editor session (another window).
        /// The caller must close it before renaming.
        case pageOpenElsewhere
    }

    struct RenameResult: Equatable, Sendable {
        let oldRelativePath: String
        let newRelativePath: String
    }

    /// Rename the page at `url` so its filename matches `title`'s slug.
    /// O(1) by design: the file, its `.history/` dir, and the in-memory
    /// bookkeeping move; **no inbound links are rewritten**. Links carrying
    /// the page's ID fragment resolve to the new path immediately through
    /// `resolve(pathRel:id:)`, and each referencing page's bytes converge
    /// via `healLinks` the next time it's open and quiet.
    ///
    /// The caller must have closed any editor session on the page first
    /// (mirroring `moveToTrash`) — a live session's Document.url is
    /// immutable, so the page reopens at the new URL.
    @discardableResult
    func renamePage(at url: URL, toMatchTitle title: String) async throws -> RenameResult {
        let key = url.standardizedFileURL
        let oldRel = relativePath(of: key)
        if let coordinator = pageCoordinators[key] {
            guard !coordinator.hasEditorSubscribers else { throw RenameError.pageOpenElsewhere }
            try await coordinator.flush()
        }

        let newRel = availablePagePath(for: title, excludingCurrent: oldRel)
        guard newRel != oldRel else {
            return RenameResult(oldRelativePath: oldRel, newRelativePath: oldRel)
        }
        let newURL = self.url(for: newRel)
        let newKey = newURL.standardizedFileURL

        // The move is the first mutating step — a failure here leaves
        // nothing partial. Case-only renames go through a temp sibling
        // name; a direct case-only `moveItem` can fail on case-insensitive
        // APFS.
        if newRel.caseInsensitiveCompare(oldRel) == .orderedSame {
            let tmp = key.deletingLastPathComponent()
                .appendingPathComponent(".rename-tmp-\(UUID().uuidString).md")
            try FileManager.default.moveItem(at: key, to: tmp)
            try FileManager.default.moveItem(at: tmp, to: newURL)
        } else {
            try FileManager.default.moveItem(at: key, to: newURL)
        }

        // Awaited inline (unlike trash's fire-and-forget): anything that
        // reconciles at the new path immediately after needs the journal
        // and its watermark already there.
        do {
            try await log.move(fromPage: oldRel, toPage: newRel)
        } catch {
            Diag.log.error("log move (rename) failed from=\(oldRel, privacy: .public) to=\(newRel, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }

        // Content is byte-identical at the new path — move the bookkeeping,
        // don't forget it. (`moveItem` preserves mtime.)
        _ = titleCache.removeValue(forKey: key)
        if let history = contentHistory.removeValue(forKey: key) { contentHistory[newKey] = history }
        if let frontmatter = pageFrontmatter.removeValue(forKey: key) { pageFrontmatter[newKey] = frontmatter }
        if let trust = pageStampTrust.removeValue(forKey: key) { pageStampTrust[newKey] = trust }
        if let id = knownPageID(forRel: oldRel) { registerPageID(id, forRel: newRel) }
        if let entry = linkCacheEntries.removeValue(forKey: oldRel) {
            var entries = linkCacheEntries
            entries[newRel] = entry
            storeLinkEntries(entries)
        }
        await searchIndex.rename(from: oldRel, to: newRel)

        if homeRelativePath == oldRel {
            homeRelativePath = newRel
        }
        try? rescan()

        // A page can be renamed before its lazily-warmed title has entered
        // `titleCache`. Seed the destination from the title the caller just
        // confirmed, using the scan's timestamp representation so the cache
        // survives its next lookup and pickers immediately expose/search the
        // exact human title rather than the generated filename.
        let scannedMtime = entry(at: newRel)?.modificationDate
        titleCache[newKey] = CachedTitle(title: title, modificationDate: scannedMtime)
        return RenameResult(oldRelativePath: oldRel, newRelativePath: newRel)
    }

    // MARK: - Trash (soft-deleted pages)

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
        unregisterPageIDs(forRel: rel)
        Task { [searchIndex] in await searchIndex.remove(relativePath: rel) }
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
        if let restoredEntry = self.entry(at: restoredRel),
           let envelope = try? await readEnvelope(at: restoredURL) {
            let parsed = envelope.parsed
            await searchIndex.upsert(SearchIndexedPage(
                relativePath: restoredRel,
                modificationDate: restoredEntry.modificationDate,
                title: Document.deriveTitle(
                    from: parsed.blocks,
                    fallback: restoredURL.deletingPathExtension().lastPathComponent
                ),
                body: searchableText(in: parsed.blocks)
            ))
        }
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
            return await log.enumerate(page: rel, trustedFrontier: trustedFrontierForPage(relativePath: rel))
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
    /// One-shot, content-immutable writes — no need to go through a page coordinator.
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

@MainActor
extension Clamshell.Page {
    func setIcon(_ emoji: String) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Clamshell.AppendBlocksError.pageMissing(relativePath)
        }
        try owner.files.requireLocallyWritable(url)

        let coordinator = owner.coordinator(for: url)
        try await coordinator.withTransientDocument { document in
            let before = document.children
            var after = before
            if let titleIndex = after.firstIndex(where: { block in
                if case .heading(.h1, _) = block.kind { return true }
                return false
            }), case .heading(.h1, let titleText) = after[titleIndex].kind {
                let currentTitle = String(titleText.characters)
                after[titleIndex].kind = .heading(
                    level: .h1,
                    text: AttributedString(pageTitle(currentTitle, settingEmoji: emoji))
                )
            } else {
                let title = pageTitle(document.title, settingEmoji: emoji)
                after = [.heading(level: .h1, text: AttributedString(title), children: before)]
            }
            guard after != before else { return }
            // Reconciled: the common branch rewrites one H1's text in place and
            // every other block keeps its id, so an open editor keeps its undo
            // history. The no-H1 branch above reparents the whole body under a
            // new heading, which is not rebasable — that one degrades to a
            // wholesale replacement on its own.
            document.replaceChildrenReconciled(after)
            let changes = RecoveryChangeDiff.derive(pre: before, post: after)
            try await owner.commit(.fromEditorChanges(changes), to: document, at: url)
        }
    }

    func append(_ blocks: [Block]) async throws {
        guard !blocks.isEmpty else { throw Clamshell.AppendBlocksError.empty }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Clamshell.AppendBlocksError.pageMissing(relativePath)
        }
        try owner.files.requireLocallyWritable(url)

        let coordinator = owner.coordinator(for: url)
        try await coordinator.withTransientDocument { document in
            // Reconciled: a pure append. If this page is open in another window
            // its editor keeps selection, cursor, and undo — dropping the undo
            // stack of a document the user is working in because a *different*
            // window added a block to it is not acceptable.
            document.replaceChildrenReconciled(document.children + blocks)
            try await owner.commit(
                Commit(logEntries: Patch.adds(from: blocks).entries),
                to: document,
                at: url
            )
        }
    }

    /// Move this page to Trash only after an inlined copy in `parent` is
    /// durable. No-op if this page has already disappeared.
    func trashAfterInlining(into parent: Clamshell.PageSession) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try await parent.flush()
        _ = try owner.moveToTrash(at: url)
    }

    func cloudSyncSnapshot() -> Clamshell.CloudSyncSnapshot {
        owner.cloudSyncSnapshot(for: url)
    }

    func compactThisDeviceLog() async throws -> LogCompactionResult {
        let coordinator = owner.coordinator(for: url)
        return try await coordinator.withTransientDocument { _ in
            try await coordinator.flush()
            return try await owner.compactThisDeviceLog(for: coordinator)
        }
    }

    /// Merge unresolved iCloud alternates into this page's canonical document
    /// and return the number of block hashes salvaged.
    func resolveConflicts() async throws -> Int {
        let nsfvT = perfStart()
        let alternates = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
        perfEnd(nsfvT, "NSFileVersion.unresolved", "url=\(url.lastPathComponent) count=\(alternates.count)")
        guard !alternates.isEmpty else { return 0 }

        let coordinator = owner.coordinator(for: url)
        return try await coordinator.withTransientDocument { canonical in
            var alternateBlockLists: [[Block]] = []
            for version in alternates {
                guard let text = Clamshell.readCoordinated(version.url) else { continue }
                alternateBlockLists.append(ClamshellPageEnvelope.parse(text).blocks)
            }

            let intent = PatchEngine.intent(
                from: owner.log.readJournal(page: relativePath)
            )
            let result = PatchEngine.mergeConflict(
                survivor: canonical.children,
                alternates: alternateBlockLists,
                intent: intent
            )

            Diag.merge.log("resolve url=\(url.lastPathComponent, privacy: .public) alternates=\(alternates.count, privacy: .public) salvaged=\(result.salvagedHashes.count, privacy: .public)")

            guard !result.salvagedHashes.isEmpty else {
                Clamshell.markAlternatesResolved(alternates)
                return 0
            }

            canonical.replaceChildrenFromConflictResolution(result.merged)
            try await owner.commit(
                Commit(logEntries: Patch.observations(from: canonical.children).entries),
                to: canonical,
                at: url
            )

            Clamshell.markAlternatesResolved(alternates)
            return result.salvagedHashes.count
        }
    }
}
