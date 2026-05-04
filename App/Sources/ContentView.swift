import SwiftUI
import Editor
import UniformTypeIdentifiers

private let markdownFileType = UTType(filenameExtension: "md") ?? .plainText

@MainActor
@Observable
final class WorkspaceModel {
    var workspaceURL: URL?
    var entries: [WorkspaceEntry] = []
    var homeRelativePath: String?
    var openDocument: Document?
    var error: String?
    /// Stack of pages pushed *on top* of the home root, root → top. Empty =
    /// home page is visible (or, if no home is set, the page list fallback).
    /// Bound to `NavigationStack(path:)`; mutating drives push/pop, and the
    /// NavigationStack writes back here on edge-swipe / system back.
    var path: [URL] = []
    var canGoBack: Bool { !path.isEmpty }

    /// Pending "Move to" picker request from the editor. Non-nil presents the
    /// host's page-picker sheet; resolving it (pick or cancel) fires the
    /// editor's completion and clears the request.
    var moveRequest: MoveRequest?

    /// Drives the ⌘P "Jump to Page…" sheet.
    var showJumpTo: Bool = false

    struct MoveRequest: Identifiable {
        let id = UUID()
        let blockIDs: [BlockID]
        let completion: (String?) -> Void
    }

    func requestMoveDestination(blockIDs: [BlockID], completion: @escaping (String?) -> Void) {
        moveRequest = MoveRequest(blockIDs: blockIDs, completion: completion)
    }

    func resolveMoveRequest(with pageID: String?) {
        guard let req = moveRequest else { return }
        moveRequest = nil
        req.completion(pageID)
    }

    /// Push the page at `relativePath` onto the navstack — distinct from
    /// `open(_:)` which resets to a single entry above home. Used by the ⌘P
    /// jump-to picker so jumping mid-stack preserves the trail.
    func jumpTo(_ relativePath: String) {
        guard let url = entries.first(where: { $0.relativePath == relativePath })?.url else { return }
        if path.last == url { return }
        cacheOpenDocument()
        path.append(url)
    }

    /// URL of the designated home page, if one is set and resolves to a known entry.
    var homeURL: URL? {
        guard let homeRelativePath else { return nil }
        return entries.first { $0.relativePath == homeRelativePath }?.url
    }

    private var clamshell: Clamshell?
    private var debounceTask: Task<Void, Never>?
    private var backstopTask: Task<Void, Never>?
    private var titleRefreshTask: Task<Void, Never>?
    private var filePresenter: DocumentFilePresenter?
    private var accessedWorkspaceURL: URL?
    private var isDirty = false
    private var isSaving = false
    private var documentCache: [URL: Document] = [:]
    private var titleCache: [URL: CachedTitle] = [:]

    private struct CachedTitle {
        var title: String
        var modificationDate: Date?
    }

