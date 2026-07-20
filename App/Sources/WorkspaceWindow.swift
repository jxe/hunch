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
    /// it's been opened (`PageSession`); `nil` between navigations and on
    /// workspaces without a home page set. Computed from `pageSession` (a
    /// tracked stored property) so the two can't drift.
    var openDocument: Document? { pageSession?.document }
    private(set) var cloudSyncSnapshot: Clamshell.CloudSyncSnapshot?
    private(set) var isCompactingLog = false

    @ObservationIgnored private var navigationTask: Task<Void, Never>?
    @ObservationIgnored private var loadingTargetURL: URL?
    @ObservationIgnored private var navigationRequestID = 0
    @ObservationIgnored private var cloudSyncPollingTask: Task<Void, Never>?
    @ObservationIgnored private var sessionsByDocument: [ObjectIdentifier: Clamshell.PageSession] = [:]

    private var pageSession: Clamshell.PageSession?

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
    /// `clamshell.page(at:).open()`, which folds the journal, auto-restores
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

        let outgoing = pageSession
        clearPageSession()
        guard let url = topURL, let clamshell = workspace.clamshell else {
            if let outgoing {
                navigationTask = Task { @MainActor [weak self, outgoing, requestID] in
                    guard let self else { return }
                    defer { self.finishNavigationRequest(requestID) }
                    do {
                        try await outgoing.close()
                    } catch {
                        workspace.banner = .saveFailed(page: outgoing.document.title, error: error)
                    }
                    self.forgetSession(outgoing)
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
                    try await outgoing.close()
                } catch {
                    workspace.banner = .saveFailed(page: outgoing.document.title, error: error)
                }
                self.forgetSession(outgoing)
                workspace.unregisterOpenURL(outgoing.document.url)
                perfEnd(drain, "handlePathChange.drainOutgoing")
            }
            guard !Task.isCancelled, self.navigationRequestID == requestID else { return }
            do {
                let openT = perfStart()
                let open = try await clamshell.page(at: url).open { [weak self] event in
                    self?.handlePresenterEvent(event)
                }
                perfEnd(openT, "handlePathChange.pageOpen", "url=\(url.lastPathComponent)")
                // The user may have navigated again while we were awaiting.
                guard !Task.isCancelled,
                      self.navigationRequestID == requestID,
                      currentTargetURL() == url else {
                    do {
                        try await open.close()
                    } catch {
                        workspace.banner = .saveFailed(page: open.document.title, error: error)
                    }
                    return
                }
                setPageSession(open)
                refreshCloudSyncSnapshot()
                startCloudSyncPolling(for: open.document)
                workspace.registerOpenURL(url)
                perfEnd(total, "handlePathChange.total", "url=\(url.lastPathComponent)")
                // First successful page session per mount triggers the deferred
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
    /// The session retains its Clamshell, so it can still close even after the
    /// workspace drops its reference. `Clamshell.drain()` remains the terminal
    /// durability backstop during workspace switching.
    func reset() {
        navigationTask?.cancel()
        navigationTask = nil
        loadingTargetURL = nil
        navigationRequestID += 1
        if let outgoing = pageSession {
            Task {
                do {
                    try await outgoing.close()
                } catch {
                    workspace.banner = .saveFailed(page: outgoing.document.title, error: error)
                }
                forgetSession(outgoing)
            }
            workspace.unregisterOpenURL(outgoing.document.url)
        }
        clearPageSession()
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

    func session(for document: Document) -> Clamshell.PageSession? {
        sessionsByDocument[ObjectIdentifier(document)]
    }

    // MARK: - iCloud sync snapshot

    func refreshCloudSyncSnapshot() {
        guard let pageSession else {
            cloudSyncSnapshot = nil
            return
        }
        cloudSyncSnapshot = pageSession.cloudSyncSnapshot()
    }

    func compactCurrentPageLog() {
        guard !isCompactingLog, let session = pageSession else { return }
        let document = session.document
        isCompactingLog = true
        Task { @MainActor [weak self, document, session] in
            guard let self else { return }
            defer {
                self.isCompactingLog = false
                self.refreshCloudSyncSnapshot()
            }
            do {
                guard self.openDocument === document else { return }
                _ = try await session.compactThisDeviceLog()
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

    private func setPageSession(_ session: Clamshell.PageSession) {
        sessionsByDocument[ObjectIdentifier(session.document)] = session
        pageSession = session
    }

    private func forgetSession(_ session: Clamshell.PageSession) {
        let key = ObjectIdentifier(session.document)
        guard sessionsByDocument[key] === session else { return }
        sessionsByDocument[key] = nil
    }

    private func clearPageSession() {
        stopCloudSyncPolling()
        pageSession = nil
        cloudSyncSnapshot = nil
        dismissedRenameSuggestions.removeAll()
    }

    private func finishNavigationRequest(_ requestID: Int) {
        guard navigationRequestID == requestID else { return }
        loadingTargetURL = nil
        navigationTask = nil
    }

    // The save lifecycle (commit-time atomic save, per-URL PageCoordinator,
    // post-save bookkeeping) lives on `Clamshell`. The host's
    // `EditorHost.persistCommit` conformance calls
    // `PageSession.enqueueEditorOps(ops)`
    // synchronously at every edit-session commit point (so the coordinator is
    // never blind to a just-fired commit), and `PageSession.flush()`
    // awaits its writer on blur / scenePhase / navigation away. Clamshell
    // keeps the title cache + entries in sync internally; the host
    // doesn't thread anything through it.

    // MARK: - Trash & restore (per-window)

    @discardableResult
    func moveToTrash(_ entry: WorkspaceEntry) async -> Bool {
        guard let clamshell = workspace.clamshell else { return false }
        if let outgoing = pageSession, outgoing.document.url == entry.url {
            // Drain the open document BEFORE trashing so its last edits
            // are durable, then close the page and drop the presenter so
            // the trash op below never races a save against a now-
            // trashed URL.
            do {
                try await outgoing.close()
            } catch {
                workspace.banner = .saveFailed(page: outgoing.document.title, error: error)
                return false
            }
            forgetSession(outgoing)
            workspace.unregisterOpenURL(outgoing.document.url)
            clearPageSession()
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
    func moveCurrentPageToTrash() async -> Bool {
        guard let clamshell = workspace.clamshell,
              let relativePath = currentPageRelativePath,
              let entry = clamshell.entry(at: relativePath) else {
            return false
        }
        return await moveToTrash(entry)
    }

    // MARK: - Rename to match title

    /// Per-session set of `(relativePath|proposedName)` suggestions the user
    /// has already dismissed, so a dismissed banner doesn't re-appear on the
    /// next keystroke. Cleared on navigation.
    @ObservationIgnored private var dismissedRenameSuggestions: Set<String> = []

    private func renameSuggestionKey(rel: String, proposed: String) -> String { "\(rel)|\(proposed)" }

    /// The filename the current page's title would rename to, when it
    /// diverges from the current filename. Nil when they already match or
    /// there's no open page.
    var pendingRenameProposal: String? {
        guard let clamshell = workspace.clamshell,
              let rel = currentPageRelativePath,
              let doc = openDocument,
              !Clamshell.filenameMatchesTitle(relativePath: rel, title: doc.title) else {
            return nil
        }
        return clamshell.availablePagePath(for: doc.title, excludingCurrent: rel)
    }

    /// Called on title change (debounced in `ContentView`) and after a page
    /// opens: offer to rename the file to match a diverged title, unless the
    /// user already dismissed this exact suggestion.
    func evaluateRenameSuggestion() {
        guard let rel = currentPageRelativePath, let proposed = pendingRenameProposal else { return }
        let key = renameSuggestionKey(rel: rel, proposed: proposed)
        guard !dismissedRenameSuggestions.contains(key) else { return }
        let name = (proposed as NSString).lastPathComponent
        workspace.banner = Workspace.Banner(
            message: "Rename file to \"\(name)\" to match its title?",
            systemImage: "pencil",
            dismissAfter: nil,
            action: .init(label: "Rename") { [weak self] in
                self?.dismissedRenameSuggestions.insert(key)
                Task { await self?.renameCurrentPageToMatchTitle() }
            }
        )
        dismissedRenameSuggestions.insert(key)
    }

    /// Rename the visible page's file to match its title. Mirrors the trash
    /// choreography: refuse when the page is open in another window, close +
    /// forget the session, rename through Clamshell, then re-point `path` so
    /// the page reopens at its new URL via `handlePathChange`.
    @discardableResult
    func renameCurrentPageToMatchTitle() async -> Bool {
        guard let clamshell = workspace.clamshell,
              let session = pageSession else { return false }
        let oldURL = session.document.url
        let title = session.document.title
        let wasHome = clamshell.isHome(relativePath: clamshell.relativePath(of: oldURL))

        if workspace.openCount(of: oldURL) > 1 {
            workspace.banner = Workspace.Banner(
                message: "Close other windows showing this page before renaming.",
                kind: .warning,
                systemImage: "exclamationmark.triangle"
            )
            return false
        }

        do {
            try await session.close()
        } catch {
            workspace.banner = .saveFailed(page: title, error: error)
            return false
        }
        forgetSession(session)
        workspace.unregisterOpenURL(oldURL)
        clearPageSession()

        let result: Clamshell.RenameResult
        do {
            result = try await clamshell.renamePage(at: oldURL, toMatchTitle: title)
        } catch {
            workspace.error = "Couldn't rename \(title): \(error.localizedDescription)"
            handlePathChange()
            return false
        }

        guard result.newRelativePath != result.oldRelativePath else {
            handlePathChange()
            return true
        }

        let newURL = clamshell.url(for: result.newRelativePath)
        if wasHome && path.isEmpty {
            // Home page: path stays `[]`; currentTargetURL() follows the
            // updated home pointer. Force the reload directly.
            handlePathChange()
        } else {
            path = path.map { $0.standardizedFileURL == oldURL.standardizedFileURL ? newURL : $0 }
            if openDocument == nil { handlePathChange() }
        }
        return true
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
            try await clamshell.page(atPath: target.source).restore(target)
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
