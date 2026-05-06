import Foundation
import SwiftUI
import Editor

/// Per-window navigation and edit-session state. One instance per
/// `WindowGroup` body (and per macOS tab) — `ContentView` owns it as
/// `@State`, so each new window/tab gets its own. References the shared
/// `Workspace` for filesystem-level operations (page list, save coordinator,
/// disk-history).
@MainActor
@Observable
final class WorkspaceWindow {
    let workspace: Workspace

    /// Stack of pages pushed *on top* of the home root, root → top. Empty =
    /// home page is visible. Bound to `NavigationStack(path:)`.
    var path: [URL] = []
    var canGoBack: Bool { !path.isEmpty }

    var openDocument: Document?

    var moveRequest: MoveRequest?
    var showJumpTo: Bool = false
    var showPageList: Bool = false
    var recoveryFilter: RecoveryListFilter?

    struct MoveRequest: Identifiable {
        let id = UUID()
        let blockIDs: [BlockID]
        let completion: (String?) -> Void
    }

    private var debounceTask: Task<Void, Never>?
    private var backstopTask: Task<Void, Never>?
    private var filePresenter: DocumentFilePresenter?
    private var isDirty = false
    private var isSaving = false
    private var documentCache: [URL: Document] = [:]

    init(workspace: Workspace) {
        self.workspace = workspace
    }

    var homeURL: URL? { workspace.homeURL }

    var currentPageRelativePath: String? {
        guard let url = openDocument?.url else { return nil }
        return workspace.clamshell?.relativePath(of: url)
    }

    // MARK: - Navigation