    func tryRestore() {
        if ProcessInfo.processInfo.arguments.contains("--console-ui-testing") {
            installUITestWorkspace()
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--console-ui-testing-tall-doc") {
            installTallDocUITestWorkspace()
            return
        }
        if let url = WorkspaceBookmark.resolve() {
            accessedWorkspaceURL = url
            workspaceURL = url
            let clamshell = Clamshell(root: url)
            self.clamshell = clamshell
            homeRelativePath = clamshell.homeRelativePath
            rescan()
            if let homeRelativePath,
               let entry = entries.first(where: { $0.relativePath == homeRelativePath }) {
                open(entry)
            }
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
            if let entry = entries.first(where: { $0.relativePath == homePath }) {
                open(entry)
            }
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

    /// Drop the currently bookmarked workspace and current open doc. The picker UI
    /// reappears because `workspaceURL` is now nil.
    func switchWorkspace() {
        flushAndClose()
        WorkspaceBookmark.clear()
        releaseWorkspaceAccess()
        workspaceURL = nil
        homeRelativePath = nil
        entries = []
        openDocument = nil
        documentCache = [:]
        titleCache = [:]
        clamshell = nil
        titleRefreshTask?.cancel()
        titleRefreshTask = nil
        path = []
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

    /// Page-list selection: navigate to `entry`. If `entry` is the home page,
    /// drain the path so the home root becomes visible; otherwise replace the
    /// stack with a single entry pushed on top of home.
    func open(_ entry: WorkspaceEntry) {
        if entry.relativePath == homeRelativePath {
            if path.isEmpty {
                // Already at the home slot. Drive a load in case the home
                // doc isn't in `openDocument` yet (e.g. just after restore).
                handlePathChange()
            } else {
                cacheOpenDocument()
                path = []
            }
        } else if path != [entry.url] {
            cacheOpenDocument()
            path = [entry.url]
        }
    }

    /// Subpage / inline link: push deeper.
    func openSubpage(relativePath: String) {
        guard let clamshell else { return }
        let target = clamshell.url(for: relativePath)
        if path.last == target { return }
        cacheOpenDocument()
        path.append(target)
    }

    func setHome(_ entry: WorkspaceEntry) {
        homeRelativePath = entry.relativePath
        clamshell?.homeRelativePath = entry.relativePath
    }

    @discardableResult
    func moveToTrash(_ entry: WorkspaceEntry) -> Bool {
        guard let clamshell else { return false }
        if openDocument?.url == entry.url {
            if isDirty, let openDocument {
                do {
                    try clamshell.writeImmediately(openDocument, resolvingSubpageTitle: saveTitleResolver())
                    isDirty = false
                } catch {
                    self.error = "Save failed: \(error.localizedDescription)"
                    return false
                }
            }
            flushAndClose()
            openDocument = nil
        }
        documentCache.removeValue(forKey: entry.url)
        titleCache.removeValue(forKey: entry.url)
        path.removeAll { $0 == entry.url }
        do {
            _ = try clamshell.moveToTrash(at: entry.url)
            homeRelativePath = clamshell.homeRelativePath
            rescan()
            return true
        } catch {
            self.error = "Failed to move \(entry.relativePath) to trash: \(error.localizedDescription)"
            return false
        }
    }

    func goBack() {
        guard !path.isEmpty else { return }
        cacheOpenDocument()
        path.removeLast()
    }

    /// Reconcile `openDocument` with the currently visible page. The visible
    /// page is `path.last` if any subpages are pushed, otherwise the home page
    /// (if one is set). Call from a `.onChange(of: path)` observer in the view
    /// layer. Handles all transitions (push, pop, drain to home, drain to
    /// empty); flushes the outgoing doc before loading the new one.
    func handlePathChange() {
        let topURL = path.last ?? homeURL
        if openDocument?.url == topURL { return }
        cacheOpenDocument()
        flushAndClose()
        guard let url = topURL else {
            openDocument = nil
            backstopTask?.cancel()
            backstopTask = nil
            return
        }
        if let cached = documentCache[url] {
            openDocument = cached
            installFilePresenter(for: url)
            startBackstop()
            return
        }
        do {
            openDocument = try clamshell?.loadDocument(at: url)
            cacheOpenDocument()
            isDirty = false
            installFilePresenter(for: url)
            startBackstop()
        } catch {
            self.error = "Failed to load \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func createSubpage(title: String, requestedPath: String?, initialContent: [Block]?) -> String? {
        guard let clamshell else { return requestedPath }
        do {
            let path = try clamshell.createPage(title: title, requestedPath: requestedPath, blocks: initialContent)
            let target = clamshell.url(for: path)
            titleCache[target] = CachedTitle(title: title, modificationDate: modificationDate(for: target))
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
        guard let doc = try? clamshell.loadDocument(at: target) else { return nil }
        return doc.blocks
    }

    @discardableResult
    func appendToSubpage(relativePath: String, blocks: [Block]) -> Bool {
        guard !blocks.isEmpty, let clamshell else { return false }
        let target = clamshell.url(for: relativePath)
        do {
            var doc = try clamshell.loadDocument(at: target)
            doc.blocks.append(contentsOf: blocks)
            doc.title = Document.deriveTitle(from: doc.blocks, fallback: target.deletingPathExtension().lastPathComponent)
            try clamshell.writeImmediately(doc, resolvingSubpageTitle: saveTitleResolver())
            doc.modificationDate = modificationDate(for: target)
            documentCache[target] = doc
            let titleChanged = refreshTitleCache(from: doc)
            if openDocument?.url == target {
                openDocument = doc
            }
            if titleChanged {
                refreshEntriesFromTitleCache()
            }
            return true
        } catch {
            self.error = "Failed to move blocks into \(relativePath): \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func moveSubpageToTrash(relativePath: String) -> Bool {
        guard let clamshell else { return false }
        let target = clamshell.url(for: relativePath)
        documentCache.removeValue(forKey: target)
        titleCache.removeValue(forKey: target)
        do {
            _ = try clamshell.moveToTrash(at: target)
            homeRelativePath = clamshell.homeRelativePath
            rescan()
            return true
        } catch {
            self.error = "Failed to move \(relativePath) to trash: \(error.localizedDescription)"
            return false
        }
    }

    func closeDocument() {
        cacheOpenDocument()
        path = []
    }

    func documentForPage(url: URL) -> Document? {
        if openDocument?.url == url {
            return openDocument
        }
        return documentCache[url]
    }

    func updateDocumentForPage(_ document: Document) {
        let updated = documentWithCurrentTitle(document)
        documentCache[updated.url] = updated
        let titleChanged = refreshTitleCache(from: updated)
        if openDocument?.url == updated.url {
            openDocument = updated
        }
        if titleChanged {
            refreshEntriesFromTitleCache()
        }
    }

    func markEdited() {
        isDirty = true
        cacheOpenDocument()
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self?.saveNow()
        }
    }

    func saveNow() async {
        debounceTask?.cancel()
        debounceTask = nil
        guard isDirty, let doc = openDocument, let clamshell else { return }
        do {
            isSaving = true
            defer { isSaving = false }
            try await clamshell.save(doc, resolvingSubpageTitle: saveTitleResolver())
            if openDocument?.url == doc.url {
                openDocument?.modificationDate = modificationDate(for: doc.url)
                cacheOpenDocument()
                if let openDocument {
                    refreshTitleCache(from: openDocument)
                }
            }
            isDirty = false
            rescan()
        } catch {
            self.error = "Save failed: \(error.localizedDescription)"
        }
    }

    func flushAndClose() {
        debounceTask?.cancel()
        debounceTask = nil
        backstopTask?.cancel()
        backstopTask = nil
        removeFilePresenter()
        guard let doc = openDocument, let clamshell else { return }
        Task { [clamshell, doc] in
            try? await clamshell.flush(url: doc.url)
        }
    }

    private func installFilePresenter(for url: URL) {
        removeFilePresenter()
        let presenter = DocumentFilePresenter(url: url) { [weak self] in
            Task { @MainActor in
                await self?.handlePresentedFileChange()
            }
        }
        NSFileCoordinator.addFilePresenter(presenter)
        filePresenter = presenter
    }

    private func removeFilePresenter() {
        if let filePresenter {
            NSFileCoordinator.removeFilePresenter(filePresenter)
        }
        filePresenter = nil
    }

    private func handlePresentedFileChange() async {
        guard !isSaving, !isDirty, let doc = openDocument else { return }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled, !isSaving, !isDirty, openDocument?.url == doc.url else { return }

        let currentMTime = modificationDate(for: doc.url)
        if currentMTime == doc.modificationDate {
            rescan()
            return
        }

        do {
            openDocument = try clamshell?.loadDocument(at: doc.url)
            cacheOpenDocument()
            if let openDocument {
                refreshTitleCache(from: openDocument)
            }
            rescan()
        } catch {
            self.error = "Failed to reload external changes: \(error.localizedDescription)"
        }
    }

    private func cacheOpenDocument() {
        guard let openDocument else { return }
        documentCache[openDocument.url] = openDocument
        refreshTitleCache(from: openDocument)
    }

    private func modificationDate(for url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    func pageTitle(for relativePath: String) -> String? {
        guard relativePath.hasSuffix(".md") else { return nil }
        guard let clamshell else { return nil }
        let url = clamshell.url(for: relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if let openDocument, openDocument.url == url {
            return openDocument.title
        }
        let mtime = modificationDate(for: url)
        if let cached = titleCache[url], cached.modificationDate == mtime {
            return cached.title
        }
        return nil
    }

    /// Filter + rank the workspace's pages for any picker surface (sidebar,
    /// square.stack sheet, @-mention popover, move-to, jump-to). Implementation
    /// lives in `Clamshell.searchPages`; this is just the wrapper that supplies
    /// the cached entry list and resolves `excludingCurrent` against the
    /// currently-open document.
    func pages(matching query: String, excludingCurrent: Bool) -> [MentionItem] {
        guard let clamshell else { return [] }
        let excluding = excludingCurrent ? openDocument?.url : nil
        return clamshell.searchPages(in: entries, query: query, excluding: excluding)
    }

    private func cachedTitle(for entry: WorkspaceEntry, fallback: String) -> String {
        currentTitleIfCached(for: entry.url, modificationDate: entry.modificationDate) ?? fallback
    }

    private func currentTitleIfCached(for url: URL, modificationDate: Date?) -> String? {
        if let openDocument, openDocument.url == url {
            return openDocument.title
        }
        guard let cached = titleCache[url], cached.modificationDate == modificationDate else { return nil }
        return cached.title
    }

    private func refreshTitlesInBackground(for scanned: [WorkspaceEntry], workspaceURL: URL) {
        let stale = scanned.filter { entry in
            currentTitleIfCached(for: entry.url, modificationDate: entry.modificationDate) == nil
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

    private func documentWithCurrentTitle(_ document: Document) -> Document {
        var updated = document
        let fallback = document.url.deletingPathExtension().lastPathComponent
        updated.title = Document.deriveTitle(from: document.blocks, fallback: fallback)
        return updated
    }

    @discardableResult
    private func refreshTitleCache(from document: Document) -> Bool {
        let updated = documentWithCurrentTitle(document)
        let previousTitle = titleCache[updated.url]?.title
        titleCache[updated.url] = CachedTitle(title: updated.title, modificationDate: updated.modificationDate)
        return previousTitle != updated.title
    }

    private func refreshEntriesFromTitleCache() {
        entries = entries.map { entry in
            WorkspaceEntry(
                url: entry.url,
                relativePath: entry.relativePath,
                title: titleCache[entry.url]?.title ?? entry.title,
                modificationDate: entry.modificationDate
            )
        }
    }

    private func saveTitleResolver() -> @Sendable (String) -> String? {
        let titlesByPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.relativePath, $0.title) })
        return { relativePath in
            titlesByPath[relativePath]
        }
    }

    private func startBackstop() {
        backstopTask?.cancel()
        backstopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await self?.saveNow()
            }
        }
    }

    private func activateWorkspaceAccess(for url: URL) {
        releaseWorkspaceAccess()
        _ = url.startAccessingSecurityScopedResource()
        accessedWorkspaceURL = url
    }

    private func releaseWorkspaceAccess() {
        accessedWorkspaceURL?.stopAccessingSecurityScopedResource()
        accessedWorkspaceURL = nil
    }

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
            entries = try clamshell.scan()
            if let entry = entries.first(where: { $0.relativePath == "everything.md" }) {
                open(entry)
            }
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
            entries = try clamshell.scan()
            if let entry = entries.first(where: { $0.relativePath == "everything.md" }) {
                open(entry)
            }
        } catch {
            self.error = "Failed to install tall-doc UI test workspace: \(error.localizedDescription)"
        }
    }

    // MARK: - Recovery (trash + lost-block log)

    /// Fire-and-forget capture of a block-level deletion. Called from `EditorView`'s
    /// delete paths before the document mutation so the pre-deletion block list is
    /// available for anchor calculation.
    func recordBlockDeletion(indices: [Int], blocks: [Block], actionName: String) {
        _ = blocks  // (the editor passes the removed blocks; we recompute from `openDocument`)
        _ = actionName
        guard let clamshell, let openDocument else { return }
        let sourceURL = openDocument.url
        // Capture the pre-deletion block list — `recordBlockDeletion` is called
        // before the mutation lands in `openDocument`, so this is still the
        // pre-deletion state.
        let previousBlocks = openDocument.blocks
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
    func restoreRecoverable(_ entry: RecoverableEntry) async -> Bool {
        switch entry {
        case .deletedPage(let trashEntry):
            return await restoreDeletedPage(trashEntry)
        case .lostBlock(let lost):
            return await restoreLostBlock(lost)
        }
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

    @discardableResult
    func restoreLostBlock(_ entry: LostBlock) async -> Bool {
        guard let clamshell, let workspaceURL else { return false }
        let target = workspaceURL.appendingPathComponent(entry.record.source).standardizedFileURL
        guard FileManager.default.fileExists(atPath: target.path) else {
            self.error = "Original page no longer exists at \(entry.record.source)."
            return false
        }

        do {
            // Parse the lost block markdown back into [Block]. Indents are normalised
            // to start at 0 in storage; re-indent under the anchor's indent for a
            // reasonable insertion when nested under different parents.
            let parsed = BlockParser.parse(entry.record.markdown).map { $0.withFreshID() }
            guard !parsed.isEmpty else { return false }

            let useLiveDoc = (openDocument?.url == target)
            var doc: Document
            if useLiveDoc, let live = openDocument {
                doc = live
            } else {
                doc = try clamshell.loadDocument(at: target)
            }

            let anchorIndent: Int
            let insertIndex: Int
            if let anchorFP = entry.record.anchorFingerprint,
               let anchorIdx = doc.blocks.firstIndex(where: { BlockFingerprint.compute($0) == anchorFP }) {
                anchorIndent = doc.blocks[anchorIdx].indent
                insertIndex = anchorIdx + 1
            } else if let original = entry.record.originalIndex {
                anchorIndent = 0
                insertIndex = min(max(0, original), doc.blocks.count)
            } else {
                anchorIndent = 0
                insertIndex = doc.blocks.count
            }

            let reindented = parsed.map { $0.withIndent($0.indent + anchorIndent) }
            doc.blocks.insert(contentsOf: reindented, at: insertIndex)
            doc.title = Document.deriveTitle(from: doc.blocks, fallback: target.deletingPathExtension().lastPathComponent)

            if useLiveDoc {
                openDocument = doc
                cacheOpenDocument()
                markEdited()
            } else {
                try clamshell.writeImmediately(doc, resolvingSubpageTitle: saveTitleResolver())
                doc.modificationDate = modificationDate(for: target)
                documentCache[target] = doc
                rescan()
            }
            try? await clamshell.purgeLostBlock(entry)
            return true
        } catch {
            self.error = "Restore failed: \(error.localizedDescription)"
            return false
        }
    }
}

public enum RecoveryListFilter: Sendable, Hashable {
    case all
    case page(relativePath: String)
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

private final class DocumentFilePresenter: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue.main
    private let onChange: @Sendable () -> Void

    init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.presentedItemURL = url
        self.onChange = onChange
        super.init()
    }

    func presentedItemDidChange() {
        onChange()
    }

    func presentedItemDidMove(to newURL: URL) {
        onChange()
    }
}

struct ContentView: View {
    @Bindable var model: WorkspaceModel
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @State private var showingSwitchPicker = false
    #endif
    @State private var pageSearchText = ""
    @State private var recoveryFilter: RecoveryListFilter?
    @State private var showingPageList = false
    /// Sidebar's keyboard cursor (visual highlight). Mirrors the currently-open
    /// page when no arrow nav has happened; arrow keys move it independently
    /// of `model.path`. Activation (click or Return) calls `model.open` and
    /// the sidebar re-syncs on the next path change.
    @State private var sidebarCursor: MentionItem.ID?
    /// Same idea for the square.stack sheet.
    @State private var pageListSheetCursor: MentionItem.ID?

    var body: some View {
        Group {
            if model.workspaceURL == nil {
                WorkspacePickerView(model: model)
            } else {
                NavigationStack(path: $model.path) {
                    rootView
                        .navigationDestination(for: URL.self) { url in
                            pageDetail(for: url)
                        }
                }
                // `initial: true` covers the path-restored-by-tryRestore case where
                // the NavigationStack mounts with a non-empty path; without it
                // `openDocument` would never load and `pageDetail` would render
                // the ProgressView fallback forever.
                .onChange(of: model.path, initial: true) { _, newPath in
                    model.handlePathChange()
                    // Keep the sidebar's keyboard cursor pinned to whatever's
                    // currently navigated. Without this, arrow keys would resume
                    // from a stale highlight after the user clicked a row.
                    sidebarCursor = newPath.first.flatMap { url in
                        model.entries.first(where: { $0.url == url })?.relativePath
                    }
                }
                .sheet(isPresented: $showingPageList) {
                    pageListSheet
                }
                .sheet(item: $model.moveRequest) { _ in
                    PagePickerSheet(
                        title: "Move to…",
                        model: model,
                        onPick: { item in model.resolveMoveRequest(with: item.id) },
                        onCancel: { model.resolveMoveRequest(with: nil) }
                    )
                }
                .sheet(isPresented: $model.showJumpTo) {
                    PagePickerSheet(
                        title: "Jump to Page…",
                        model: model,
                        onPick: { item in
                            model.jumpTo(item.id)
                            model.showJumpTo = false
                        },
                        onCancel: { model.showJumpTo = false }
                    )
                }
                .sheet(item: Binding(
                    get: { recoveryFilter.map(RecoveryFilterBox.init) },
                    set: { recoveryFilter = $0?.filter }
                )) { box in
                    RecoveryView(
                        filter: box.filter,
                        loadEntries: { filter in await model.listRecoverableEntries(filter: filter) },
                        onRestore: { entry in await model.restoreRecoverable(entry) },
                        onClose: { recoveryFilter = nil }
                    )
                    #if os(macOS)
                    .frame(minWidth: 480, minHeight: 480)
                    #endif
                }
            }
        }
        .task { model.tryRestore() }
        .onChange(of: scenePhase) { _, new in
            if new != .active {
                Task { await model.saveNow() }
            }
        }
        .alert("Error", isPresented: errorBinding) {
            Button("OK") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }

    /// NavigationStack root: the home page editor when home is set and loaded;
    /// the page-list sidebar otherwise (fresh workspace, no home picked yet).
    @ViewBuilder
    private var rootView: some View {
        if let homeURL = model.homeURL {
            if let document = model.documentForPage(url: homeURL) {
                EditorPage(
                    url: homeURL,
                    document: document,
                    model: model,
                    recoveryFilter: $recoveryFilter,
                    onShowPageList: { showingPageList = true }
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(NotionStyle.background)
            }
        } else {
            sidebar
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.error != nil },
            set: { newValue in if !newValue { model.error = nil } }
        )
    }

    /// Activate a row from any page-picker surface: navigate to the page and,
    /// when called from a sheet (`dismissSheet: true`), close it.
    private func activate(_ item: MentionItem, dismissSheet: Bool) {
        guard let entry = model.entries.first(where: { $0.relativePath == item.id }) else { return }
        model.open(entry)
        if dismissSheet { showingPageList = false }
    }

    private func setHome(_ item: MentionItem) {
        if let entry = model.entries.first(where: { $0.relativePath == item.id }) {
            model.setHome(entry)
        }
    }

    private func moveToTrash(_ item: MentionItem) {
        if let entry = model.entries.first(where: { $0.relativePath == item.id }) {
            _ = model.moveToTrash(entry)
        }
    }

    /// Page-list sheet shown from the home toolbar icon. Mirrors the sidebar's
    /// content (PagePickerView + Recently Deleted) but in a modal context.
    private var pageListSheet: some View {
        NavigationStack {
            PagePickerView(
                items: model.pages(matching: pageSearchText, excludingCurrent: false),
                selection: $pageListSheetCursor,
                onActivate: { item in activate(item, dismissSheet: true) },
                onSetHome: setHome,
                onMoveToTrash: moveToTrash
            )
            .navigationTitle("Pages")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $pageSearchText, placement: .automatic, prompt: "Search pages")
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        showingPageList = false
                        recoveryFilter = .all
                    } label: {
                        Label("Recover", systemImage: "clock.arrow.circlepath")
                    }
                    .help("Recently Deleted")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingPageList = false }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 480)
        #endif
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Pages")
                .font(NotionStyle.body(size: 13, weight: .semibold))
                .foregroundStyle(NotionStyle.mutedForeground)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            PagePickerView(
                items: model.pages(matching: pageSearchText, excludingCurrent: false),
                selection: $sidebarCursor,
                onActivate: { item in activate(item, dismissSheet: false) },
                onSetHome: setHome,
                onMoveToTrash: moveToTrash
            )
            Divider()
            Button {
                recoveryFilter = .all
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 11))
                    Text("Recover")
                        .font(NotionStyle.body(size: 12))
                    Spacer()
                }
                .foregroundStyle(NotionStyle.mutedForeground)
                .contentShape(Rectangle())
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        }
        .navigationTitle(model.workspaceURL?.lastPathComponent ?? "Workspace")
        .searchable(text: $pageSearchText, placement: .automatic, prompt: "Search pages")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingSwitchPicker = true
                } label: {
                    Image(systemName: "folder.badge.gearshape")
                }
                .accessibilityLabel("Switch Workspace")
            }
        }
        .fileImporter(
            isPresented: $showingSwitchPicker,
            allowedContentTypes: [markdownFileType],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    model.switchWorkspace()
                    model.setWorkspaceFromKeyFile(url)
                }
            case .failure(let error):
                model.error = error.localizedDescription
            }
        }
        #endif
    }

    private struct RecoveryFilterBox: Identifiable, Hashable {
        let filter: RecoveryListFilter
        var id: String {
            switch filter {
            case .all: return "all"
            case .page(let r): return "page:\(r)"
            }
        }
    }

    @ViewBuilder
    private func pageDetail(for url: URL) -> some View {
        if let document = model.documentForPage(url: url) {
            // Wrap the editor in a per-URL view so SwiftUI's view-identity gives
            // us a fresh EditorState (and undo controller, focus, etc.) each
            // time the user navigates to a different document. The Editor
            // contract is one EditorState per document; navigating to a new
            // page mounts a new EditorPage with new state.
            EditorPage(
                url: url,
                document: document,
                model: model,
                recoveryFilter: $recoveryFilter
            )
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(NotionStyle.background)
        }
    }
}

