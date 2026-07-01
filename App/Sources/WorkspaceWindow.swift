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
    var canNavigateBack: Bool { !path.isEmpty }

    /// Document currently rendered by `EditorPage`. Owned-by-clamshell once
    /// it's been opened (`openPage`); `nil` between navigations and on
    /// workspaces without a home page set. Computed from `openPage` (a
    /// tracked stored property) so the two can't drift.
    var openDocument: Document? { openPage?.document }
    private(set) var cloudSyncSnapshot: Clamshell.CloudSyncSnapshot?
    private(set) var isCompactingLog = false

    @ObservationIgnored private var navigationTask: Task<Void, Never>?
    @ObservationIgnored private var loadingTargetURL: URL?
    @ObservationIgnored private var navigationRequestID = 0
    @ObservationIgnored private var cloudSyncPollingTask: Task<Void, Never>?

    private var openPage: Clamshell.OpenPage?

    var moveRequest: MoveRequest?
    /// Unified page-search sheet — replaces the old jump-to and page-list sheets.
    /// Selecting a result pushes the page onto the nav stack (or resets to home
    /// when the result *is* home), preserving the trail.
    var showSearch: Bool = false
    /// Destination picker for adding a link to the current page onto another
    /// page. Kept separate from `showSearch` so Cmd-P and Cmd-Shift-P can
    /// present the same picker surface with distinct activation behavior.
    var showAddToPageSearch: Bool = false
    var recoveryFilter: RecoveryListFilter?
    var pendingSubpageTrashPrompt: SubpageTrashPrompt?

    struct MoveRequest: Identifiable {
        let id = UUID()
        let inDocCandidates: [InDocMoveTarget]
        let completion: (MoveDestination?) -> Void
    }

    struct SubpageTrashPrompt: Identifiable, Equatable {
        let id = UUID()
        let pageID: String
        let title: String
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
        if workspace.clamshell?.isHome(relativePath: relativePath) == true {
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

    func navigateBack() {
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
        let topURL = currentTargetURL()
        if let topURL, openDocument?.url.standardizedFileURL == topURL { return }
        if navigationTask != nil, loadingTargetURL == topURL { return }

        navigationTask?.cancel()
        navigationRequestID += 1
        let requestID = navigationRequestID
        loadingTargetURL = topURL

        let outgoing = openPage
        clearOpenPage()
        guard let url = topURL, let clamshell = workspace.clamshell else {
            if let outgoing, let priorClamshell = workspace.clamshell {
                navigationTask = Task { @MainActor [weak self, outgoing, priorClamshell, requestID] in
                    guard let self else { return }
                    defer { self.finishNavigationRequest(requestID) }
                    do {
                        try await priorClamshell.closePage(outgoing)
                    } catch {
                        workspace.banner = .saveFailed(page: outgoing.document.title, error: error)
                    }
                    workspace.unregisterOpenURL(outgoing.document.url)
                }
            } else {
                finishNavigationRequest(requestID)
            }
            return
        }
        navigationTask = Task { @MainActor [weak self, outgoing, url, clamshell, requestID] in
            guard let self else { return }
            defer { self.finishNavigationRequest(requestID) }
            let total = perfStart()
            // Drain the outgoing doc's flush before loading the next — a
            // force-quit between path change and flush completion would
            // otherwise drop the last keystroke.
            if let outgoing {
                let drain = perfStart()
                do {
                    try await clamshell.closePage(outgoing)
                } catch {
                    workspace.banner = .saveFailed(page: outgoing.document.title, error: error)
                }
                workspace.unregisterOpenURL(outgoing.document.url)
                perfEnd(drain, "handlePathChange.drainOutgoing")
            }
            guard !Task.isCancelled, self.navigationRequestID == requestID else { return }
            do {
                let openT = perfStart()
                let open = try await clamshell.openPage(at: url) { [weak self] event in
                    self?.handlePresenterEvent(event)
                }
                perfEnd(openT, "handlePathChange.openPage", "url=\(url.lastPathComponent)")
                // The user may have navigated again while we were awaiting.
                guard !Task.isCancelled,
                      self.navigationRequestID == requestID,
                      currentTargetURL() == url else {
                    do {
                        try await clamshell.closePage(open)
                    } catch {
                        workspace.banner = .saveFailed(page: open.document.title, error: error)
                    }
                    return
                }
                setOpenPage(open)
                refreshCloudSyncSnapshot()
                startCloudSyncPolling(for: open.document)
                workspace.registerOpenURL(url)
                perfEnd(total, "handlePathChange.total", "url=\(url.lastPathComponent)")
                // First successful openPage per mount triggers the deferred
                // conflict sweep — keeps the home-page critical path clear of
                // the 49× NSFileVersion sweep until the editor is visible.
                workspace.scheduleConflictSweepIfNeeded()
            } catch {
                if !Task.isCancelled, self.navigationRequestID == requestID {
                    workspace.error = "Failed to load \(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }
    }

    private func handlePresenterEvent(_ event: Clamshell.PresenterEvent) {
        guard let doc = openDocument else { return }
        switch event {
        case .conflictMerged(let salvaged):
            workspace.banner = .merged(salvaged: salvaged, into: doc.title)
        case .restored(let count):
            workspace.banner = .restored(count: count, into: doc.title)
        }
    }

    /// Workspace was dropped (switchWorkspace, etc.). Clear all per-window
    /// state. Called by `ContentView` via `.onChange(of: workspace.workspaceURL)`.
    /// When that fires the clamshell is already nil, so the closePage branch
    /// below is skipped — durability is backstopped by `Clamshell.drain()`,
    /// which `switchWorkspace` awaits before releasing the outgoing instance.
    func reset() {
        navigationTask?.cancel()
        navigationTask = nil
        loadingTargetURL = nil
        navigationRequestID += 1
        if let outgoing = openPage, let clamshell = workspace.clamshell {
            Task {
                do {
                    try await clamshell.closePage(outgoing)
                } catch {
                    workspace.banner = .saveFailed(page: outgoing.document.title, error: error)
                }
            }
            workspace.unregisterOpenURL(outgoing.document.url)
        }
        clearOpenPage()
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
    /// reloads mutate the existing instance via Document's named replacement
    /// helpers rather than swapping, so once `EditorPage` is mounted the
    /// Document reference is stable for its lifetime.
    func documentForPage(url: URL) -> Document? {
        openDocument?.url.standardizedFileURL == url.standardizedFileURL ? openDocument : nil
    }

    // MARK: - iCloud sync snapshot

    func refreshCloudSyncSnapshot() {
        guard let doc = openDocument, let clamshell = workspace.clamshell else {
            cloudSyncSnapshot = nil
            return
        }
        cloudSyncSnapshot = clamshell.cloudSyncSnapshot(for: doc)
    }

    func compactCurrentPageLog() {
        guard !isCompactingLog, let document = openDocument, let clamshell = workspace.clamshell else { return }
        isCompactingLog = true
        Task { @MainActor [weak self, document, clamshell] in
            guard let self else { return }
            defer {
                self.isCompactingLog = false
                self.refreshCloudSyncSnapshot()
            }
            do {
                // Direct clamshell flush (throwing) — compaction must abort
                // on a failed flush; the host's EditorHost.flush swallows.
                try await clamshell.flush(document)
                guard self.openDocument === document else { return }
                _ = try await clamshell.compactThisDeviceLog(for: document)
            } catch {
                self.workspace.error = "Failed to compact log: \(error.localizedDescription)"
            }
        }
    }

    private func startCloudSyncPolling(for document: Document) {
        cloudSyncPollingTask?.cancel()
        cloudSyncPollingTask = Task { @MainActor [weak self, weak document] in
            while !Task.isCancelled {
                guard let self, let document, self.openDocument === document else { return }
                self.refreshCloudSyncSnapshot()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func stopCloudSyncPolling() {
        cloudSyncPollingTask?.cancel()
        cloudSyncPollingTask = nil
    }

    private func currentTargetURL() -> URL? {
        (path.last ?? workspace.homeURL)?.standardizedFileURL
    }

    private func setOpenPage(_ open: Clamshell.OpenPage) {
        openPage = open
    }

    private func clearOpenPage() {
        stopCloudSyncPolling()
        openPage = nil
        cloudSyncSnapshot = nil
    }

    private func finishNavigationRequest(_ requestID: Int) {
        guard navigationRequestID == requestID else { return }
        loadingTargetURL = nil
        navigationTask = nil
    }

    // The save lifecycle (commit-time atomic save, per-URL SaveChain,
    // post-save bookkeeping) lives on `Clamshell`. The host's
    // `EditorHost.persistCommit` conformance calls
    // `clamshell.enqueueCommit(.fromEditorOps(ops), to: doc)`
    // synchronously at every edit-session commit point (so the chain is
    // never blind to a just-fired commit), and `clamshell.flush(_:)`
    // awaits the chain on blur / scenePhase / navigation away. Clamshell
    // keeps the title cache + entries in sync internally; the host
    // doesn't thread anything through it.

    // MARK: - Trash & restore (per-window)

    @discardableResult
    func moveToTrash(_ entry: WorkspaceEntry) async -> Bool {
        guard let clamshell = workspace.clamshell else { return false }
        if let outgoing = openPage, outgoing.document.url == entry.url {
            // Drain the open document BEFORE trashing so its last edits
            // are durable, then close the page and drop the presenter so
            // the trash op below never races a save against a now-
            // trashed URL.
            do {
                try await clamshell.closePage(outgoing)
            } catch {
                workspace.banner = .saveFailed(page: outgoing.document.title, error: error)
                return false
            }
            workspace.unregisterOpenURL(outgoing.document.url)
            clearOpenPage()
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
