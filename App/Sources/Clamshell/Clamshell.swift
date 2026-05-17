import Foundation
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
public final class Clamshell {
    nonisolated public let root: URL

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

    nonisolated let files: FileStore
    nonisolated let saver: DocumentSaveCoordinator
    nonisolated let trash: TrashStore
    nonisolated let log: RecoveryLog

    /// Resolves a subpage's title given its relative path. Set once by
    /// the host so `documentDidChange` / `flush(_:)` can serialize without
    /// the host threading a resolver through every call site. Default
    /// returns nil (subpage rows fall back to their cached title).
    public var subpageTitleResolver: (String) -> String? = { _ in nil }

    /// Fired on the main actor after every successful save (debounced or
    /// via `flush(_:)`). Host wires per-doc bookkeeping here — modification
    /// date refresh, title cache, page rescan — without owning the
    /// debounce timer.
    public var didSave: ((Document) -> Void)?

    /// Per-URL pending save state. An entry exists while a debounce is
    /// armed or a save is in flight; cleared once the save completes and
    /// no new edits are pending. See `Clamshell+Saving.swift`.
    var pending: [URL: PendingSave] = [:]

    struct PendingSave {
        var debounceTask: Task<Void, Never>?
        /// The most recent Document passed to `documentDidChange`. Captured
        /// here so a later call (e.g. from a second window editing the same
        /// URL) replaces it before the debounce fires.
        var pendingDoc: Document
        var isSaving: Bool
        /// The most recent log-apply Task for this URL. The log actor
        /// serializes apply calls, so awaiting the latest task guarantees
        /// every prior batch's effects are durable on disk too. Both
        /// `fireScheduledSave` and `flush` await this before writing the
        /// `.md` so the log is always at or ahead of the file on disk.
        var latestLogTask: Task<Void, Error>?
    }

