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
public final class Clamshell {
    @ObservationIgnored nonisolated public let root: URL

    /// Path (relative to `root`) of the page designated as "home", or nil if unset.
    /// Persisted to `.clamshell.json` at the root; written atomically on every change.
    /// Cleared automatically when the home page is moved to trash.
    public var homeRelativePath: String? {
        didSet {
            guard oldValue != homeRelativePath else { return }
            persistMetadata()
        }
    }

    /// Scope for `listLostBlocks(filter:)`.
    public enum LostBlocksFilter: Sendable {
        /// Every page in the workspace, including trashed ones.
        case all
        /// One specific page only.
        case page(relativePath: String)
    }

    @ObservationIgnored nonisolated let files: FileStore
    @ObservationIgnored nonisolated let trash: TrashStore
    @ObservationIgnored nonisolated let log: RecoveryLog

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
    /// falls back to the filename-derived title).
    private var titleCache: [URL: CachedTitle] = [:]
    @ObservationIgnored private var titleRefreshTask: Task<Void, Never>?

    /// Per-URL save chain head. Each `documentDidChange` spawns a Task that
    /// awaits the previous chain entry for that URL before running its own
    /// log apply + .md write, so concurrent commits land in order. Absent ⇒
    /// no work pending (i.e. `isQuiescent(at:)`).
    @ObservationIgnored private var saveChain: [URL: Task<Void, Never>] = [:]

