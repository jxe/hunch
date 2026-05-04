import Foundation
import Editor

/// Hunch's persistent markdown format and its API.
///
/// On disk, a Clamshell is a folder:
///
///     <clamshell-root>/
///       *.md                          live pages
///       Trash/<relpath>.md            soft-deleted pages (mirrors source structure)
///       .history/<relpath>.md.jsonl   append-only log of lost / edited blocks
///       .clamshell.json               format metadata (home page pointer)
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

    public typealias LostBlocksFilter = RecoveryStore.ListFilter

    nonisolated private let files: FileStore
    nonisolated private let saver: DocumentSaveCoordinator
    nonisolated private let trash: TrashStore
    nonisolated private let history: RecoveryStore

    public init(root: URL) {
        self.root = root
        let files = FileStore()
        self.files = files
        self.saver = DocumentSaveCoordinator(store: files)
        self.trash = TrashStore(workspaceRoot: root, store: files)
        self.history = RecoveryStore(workspaceRoot: root, store: files)

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

    nonisolated public func loadDocument(at url: URL) throws -> Document {
        try files.loadDocument(at: url)
    }

    nonisolated public func loadDocumentTitle(at url: URL) throws -> String {
        try files.loadDocumentTitle(at: url)
    }

    // MARK: - Pages: write

    /// Coalesced async save (autosave path). If a write is already in flight for
    /// this URL, the snapshot replaces any pending one and is written after the
    /// in-flight write completes. After the write lands, fires a fire-and-forget
    /// `recordEdits` against the lost-block log so the format keeps its own diff
    /// history without the caller having to wire it up.
    nonisolated public func save(
        _ document: Document,
        resolvingSubpageTitle titleForPath: @Sendable @escaping (String) -> String? = { _ in nil }
    ) async throws {
        let priorText = try await saver.save(document, resolvingSubpageTitle: titleForPath)
        guard let priorText else { return }
        let newText = BlockSerializer.serialize(document.blocks, resolvingSubpageTitle: titleForPath)
        scheduleRecordEdits(at: document.url, previousText: priorText, newText: newText)
    }

    /// Synchronous full write — bypasses the coalescer. For modifications-as-a-unit
    /// (trashing a dirty open doc, appending to a subpage, restoring a lost block)
    /// where the doc must be on disk before the next operation runs. Also records
    /// the diff into the lost-block log.
    nonisolated public func writeImmediately(
        _ document: Document,
        resolvingSubpageTitle titleForPath: @Sendable @escaping (String) -> String? = { _ in nil }
    ) throws {
        let priorText = try? files.read(document.url)
        let newText = BlockSerializer.serialize(document.blocks, resolvingSubpageTitle: titleForPath)
        try files.write(newText, to: document.url)
        if let priorText {
            scheduleRecordEdits(at: document.url, previousText: priorText, newText: newText)
        }
    }

    /// Awaits any in-flight + pending save for the URL.
    nonisolated public func flush(url: URL) async throws {
        try await saver.flush(url: url)
    }

    nonisolated private func scheduleRecordEdits(at url: URL, previousText: String, newText: String) {
        guard previousText != newText else { return }
        let rel = relativePath(of: url)
        Task { [history] in
            try? await history.recordEdits(
                relativePath: rel,
                previousText: previousText,
                newText: newText
            )
        }
    }

    // MARK: - Pages: create

    /// Creates a new page at `url` with `# title` followed by the serialized
    /// blocks (or just the title if `blocks` is nil). No-op if the file already
    /// exists. Creates intermediate directories as needed.
    nonisolated public func createPage(at url: URL, title: String, blocks: [Block]?) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let body: String
        if let blocks {
            body = "# \(title)\n\n" + BlockSerializer.serialize(blocks)
        } else {
            body = "# \(title)\n"
        }
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A page-relative path under `root` for a new page titled `title`, suffixed
    /// with `-2`, `-3`, etc. as needed to avoid collision with existing files.
    nonisolated public func availablePagePath(for title: String) -> String {
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
    @discardableResult
    public func moveToTrash(at url: URL) throws -> String {
        let rel = relativePath(of: url)
        let result = try files.moveToTrash(relativePath: rel, workspaceRoot: root)
        if homeRelativePath == rel {
            homeRelativePath = nil
        }
        return result
    }

    nonisolated public func listTrashedPages() async throws -> [TrashEntry] {
        try await trash.listEntries()
    }

    @discardableResult
    nonisolated public func restorePage(_ entry: TrashEntry) async throws -> URL {
        try await trash.restorePage(entry)
    }

    // MARK: - Lost-block log

    nonisolated public func recordDeletion(
        at url: URL,
        previousBlocks: [Block],
        removedIndices: [Int]
    ) async throws {
        try await history.recordDeletion(
            relativePath: relativePath(of: url),
            previousBlocks: previousBlocks,
            removedIndices: removedIndices
        )
    }

    nonisolated public func listLostBlocks(filter: LostBlocksFilter = .all) async throws -> [LostBlock] {
        try await history.list(filter: filter)
    }

    nonisolated public func purgeLostBlock(_ entry: LostBlock) async throws {
        try await history.purge(entry)
    }

    // MARK: - .clamshell.json

    private static let metadataFilename = ".clamshell.json"

    private struct Metadata: Codable, Sendable {
        var homeRelativePath: String?
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
        let metadata = Metadata(homeRelativePath: homeRelativePath)

        // If everything's empty, prefer removing the file over leaving `{}` behind.
        let isEmpty = metadata.homeRelativePath == nil
        if isEmpty {
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
