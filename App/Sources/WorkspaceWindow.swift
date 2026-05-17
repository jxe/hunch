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
    /// Unified page-search sheet — replaces the old jump-to and page-list sheets.
    /// Selecting a result pushes the page onto the nav stack (or resets to home
    /// when the result *is* home), preserving the trail.
    var showSearch: Bool = false
    var recoveryFilter: RecoveryListFilter?

    struct MoveRequest: Identifiable {
        let id = UUID()
        let blockIDs: [BlockID]
        let inDocCandidates: [InDocMoveTarget]
        let completion: (MoveDestination?) -> Void
    }

    private var filePresenter: DocumentFilePresenter?

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
                path = []
            }
        } else if path != [entry.url] {
            path = [entry.url]
        }
    }

    /// Search-result activation: push the picked page onto the navstack so the
    /// back trail is preserved. If the picked page *is* home and we're already
    /// at the root, do nothing; if it's home from a deeper page, drain the
    /// path back to root rather than pushing home on top of itself.
    func navigateFromSearch(relativePath: String) {
        if relativePath == workspace.homeRelativePath {
            if !path.isEmpty {
                path = []
            }
            return
        }
        openSubpage(relativePath: relativePath)
    }

    /// Subpage / inline link: push deeper.
    func openSubpage(relativePath: String) {
        guard let clamshell = workspace.clamshell else { return }
        let target = clamshell.url(for: relativePath)
        if path.last == target { return }
        path.append(target)
    }

    func goBack() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    func closeDocument() {
        path = []
    }

    /// Reconcile `openDocument` with the currently visible page. Driven by
    /// `.onChange(of: path)` in `ContentView`. The new page's coordinator
    /// (which owns the save session) is built lazily by `EditorPage`; this
    /// function loads the `Document` fresh from disk via
    /// `clamshell.loadAndReconcile` (which parses, folds the journal, and
    /// auto-restores any lost subtrees in one step), installs the file
    /// presenter, and surfaces a banner if anything was restored.
    /// Back-navigation re-parses — markdown parse is cheap, and not caching
    /// means there's only one authoritative `Document` instance per page
    /// (the visible one) so no invalidation bookkeeping.
    func handlePathChange() {
        let topURL = path.last ?? homeURL
        if openDocument?.url == topURL { return }
        closeOpenDocument()
        guard let url = topURL else {
            openDocument = nil
            return
        }
        guard let clamshell = workspace.clamshell else {
            do {
                let doc = try workspace.loadDocument(at: url)
                openDocument = doc
                workspace.refreshTitleCache(from: doc)
            } catch {
                workspace.error = "Failed to load \(url.lastPathComponent): \(error.localizedDescription)"
            }
            return
        }
        Task { @MainActor in
            do {
                let (doc, summary) = try await clamshell.loadAndReconcile(at: url)
                // The user may have navigated again while we were awaiting.
                guard path.last ?? homeURL == url else { return }
                openDocument = doc
                workspace.refreshTitleCache(from: doc)
                installFilePresenter(for: url)
                postReconcileBanner(summary: summary, doc: doc, url: url)
            } catch {
                workspace.error = "Failed to load \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    private func postReconcileBanner(
        summary: PatchEngine.ReconcileSummary,
        doc: Document,
        url: URL
    ) {
        if !summary.unrestorable.isEmpty {
            let hashList = summary.unrestorable.map(\.hash).joined(separator: ",")
            Diag.merge.error("reconcile quarantining url=\(url.lastPathComponent, privacy: .public) count=\(summary.unrestorable.count, privacy: .public) hashes=\(hashList, privacy: .public)")
            for entry in summary.unrestorable {
                let reasonLabel: String
                switch entry.reason {
                case .parseFailure: reasonLabel = "parseFailure"
                case .hashMismatch(let actual, let kind): reasonLabel = "hashMismatch actual=\(actual) kind=\(kind)"
                case .descendantOfUnrestorableRoot(let rootHash): reasonLabel = "descendantOf=\(rootHash)"
                }
                let mdPreview = entry.recordedMarkdown
                    .prefix(160)
                    .replacingOccurrences(of: "\n", with: "\\n")
                Diag.merge.error("unrestorable hash=\(entry.hash, privacy: .public) reason=\(reasonLabel, privacy: .public) parent=\(entry.recordedParent ?? "nil", privacy: .public) recordedAt=\(entry.recordedAt.timeIntervalSince1970, privacy: .public) md=\(String(mdPreview), privacy: .public)")
            }
        }
        guard summary.didChange else { return }
        let count = summary.restoredHashes.count
        let noun = count == 1 ? "block" : "blocks"
        workspace.banner = .init(message: "Restored \(count) \(noun) from another device into \(doc.title)")
        Diag.merge.log("auto-restore url=\(url.lastPathComponent, privacy: .public) restored=\(count, privacy: .public) hashes=\(summary.restoredHashes.joined(separator: ","), privacy: .public)")
    }

    /// Workspace was dropped (switchWorkspace, etc.). Clear all per-window
    /// state. Called by `ContentView` via `.onChange(of: workspace.workspaceURL)`.
    func reset() {
        closeOpenDocument()
        openDocument = nil
        path = []
    }

    /// Tear down the file presenter and queue a final flush of `openDocument`
    /// through Clamshell. The flush survives this caller returning — the
    /// per-URL coordinator inside Clamshell serializes writes, so a rapid
    /// page switch doesn't drop the latest snapshot. Idempotent.
    func closeOpenDocument() {
        removeFilePresenter()
        guard let doc = openDocument, let clamshell = workspace.clamshell else { return }
        Task { await clamshell.flush(doc) }
    }

    // MARK: - Move-to picker

    func requestMoveDestination(
        blockIDs: [BlockID],
        inDocCandidates: [InDocMoveTarget],
        completion: @escaping (MoveDestination?) -> Void
    ) {
        moveRequest = MoveRequest(
            blockIDs: blockIDs,
            inDocCandidates: inDocCandidates,
            completion: completion
        )
    }

    func resolveMoveRequest(with destination: MoveDestination?) {
        guard let req = moveRequest else { return }
        moveRequest = nil
        req.completion(destination)
    }

    // MARK: - Document lookup

    /// Returns `openDocument` iff its URL matches — used by `ContentView` to
    /// gate the EditorPage construction on "is this page loaded yet". External
    /// reloads mutate the existing instance via `Document.replaceChildren`
    /// rather than swapping, so once `EditorPage` is mounted the Document
    /// reference is stable for its lifetime.
    func documentForPage(url: URL) -> Document? {
        openDocument?.url == url ? openDocument : nil
    }

    // The save lifecycle (600ms debounce, per-URL coalescing, post-save
    // bookkeeping) lives on `Clamshell`. The host calls
    // `clamshell.documentDidChange(ops:in:)` on every edit and
    // `clamshell.flush(_:)` on blur / scenePhase / navigation away.
    // Clamshell's `subpageTitleResolver` and `didSave` hooks (set in
    // `Workspace.makeClamshell`) handle serialization and per-doc
    // bookkeeping (mtime, title cache, rescan).

    // MARK: - Trash & restore (per-window)

    @discardableResult
    func moveToTrash(_ entry: WorkspaceEntry) async -> Bool {
        guard let clamshell = workspace.clamshell else { return false }
        if let doc = openDocument, doc.url == entry.url {
            // Drain any pending save BEFORE trashing so the in-memory state
            // is durably on disk first, then close the open doc. Awaiting
            // here (instead of fire-and-forget) means the trash op below
            // never races a save against a now-trashed URL.
            removeFilePresenter()
            await clamshell.flush(doc)
            self.openDocument = nil
        }
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
        // If this window has the subpage open (multi-window scenario), splice
        // the appended content into the live instance rather than swapping —
        // keeps the editor's state references stable.
        if let live = openDocument, live.url == target, live !== doc {
            live.replaceChildren(doc.children)
            live.modificationDate = doc.modificationDate
        }
        return true
    }

    @discardableResult
    func restoreRecoverable(_ entry: RecoverableEntry) async -> Bool {
        switch entry {
        case .deletedPage(let trashEntry):
            return await workspace.restoreDeletedPage(trashEntry)
        case .lostBlock(let group):
            return await performBlockRestore(.lost(group.root))
        case .purgedBlock(let group):
            return await performBlockRestore(.purged(group.root))
        }
    }

    private func performBlockRestore(_ target: Clamshell.RecoveryTarget) async -> Bool {
        guard let clamshell = workspace.clamshell else { return false }
        do {
            _ = try await clamshell.restore(target, liveDoc: openDocument)
            return true
        } catch Clamshell.RestoreError.pageMissing(let source) {
            workspace.error = "Original page no longer exists at \(source)."
            return false
        } catch Clamshell.RestoreError.unparseable {
            workspace.error = "Couldn't parse the recovered block."
            return false
        } catch {
            workspace.error = "Restore failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Reconcile the open document against the page's recovery-log journal.
    /// Thin wrapper around `Clamshell.reconcile(liveDoc:)` — the engine
    /// plumbing (read journal, derive intent, splice, append observations,
    /// quarantine unrestorables) lives there. Held off while the doc is
    /// dirty or a save is in flight (gated inside Clamshell).
    private func reconcileOpenDocumentAgainstLog(_ doc: Document) {
        guard let clamshell = workspace.clamshell else { return }
        Task { @MainActor [weak self] in
            guard let self, self.openDocument === doc else { return }
            let summary = await clamshell.reconcile(liveDoc: doc)
            guard self.openDocument === doc, summary.didChange else { return }
            let count = summary.restoredHashes.count
            let noun = count == 1 ? "block" : "blocks"
            self.workspace.banner = .init(message: "Restored \(count) \(noun) from another device into \(doc.title)")
        }
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
        workspace.registerOpenURL(url)
    }

    private func removeFilePresenter() {
        if let filePresenter {
            NSFileCoordinator.removeFilePresenter(filePresenter)
            if let url = filePresenter.presentedItemURL {
                workspace.unregisterOpenURL(url)
            }
        }
        filePresenter = nil
    }

    private func handlePresentedFileChange() async {
        guard let doc = openDocument else { workspace.rescan(); return }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled, openDocument === doc else { return }

        let url = doc.url
        // iCloud often delivers the `.md` and a sibling
        // `.history/<rel>/<other-device>.jsonl` in the same burst — by the
        // time the presenter wakes, we may have new log entries to act on
        // even if the `.md` hash hasn't changed. Re-run reconcile on every
        // wakeup; the engine is idempotent (already-live hashes produce no
        // inserts; already-logged hashes produce no observations) so back-
        // to-back calls cost just a journal read.
        defer { reconcileOpenDocumentAgainstLog(doc) }

        // Auto-merge any unresolved iCloud conflict versions before falling
        // back to the echo/stomp/external-edit branching. When the resolver
        // mutated the live `doc` in place, reseed per-doc state (mtime,
        // title cache) and surface the banner. Clamshell records the merged
        // bytes in its disk-content history internally.
        if let clamshell = workspace.clamshell {
            do {
                let resolution = try clamshell.resolveConflictVersions(
                    at: url,
                    againstLive: doc
                )
                if resolution.liveDocumentMutated {
                    // Mtime / title cache / rescan flow through `didSave`,
                    // which `writeExternal` (inside `resolveConflictVersions`)
                    // now fires.
                    let noun = resolution.salvaged == 1 ? "block" : "blocks"
                    workspace.banner = .init(message: "Merged \(resolution.salvaged) \(noun) from another device into \(doc.title)")
                    return
                }
            } catch {
                Diag.merge.error("presenter resolve failed url=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }

        guard let clamshell = workspace.clamshell else { workspace.rescan(); return }
        switch clamshell.classifyDiskContent(at: url, expectingModificationDate: doc.modificationDate) {
        case .unchanged:
            workspace.rescan()
        case .echo:
            openDocument?.modificationDate = workspace.modificationDate(for: url)
            workspace.rescan()
        case .stomp:
            // Reverted to a prior state we've seen on disk → likely an iCloud
            // Drive stomp. Re-save our in-memory authoritative copy, unless a
            // save is in flight or fresh dirty edits are pending (the
            // upcoming debounce save will overwrite anyway).
            if clamshell.isQuiescent(at: url), let doc = openDocument {
                Task { await clamshell.flush(doc) }
            }
            workspace.rescan()
        case .external:
            // Genuinely new content from outside Hunch. Reload only if no
            // unsaved in-memory edits would be lost. Swap the tree in place
            // via `replaceChildren` so the editor's `EditorState` keeps its
            // reference to the same Document instance — `didReplaceChildren`
            // fires inside, revalidating `state.cursor` / `state.selection`
            // against the freshly-parsed BlockIDs.
            guard clamshell.isQuiescent(at: url), let doc = openDocument else { workspace.rescan(); return }
            do {
                let reloaded = try workspace.loadDocument(at: url)
                doc.replaceChildren(reloaded.children)
                doc.modificationDate = reloaded.modificationDate
                workspace.refreshTitleCache(from: doc)
                workspace.rescan()
            } catch {
                workspace.error = "Failed to reload external changes: \(error.localizedDescription)"
            }
        case .unreadable:
            workspace.rescan()
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
