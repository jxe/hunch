import Foundation
import Editor

public struct WorkspaceEntry: Identifiable, Sendable, Hashable {
    public let url: URL
    public let relativePath: String
    public let title: String
    public let modificationDate: Date

    public var id: URL { url }

    public init(url: URL, relativePath: String, title: String, modificationDate: Date) {
        self.url = url
        self.relativePath = relativePath
        self.title = title
        self.modificationDate = modificationDate
    }
}

/// Shared workspace state — one per app instance, mounted as `@State` at the
/// `App` level. Owns the open `Clamshell`, the page list, the title cache, and
/// the disk-content history that defends in-memory edits against iCloud-Drive
/// stomps. Per-window state (path, openDocument, save lifecycle) lives on
/// `WorkspaceWindow`, which holds a reference to this.
@MainActor
@Observable
final class Workspace {
    var workspaceURL: URL?
    var entries: [WorkspaceEntry] = []
    var homeRelativePath: String?
    /// Surfaced in the alert in any open window. Last-write-wins across
    /// concurrent windows — acceptable; user dismisses the alert.
    var error: String?

    private(set) var clamshell: Clamshell?

    /// Per-URL ring buffer of recently observed on-disk content hashes
    /// (most recent first, capped at 5). Used by
    /// `WorkspaceWindow.handlePresentedFileChange` to distinguish:
    ///  - our own write echoing back through the FS (matches head)
    ///  - an iCloud Drive revert to a state we've previously seen (matches tail)
    ///  - a genuine external edit (matches nothing)
    private(set) var diskHistory: [URL: [Int]] = [:]

    private var titleCache: [URL: CachedTitle] = [:]
    private var titleRefreshTask: Task<Void, Never>?
    private var accessedWorkspaceURL: URL?

    private struct CachedTitle {
        var title: String
        var modificationDate: Date?
    }

    var homeURL: URL? {
        guard let homeRelativePath else { return nil }
        return entries.first { $0.relativePath == homeRelativePath }?.url
    }

    func relativePath(of url: URL) -> String {
        clamshell?.relativePath(of: url) ?? url.lastPathComponent
    }

    // MARK: - Lifecycle

    func tryRestore() {
        if ProcessInfo.processInfo.arguments.contains("--console-ui-testing") {
            installUITestWorkspace()
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--console-ui-testing-tall-doc") {
            installTallDocUITestWorkspace()
            return
        }
        // tryRestore is called from `.task` in every window; only the first
        // call needs to do anything.
        guard workspaceURL == nil else { return }
        if let url = WorkspaceBookmark.resolve() {
            accessedWorkspaceURL = url
            workspaceURL = url
            let clamshell = Clamshell(root: url)
            self.clamshell = clamshell
            homeRelativePath = clamshell.homeRelativePath
            rescan()
        }
    }

    func setWorkspaceFromKeyFile(_ url: URL) {
        let root = url.deletingLastPathComponent()
        let homePath = url.lastPathComponent
        do {
            try WorkspaceBookmark.save(url: root)
            activateWorkspaceAccess(for: root)
            workspaceURL = root
            let clamshell = Clamshell(root: root)
            clamshell.homeRelativePath = homePath
            self.clamshell = clamshell
            homeRelativePath = homePath
            rescan()
        } catch {
            self.error = "Failed to save workspace bookmark: \(error.localizedDescription)"
        }
    }

    func setWorkspace(_ url: URL) {
        do {
            try WorkspaceBookmark.save(url: url)
            activateWorkspaceAccess(for: url)
            workspaceURL = url
            let clamshell = Clamshell(root: url)
            self.clamshell = clamshell
            homeRelativePath = clamshell.homeRelativePath
            rescan()
        } catch {
            self.error = "Failed to save workspace bookmark: \(error.localizedDescription)"
        }
    }

    /// Drop the currently bookmarked workspace. Open windows observe
    /// `workspaceURL == nil` and reset their navigation state to empty;
    /// see `WorkspaceWindow` reactions.
    func switchWorkspace() {
        WorkspaceBookmark.clear()
        releaseWorkspaceAccess()
        workspaceURL = nil
        homeRelativePath = nil
        entries = []
        titleCache = [:]
        diskHistory = [:]
        clamshell = nil
        titleRefreshTask?.cancel()
        titleRefreshTask = nil
    }

