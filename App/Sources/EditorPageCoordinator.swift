import Foundation
import Editor

/// Per-page bridge between `EditorView` and the host's document/workspace
/// layer. Owns the open-document save lifecycle (debounce + 30s backstop +
/// in-flight/pending coalescing on top of `Clamshell.save`) for its
/// document. One instance per `EditorPage` view-identity (held in `@State`),
/// so its identity is stable across SwiftUI re-renders — that's what lets
/// `EditorView` pass it through `.equatable()`-gated subviews without the
/// closure-identity churn that 17 individual `@escaping` callbacks caused.
///
/// Lifecycle: created in `EditorPage.init`, `onAppear` registers it as the
/// window's `activeCoordinator` (weak), `onDisappear` calls `flushAndClose`
/// and clears the registration. `WorkspaceWindow.markEdited` / `saveNow` /
/// `flushAndClose` are thin facades that route to the active coordinator.
///
/// Save lifecycle simplified to one boolean (`isDirty`) plus the in-flight
/// task: `markDirty` flips the bit and (re)schedules a 600ms debounce. The
/// debounce — or a force save — claims the dirty bit and runs `performSave`.
/// If more edits arrive while a save is in flight, `isDirty` flips back to
/// true and the post-completion check schedules another debounce. The
/// underlying `Clamshell.DocumentSaveCoordinator` already serializes writes
/// per URL, so there's no `.savingDirty` distinction to track.
@MainActor
final class EditorPageCoordinator: EditorHost {
    let url: URL
    let document: Document
    let workspace: Workspace
    let window: WorkspaceWindow

    // MARK: - Save lifecycle

    /// Debounce window for "user stopped typing → save". 600ms.
    static let debounceInterval: Duration = .milliseconds(600)
    /// Periodic save when the user keeps editing without ever stopping long
    /// enough to trigger debounce. 30s.
    static let backstopInterval: Duration = .seconds(30)

    private(set) var isDirty: Bool = false
    private(set) var isSaving: Bool = false
    private var closed: Bool = false
    private var debounceTask: Task<Void, Never>?
    private var backstopTask: Task<Void, Never>?

    init(url: URL, document: Document, workspace: Workspace, window: WorkspaceWindow) {
        self.url = url
        self.document = document
        self.workspace = workspace
        self.window = window
        startBackstop()
    }

    /// Note that the document was edited. Flips `isDirty` and (re)schedules
    /// the 600ms debounce. No-op once `closed`.
    func markDirty() {
        guard !closed else { return }
        isDirty = true
        scheduleDebounce()
    }

    /// Save immediately. Cancels any pending debounce. Returns true on success
    /// or when there was nothing to save; false on save failure. `force: true`
    /// saves even when not dirty (used by the trash-while-dirty and
    /// absorb-subpage paths, which need a guaranteed-on-disk snapshot).
    @discardableResult
    func saveNow(force: Bool = false) async -> Bool {
        debounceTask?.cancel(); debounceTask = nil
        guard !closed else { return true }
        guard force || isDirty else { return true }
        // Claim the current dirty bit for this save. New edits arriving during
        // the save will flip it back to true and the post-completion branch
        // schedules another debounce.
        isDirty = false
        isSaving = true
        let success = await performSave()
        isSaving = false
        if !success {
            isDirty = true
            scheduleDebounce()
        } else if isDirty {
            scheduleDebounce()
        }
        return success
    }

    /// Cancel pending tasks and queue a final save + flush. The save+flush
    /// survives this caller returning (the per-URL `DocumentSaveCoordinator`
    /// inside Clamshell handles the queuing) so a rapid page switch doesn't
    /// drop the latest snapshot. Idempotent.
    func flushAndClose() {
        debounceTask?.cancel(); debounceTask = nil
        backstopTask?.cancel(); backstopTask = nil
        guard !closed else { return }
        let wasDirty = isDirty
        closed = true
        Task { [workspace, doc = document, wasDirty] in
            if wasDirty {
                _ = await Self.performSave(document: doc, workspace: workspace)
            }
            try? await workspace.clamshell?.flush(url: doc.url)
        }
    }