/// Per-URL editor page. Owns an `EditorState` whose lifetime matches the
/// navigation destination's view-identity — pushing a new URL mounts a fresh
/// `EditorPage` (and a fresh `EditorState`); navigating back unmounts it.
private struct EditorPage: View {
    let url: URL
    let document: Document
    @Bindable var model: WorkspaceModel
    @Binding var recoveryFilter: RecoveryListFilter?
    /// Non-nil only for the home root: adds a toolbar button that surfaces
    /// the page-list sheet. Subpages get `nil` and don't show the icon.
    var onShowPageList: (() -> Void)? = nil

    @State private var editorState = EditorState()
    @Environment(\.scenePhase) private var scenePhase
    @FocusedValue(\.documentUndoController) private var undoController

    var body: some View {
        EditorView(
            document: Binding(
                get: { model.documentForPage(url: url) ?? document },
                set: { model.updateDocumentForPage($0) }
            ),
            state: editorState,
            suggestPages: { query in
                model.pages(matching: query, excludingCurrent: true)
            },
            onSubpageTap: { pageID in
                model.openSubpage(relativePath: pageID)
            },
            pageTitle: { pageID in
                model.pageTitle(for: pageID)
            },
            onCreateSubpage: { title, requestedID, initialContent in
                model.createSubpage(title: title, requestedPath: requestedID, initialContent: initialContent)
            },
            onLoadSubpage: { pageID in
                model.loadSubpage(relativePath: pageID)
            },
            onAbsorbSubpage: { pageID in
                model.moveSubpageToTrash(relativePath: pageID)
            },
            onAppendToSubpage: { pageID, blocks in
                model.appendToSubpage(relativePath: pageID, blocks: blocks)
            },
            onRequestMoveDestination: { blockIDs, completion in
                model.requestMoveDestination(blockIDs: blockIDs, completion: completion)
            },
            onNavigateBack: {
                model.goBack()
            },
            onEdited: {
                model.markEdited()
            },
            onBlur: {
                Task { await model.saveNow() }
            },
            onRecordBlockDeletion: { indices, blocks, actionName in
                model.recordBlockDeletion(indices: indices, blocks: blocks, actionName: actionName)
            },
            serializeBlocksForPasteboard: { blocks in
                BlockSerializer.serialize(blocks)
            },
            parseBlocksFromPasteboard: { string in
                let blocks = BlockParser.parse(string)
                return blocks.isEmpty ? nil : blocks
            }
        )
        .toolbar {
            if let onShowPageList {
                ToolbarItem(placement: .navigation) {
                    Button(action: onShowPageList) {
                        Image(systemName: "square.stack")
                    }
                    .accessibilityLabel("Show Page List")
                }
            }
            #if os(iOS)
            ToolbarItem(placement: .primaryAction) {
                Button {
                    undoController?.undoManager.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .accessibilityLabel("Undo")
                .disabled(!(undoController?.undoManager.canUndo ?? false))
                .contextMenu {
                    Button {
                        let relPath = workspaceRelativePath(for: url, root: model.workspaceURL)
                        recoveryFilter = .page(relativePath: relPath)
                    } label: {
                        Label("Recover lost blocks…", systemImage: "clock.arrow.circlepath")
                    }
                }
            }
            if undoController?.undoManager.canRedo == true {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        undoController?.undoManager.redo()
                    } label: {
                        Image(systemName: "arrow.uturn.forward")
                    }
                    .accessibilityLabel("Redo")
                }
            }
            #else
            // macOS keeps the clock toolbar icon — there's no toolbar Undo to long-press.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    let relPath = workspaceRelativePath(for: url, root: model.workspaceURL)
                    recoveryFilter = .page(relativePath: relPath)
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .accessibilityLabel("Recover")
            }
            #endif
            ToolbarItem(placement: .primaryAction) {
                EditorRecordingButton(state: editorState)
            }
        }
        .onAppear { forwardPendingVoiceRecording() }
        .onChange(of: scenePhase) { _, new in
            if new == .active { forwardPendingVoiceRecording() }
        }
        .onReceive(NotificationCenter.default.publisher(for: VoiceRecordingLaunchRequest.notificationName)) { _ in
            // The intent fires from another process and writes the pending-start
            // flag before posting the notification — consume the flag too so a
            // later `.active` transition doesn't fire a second time.
            _ = VoiceRecordingLaunchRequest.consumePendingStart()
            // Defer the state mutation off the publisher's synchronous delivery —
            // if the notification posts during a SwiftUI render pass the inline
            // assign trips "Modifying state during view update".
            Task { @MainActor in
                editorState.requestToggleVoiceRecording()
            }
        }
    }

    private func forwardPendingVoiceRecording() {
        guard VoiceRecordingLaunchRequest.consumePendingStart() else { return }
        editorState.requestToggleVoiceRecording()
    }

    private func workspaceRelativePath(for url: URL, root: URL?) -> String {
        guard let root else { return url.lastPathComponent }
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        if filePath.hasPrefix(rootPath + "/") {
            return String(filePath.dropFirst(rootPath.count + 1))
        }
        return url.lastPathComponent
    }
}