    func rescan() {
        guard let workspaceURL, let clamshell else { return }
        do {
            let scanned = try clamshell.scan()
            entries = scanned.map { entry in
                WorkspaceEntry(
                    url: entry.url,
                    relativePath: entry.relativePath,
                    title: cachedTitle(for: entry, fallback: entry.title),
                    modificationDate: entry.modificationDate
                )
            }
            refreshTitlesInBackground(for: scanned, workspaceURL: workspaceURL)
        } catch {
            self.error = "Failed to scan workspace: \(error.localizedDescription)"
        }
    }

    func setHome(_ entry: WorkspaceEntry) {
        homeRelativePath = entry.relativePath
        clamshell?.homeRelativePath = entry.relativePath
    }

    // MARK: - Disk-history (iCloud-stomp defense)

    /// Record a hash of on-disk content for `url`. Most recent first; ring
    /// buffer of 5 entries. Consecutive duplicates are deduped.
    func recordDiskHash(_ hash: Int, for url: URL) {
        var history = diskHistory[url] ?? []
        if history.first == hash { return }
        history.insert(hash, at: 0)
        if history.count > 5 { history.removeLast(history.count - 5) }
        diskHistory[url] = history
    }

    func recordDiskText(_ text: String, for url: URL) {
        recordDiskHash(text.hashValue, for: url)
    }

    /// Load via Clamshell with disk-hash side-effects. Prefer this over
    /// `clamshell?.loadDocument(at:)` from any host call site so the history
    /// stays seeded.
    func loadDocument(at url: URL) throws -> Document {
        guard let clamshell else {
            throw NSError(domain: "Workspace", code: -1, userInfo: [NSLocalizedDescriptionKey: "No workspace"])
        }
        let (document, raw) = try clamshell.loadDocumentAndRawText(at: url)
        recordDiskText(raw, for: url)
        return document
    }

    // MARK: - Read queries