    public init(root: URL) {
        self.root = root
        let files = FileStore()
        self.files = files
        self.saver = DocumentSaveCoordinator(store: files)
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

    nonisolated public func scan() throws -> [WorkspaceEntry] {
        try files.scan(workspaceRoot: root)
    }

    @MainActor
    public func loadDocument(at url: URL) throws -> Document {
        let raw = try files.read(url)
        let blocks = BlockParser.parse(raw)
        let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        recordDiskContent(raw, at: url)
        return Document(url: url, children: blocks, modificationDate: mtime)
    }

    /// Load `url` and reconcile its parsed content against the journal in
    /// one step. Returns the Document the host should display (disk
    /// content with any lost-block subtrees spliced in) and a summary
    /// describing what changed. The log is updated atomically with
    /// observation lifts + unrestorable quarantines as one batched write,
    /// awaited before return so the log is at-or-ahead of the file on
    /// disk. If reconcile spliced any subtrees, a debounced save is
    /// scheduled because the doc now differs from disk.
    ///
    /// Intended for the open-doc path. The presenter-wakeup path (which
    /// must update an existing live Document in place to preserve editor
    /// state) still goes through `reconcileOpenDocumentAgainstLog` in the
    /// host.
    @MainActor
    public func loadAndReconcile(at url: URL) async throws -> (Document, PatchEngine.ReconcileSummary) {
        let raw = try files.read(url)
        let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        recordDiskContent(raw, at: url)

        let rel = relativePath(of: url)
        let journal = log.readJournal(page: rel)
        let (blocks, patch, summary) = PatchEngine.reconcileFromDisk(rawMarkdown: raw, journal: journal)

        if !patch.isEmpty {
            try await log.apply(patch, to: rel)
        }

        let doc = Document(url: url, children: blocks, modificationDate: mtime)
        if summary.didChange {
            // No ops — pure structural restore; the file is now stale and
            // needs a save. `documentDidChange` with empty ops just (re)arms
            // the debounce without writing to the log.
            documentDidChange(ops: [], in: doc)
        }
        return (doc, summary)
    }

    /// Read the raw bytes on disk without parsing — used by the file
    /// presenter to compare against the open document's snapshot.
    nonisolated public func readRawText(at url: URL) throws -> String {
        try files.read(url)
    }

    // MARK: - Disk-content classification (iCloud-stomp / echo defense)

    /// Ring buffer of recent on-disk content hashes per URL. Seeded by every
    /// load/save/write that goes through Clamshell; consulted by
    /// `classifyDiskContent` so the presenter callback can distinguish
    /// "our own write echoed back" / "iCloud rolled us back" / "an external
    /// editor changed the file".
    private var contentHistory: [URL: [Int]] = [:]
    private static let historyDepth = 5

    private func recordDiskContent(_ text: String, at url: URL) {
        var history = contentHistory[url] ?? []
        let hash = text.hashValue
        if history.first == hash { return }
        history.insert(hash, at: 0)
        if history.count > Self.historyDepth { history.removeLast(history.count - Self.historyDepth) }
        contentHistory[url] = history
    }

    public enum DiskClassification: Equatable, Sendable {
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
    public func classifyDiskContent(at url: URL, expectingModificationDate: Date? = nil) -> DiskClassification {
        if let expected = expectingModificationDate {
            let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if mtime == expected { return .unchanged }
        }
        guard let text = try? files.read(url) else { return .unreadable }
        let hash = text.hashValue
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

    @MainActor
    public func loadDocumentTitle(at url: URL) throws -> String {
        try files.loadDocumentTitle(at: url)
    }

    // MARK: - Pages: write

    /// Coalesced async save (autosave path). Document is `@MainActor`-isolated,
    /// so we serialize on the calling actor (MainActor) before handing the
    /// String + URL across to the save coordinator. Called internally by
    /// `Clamshell+Saving.swift` — callers from outside use
    /// `documentDidChange` or `flush(_:)`.
    ///
    /// Does NOT touch the recovery log. Editor-driven structural changes
    /// already flowed through `EditorView.mutate(_:_:)` →
    /// `EditorHost.documentDidChange` → log append, so the journal is
    /// current by the time the debounce fires. Bare-md and external-editor
    /// cases are absorbed at reconcile time (`PatchEngine.unloggedObservations`
    /// → `appendObservations`).
    @MainActor
    @discardableResult
    func save(_ document: Document) async throws -> String {
        let newText = BlockSerializer.serialize(document.children, resolvingSubpageTitle: subpageTitleResolver)
        let url = document.url
        try await saver.save(url: url, contents: newText)
        recordDiskContent(newText, at: url)
        return newText
    }

    /// Synchronous full write for callers that didn't flow through the
    /// editor's `documentDidChange` op pipeline — conflict merge,
    /// appending to a non-open subpage, restoring a lost block into a
    /// closed page. Bypasses the coalescer (the doc is on disk before
    /// this call returns) and schedules a tree-walk recovery-log
    /// catch-up so the new blocks reach the journal without waiting for
    /// the next reconcile pass to absorb them.
    @MainActor
    @discardableResult
    public func writeExternal(_ document: Document) throws -> String {
        let newText = BlockSerializer.serialize(document.children, resolvingSubpageTitle: subpageTitleResolver)
        let url = document.url
        let rel = relativePath(of: url)
        let blocks = document.children
        try files.write(newText, to: url)
        recordDiskContent(newText, at: url)
        scheduleRecord(rel: rel, blocks: blocks)
        return newText
    }

    /// Awaits any in-flight + pending save for the URL. Internal — outside
    /// callers go through `flush(_:)` which both saves and drains.
    nonisolated func flush(url: URL) async throws {
        try await saver.flush(url: url)
    }

    @MainActor
    private func scheduleRecord(rel: String, blocks: [Block]) {
        let patch = Patch.adds(from: blocks)
        Task { [log, rel] in
            do {
                try await log.apply(patch, to: rel)
            } catch {
                Diag.log.error("record failed page=\(rel, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
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
    /// otherwise the on-disk text), write the merged document immediately,
    /// and mark each alternate version resolved.
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
    ) throws -> ConflictResolution {
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
        try writeExternal(merged)

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
    /// are created as needed.
    @discardableResult
    nonisolated public func createPage(
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
        return path
    }

    /// Workspace-relative slug for a new page titled `title`, suffixed with
    /// `-2`, `-3`, etc. to avoid collision with existing files.
    nonisolated private func availablePagePath(for title: String) -> String {
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

    // MARK: - Pages: search

    /// Filter + rank `entries` for any page-picker surface (sidebar,
    /// square.stack sheet, @-mention popover, move-to, jump-to).
    /// Title-prefix beats title-substring beats path-substring; mtime breaks ties.
    /// Empty query returns the full pool in mtime-descending order.
    /// `excluding` omits a specific URL — typically the currently-open document
    /// (move-to / mention / jump-to). Pass nil to include it (sidebar / sheet).
    public func searchPages(
        in entries: [WorkspaceEntry],
        query: String,
        excluding: URL? = nil
    ) -> [MentionItem] {
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


    /// Read every device's per-page log and return as a `LogJournal` (engine
    /// input). Callers that drive auto-restore or the Recover sheet via
    /// `PatchEngine` use this to get a snapshot of the journal in one I/O
    /// pass, then derive intent / classify lost / classify purged without
    /// re-hitting disk.
    nonisolated public func readJournal(forPage page: String) -> LogJournal {
        log.readJournal(page: page)
    }

    /// Apply an arbitrary patch to a page's recovery log. The unified path
    /// used by reconcile (lift unlogged observations + quarantine
    /// unrestorable hashes in one batched write) and by manual restore
    /// (sweep covered hashes as purges, or fresh adds for unpurge).
    public func applyPatch(_ patch: Patch, forPage page: String) async throws {
        guard !patch.isEmpty else { return }
        try await log.apply(patch, to: page)
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
    /// One-shot, content-immutable writes — no need for the `DocumentSaveCoordinator`.
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
