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

    nonisolated private let files: FileStore
    nonisolated private let saver: DocumentSaveCoordinator
    nonisolated private let trash: TrashStore
    nonisolated private let log: RecoveryLog

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
        try files.loadDocument(at: url)
    }

    /// Load + return the raw bytes that produced the document. The raw text is
    /// needed by the host to seed `Workspace.diskHistory`, which protects
    /// in-memory edits from iCloud-Drive stomps (an external write reverting
    /// the file to a previously-seen disk state triggers a defender re-save).
    @MainActor
    public func loadDocumentAndRawText(at url: URL) throws -> (Document, String) {
        let raw = try files.read(url)
        let blocks = BlockParser.parse(raw)
        let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return (Document(url: url, children: blocks, modificationDate: mtime), raw)
    }

    /// Read the raw bytes on disk without parsing — used for hashing into
    /// `diskHistory` when only the bytes are needed (e.g. on a presenter event).
    nonisolated public func readRawText(at url: URL) throws -> String {
        try files.read(url)
    }

    @MainActor
    public func loadDocumentTitle(at url: URL) throws -> String {
        try files.loadDocumentTitle(at: url)
    }

    // MARK: - Pages: write

    /// Coalesced async save (autosave path). Document is `@MainActor`-isolated,
    /// so we serialize on the calling actor (MainActor) before handing the
    /// String + URL across to the save coordinator. After the write lands,
    /// fires a fire-and-forget `RecoveryLog.record` that logs any new atomic
    /// block content this device hasn't seen before. Deletions are not
    /// inferred here — the editor calls `purgeHash` explicitly at the
    /// mutation site for blocks the user removes, so the save path stays
    /// purely observational.
    @MainActor
    @discardableResult
    public func save(
        _ document: Document,
        resolvingSubpageTitle titleForPath: (String) -> String? = { _ in nil }
    ) async throws -> String {
        let newText = BlockSerializer.serialize(document.children, resolvingSubpageTitle: titleForPath)
        let url = document.url
        let rel = relativePath(of: url)
        let blocks = document.children
        try await saver.save(url: url, contents: newText)
        scheduleRecord(rel: rel, blocks: blocks)
        return newText
    }

    /// Synchronous full write — bypasses the coalescer. For modifications-as-a-unit
    /// (trashing a dirty open doc, appending to a subpage, restoring a lost block)
    /// where the doc must be on disk before the next operation runs. Also schedules
    /// a recovery-log append for any new atomic block content this device hasn't
    /// seen before. Returns the serialized text so callers can reuse it (e.g.
    /// to seed `diskHistory`) without re-running the serializer.
    @MainActor
    @discardableResult
    public func writeImmediately(
        _ document: Document,
        resolvingSubpageTitle titleForPath: (String) -> String? = { _ in nil }
    ) throws -> String {
        let newText = BlockSerializer.serialize(document.children, resolvingSubpageTitle: titleForPath)
        let url = document.url
        let rel = relativePath(of: url)
        let blocks = document.children
        try files.write(newText, to: url)
        scheduleRecord(rel: rel, blocks: blocks)
        return newText
    }

    /// Awaits any in-flight + pending save for the URL.
    nonisolated public func flush(url: URL) async throws {
        try await saver.flush(url: url)
    }

    @MainActor
    private func scheduleRecord(rel: String, blocks: [Block]) {
        Task { [log] in
            try? await log.record(page: rel, blocks: blocks)
        }
    }

    /// Force a recovery-log snapshot of `blocks` for the page at `url`. Used
    /// by the editor right before a destructive mutation so transient blocks
    /// that never hit the autosave still land in the log. Never tombstones —
    /// the snapshot is a *pre*-mutation capture; the post-mutation autosave
    /// is the one that derives tombstones.
    public func snapshotIntoRecoveryLog(at url: URL, blocks: [Block]) {
        let rel = relativePath(of: url)
        scheduleRecord(rel: rel, blocks: blocks)
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

    /// If `url` has any unresolved `NSFileVersion` conflict alternates,
    /// merge their blocks into the survivor (in-memory `doc` if provided,
    /// otherwise the on-disk text), write the merged document immediately,
    /// and mark each alternate version resolved. Returns the count of
    /// distinct block-hashes that were salvaged from alternates and weren't
    /// already in the survivor. Returns 0 when there are no alternates or
    /// when alternates contributed nothing new.
    ///
    /// Open-page callers: pass the live `Document`. On a non-zero return
    /// the live doc's `children` and `title` are updated in place; the
    /// caller is responsible for any post-update plumbing (cache refresh,
    /// disk-hash seeding, banner).
    ///
    /// Closed-page callers: pass `nil`. The merged result is written
    /// straight to disk.
    @MainActor
    public func resolveConflictVersions(
        at url: URL,
        againstLive doc: Document? = nil,
        resolvingSubpageTitle titleForPath: (String) -> String? = { _ in nil }
    ) throws -> Int {
        let alternates = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
        guard !alternates.isEmpty else { return 0 }

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
        let context = log.mergeContext(page: rel)

        let result = ConflictMerger.merge(
            survivor: survivorBlocks,
            alternates: alternateBlockLists,
            tombstones: context.tombstones,
            parentHashLookup: { hash in context.parentHashes[hash] }
        )

        Diag.merge.log("resolve url=\(url.lastPathComponent, privacy: .public) alternates=\(alternates.count, privacy: .public) salvaged=\(result.salvagedHashes.count, privacy: .public)")

        if result.salvagedHashes.isEmpty {
            Clamshell.markAlternatesResolved(alternates)
            return 0
        }

        let merged = Document(url: url, children: result.merged)
        try writeImmediately(merged, resolvingSubpageTitle: titleForPath)

        if let doc {
            doc.children = result.merged
        }

        Clamshell.markAlternatesResolved(alternates)
        return result.salvagedHashes.count
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
        Task { [log, rel, result] in
            try? await log.move(fromPage: rel, toPage: result)
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
        try? await log.move(fromPage: entry.trashRelativePath, toPage: restoredRel)
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

    /// Append a tombstone for `entry` against its source page in this
    /// device's log. Subsequent `listLostBlocks` calls (on this device
    /// and on any other device that syncs the tombstone) will exclude
    /// the entry's hash.
    public func purgeLostBlock(_ entry: LostBlock) async throws {
        try await log.purge(page: entry.source, hash: entry.hash)
    }

    /// Hash-keyed tombstone variant. Used by the manual-restore path
    /// when purging an entire restored subtree — the caller has the
    /// page + hash set in hand but no `LostBlock` per descendant.
    public func purgeHash(_ hash: String, in page: String) async throws {
        try await log.purge(page: page, hash: hash)
    }

    /// Resolve a hash to its recorded parent hash via the per-device recovery
    /// log union. Used by the restore flow's ancestor climb when the
    /// immediate parent isn't alive in the page anymore.
    public func parentHash(forPage page: String, hash: String) async -> String? {
        await log.parentHash(page: page, hash: hash)
    }

    /// Blocks the user (or auto-tombstone) deleted on purpose: the log
    /// union's latest record is a `purge`, but a prior `add` carries the
    /// markdown + parent metadata so we can reconstruct them. `since`
    /// caps the result to recent purges (default: last 30 days). Pass
    /// `since: nil` to disable the cap.
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

    /// Restore-from-tombstone: append a fresh `add` for `block` so the log
    /// union's latest record is no longer a `purge`. The caller is
    /// responsible for inserting `block` back into the doc and saving — the
    /// `reAdd` call alone changes only the log, not the `.md`.
    public func unpurgeBlock(_ block: Block, in page: String, parentHash: String?) async throws {
        try await log.reAdd(page: page, block: block, parentHash: parentHash)
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
