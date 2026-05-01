import SwiftUI
import Core
import UI
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
    /// Stack of pushed document URLs, root → top. Empty = page list root visible.
    /// Bound to `NavigationStack(path:)`; mutating drives push/pop, and the
    /// NavigationStack writes back here on edge-swipe / system back.
    var path: [URL] = []
    var canGoBack: Bool { !path.isEmpty }

    private let store = FileStore()
    private let saver = DocumentSaveCoordinator()
    private var debounceTask: Task<Void, Never>?
    private var backstopTask: Task<Void, Never>?
    private var titleRefreshTask: Task<Void, Never>?
    private var filePresenter: DocumentFilePresenter?
    private var accessedWorkspaceURL: URL?
    private var isDirty = false
    private var isSaving = false
    private var documentCache: [URL: Document] = [:]
    private var titleCache: [URL: CachedTitle] = [:]
    private var trashStore: TrashStore?
    private var historyStore: HistoryStore?

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
        if let persisted = WorkspaceBookmark.resolve() {
            accessedWorkspaceURL = persisted.url
            workspaceURL = persisted.url
            homeRelativePath = persisted.homeRelativePath
            installRecoveryStores(for: persisted.url)
            rescan()
            if let homeRelativePath,
               let entry = entries.first(where: { $0.relativePath == homeRelativePath }) {
                open(entry)
            }
        }
    }

    private func installRecoveryStores(for root: URL) {
        trashStore = TrashStore(workspaceRoot: root)
        historyStore = HistoryStore(workspaceRoot: root)
    }

    func setWorkspaceFromKeyFile(_ url: URL) {
        let root = url.deletingLastPathComponent()
        let homePath = url.lastPathComponent
        do {
            try WorkspaceBookmark.save(url: root, homeRelativePath: homePath)
            activateWorkspaceAccess(for: root)
            workspaceURL = root
            homeRelativePath = homePath
            installRecoveryStores(for: root)
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
            try WorkspaceBookmark.save(url: url, homeRelativePath: nil)
            activateWorkspaceAccess(for: url)
            workspaceURL = url
            homeRelativePath = nil
            installRecoveryStores(for: url)
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
        trashStore = nil
        historyStore = nil
        titleRefreshTask?.cancel()
        titleRefreshTask = nil
        path = []
    }

    func rescan() {
        guard let workspaceURL else { return }
        do {
            let scanned = try store.scan(workspaceRoot: workspaceURL)
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

    /// Sidebar tap: reset the stack to just this entry. The list is only visible
    /// at `path == []`, so this is effectively the "open from the root" path.
    func open(_ entry: WorkspaceEntry) {
        if path == [entry.url] { return }
        cacheOpenDocument()
        path = [entry.url]
    }

    /// Subpage / inline link: push deeper.
    func openSubpage(relativePath: String) {
        guard let target = urlForRelativePath(relativePath) else { return }
        if path.last == target { return }
        cacheOpenDocument()
        path.append(target)
    }

    func setHome(_ entry: WorkspaceEntry) {
        homeRelativePath = entry.relativePath
        WorkspaceBookmark.setHomeRelativePath(entry.relativePath)
    }

    @discardableResult
    func moveToTrash(_ entry: WorkspaceEntry) -> Bool {
        guard let workspaceURL else { return false }
        if openDocument?.url == entry.url {
            if isDirty, let openDocument {
                do {
                    try store.save(openDocument, resolvingSubpageTitle: saveTitleResolver())
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
            _ = try store.moveToTrash(relativePath: entry.relativePath, workspaceRoot: workspaceURL)
            if homeRelativePath == entry.relativePath {
                homeRelativePath = nil
                WorkspaceBookmark.setHomeRelativePath(nil)
            }
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

    /// Reconcile `openDocument` with `path.last`. Call from a `.onChange(of: path)`
    /// observer in the view layer. Handles all three transitions (push, pop,
    /// drain to empty); flushes the outgoing doc before loading the new one.
    func handlePathChange() {
        let topURL = path.last
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
            openDocument = try store.loadDocument(at: url)
            cacheOpenDocument()
            isDirty = false
            installFilePresenter(for: url)
            startBackstop()
        } catch {
            self.error = "Failed to load \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func createSubpage(title: String, requestedPath: String?, initialContent: String?) -> String? {
        guard let workspaceURL else { return requestedPath }
        let path = requestedPath ?? availableSubpagePath(for: title)
        let target = workspaceURL.appendingPathComponent(path)
        do {
            let parent = target.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: target.path) {
                let body = initialContent ?? "# \(title)\n"
                try body.write(to: target, atomically: true, encoding: .utf8)
            }
            titleCache[target] = CachedTitle(title: title, modificationDate: modificationDate(for: target))
            rescan()
            return path
        } catch {
            self.error = "Failed to create \(path): \(error.localizedDescription)"
            return requestedPath
        }
    }

    func loadSubpage(relativePath: String) -> [Block]? {
        guard let workspaceURL else { return nil }
        let target = workspaceURL.appendingPathComponent(relativePath)
        guard let doc = try? store.loadDocument(at: target) else { return nil }
        return doc.blocks
    }

    @discardableResult
    func appendToSubpage(relativePath: String, blocks: [Block]) -> Bool {
        guard !blocks.isEmpty, let target = urlForRelativePath(relativePath) else { return false }
        do {
            var doc = try store.loadDocument(at: target)
            doc.blocks.append(contentsOf: blocks)
            doc.title = Document.deriveTitle(from: doc.blocks, fallback: target.deletingPathExtension().lastPathComponent)
            try store.save(doc, resolvingSubpageTitle: saveTitleResolver())
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
        guard let workspaceURL else { return false }
        let target = workspaceURL.appendingPathComponent(relativePath)
        documentCache.removeValue(forKey: target)
        titleCache.removeValue(forKey: target)
        do {
            _ = try store.moveToTrash(relativePath: relativePath, workspaceRoot: workspaceURL)
            if homeRelativePath == relativePath {
                homeRelativePath = nil
                WorkspaceBookmark.setHomeRelativePath(nil)
            }
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
        guard isDirty, let doc = openDocument else { return }
        do {
            isSaving = true
            defer { isSaving = false }
            let resolver = saveTitleResolver()
            try await saver.save(doc, resolvingSubpageTitle: resolver)
            if openDocument?.url == doc.url {
                openDocument?.modificationDate = modificationDate(for: doc.url)
                cacheOpenDocument()
                if let openDocument {
                    refreshTitleCache(from: openDocument)
                }
            }
            isDirty = false
            scheduleHistorySnapshot(for: doc, resolver: resolver)
            rescan()
        } catch {
            self.error = "Save failed: \(error.localizedDescription)"
        }
    }

    private func scheduleHistorySnapshot(for document: Document, resolver: @Sendable @escaping (String) -> String?) {
        guard let historyStore, let workspaceURL else { return }
        let relPath = relativePath(of: document.url, under: workspaceURL)
        let contents = BlockSerializer.serialize(document.blocks, resolvingSubpageTitle: resolver)
        Task.detached { [historyStore] in
            try? await historyStore.snapshotIfNeeded(relativePath: relPath, contents: contents)
        }
    }

    private func relativePath(of url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        if filePath.hasPrefix(rootPath + "/") {
            return String(filePath.dropFirst(rootPath.count + 1))
        }
        return url.lastPathComponent
    }

    func flushAndClose() {
        debounceTask?.cancel()
        debounceTask = nil
        backstopTask?.cancel()
        backstopTask = nil
        removeFilePresenter()
        guard let doc = openDocument else { return }
        Task { [saver, doc] in
            try? await saver.flush(url: doc.url)
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
            openDocument = try store.loadDocument(at: doc.url)
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
        guard let url = urlForRelativePath(relativePath) else { return nil }
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
        guard !stale.isEmpty else { return }

        titleRefreshTask?.cancel()
        let store = self.store
        titleRefreshTask = Task.detached(priority: .utility) { [weak self, store, stale, workspaceURL] in
            var refreshed: [URL: CachedTitle] = [:]
            for entry in stale {
                guard !Task.isCancelled else { return }
                if let title = try? store.loadDocumentTitle(at: entry.url) {
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

    private func urlForRelativePath(_ relativePath: String) -> URL? {
        guard let workspaceURL else { return nil }
        return workspaceURL.appendingPathComponent(relativePath).standardizedFileURL
    }

    private func availableSubpagePath(for title: String) -> String {
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
        while let workspaceURL,
              FileManager.default.fileExists(atPath: workspaceURL.appendingPathComponent(candidate).path) {
            candidate = "\(stem)-\(suffix).md"
            suffix += 1
        }
        return candidate
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
            entries = try store.scan(workspaceRoot: root)
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
            entries = try store.scan(workspaceRoot: root)
            if let entry = entries.first(where: { $0.relativePath == "everything.md" }) {
                open(entry)
            }
        } catch {
            self.error = "Failed to install tall-doc UI test workspace: \(error.localizedDescription)"
        }
    }

    // MARK: - Recovery (trash + history)

    /// Fire-and-forget capture of a block-level deletion. Called from `PageView`'s
    /// delete paths before the document mutation so the block contents survive.
    func recordBlockDeletion(indices: [Int], blocks: [Block], actionName: String) {
        guard let trashStore, let workspaceURL, let openDocument else { return }
        let source = relativePath(of: openDocument.url, under: workspaceURL)
        Task.detached { [trashStore, source, indices, blocks, actionName] in
            try? await trashStore.recordBlockDeletion(
                source: source,
                indices: indices,
                blocks: blocks,
                actionName: actionName
            )
        }
    }

    func listDeletedEntries() async -> [TrashEntry] {
        guard let trashStore else { return [] }
        return (try? await trashStore.listEntries()) ?? []
    }

    @discardableResult
    func restoreDeletedPage(_ entry: TrashEntry) async -> Bool {
        guard let trashStore else { return false }
        do {
            _ = try await trashStore.restorePage(entry)
            rescan()
            return true
        } catch {
            self.error = "Restore failed: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func restoreDeletedBlocks(_ entry: TrashEntry) async -> Bool {
        guard let trashStore, let workspaceURL else { return false }
        do {
            let payload = try await trashStore.loadDeletedBlocks(entry)
            let target = workspaceURL.appendingPathComponent(payload.source).standardizedFileURL
            guard FileManager.default.fileExists(atPath: target.path) else {
                self.error = "Original page no longer exists at \(payload.source)."
                return false
            }
            var doc = try store.loadDocument(at: target)
            // Insert in original order at recorded indices. The recorded index already
            // reflects the position in the original (pre-deletion) array, so by the time
            // we insert the i-th block, prior inserts have re-filled positions 0..i-1
            // and the current insertion index equals the original index.
            for (i, originalIndex) in payload.indices.enumerated() {
                let insertAt = min(max(0, originalIndex), doc.blocks.count)
                doc.blocks.insert(payload.blocks[i], at: insertAt)
            }
            doc.title = Document.deriveTitle(from: doc.blocks, fallback: target.deletingPathExtension().lastPathComponent)
            try store.save(doc, resolvingSubpageTitle: saveTitleResolver())
            try? await trashStore.deleteRecord(entry)

            doc.modificationDate = modificationDate(for: target)
            documentCache[target] = doc
            if openDocument?.url == target {
                openDocument = doc
            }
            rescan()
            return true
        } catch {
            self.error = "Restore failed: \(error.localizedDescription)"
            return false
        }
    }

    func listSnapshots(for relativePath: String) async -> [HistorySnapshot] {
        guard let historyStore else { return [] }
        return (try? await historyStore.listSnapshots(for: relativePath)) ?? []
    }

    func loadSnapshotContent(_ snapshot: HistorySnapshot) async -> String? {
        guard let historyStore else { return nil }
        return try? await historyStore.loadSnapshot(snapshot)
    }

    /// Replace the currently open document's contents with the snapshot. Marks dirty
    /// and schedules a save, which itself snapshots the just-replaced state — keeping
    /// the operation reversible from history.
    @discardableResult
    func restoreSnapshot(_ snapshot: HistorySnapshot) async -> Bool {
        guard let workspaceURL else { return false }
        let target = workspaceURL.appendingPathComponent(snapshot.relativePath).standardizedFileURL
        guard let content = await loadSnapshotContent(snapshot) else { return false }
        let blocks = BlockParser.parse(content)
        let title = Document.deriveTitle(from: blocks, fallback: target.deletingPathExtension().lastPathComponent)

        // Force-snapshot the live pre-restore state so the restore itself is reversible
        // even if the live edits are younger than the 5-minute debounce window.
        await snapshotPreRestore(targetURL: target)

        if openDocument?.url == target {
            var doc = openDocument!
            doc.blocks = blocks
            doc.title = title
            openDocument = doc
            cacheOpenDocument()
            markEdited()
            return true
        }
        do {
            var doc = try store.loadDocument(at: target)
            doc.blocks = blocks
            doc.title = title
            try store.save(doc, resolvingSubpageTitle: saveTitleResolver())
            documentCache[target] = doc
            rescan()
            return true
        } catch {
            self.error = "Restore failed: \(error.localizedDescription)"
            return false
        }
    }

    private func snapshotPreRestore(targetURL: URL) async {
        guard let historyStore, let workspaceURL else { return }
        let relPath = relativePath(of: targetURL, under: workspaceURL)
        let resolver = saveTitleResolver()
        let currentBlocks: [Block]
        if let openDocument, openDocument.url == targetURL {
            currentBlocks = openDocument.blocks
        } else if let cached = documentCache[targetURL] {
            currentBlocks = cached.blocks
        } else if let loaded = try? store.loadDocument(at: targetURL) {
            currentBlocks = loaded.blocks
        } else {
            return
        }
        let serialized = BlockSerializer.serialize(currentBlocks, resolvingSubpageTitle: resolver)
        try? await historyStore.snapshotIfNeeded(
            relativePath: relPath,
            contents: serialized,
            minInterval: 0
        )
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
    @State private var showingRecentlyDeleted = false
    @State private var versionHistoryURL: URL?

    var body: some View {
        Group {
            if model.workspaceURL == nil {
                WorkspacePickerView(model: model)
            } else {
                NavigationStack(path: $model.path) {
                    sidebar
                        .navigationDestination(for: URL.self) { url in
                            pageDetail(for: url)
                        }
                }
                // `initial: true` covers the path-restored-by-tryRestore case where
                // the NavigationStack mounts with a non-empty path; without it
                // `openDocument` would never load and `pageDetail` would render
                // the ProgressView fallback forever.
                .onChange(of: model.path, initial: true) { _, _ in
                    model.handlePathChange()
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

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.error != nil },
            set: { newValue in if !newValue { model.error = nil } }
        )
    }

    /// Drives `PageListView`'s selection. The list is only visible at
    /// `path == []` (NavigationStack root), so the highlight reflects the
    /// root-pushed doc and tapping a row pushes onto the stack via
    /// `model.open`. Nil writes (auto-deselect on stack pop) are ignored —
    /// NavigationStack itself owns the path.
    private var pageSelection: Binding<WorkspaceEntry.ID?> {
        Binding(
            get: { model.path.first },
            set: { newID in
                if let id = newID, let entry = model.entries.first(where: { $0.id == id }) {
                    model.open(entry)
                }
            }
        )
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Pages")
                .font(NotionStyle.body(size: 13).weight(.semibold))
                .foregroundStyle(NotionStyle.mutedForeground)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            PageListView(
                entries: model.entries,
                homeRelativePath: model.homeRelativePath,
                selection: pageSelection,
                searchText: $pageSearchText,
                onSetHome: { entry in
                    model.setHome(entry)
                },
                onMoveToTrash: { entry in
                    _ = model.moveToTrash(entry)
                }
            )
            Divider()
            Button {
                showingRecentlyDeleted = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "trash")
                    Text("Recently Deleted")
                    Spacer()
                }
                .font(NotionStyle.body())
                .foregroundStyle(NotionStyle.mutedForeground)
                .contentShape(Rectangle())
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $showingRecentlyDeleted) {
            RecentlyDeletedView(
                loadEntries: { await model.listDeletedEntries() },
                onRestorePage: { entry in await model.restoreDeletedPage(entry) },
                onRestoreBlocks: { entry in await model.restoreDeletedBlocks(entry) },
                onClose: { showingRecentlyDeleted = false }
            )
            .frame(minWidth: 480, minHeight: 480)
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

    private struct URLBox: Identifiable, Hashable {
        let url: URL
        var id: URL { url }
    }

    @ViewBuilder
    private func versionHistorySheet(for url: URL) -> some View {
        let relPath = workspaceRelativePath(for: url)
        let title = model.documentForPage(url: url)?.title
            ?? url.deletingPathExtension().lastPathComponent
        VersionHistoryView(
            pageTitle: title,
            relativePath: relPath,
            loadSnapshots: { await model.listSnapshots(for: relPath) },
            loadContent: { snapshot in await model.loadSnapshotContent(snapshot) },
            onRestore: { snapshot in await model.restoreSnapshot(snapshot) },
            onClose: { versionHistoryURL = nil }
        )
        .frame(minWidth: 600, minHeight: 480)
    }

    private func workspaceRelativePath(for url: URL) -> String {
        guard let root = model.workspaceURL else { return url.lastPathComponent }
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        if filePath.hasPrefix(rootPath + "/") {
            return String(filePath.dropFirst(rootPath.count + 1))
        }
        return url.lastPathComponent
    }

    @ViewBuilder
    private func pageDetail(for url: URL) -> some View {
        if let document = model.documentForPage(url: url) {
            PageView(
                document: Binding(
                    get: { model.documentForPage(url: url) ?? document },
                    set: { model.updateDocumentForPage($0) }
                ),
                entries: model.entries,
                onSubpageTap: { relativePath in
                    model.openSubpage(relativePath: relativePath)
                },
                pageTitle: { relativePath in
                    model.pageTitle(for: relativePath)
                },
                onCreateSubpage: { title, requestedPath, initialContent in
                    model.createSubpage(title: title, requestedPath: requestedPath, initialContent: initialContent)
                },
                onLoadSubpage: { relativePath in
                    model.loadSubpage(relativePath: relativePath)
                },
                onMoveSubpageToTrash: { relativePath in
                    model.moveSubpageToTrash(relativePath: relativePath)
                },
                onAppendToSubpage: { relativePath, blocks in
                    model.appendToSubpage(relativePath: relativePath, blocks: blocks)
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
                }
            )
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        versionHistoryURL = url
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .accessibilityLabel("Version History")
                }
            }
            .sheet(item: Binding(
                get: { versionHistoryURL.map(URLBox.init) },
                set: { versionHistoryURL = $0?.url }
            )) { box in
                versionHistorySheet(for: box.url)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(NotionStyle.background)
        }
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
                .font(NotionStyle.body(size: 18).weight(.semibold))
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