    private func scheduleDebounce() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounceInterval)
            guard !Task.isCancelled else { return }
            await self?.saveNow()
        }
    }

    private func startBackstop() {
        backstopTask?.cancel()
        backstopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.backstopInterval)
                guard !Task.isCancelled else { return }
                await self?.saveNow()
            }
        }
    }

    /// Serialize + persist this coordinator's document through Clamshell, then
    /// update per-doc bookkeeping (mtime, title cache, disk-hash, rescan). The
    /// "is this still the visible doc" gate avoids stomping a fresher page's
    /// state when a stale backstop save lands after the user navigated away.
    private func performSave() async -> Bool {
        await Self.performSave(document: document, workspace: workspace, openIfStillVisible: window)
    }

    /// Static helper so `flushAndClose` can dispatch a final save without
    /// holding `self` alive — the queued Task captures `document` and
    /// `workspace` directly and survives the coordinator going away.
    private static func performSave(
        document: Document,
        workspace: Workspace,
        openIfStillVisible window: WorkspaceWindow? = nil
    ) async -> Bool {
        guard let clamshell = workspace.clamshell else { return true }
        do {
            let resolver = workspace.saveTitleResolver()
            _ = try await clamshell.save(document, resolvingSubpageTitle: resolver)
            if let window, window.openDocument === document {
                document.modificationDate = workspace.modificationDate(for: document.url)
                workspace.refreshTitleCache(from: document)
            }
            workspace.rescan()
            return true
        } catch {
            workspace.error = "Save failed: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - EditorHost

    func suggestPages(_ query: String) -> [MentionItem] {
        workspace.pages(matching: query, excluding: window.openDocument?.url)
    }

    @discardableResult
    func openLink(_ target: LinkTarget) -> Bool {
        switch target {
        case .workspacePage(let pageID):
            window.openSubpage(relativePath: pageID)
            return true
        case .url(let url):
            // Workspace-relative `*.md` links resolve against the open doc's
            // URL (or home if we're at the root) and navigate internally.
            // Everything else falls through to the system handler.
            let currentDocURL = window.path.last ?? workspace.homeURL
            if let rel = workspace.workspaceRelativeMarkdownPath(for: url, currentDocURL: currentDocURL) {
                window.openSubpage(relativePath: rel)
                return true
            }
            return false
        }
    }

    func lookupPage(_ pageID: String) -> PageLookup {
        workspace.lookupPage(pageID)
    }

    func onCreateSubpage(_ title: String, _ requestedID: String?, _ initialContent: [Block]?) -> String? {
        workspace.createSubpage(title: title, requestedPath: requestedID, initialContent: initialContent)
    }

    func onLoadSubpage(_ pageID: String) -> [Block]? {
        workspace.loadSubpage(relativePath: pageID)
    }

    func onAbsorbSubpage(_ pageID: String) async -> Bool {
        // The editor calls this immediately after the inline-content mutation
        // and relies on the host to durably persist the parent doc before the
        // source file is trashed. Without the force-save here, the autosave is
        // still debounced — and a crash in that window would leave the source
        // gone and the inlined content unpersisted.
        guard let clamshell = workspace.clamshell else { return false }
        let target = clamshell.url(for: pageID)
        guard FileManager.default.fileExists(atPath: target.path) else { return false }
        guard await saveNow(force: true) else {
            Diag.subpage.error("onAbsorbSubpage: force-save failed; skipping trash of \(pageID, privacy: .public) to avoid data loss")
            return false
        }
        return workspace.moveSubpageToTrash(relativePath: pageID)
    }

    func onAppendToSubpage(_ pageID: String, _ blocks: [Block]) -> Bool {
        window.appendToSubpage(relativePath: pageID, blocks: blocks)
    }

    func onRequestMoveDestination(_ blockIDs: [BlockID], _ inDocCandidates: [InDocMoveTarget], _ pick: @escaping (MoveDestination?) -> Void) {
        window.requestMoveDestination(blockIDs: blockIDs, inDocCandidates: inDocCandidates, completion: pick)
    }

    func onNavigateBack() {
        window.goBack()
    }

    func markDocumentDirty() {
        markDirty()
    }

    func didMutate(pre: [Block], post: Document, name: String) {
        guard let clamshell = workspace.clamshell else { return }
        let rel = clamshell.relativePath(of: post.url)
        // Snapshot pre into recovery log to catch any blocks the device hasn't
        // seen — including transient blocks that appeared in an earlier
        // mutation, were never saved (debounce window), and are about to
        // change here. Cheap when nothing's new (RecoveryLog dedupes by
        // device-known hash set).
        clamshell.snapshotIntoRecoveryLog(at: post.url, blocks: pre)
        // Snapshot post too: blocks added by *this* mutation aren't in `pre`,
        // so without this path they'd only land in the log via the next
        // mutation's pre snapshot — and never at all if no further mutation
        // happens. The dedup cache makes a second walk effectively free.
        clamshell.snapshotIntoRecoveryLog(at: post.url, blocks: post.children)
        // Tombstone any block whose id was in pre but isn't in post.
        let preByID = BlockTreeDiff.idToAtomicHash(pre)
        for hash in BlockTreeDiff.removedHashes(preByID: preByID, post: post.children) {
            Task { [clamshell, rel, hash] in
                do {
                    try await clamshell.purgeHash(hash, in: rel)
                } catch {
                    Diag.merge.error("purgeHash failed page=\(rel, privacy: .public) hash=\(hash, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    func onBlur() async {
        await saveNow(force: true)
    }

    func serializeBlocksForPasteboard(_ blocks: [Block]) -> String {
        BlockSerializer.serialize(blocks, consecutiveNumbering: true)
    }

    func parseBlocksFromPasteboard(_ string: String) -> [Block]? {
        let blocks = BlockParser.parse(string)
        return blocks.isEmpty ? nil : blocks
    }

    func onSaveImages(_ items: [PastedImage]) -> [String] {
        workspace.saveImages(items)
    }

    var linkPreviewProvider: LinkPreviewProvider? {
        workspace.linkPreviewService.provider()
    }

    var imageURLResolver: ImageURLResolver? {
        // ImageURLResolver is `@Sendable`, so the closure can't directly call
        // a MainActor method on `workspace`. The renderer always invokes the
        // resolver on the main thread (image rows render in SwiftUI body), so
        // `assumeIsolated` is sound here — and matches the original ContentView
        // call site, which got the same isolation inferred from being inside
        // a MainActor `body`.
        { [workspace] source in
            MainActor.assumeIsolated { workspace.imageURL(for: source) }
        }
    }
}