private struct WorkspacePickerView: View {
    let model: WorkspaceModel
    @State private var showingPicker = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 64))
                .foregroundStyle(NotionStyle.mutedForeground)
            Text("Choose a key file")
                .font(NotionStyle.body(size: 18, weight: .semibold))
                .foregroundStyle(NotionStyle.foreground)
            Text("Pick the .md file Hunch should open by default. Its folder becomes the workspace.")
                .font(NotionStyle.body(size: 14))
                .foregroundStyle(NotionStyle.mutedForeground)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Choose key file") {
                showingPicker = true
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NotionStyle.background)
        .fileImporter(
            isPresented: $showingPicker,
            allowedContentTypes: [markdownFileType],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    model.setWorkspaceFromKeyFile(url)
                }
            case .failure(let error):
                model.error = error.localizedDescription
            }
        }
    }
}

/// Sheet shell shared by the move-to and jump-to flows. Owns its own search
/// query so each presentation starts fresh. The currently-open document is
/// always excluded — both flows are about navigating somewhere else.
private struct PagePickerSheet: View {
    let title: String
    let model: WorkspaceModel
    let onPick: (MentionItem) -> Void
    let onCancel: () -> Void

    @State private var query: String = ""
    @State private var cursor: MentionItem.ID?

    private var items: [MentionItem] {
        model.pages(matching: query, excludingCurrent: true)
    }

    var body: some View {
        NavigationStack {
            PagePickerView(
                items: items,
                selection: $cursor,
                onActivate: { item in onPick(item) }
            )
            .onAppear {
                if cursor == nil { cursor = items.first?.id }
            }
            .onChange(of: query) { _, _ in
                cursor = items.first?.id
            }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $query, placement: .automatic, prompt: "Search pages")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 480)
        #endif
    }
}