    /// Page-list selection: navigate to `entry`. If `entry` is the home page,
    /// drain the path so the home root becomes visible; otherwise replace the
    /// stack with a single entry pushed on top of home.
    func open(_ entry: WorkspaceEntry) {
        if entry.relativePath == workspace.homeRelativePath {
            if path.isEmpty {
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
        guard let clamshell = workspace.clamshell else { return }
        let target = clamshell.url(for: relativePath)
        if path.last == target { return }
        cacheOpenDocument()
        path.append(target)
    }

    /// Push a page onto the navstack — distinct from `open(_:)` which resets
    /// to a single entry above home. Used by ⌘P jump-to so jumping mid-stack
    /// preserves the trail.
    func jumpTo(_ relativePath: String) {
        guard let url = workspace.entries.first(where: { $0.relativePath == relativePath })?.url else { return }
        if path.last == url { return }
        cacheOpenDocument()
        path.append(url)
    }

    func goBack() {
        guard !path.isEmpty else { return }
        cacheOpenDocument()
        path.removeLast()
    }

    func closeDocument() {
        cacheOpenDocument()
        path = []
    }

    /// Reconcile `openDocument` with the currently visible page. Driven by
    /// `.onChange(of: path)` in `ContentView`.
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
            openDocument = try workspace.loadDocument(at: url)
            cacheOpenDocument()
            isDirty = false
            installFilePresenter(for: url)
            startBackstop()
        } catch {
            workspace.error = "Failed to load \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Workspace was dropped (switchWorkspace, etc.). Clear all per-window
    /// state. Called by `ContentView` via `.onChange(of: workspace.workspaceURL)`.
    func reset() {
        flushAndClose()
        openDocument = nil
        path = []
        documentCache = [:]
        isDirty = false
        isSaving = false
    }

    // MARK: - Move-to picker

    func requestMoveDestination(blockIDs: [BlockID], completion: @escaping (String?) -> Void) {
        moveRequest = MoveRequest(blockIDs: blockIDs, completion: completion)
    }

    func resolveMoveRequest(with pageID: String?) {
        guard let req = moveRequest else { return }
        moveRequest = nil
        req.completion(pageID)
    }

    // MARK: - Document binding

    func documentForPage(url: URL) -> Document? {
        if openDocument?.url == url {
            return openDocument
        }
        return documentCache[url]
    }

    func updateDocumentForPage(_ document: Document) {
        let updated = documentWithCurrentTitle(document)
        documentCache[updated.url] = updated
        let titleChanged = workspace.refreshTitleCache(from: updated)
        if openDocument?.url == updated.url {
            openDocument = updated
        }
        if titleChanged {
            workspace.refreshEntriesFromTitleCache()
        }
    }

    /// Refresh the document's title from its current top-level H1. Document
    /// is a class so this mutates in place; returns the same reference for
    /// call-site readability (`let updated = documentWithCurrentTitle(...)`).
    @discardableResult
    private func documentWithCurrentTitle(_ document: Document) -> Document {
        let fallback = document.url.deletingPathExtension().lastPathComponent
        document.title = Document.deriveTitle(from: document.children, fallback: fallback)
        return document
    }

    // MARK: - Save lifecycle

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

    func saveNow(force: Bool = false) async {
        debounceTask?.cancel()
        debounceTask = nil
        guard let doc = openDocument, let clamshell = workspace.clamshell else { return }
        guard force || isDirty else { return }
        do {
            isSaving = true
            defer { isSaving = false }
            let resolver = workspace.saveTitleResolver()
            // Re-serialize locally so we can record the post-save hash. The
            // coordinator serializes its own copy too — acceptable double-work.
            let serialized = BlockSerializer.serialize(doc.children, resolvingSubpageTitle: resolver)
            try await clamshell.save(doc, resolvingSubpageTitle: resolver)
            workspace.recordDiskText(serialized, for: doc.url)
            if openDocument?.url == doc.url {
                openDocument?.modificationDate = workspace.modificationDate(for: doc.url)
                cacheOpenDocument()
                if let openDocument {
                    workspace.refreshTitleCache(from: openDocument)
                }
            }
            isDirty = false
            workspace.rescan()
        } catch {
            workspace.error = "Save failed: \(error.localizedDescription)"
        }
    }

    /// Cancel pending tasks and ensure any unsaved edits land on disk before
    /// returning. The save is enqueued through the per-URL coordinator (it
    /// survives this caller returning) so a rapid page switch doesn't drop
    /// the latest snapshot.
    func flushAndClose() {
        debounceTask?.cancel(); debounceTask = nil
        backstopTask?.cancel(); backstopTask = nil
        removeFilePresenter()
        guard let doc = openDocument, let clamshell = workspace.clamshell else { return }
        let wasDirty = isDirty
        isDirty = false
        let resolver = workspace.saveTitleResolver()
        let serialized = wasDirty ? BlockSerializer.serialize(doc.children, resolvingSubpageTitle: resolver) : nil
        let url = doc.url
        Task { [clamshell, doc, wasDirty, resolver, serialized, weak workspace] in
            if wasDirty {
                try? await clamshell.save(doc, resolvingSubpageTitle: resolver)
                if let serialized {
                    await MainActor.run {
                        workspace?.recordDiskText(serialized, for: url)
                    }
                }
            }
            try? await clamshell.flush(url: url)
        }
    }

    // MARK: - Trash & restore (per-window)

    @discardableResult
    func moveToTrash(_ entry: WorkspaceEntry) -> Bool {
        guard let clamshell = workspace.clamshell else { return false }
        if openDocument?.url == entry.url {
            if isDirty, let openDocument {
                do {
                    try clamshell.writeImmediately(openDocument, resolvingSubpageTitle: workspace.saveTitleResolver())
                    isDirty = false
                } catch {
                    workspace.error = "Save failed: \(error.localizedDescription)"
                    return false
                }
            }
            flushAndClose()
            self.openDocument = nil
        }
        documentCache.removeValue(forKey: entry.url)
        path.removeAll { $0 == entry.url }
        return workspace.moveToTrash(at: entry.url)
    }

    @discardableResult
    func appendToSubpage(relativePath: String, blocks: [Block]) -> Bool {
        guard !blocks.isEmpty, let clamshell = workspace.clamshell else { return false }
        let target = clamshell.url(for: relativePath)
        guard let doc = workspace.appendToSubpage(relativePath: relativePath, blocks: blocks) else {
            return false
        }
        if openDocument?.url == target {
            openDocument = doc
            cacheOpenDocument()
        } else {
            documentCache[target] = doc
        }
        return true
    }

    func recordBlockDeletion(indices: [Int], blocks: [Block], actionName: String) {
        _ = indices
        _ = blocks
        _ = actionName
        guard let openDocument else { return }
        workspace.recordBlockDeletion(
            sourceURL: openDocument.url,
            previousBlocks: openDocument.children
        )
    }

    @discardableResult
    func restoreRecoverable(_ entry: RecoverableEntry) async -> Bool {
        switch entry {
        case .deletedPage(let trashEntry):
            return await workspace.restoreDeletedPage(trashEntry)
        case .lostBlock(let lost):
            return await restoreLostBlock(lost)
        }
    }

    @discardableResult
    func restoreLostBlock(_ entry: LostBlock) async -> Bool {
        guard let clamshell = workspace.clamshell, let workspaceURL = workspace.workspaceURL else { return false }
        let target = workspaceURL.appendingPathComponent(entry.record.source).standardizedFileURL
        guard FileManager.default.fileExists(atPath: target.path) else {
            workspace.error = "Original page no longer exists at \(entry.record.source)."
            return false
        }

        do {
            let parsed = BlockParser.parse(entry.record.markdown).map { $0.withFreshIDs() }
            guard !parsed.isEmpty else { return false }

            let useLiveDoc = (openDocument?.url == target)
            let doc: Document
            if useLiveDoc, let live = openDocument {
                doc = live
            } else {
                doc = try workspace.loadDocument(at: target)
            }

            // Restore as siblings of the anchor block (or appended at the
            // top level when the anchor isn't found). Tree depth is
            // implicit — `parsed` carries its own structure.
            if let anchorFP = entry.record.anchorFingerprint,
               let anchorID = findFingerprint(anchorFP, in: doc) {
                let parentID = doc.parent(of: anchorID)
                let siblings: [Block] = parentID.flatMap(doc.find)?.children ?? doc.children
                let i = siblings.firstIndex(where: { $0.id == anchorID }) ?? siblings.count - 1
                doc.insertSubtrees(parsed, at: DropPath(parent: parentID, position: i + 1))
            } else if let original = entry.record.originalIndex {
                let pos = min(max(0, original), doc.children.count)
                doc.insertSubtrees(parsed, at: DropPath(parent: nil, position: pos))
            } else {
                doc.insertSubtrees(parsed, at: DropPath(parent: nil, position: doc.children.count))
            }
            // Restored blocks may have inserted as siblings of headings; fold
            // them in so the recovered shape matches the rest of the doc.
            doc.enforceHeadingContainment()
            doc.title = Document.deriveTitle(from: doc.children, fallback: target.deletingPathExtension().lastPathComponent)

            if useLiveDoc {
                openDocument = doc
                cacheOpenDocument()
                markEdited()
            } else {
                try clamshell.writeImmediately(doc, resolvingSubpageTitle: workspace.saveTitleResolver())
                doc.modificationDate = workspace.modificationDate(for: target)
                documentCache[target] = doc
                if let raw = try? clamshell.readRawText(at: target) {
                    workspace.recordDiskText(raw, for: target)
                }
                workspace.rescan()
            }
            try? await clamshell.purgeLostBlock(entry)
            return true
        } catch {
            workspace.error = "Restore failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Find the block with the given fingerprint anywhere in the document
    /// tree. Used by the recovery / lost-block restore path to anchor inserts.
    private func findFingerprint(_ fp: String, in doc: Document) -> BlockID? {
        var match: BlockID?
        doc.walk { block, _, _ in
            if match == nil, BlockFingerprint.compute(block) == fp {
                match = block.id
            }
        }
        return match
    }

    // MARK: - File presenter

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
        guard let doc = openDocument else { workspace.rescan(); return }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled, openDocument?.url == doc.url else { return }

        let url = doc.url
        let currentMTime = workspace.modificationDate(for: url)
        if currentMTime == doc.modificationDate { workspace.rescan(); return }

        guard let diskText = try? workspace.clamshell?.readRawText(at: url) else {
            workspace.rescan(); return
        }
        let diskHash = diskText.hashValue
        let history = workspace.diskHistory[url] ?? []

        if history.first == diskHash {
            // Echo of what we just loaded or wrote.
            openDocument?.modificationDate = currentMTime
            cacheOpenDocument()
            workspace.rescan()
            return
        }
        if history.contains(diskHash) {
            // Reverted to a prior state we've seen on disk → likely an
            // iCloud Drive stomp. Re-save our in-memory authoritative copy,
            // unless the user has a save in flight or fresh dirty edits
            // (the upcoming debounce save will overwrite anyway).
            if !isSaving && !isDirty {
                Task { await self.saveNow(force: true) }
            }
            workspace.rescan()
            return
        }
        // Genuinely new content from outside Hunch. Reload only if no
        // unsaved in-memory edits would be lost.
        if isSaving || isDirty {
            workspace.rescan()
            return
        }
        do {
            let reloaded = try workspace.loadDocument(at: url)
            openDocument = reloaded
            cacheOpenDocument()
            workspace.refreshTitleCache(from: reloaded)
            workspace.rescan()
        } catch {
            workspace.error = "Failed to reload external changes: \(error.localizedDescription)"
        }
    }

    private func cacheOpenDocument() {
        guard let openDocument else { return }
        documentCache[openDocument.url] = openDocument
        workspace.refreshTitleCache(from: openDocument)
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
}

// MARK: - File presenter shim

final class DocumentFilePresenter: NSObject, NSFilePresenter {
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

// MARK: - FocusedValue plumbing

struct WorkspaceWindowFocusedValueKey: FocusedValueKey {
    typealias Value = WorkspaceWindow
}

extension FocusedValues {
    var workspaceWindow: WorkspaceWindow? {
        get { self[WorkspaceWindowFocusedValueKey.self] }
        set { self[WorkspaceWindowFocusedValueKey.self] = newValue }
    }
}