    func pageTitle(for relativePath: String) -> String? {
        guard relativePath.hasSuffix(".md") else { return nil }
        guard let clamshell else { return nil }
        let url = clamshell.url(for: relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let mtime = modificationDate(for: url)
        if let cached = titleCache[url], cached.modificationDate == mtime {
            return cached.title
        }
        return nil
    }

    /// Filter + rank pages for any picker surface. `excluding` typically the
    /// currently-open document (move-to / mention / jump-to); pass nil to
    /// include everything (sidebar / page-list sheet).
    func pages(matching query: String, excluding: URL?) -> [MentionItem] {
        guard let clamshell else { return [] }
        return clamshell.searchPages(in: entries, query: query, excluding: excluding)
    }

    func saveTitleResolver() -> @Sendable (String) -> String? {
        let titlesByPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.relativePath, $0.title) })
        return { relativePath in
            titlesByPath[relativePath]
        }
    }

    func modificationDate(for url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    // MARK: - Title cache

    @discardableResult
    func refreshTitleCache(from document: Document) -> Bool {
        let updated = documentWithCurrentTitle(document)
        let previousTitle = titleCache[updated.url]?.title
        titleCache[updated.url] = CachedTitle(title: updated.title, modificationDate: updated.modificationDate)
        return previousTitle != updated.title
    }

    func refreshEntriesFromTitleCache() {
        entries = entries.map { entry in
            WorkspaceEntry(
                url: entry.url,
                relativePath: entry.relativePath,
                title: titleCache[entry.url]?.title ?? entry.title,
                modificationDate: entry.modificationDate
            )
        }
    }

    private func cachedTitle(for entry: WorkspaceEntry, fallback: String) -> String {
        if let cached = titleCache[entry.url], cached.modificationDate == entry.modificationDate {
            return cached.title
        }
        return fallback
    }

    private func documentWithCurrentTitle(_ document: Document) -> Document {
        var updated = document
        let fallback = document.url.deletingPathExtension().lastPathComponent
        updated.title = Document.deriveTitle(from: document.blocks, fallback: fallback)
        return updated
    }

    private func refreshTitlesInBackground(for scanned: [WorkspaceEntry], workspaceURL: URL) {
        let stale = scanned.filter { entry in
            titleCache[entry.url]?.modificationDate != entry.modificationDate
        }
        guard !stale.isEmpty, let clamshell else { return }

        titleRefreshTask?.cancel()
        titleRefreshTask = Task.detached(priority: .utility) { [weak self, clamshell, stale, workspaceURL] in
            var refreshed: [URL: CachedTitle] = [:]
            for entry in stale {
                guard !Task.isCancelled else { return }
                if let title = try? clamshell.loadDocumentTitle(at: entry.url) {
                    refreshed[entry.url] = CachedTitle(title: title, modificationDate: entry.modificationDate)
                }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.applyRefreshedTitles(refreshed, workspaceURL: workspaceURL)
            }
        }
    }

    private func applyRefreshedTitles(_ refreshed: [URL: CachedTitle], workspaceURL: URL) {
        guard self.workspaceURL == workspaceURL, !refreshed.isEmpty else { return }
        titleCache.merge(refreshed) { _, new in new }
        refreshEntriesFromTitleCache()
    }

    // MARK: - Page-level mutations

    /// Filesystem-only: move a page to trash. Caller (`WorkspaceWindow`) is
    /// responsible for any per-window cleanup (close openDocument, drop from
    /// path) before calling.
    @discardableResult
    func moveToTrash(at url: URL) -> Bool {
        guard let clamshell else { return false }
        titleCache.removeValue(forKey: url)
        diskHistory.removeValue(forKey: url)
        do {
            _ = try clamshell.moveToTrash(at: url)
            homeRelativePath = clamshell.homeRelativePath
            rescan()
            return true
        } catch {
            self.error = "Failed to move \(relativePath(of: url)) to trash: \(error.localizedDescription)"
            return false
        }
    }

    func createSubpage(title: String, requestedPath: String?, initialContent: [Block]?) -> String? {
        guard let clamshell else { return requestedPath }
        do {
            let path = try clamshell.createPage(title: title, requestedPath: requestedPath, blocks: initialContent)
            let target = clamshell.url(for: path)
            titleCache[target] = CachedTitle(title: title, modificationDate: modificationDate(for: target))
            // Seed disk history for the freshly-created file so the presenter
            // doesn't classify the create event as "external".
            if let raw = try? clamshell.readRawText(at: target) {
                recordDiskText(raw, for: target)
            }
            rescan()
            return path
        } catch {
            self.error = "Failed to create page: \(error.localizedDescription)"
            return requestedPath
        }
    }

    func loadSubpage(relativePath: String) -> [Block]? {
        guard let clamshell else { return nil }
        let target = clamshell.url(for: relativePath)
        guard let doc = try? loadDocument(at: target) else { return nil }
        return doc.blocks
    }

    @discardableResult
    func appendToSubpage(relativePath: String, blocks: [Block]) -> Document? {
        guard !blocks.isEmpty, let clamshell else { return nil }
        let target = clamshell.url(for: relativePath)
        do {
            var doc = try loadDocument(at: target)
            doc.blocks.append(contentsOf: blocks)
            doc.title = Document.deriveTitle(from: doc.blocks, fallback: target.deletingPathExtension().lastPathComponent)
            try clamshell.writeImmediately(doc, resolvingSubpageTitle: saveTitleResolver())
            doc.modificationDate = modificationDate(for: target)
            // Seed history with the new on-disk text.
            if let raw = try? clamshell.readRawText(at: target) {
                recordDiskText(raw, for: target)
            }
            refreshTitleCache(from: doc)
            refreshEntriesFromTitleCache()
            return doc
        } catch {
            self.error = "Failed to move blocks into \(relativePath): \(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func moveSubpageToTrash(relativePath: String) -> Bool {
        guard let clamshell else { return false }
        let target = clamshell.url(for: relativePath)
        return moveToTrash(at: target)
    }

    // MARK: - Recovery

    func recordBlockDeletion(sourceURL: URL, previousBlocks: [Block], indices: [Int]) {
        guard let clamshell else { return }
        Task { [weak self, clamshell, sourceURL, previousBlocks, indices] in
            do {
                try await clamshell.recordDeletion(
                    at: sourceURL,
                    previousBlocks: previousBlocks,
                    removedIndices: indices
                )
            } catch {
                await MainActor.run {
                    self?.error = "Recording block deletion failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func listRecoverableEntries(filter: RecoveryListFilter = .all) async -> [RecoverableEntry] {
        var out: [RecoverableEntry] = []
        guard let clamshell else { return out }
        if case .all = filter {
            let pages = (try? await clamshell.listTrashedPages()) ?? []
            out.append(contentsOf: pages.map { .deletedPage($0) })
        }
        let lostFilter: Clamshell.LostBlocksFilter
        switch filter {
        case .all: lostFilter = .all
        case .page(let rel): lostFilter = .page(relativePath: rel)
        }
        let lost = (try? await clamshell.listLostBlocks(filter: lostFilter)) ?? []
        out.append(contentsOf: lost.map { .lostBlock($0) })
        out.sort { $0.timestamp > $1.timestamp }
        return out
    }

    @discardableResult
    func restoreDeletedPage(_ entry: TrashEntry) async -> Bool {
        guard let clamshell else { return false }
        do {
            _ = try await clamshell.restorePage(entry)
            rescan()
            return true
        } catch {
            self.error = "Restore failed: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Workspace-scoped resource access

    private func activateWorkspaceAccess(for url: URL) {
        releaseWorkspaceAccess()
        _ = url.startAccessingSecurityScopedResource()
        accessedWorkspaceURL = url
    }

    private func releaseWorkspaceAccess() {
        accessedWorkspaceURL?.stopAccessingSecurityScopedResource()
        accessedWorkspaceURL = nil
    }

    // MARK: - UI test fixtures

    private func installUITestWorkspace() {
        do {
            let root = FileManager.default
                .temporaryDirectory
                .appendingPathComponent("console-ui-tests", isDirectory: true)
            try? FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let documentURL = root.appendingPathComponent("everything.md")
            let source = """
            # Drag Test

            Alpha

            Bravo

            Charlie

            Delta

            Echo

            Foxtrot
            """
            try source.write(to: documentURL, atomically: true, encoding: .utf8)
            workspaceURL = root
            let clamshell = Clamshell(root: root)
            self.clamshell = clamshell
            entries = (try? clamshell.scan()) ?? []
        } catch {
            self.error = "Failed to install UI test workspace: \(error.localizedDescription)"
        }
    }

    private func installTallDocUITestWorkspace() {
        do {
            let root = FileManager.default
                .temporaryDirectory
                .appendingPathComponent("console-ui-tests", isDirectory: true)
            try? FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let documentURL = root.appendingPathComponent("everything.md")
            var lines: [String] = ["# Tall Doc"]
            for i in 1...60 {
                lines.append("Row \(String(format: "%02d", i))")
            }
            let source = lines.joined(separator: "\n\n")
            try source.write(to: documentURL, atomically: true, encoding: .utf8)
            workspaceURL = root
            let clamshell = Clamshell(root: root)
            self.clamshell = clamshell
            entries = (try? clamshell.scan()) ?? []
        } catch {
            self.error = "Failed to install tall-doc UI test workspace: \(error.localizedDescription)"
        }
    }
}

public enum RecoveryListFilter: Sendable, Hashable, Identifiable {
    case all
    case page(relativePath: String)

    public var id: Self { self }
}

public enum RecoverableEntry: Identifiable, Sendable, Hashable {
    case deletedPage(TrashEntry)
    case lostBlock(LostBlock)

    public var id: String {
        switch self {
        case .deletedPage(let e): return "page:\(e.id)"
        case .lostBlock(let l): return "lost:\(l.id)"
        }
    }

    public var timestamp: Date {
        switch self {
        case .deletedPage(let e): return e.timestamp
        case .lostBlock(let l): return l.record.recordedAt
        }
    }

    public var sourcePath: String {
        switch self {
        case .deletedPage(let e): return e.sourcePath
        case .lostBlock(let l): return l.record.source
        }
    }

    public var displayTitle: String {
        switch self {
        case .deletedPage(let e): return e.displayTitle
        case .lostBlock(let l): return RecoverableEntry.previewLine(from: l.record.markdown)
        }
    }

    public var isPageEntry: Bool {
        if case .deletedPage = self { return true }
        return false
    }

    private static func previewLine(from body: String) -> String {
        for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return String(trimmed.prefix(80)) }
        }
        return ""
    }
}
