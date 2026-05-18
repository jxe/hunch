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

    private var presenterHandle: Clamshell.PresenterHandle?

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
    /// `clamshell.reconcile(at:)` (which parses, folds the journal, and
    /// auto-restores any lost subtrees in one step), installs the file
    /// presenter, and surfaces a banner if anything was restored.
    /// Back-navigation re-parses — markdown parse is cheap, and not caching
    /// means there's only one authoritative `Document` instance per page
    /// (the visible one) so no invalidation bookkeeping.
    func handlePathChange() {
        let topURL = path.last ?? homeURL
        if openDocument?.url == topURL { return }
        let outgoingFlush = closeOpenDocument()
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
            // Drain the outgoing doc's flush before loading the next — a
            // force-quit between path change and flush completion would
            // otherwise drop the last keystroke.
            if let outgoingFlush { await outgoingFlush.value }
            do {
                let (doc, summary) = try await clamshell.reconcile(at: url)
                // The user may have navigated again while we were awaiting.
                guard path.last ?? homeURL == url else { return }
                openDocument = doc
                workspace.refreshTitleCache(from: doc)
                installPresenter(for: doc)
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

    /// Tear down the file presenter and return a Task that flushes
    /// `openDocument` through Clamshell. Callers that can await (e.g.
    /// navigation handlers, which are already inside a Task) should
    /// await the returned value before swapping the document — a force-
    /// quit between path change and flush completion would otherwise
    /// drop the last keystroke. Fire-and-forget callers can discard.
    /// Returns nil when there's nothing to flush. Idempotent.
    @discardableResult
    func closeOpenDocument() -> Task<Void, Never>? {
        removePresenter()
        guard let doc = openDocument, let clamshell = workspace.clamshell else { return nil }
        return Task { _ = await clamshell.flush(doc) }
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
            removePresenter()
            await clamshell.flush(doc)
            self.openDocument = nil
        }
        path.removeAll { $0 == entry.url }
        return workspace.moveToTrash(at: entry.url)
    }

    @discardableResult
    func appendToSubpage(relativePath: String, blocks: [Block]) async -> Bool {
        guard !blocks.isEmpty, let clamshell = workspace.clamshell else { return false }
        let target = clamshell.url(for: relativePath)
        guard let doc = await workspace.appendToSubpage(relativePath: relativePath, blocks: blocks) else {
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

    // MARK: - File presenter

    /// Install Clamshell's NSFilePresenter on `doc.url`. Filesystem-level
    /// work (conflict merge, content reload, journal reconcile) happens
    /// inside Clamshell on every wakeup; the callback below handles only
    /// the UI/workspace reactions (banners, rescan, title cache).
    private func installPresenter(for doc: Document) {
        removePresenter()
        guard let clamshell = workspace.clamshell else { return }
        let url = doc.url
        presenterHandle = clamshell.installPresenter(for: doc) { [weak self] event in
            guard let self else { return }
            switch event {
            case .conflictMerged(let salvaged) where salvaged > 0:
                let noun = salvaged == 1 ? "block" : "blocks"
                self.workspace.banner = .init(message: "Merged \(salvaged) \(noun) from another device into \(doc.title)")
            case .restored(let count):
                let noun = count == 1 ? "block" : "blocks"
                self.workspace.banner = .init(message: "Restored \(count) \(noun) from another device into \(doc.title)")
            case .externallyReloaded:
                self.workspace.refreshTitleCache(from: doc)
            case .conflictMerged, .noteworthyNothing:
                break
            }
            self.workspace.rescan()
        }
        workspace.registerOpenURL(url)
    }

    private func removePresenter() {
        guard let handle = presenterHandle else { return }
        if let clamshell = workspace.clamshell {
            clamshell.removePresenter(handle)
        }
        if let url = openDocument?.url {
            workspace.unregisterOpenURL(url)
        }
        presenterHandle = nil
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