    public init(root: URL) {
        self.root = root
        let files = FileStore()
        self.files = files
        self.trash = TrashStore(workspaceRoot: root, store: files)
        self.log = RecoveryLog(workspaceRoot: root, store: files)

        let metadataURL = Clamshell.metadataURL(forRoot: root)
        if let metadata = Clamshell.readMetadata(at: metadataURL) {
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
        if FileManager.default.fileExists(atPath: blocksDir.path) {
            try? FileManager.default.removeItem(at: blocksDir)
        }
    }

    // MARK: - Path conversions

    nonisolated public func relativePath(of url: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        if filePath.hasPrefix(rootPath + "/") {
            return String(filePath.dropFirst(rootPath.count + 1))
        }
        return url.lastPathComponent
    }

    nonisolated public func url(for relativePath: String) -> URL {
        root.appendingPathComponent(relativePath).standardizedFileURL
    }

    // MARK: - Pages: read

    /// Page list with the live title overlay applied. Computed from
    /// the raw scan result and the title cache so the two never drift —
    /// mutating either invalidates Observation subscribers automatically.
    /// SwiftUI views observe this directly; the scan runs eagerly on
    /// workspace open and rescans fire on page-set changes.
    public var entries: [WorkspaceEntry] {
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

    /// Walk the workspace folder and refresh `entries`. Kicks a background
    /// title-refresh pass for any rows whose mtime changed since the
    /// title cache last saw them. Idempotent — safe to call on any
    /// page-set change (create / trash / restore / external add).
    @discardableResult
    public func rescan() throws -> [WorkspaceEntry] {
        let result = try files.scan(workspaceRoot: root)
        scanResult = result
        refreshTitlesInBackground(for: result)
        return result
    }

    /// Live title for `relativePath` if the cache has one matching the
    /// page's current mtime; nil otherwise. The serializer uses this for
    /// subpage rows so the on-disk markdown stays in sync with the title
    /// the user sees in other windows.
    public func title(for relativePath: String) -> String? {
        entries.first { $0.relativePath == relativePath }?.title
    }

    /// Existence + cached title for a `*.md` page id. `.missing` when the
    /// file isn't on disk; `.present(title: nil)` when the title cache
    /// hasn't been warmed for the URL yet.
    public func lookupPage(_ relativePath: String) -> PageLookup {
        guard relativePath.hasSuffix(".md") else { return .missing }
        let url = self.url(for: relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        if let cached = titleCache[url], cached.modificationDate == mtime {
            return .present(title: cached.title)
        }
        return .present(title: nil)
    }

    /// Filter + rank `entries` for any page-picker surface (search sheet,
    /// @-mention popover, move-to, jump-to). Title-prefix beats
    /// title-substring beats path-substring; mtime breaks ties. Empty
    /// query returns the full pool in mtime-descending order.
    /// `excluding` omits a specific URL — typically the currently-open
    /// document (move-to / mention / jump-to). Pass nil to include it.
    public func pages(matching query: String, excluding: URL? = nil) -> [MentionItem] {
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

    @MainActor
    public func loadDocument(at url: URL) throws -> Document {
        let raw = try files.read(url)
        let blocks = BlockParser.parse(raw)
        let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        recordDiskContent(raw, at: url)
        return Document(url: url, children: blocks, modificationDate: mtime)
    }

    // MARK: - Title cache

    /// Update the cache with this document's title + mtime. Returns true
    /// when the cached title for the URL actually changed (so the host
    /// can decide whether to refresh windowed title displays). Called
    /// internally after every save; external callers don't need it.
    @discardableResult
    func refreshTitleCache(from document: Document) -> Bool {
        let previous = titleCache[document.url]
        let titleChanged = previous?.title != document.title
        if titleChanged || previous?.modificationDate != document.modificationDate {
            titleCache[document.url] = CachedTitle(title: document.title, modificationDate: document.modificationDate)
        }
        return titleChanged
    }

    private func refreshTitlesInBackground(for scanned: [WorkspaceEntry]) {
        let stale = scanned.filter { entry in
            titleCache[entry.url]?.modificationDate != entry.modificationDate
        }
        guard !stale.isEmpty else { return }
        titleRefreshTask?.cancel()
        // `loadDocumentTitle` constructs a transient `Document` (MainActor)
        // before deriving the title; the lookup itself stays cheap (no parse
        // beyond the leading H1).
        titleRefreshTask = Task { @MainActor [weak self, stale] in
            var refreshed: [URL: CachedTitle] = [:]
            for entry in stale {
                guard !Task.isCancelled else { return }
                if let title = try? self?.files.loadDocumentTitle(at: entry.url) {
                    refreshed[entry.url] = CachedTitle(title: title, modificationDate: entry.modificationDate)
                }
            }
            guard !Task.isCancelled else { return }
            self?.applyRefreshedTitles(refreshed)
        }
    }

    private func applyRefreshedTitles(_ refreshed: [URL: CachedTitle]) {
        guard !refreshed.isEmpty else { return }
        let truly = refreshed.filter { url, new in
            let prev = titleCache[url]
            return prev?.title != new.title || prev?.modificationDate != new.modificationDate
        }
        guard !truly.isEmpty else { return }
        titleCache.merge(truly) { _, new in new }
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
    // Save model is commit-time atomic: every `documentDidChange(ops:in:)`
    // applies its op batch to the recovery log and writes the .md file as
    // one awaited sequence, log strictly before file. Concurrent calls for
    // the same URL are chained on `saveChain[url]` — each spawned Task
    // awaits the previous before its own log + .md write, so a fast burst
    // of commits (typing → focus blur → navigation) lands in order. No
    // debounce, no separate per-op log task: every `Document.transaction`
    // (typing via `commitLiveText`, structural via `mutate(_:_:)`, undo,
    // redo) emits its pre→post diff through
    // `DocumentUndoController.onCommit` → here.

    /// Editor mutated `doc` and produced these `ops`. Applies the patch
    /// to the recovery log (when non-empty), then serializes the current
    /// `.md` and writes it. Calls for the same URL are chained — the
    /// spawned Task awaits any pending chain head for that URL before its
    /// own work, so rapid-fire commits land in order. Sync entry so the
    /// editor can call it from the mutation-commit thread without
    /// ceremony.
    public func documentDidChange(ops: [EditorOp], in doc: Document) {
        let patch: Patch = ops.isEmpty ? .empty : Patch.from(ops: ops)
        enqueueSave(doc, patch: patch)
    }

    /// Clamshell-internal "save this doc": chains a `.md` write onto the
    /// per-URL save queue with no log apply. Used by paths that mutated
    /// the live doc in place without going through the editor —
    /// reconcile's auto-restore splice, the manual restore splice,
    /// anything that already wrote its own log entries directly. Distinct
    /// name (vs. `documentDidChange`) because no editor actually changed
    /// anything; Clamshell did, and the journal is already current.
    func scheduleSave(_ doc: Document) {
        enqueueSave(doc, patch: .empty)
    }

    /// Await durability of any writes already in flight for `doc`. Does
    /// not trigger a save — that's what `documentDidChange` is for. Used
    /// on navigation / blur / scenePhase / close to make sure the bytes
    /// for the just-fired commit are on disk before the editor unmounts.
    @discardableResult
    public func flush(_ doc: Document) async -> Bool {
        guard let pending = saveChain[doc.url] else { return true }
        await pending.value
        saveChain.removeValue(forKey: doc.url)
        return true
    }

    /// True when no work is pending for `url`. The engine's reconcile and
    /// presenter paths gate on this — they assume
    /// `doc.children == parsed(.md)`, which is only true on a settled page.
    func isQuiescent(at url: URL) -> Bool {
        saveChain[url] == nil
    }

    private func enqueueSave(_ doc: Document, patch: Patch) {
        let url = doc.url
        let rel = relativePath(of: url)
        let previous = saveChain[url]
        let task = Task<Void, Never> { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                if !patch.isEmpty {
                    try await self.log.apply(patch, to: rel)
                }
                _ = try self.save(doc)
                self.postSaveBookkeeping(doc)
            } catch {
                Diag.log.error("save failed url=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
        saveChain[url] = task
    }

    /// The actual on-disk write. Serializes `document.children` and writes
    /// the bytes through `FileStore` (which wraps `NSFileCoordinator` to
    /// avoid racing with iCloud sync). Does NOT touch the recovery log —
    /// callers that own the log durability invariant (chain tasks,
    /// `writeClosedPage`, `append(_:toPage:)`) apply log records first,
    /// then call this.
    @MainActor
    @discardableResult
    private func save(_ document: Document) throws -> String {
        let newText = BlockSerializer.serialize(document.children, resolvingSubpageTitle: { [weak self] rel in self?.title(for: rel) })
        let url = document.url
        try files.write(newText, to: url)
        recordDiskContent(newText, at: url)
        return newText
    }

    /// Apply `patch` to the recovery log, then persist `document` to disk.
    /// Awaited end-to-end so log lands strictly before file — a crash
    /// anywhere leaves the log at-or-ahead of disk and the next reconcile
    /// heals. The closed-page sibling of `documentDidChange`: used when
    /// there's no live editor session (no `saveChain` entry to enqueue
    /// against), so the caller can await durability directly. Used by
    /// conflict merge and closed-page manual restore. Editor mutations go
    /// through `documentDidChange`; the sync append-onto-subpage path goes
    /// through `append(_:toPage:)`.
    ///
    /// Folds in the post-save bookkeeping (mtime refresh, title cache)
    /// so closed-doc paths get the same hygiene as the editor-driven
    /// save path.
    @MainActor
    func writeClosedPage(_ document: Document, patch: Patch) async throws {
        let url = document.url
        if !patch.isEmpty {
            try await log.apply(patch, to: relativePath(of: url))
        }
        _ = try save(document)
        postSaveBookkeeping(document)
    }

    /// Append `blocks` to the end of `relativePath`. Logs the appended
    /// blocks, then writes the file — the at-or-ahead invariant holds
    /// across crashes. Used by the editor's drop-on-subpage path via the
    /// async `EditorHost.onAppendToSubpage`.
    ///
    /// Returns the loaded-and-mutated `Document` so callers can splice
    /// the appended content into any open window of the same URL.
    @MainActor
    @discardableResult
    public func append(_ blocks: [Block], toPage relativePath: String) async throws -> Document {
        let url = self.url(for: relativePath)
        let doc = try loadDocument(at: url)
        doc.transaction(name: "Append to subpage") { d in
            d.insertSubtrees(blocks, at: DropPath(parent: nil, position: d.children.count))
        }
        try await log.apply(Patch.adds(from: blocks), to: relativePath)
        let newText = BlockSerializer.serialize(doc.children, resolvingSubpageTitle: { [weak self] rel in self?.title(for: rel) })
        try files.write(newText, to: url)
        recordDiskContent(newText, at: url)
        postSaveBookkeeping(doc)
        return doc
    }

    /// Post-save hygiene: refresh the document's mtime from disk, update
    /// the title cache, and rescan the workspace if any of those changed
    /// the entries surface. Called from every successful save path (chain
    /// task via `documentDidChange` / `scheduleSave`,
    /// `writeClosedPage(_:patch:)`, `append(_:toPage:)`).
    @MainActor
    func postSaveBookkeeping(_ document: Document) {
        document.modificationDate = (try? document.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let titleChanged = refreshTitleCache(from: document)
        if titleChanged {
            // Title overlay changed → entries' surface mtime is now stale.
            // A scan picks up the new mtime for this URL; subscribers
            // re-render through the entries computed.
            _ = try? rescan()
        }
    }


    static func atomicHashes(of blocks: [Block]) -> Set<String> {
        var out: Set<String> = []
        collect(blocks, into: &out)
        return out
    }

    private static func collect(_ blocks: [Block], into out: inout Set<String>) {
        for block in blocks {
            out.insert(block.atomicHash)
            collect(block.children, into: &out)
        }
    }

    // MARK: - iCloud conflict resolution

    /// Outcome of a conflict-resolution pass. `salvaged` counts block-hashes
    /// pulled in from alternates that weren't already in the survivor;
    /// `liveDocumentMutated` is true exactly when the live `Document` passed
    /// in was rewritten in place — the caller's signal to reseed mtime, the
    /// disk-content history, the title cache, and to show a banner.
    public struct ConflictResolution: Equatable, Sendable {
        public let salvaged: Int
        public let liveDocumentMutated: Bool
        public static let none = ConflictResolution(salvaged: 0, liveDocumentMutated: false)
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
    public func resolveConflictVersions(
        at url: URL,
        againstLive doc: Document? = nil
    ) async throws -> ConflictResolution {
        let alternates = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
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
        try await writeClosedPage(merged, patch: Patch.adds(from: merged.children))

        let mutated: Bool
        if let doc {
            doc.replaceChildren(result.merged)
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

    /// Creates a new page with `# title` followed by the serialized blocks
    /// (or just the title if `blocks` is nil). Returns the workspace-relative
    /// path of the created page.
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
    public func createPage(
        title: String,
        requestedPath: String?,
        blocks: [Block]?
    ) throws -> String {
        let path = requestedPath ?? availablePagePath(for: title)
        let url = self.url(for: path)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: url.path) else { return path }
        let body: String
        if let blocks {
            body = "# \(title)\n\n" + BlockSerializer.serialize(blocks)
        } else {
            body = "# \(title)\n"
        }
        try body.write(to: url, atomically: true, encoding: .utf8)
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        titleCache[url] = CachedTitle(title: title, modificationDate: mtime)
        _ = try? rescan()
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

    /// Move a page to `Trash/`. If the page is the current home page, also clears
    /// `homeRelativePath` (the home pointer can't reference a trashed page).
    /// The page's recovery log dir travels with it so restoration brings the
    /// per-block log entries back too.
    @discardableResult
    public func moveToTrash(at url: URL) throws -> String {
        let rel = relativePath(of: url)
        let result = try files.moveToTrash(relativePath: rel, workspaceRoot: root)
        if homeRelativePath == rel {
            homeRelativePath = nil
        }
        forgetDiskContent(at: url)
        forgetTitle(at: url)
        _ = try? rescan()
        Task { [log, rel, result] in
            do {
                try await log.move(fromPage: rel, toPage: result)
            } catch {
                Diag.log.error("log move (trash) failed from=\(rel, privacy: .public) to=\(result, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
        return result
    }

    nonisolated public func listTrashedPages() async throws -> [TrashEntry] {
        try await trash.listEntries()
    }

    @discardableResult
    public func restorePage(_ entry: TrashEntry) async throws -> URL {
        let restoredURL = try await trash.restorePage(entry)
        let restoredRel = relativePath(of: restoredURL)
        do {
            try await log.move(fromPage: entry.trashRelativePath, toPage: restoredRel)
        } catch {
            Diag.log.error("log move (restore) failed from=\(entry.trashRelativePath, privacy: .public) to=\(restoredRel, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
        _ = try? rescan()
        return restoredURL
    }

    // MARK: - Lost blocks (recovery-log-backed)

    /// Atomic blocks that were once recorded for a page but aren't in its
    /// live `.md` right now (and aren't tombstoned). Each entry arrives
    /// fully populated — JSONL gives us hash, parent hash, atomic
    /// markdown, and timestamp per line. Sorted by recordedAt descending.
    public func listLostBlocks(filter: LostBlocksFilter = .all) async -> [LostBlock] {
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
    public func listPurgedBlocks(
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
    nonisolated public func writeImage(_ image: PastedImage) throws -> String {
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
    nonisolated public func resolveImage(source: String) -> URL? {
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
