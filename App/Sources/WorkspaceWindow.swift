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

    /// Document currently rendered by `EditorPage`. Owned-by-clamshell once
    /// it's been opened (`openPage`); `nil` between navigations and on
    /// workspaces without a home page set.
    var openDocument: Document? { openPage?.document }

    private var openPage: Clamshell.OpenPage?

    var moveRequest: MoveRequest?
    /// Unified page-search sheet — replaces the old jump-to and page-list sheets.
    /// Selecting a result pushes the page onto the nav stack (or resets to home
    /// when the result *is* home), preserving the trail.
    var showSearch: Bool = false
    var recoveryFilter: RecoveryListFilter?

    struct MoveRequest: Identifiable {
        let id = UUID()
        let inDocCandidates: [InDocMoveTarget]
        let completion: (MoveDestination?) -> Void
    }

    init(workspace: Workspace) {
        self.workspace = workspace
    }

    var currentPageRelativePath: String? {
        guard let url = openDocument?.url else { return nil }
        return workspace.clamshell?.relativePath(of: url)
    }

    // MARK: - Navigation

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

    /// Reconcile `openDocument` with the currently visible page. Driven by
    /// `.onChange(of: path)` in `ContentView`. Drains the outgoing
    /// document's pending writes before loading the next via
    /// `clamshell.openPage(at:)`, which folds the journal, auto-restores
    /// any lost subtrees, and installs the file presenter. Banner-worthy
    /// reconcile outcomes are surfaced via `postReconcileBanner`.
    func handlePathChange() {
        let topURL = path.last ?? workspace.homeURL
        if openDocument?.url == topURL { return }
        let outgoing = openPage
        openPage = nil
        guard let url = topURL, let clamshell = workspace.clamshell else {
            if let outgoing, let priorClamshell = workspace.clamshell {
                Task { await priorClamshell.closePage(outgoing) }
            }
            return
        }
        Task { @MainActor in
            let total = perfStart()
            // Drain the outgoing doc's flush before loading the next — a
            // force-quit between path change and flush completion would
            // otherwise drop the last keystroke.
            if let outgoing {
                let drain = perfStart()
                await clamshell.closePage(outgoing)
                workspace.unregisterOpenURL(outgoing.document.url)
                perfEnd(drain, "handlePathChange.drainOutgoing")
            }
            do {
                let openT = perfStart()
                let open = try await clamshell.openPage(at: url) { [weak self] event in
                    self?.handlePresenterEvent(event)
                }
                perfEnd(openT, "handlePathChange.openPage", "url=\(url.lastPathComponent)")
                // The user may have navigated again while we were awaiting.
                guard path.last ?? workspace.homeURL == url else {
                    await clamshell.closePage(open)
                    return
                }
                openPage = open
                workspace.registerOpenURL(url)
                perfEnd(total, "handlePathChange.total", "url=\(url.lastPathComponent)")
                // First successful openPage per mount triggers the deferred
                // conflict sweep — keeps the home-page critical path clear of
                // the 49× NSFileVersion sweep until the editor is visible.
                workspace.scheduleConflictSweepIfNeeded()
            } catch {
                workspace.error = "Failed to load \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    private func handlePresenterEvent(_ event: Clamshell.PresenterEvent) {
        guard let doc = openDocument else { return }
        switch event {
        case .conflictMerged(let salvaged) where salvaged > 0:
            workspace.banner = .merged(salvaged: salvaged, into: doc.title)
        case .restored(let count):
            workspace.banner = .restored(count: count, into: doc.title)
        case .externallyReloaded, .conflictMerged, .noteworthyNothing:
            break
        }
    }

    /// Workspace was dropped (switchWorkspace, etc.). Clear all per-window
    /// state. Called by `ContentView` via `.onChange(of: workspace.workspaceURL)`.
    func reset() {
        if let outgoing = openPage, let clamshell = workspace.clamshell {
            Task { await clamshell.closePage(outgoing) }
            workspace.unregisterOpenURL(outgoing.document.url)
        }
        openPage = nil
        path = []
    }

    // MARK: - Move-to picker

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

    // The save lifecycle (commit-time atomic save, per-URL Task chain,
    // post-save bookkeeping) lives on `Clamshell`. The host calls
    // `clamshell.documentDidChange(ops:in:)` at every edit-session commit
    // point and `clamshell.flush(_:)` on blur / scenePhase / navigation
    // away. Clamshell keeps the title cache + entries in sync internally;
    // the host doesn't thread anything through it.

    // MARK: - Trash & restore (per-window)

    @discardableResult
    func moveToTrash(_ entry: WorkspaceEntry) async -> Bool {
        guard let clamshell = workspace.clamshell else { return false }
        if let outgoing = openPage, outgoing.document.url == entry.url {
            // Drain the open document BEFORE trashing so its last edits
            // are durable, then close the page and drop the presenter so
            // the trash op below never races a save against a now-
            // trashed URL.
            await clamshell.closePage(outgoing)
            workspace.unregisterOpenURL(outgoing.document.url)
            openPage = nil
        }
        path.removeAll { $0 == entry.url }
        do {
            _ = try clamshell.moveToTrash(at: entry.url)
            return true
        } catch {
            workspace.error = "Failed to move \(clamshell.relativePath(of: entry.url)) to trash: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func restoreRecoverable(_ entry: RecoverableEntry) async -> Bool {
        switch entry {
        case .deletedPage(let trashEntry):
            return await workspace.restoreDeletedPage(trashEntry)
        case .lostBlock(let group):
            return await restoreBlock(.lost(group.root))
        case .purgedBlock(let group):
            return await restoreBlock(.purged(group.root))
        }
    }

    private func restoreBlock(_ target: Clamshell.RecoveryTarget) async -> Bool {
        guard let clamshell = workspace.clamshell else { return false }
        do {
            try await clamshell.restoreBlocks(target, liveDoc: openDocument)
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
