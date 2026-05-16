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
    /// Owns the per-open-document save state machine (clean / dirty / saving /
    /// flushing) plus debounce + backstop tasks. Nil before any document is
    /// loaded and after `flushAndClose`. Replaced on every page-change.
    private var saveSession: DocumentSaveSession?
    private var isDirty: Bool { saveSession?.isDirty == true }
    private var isSaving: Bool { saveSession?.isSaving == true }
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

    /// Search-result activation: push the picked page onto the navstack so the
    /// back trail is preserved. If the picked page *is* home and we're already
    /// at the root, do nothing; if it's home from a deeper page, drain the
    /// path back to root rather than pushing home on top of itself.
    func navigateFromSearch(relativePath: String) {
        if relativePath == workspace.homeRelativePath {
            if !path.isEmpty {
                cacheOpenDocument()
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
        cacheOpenDocument()
        path.append(target)
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
            return
        }
        if let cached = documentCache[url] {
            openDocument = cached
            installSaveSession(for: url)
            installFilePresenter(for: url)
            reconcileOpenDocumentAgainstLog(for: url)
            return
        }
        do {
            openDocument = try workspace.loadDocument(at: url)
            cacheOpenDocument()
            installSaveSession(for: url)
            installFilePresenter(for: url)
            reconcileOpenDocumentAgainstLog(for: url)
        } catch {
            workspace.error = "Failed to load \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Create a fresh `DocumentSaveSession` for the given URL and start its
    /// 30s backstop. Captures the URL into the save/flush closures so the
    /// session is self-contained.
    private func installSaveSession(for url: URL) {
        let session = DocumentSaveSession(
            performSave: { [weak self] in
                await self?.performSave(for: url) ?? false
            },
            performFlush: { [weak workspace] in
                guard let clamshell = workspace?.clamshell else { return }
                try? await clamshell.flush(url: url)
            }
        )
        saveSession = session
        session.startBackstop()
    }

    /// The actual save work: serialize, write through Clamshell, record disk
    /// hash for stomp defense, refresh mtime/title cache, rescan the workspace.
    /// Called by `DocumentSaveSession` when its state transitions to `.saving`.
    private func performSave(for url: URL) async -> Bool {
        guard let doc = openDocument, doc.url == url,
              let clamshell = workspace.clamshell else { return true }
        do {
            let resolver = workspace.saveTitleResolver()
            let serialized = try await clamshell.save(doc, resolvingSubpageTitle: resolver)
            workspace.recordDiskText(serialized, for: doc.url)
            if openDocument?.url == doc.url {
                openDocument?.modificationDate = workspace.modificationDate(for: doc.url)
                cacheOpenDocument()
                if let openDocument {
                    workspace.refreshTitleCache(from: openDocument)
                }
            }
            workspace.rescan()
            return true
        } catch {
            workspace.error = "Save failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Workspace was dropped (switchWorkspace, etc.). Clear all per-window
    /// state. Called by `ContentView` via `.onChange(of: workspace.workspaceURL)`.
    func reset() {
        flushAndClose()
        openDocument = nil
        path = []
        documentCache = [:]
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

    // MARK: - Document binding

    func documentForPage(url: URL) -> Document? {
        if openDocument?.url == url {
            return openDocument
        }
        return documentCache[url]
    }

    func updateDocumentForPage(_ document: Document) {
        if documentCache[document.url] !== document {
            documentCache[document.url] = document
        }
        workspace.refreshTitleCache(from: document)
        if openDocument?.url == document.url, openDocument !== document {
            openDocument = document
        }
    }

    // MARK: - Save lifecycle (thin façade over DocumentSaveSession)

    func markEdited() {
        cacheOpenDocument()
        saveSession?.markDirty()
    }

    @discardableResult
    func saveNow(force: Bool = false) async -> Bool {
        await saveSession?.saveNow(force: force) ?? true
    }

    /// Cancel pending tasks and ensure any unsaved edits land on disk before
    /// returning. The save is enqueued through the per-URL coordinator (it
    /// survives this caller returning) so a rapid page switch doesn't drop
    /// the latest snapshot.
    func flushAndClose() {
        removeFilePresenter()
        saveSession?.flushAndClose()
        saveSession = nil
    }

    // MARK: - Trash & restore (per-window)

    @discardableResult
    func moveToTrash(_ entry: WorkspaceEntry) -> Bool {
        guard let clamshell = workspace.clamshell else { return false }
        if openDocument?.url == entry.url {
            if isDirty, let openDocument {
                do {
                    try clamshell.writeImmediately(openDocument, resolvingSubpageTitle: workspace.saveTitleResolver())
                } catch {
                    workspace.error = "Save failed: \(error.localizedDescription)"
                    return false
                }
            }
            // flushAndClose tears down the save session and queues any
            // pending save+flush. After writeImmediately above, the session
            // may still report .dirty (writeImmediately bypassed it); the
            // queued save in flushAndClose is then a redundant no-op write
            // that the per-URL coordinator coalesces — harmless.
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

    @discardableResult
    func restoreRecoverable(_ entry: RecoverableEntry) async -> Bool {
        switch entry {
        case .deletedPage(let trashEntry):
            return await workspace.restoreDeletedPage(trashEntry)
        case .lostBlock(let group):
            return await restoreLostBlock(group.root)
        case .purgedBlock(let purged):
            return await restorePurgedBlock(purged)
        }
    }

    /// Reconcile the open document against the page's recovery-log journal:
    ///
    /// - Insert any block the journal considers `.alive` that isn't currently
    ///   in `doc` (auto-restore), splicing under the closest live ancestor
    ///   via the engine's recorded-parent chain climb.
    /// - Lift any block present in `doc` but not in the journal (bare-md,
    ///   external-editor additions) into our device's log as fresh `add`
    ///   records, fire-and-forget.
    ///
    /// Called from `handlePathChange` (on page open) and the file-presenter
    /// wakeup. Idempotent: with no changes pending, the second call reads
    /// the journal and exits without I/O. Held off while the local doc is
    /// dirty or a save is in flight — the engine's invariant is `doc.children
    /// == parsed(.md)`, which is only true on a clean page.
    @MainActor
    private func reconcileOpenDocumentAgainstLog(for url: URL) {
        guard let clamshell = workspace.clamshell else { return }
        guard openDocument?.url == url, let doc = openDocument else { return }
        // Don't race with in-flight user edits or saves. The engine assumes
        // `doc.children == parsed(.md)` — only true when the page is clean.
        if isDirty || isSaving { return }

        let rel = clamshell.relativePath(of: url)
        let journal = clamshell.readJournal(forPage: rel)
        let intent = PatchEngine.intent(from: journal)
        let recon = PatchEngine.reconcile(intent: intent, doc: doc.children)

        // Bare-md / external-edit absorption: lift any unlogged blocks into
        // the journal as `add` observations. Fire-and-forget; the engine has
        // already deduped against the journal, the actor de-dupes against
        // our per-device cache.
        clamshell.appendObservations(recon.toAppend, forPage: rel)

        guard recon.didChange else { return }
        guard openDocument?.url == url else { return }

        PatchEngine.apply(recon, to: doc)
        cacheOpenDocument()
        markEdited()
        let restored = recon.restoredHashes.count
        let noun = restored == 1 ? "block" : "blocks"
        workspace.banner = .init(message: "Restored \(restored) \(noun) from another device into \(doc.title)")
        Diag.merge.log("auto-restore url=\(url.lastPathComponent, privacy: .public) restored=\(restored, privacy: .public) roots=\(recon.inserts.count, privacy: .public)")
    }

    @discardableResult
    func restoreLostBlock(_ entry: LostBlock) async -> Bool {
        guard let clamshell = workspace.clamshell, let workspaceURL = workspace.workspaceURL else { return false }
        let target = workspaceURL.appendingPathComponent(entry.source).standardizedFileURL
        guard FileManager.default.fileExists(atPath: target.path) else {
            workspace.error = "Original page no longer exists at \(entry.source)."
            return false
        }

        do {
            let useLiveDoc = (openDocument?.url == target)
            let doc: Document
            if useLiveDoc, let live = openDocument {
                doc = live
            } else {
                doc = try workspace.loadDocument(at: target)
            }

            // Engine input: the page's journal + the current doc. Falls back
            // to the entry passed in if the freshly-read journal no longer
            // surfaces the hash (rare race with a refresh).
            let journal = clamshell.readJournal(forPage: entry.source)
            let intent = PatchEngine.intent(from: journal)
            let candidates = intent.lostEntries(notIn: [], source: entry.source)
            let insert: PatchEngine.Insert
            if let primary = PatchEngine.insertion(
                rootHash: entry.hash,
                candidates: candidates,
                intent: intent,
                doc: doc.children
            ) {
                insert = primary
            } else if let fallback = PatchEngine.insertion(
                rootHash: entry.hash,
                candidates: [entry],
                intent: intent,
                doc: doc.children
            ) {
                insert = fallback
            } else {
                workspace.error = "Couldn't parse the recovered block."
                return false
            }

            let recon = PatchEngine.Reconciliation(
                inserts: [insert],
                restoredHashes: Array(insert.coveredHashes)
            )
            PatchEngine.apply(recon, to: doc)

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
            // Purge every hash in the restored subtree so the Recover sheet
            // stops surfacing it. Includes the clicked entry's hash and any
            // descendants we pulled in.
            for hash in insert.coveredHashes {
                try? await clamshell.purgeHash(hash, in: entry.source)
            }
            return true
        } catch {
            workspace.error = "Restore failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Restore a block the user intentionally deleted (latest log record is
    /// a `purge`). Mirror of `restoreLostBlock`: pulls the full purged set
    /// for the page, rebuilds the subtree rooted at the clicked entry, and
    /// inserts it under the closest live ancestor. Writes a fresh `add`
    /// record per restored hash so the union stops treating them as
    /// tombstoned — a plain doc save would skip the hashes (the device
    /// cache says "already recorded") and the tombstones would linger.
    @discardableResult
    func restorePurgedBlock(_ group: PurgedBlockGroup) async -> Bool {
        guard let clamshell = workspace.clamshell, let workspaceURL = workspace.workspaceURL else { return false }
        let target = workspaceURL.appendingPathComponent(group.source).standardizedFileURL
        guard FileManager.default.fileExists(atPath: target.path) else {
            workspace.error = "Original page no longer exists at \(group.source)."
            return false
        }

        do {
            let useLiveDoc = (openDocument?.url == target)
            let doc: Document
            if useLiveDoc, let live = openDocument {
                doc = live
            } else {
                doc = try workspace.loadDocument(at: target)
            }

            // Pull the full purged set for the page (no time cap — we know the
            // entry exists in the union or the row wouldn't have rendered),
            // adapt to LostBlock-shape (using purgedAt as recordedAt for forest
            // sorting), and ask the engine to build the insertion.
            let allPurged = await clamshell.listPurgedBlocks(
                filter: .page(relativePath: group.source),
                since: nil
            )
            let candidates: [LostBlock] = allPurged.map { p in
                LostBlock.adapt(
                    hash: p.hash,
                    parentHash: p.parentHash,
                    markdown: p.markdown,
                    source: p.source,
                    recordedAt: p.purgedAt
                )
            }
            let fallbackCandidate = LostBlock.adapt(
                hash: group.root.hash,
                parentHash: group.root.parentHash,
                markdown: group.root.markdown,
                source: group.root.source,
                recordedAt: group.root.purgedAt
            )
            let purgedByHash = Dictionary(uniqueKeysWithValues: allPurged.map { ($0.hash, $0) })

            let journal = clamshell.readJournal(forPage: group.source)
            let intent = PatchEngine.intent(from: journal)
            let insert: PatchEngine.Insert
            if let primary = PatchEngine.insertion(
                rootHash: group.hash,
                candidates: candidates,
                intent: intent,
                doc: doc.children
            ) {
                insert = primary
            } else if let fallback = PatchEngine.insertion(
                rootHash: group.hash,
                candidates: [fallbackCandidate],
                intent: intent,
                doc: doc.children
            ) {
                insert = fallback
            } else {
                workspace.error = "Couldn't parse the recovered block."
                return false
            }

            let recon = PatchEngine.Reconciliation(
                inserts: [insert],
                restoredHashes: Array(insert.coveredHashes)
            )
            PatchEngine.apply(recon, to: doc)

            // Unpurge each restored hash BEFORE the save so the save's
            // recovery-log walk sees them as already-recorded (in the
            // device cache) and doesn't immediately re-emit them.
            for hash in insert.coveredHashes {
                guard let purgedRecord = purgedByHash[hash],
                      let parsed = BlockParser.parse(purgedRecord.markdown).first else { continue }
                try? await clamshell.unpurgeBlock(
                    parsed,
                    in: group.source,
                    parentHash: purgedRecord.parentHash
                )
            }

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
            return true
        } catch {
            workspace.error = "Restore failed: \(error.localizedDescription)"
            return false
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
        guard !Task.isCancelled, openDocument?.url == doc.url else { return }

        let url = doc.url
        // iCloud often delivers the `.md` and a sibling
        // `.history/<rel>/<other-device>.jsonl` in the same burst — by the
        // time the presenter wakes, we may have new log entries to act on
        // even if the `.md` hash hasn't changed. Re-run reconcile on every
        // wakeup; the engine is idempotent (already-live hashes produce no
        // inserts; already-logged hashes produce no observations) so back-
        // to-back calls cost just a journal read.
        defer { reconcileOpenDocumentAgainstLog(for: url) }

        // Auto-merge any unresolved iCloud conflict versions before falling
        // back to the echo/stomp/external-edit branching. The live `doc` is
        // mutated in place when blocks get salvaged, so subsequent state
        // (diskHistory, mtime, title cache) needs reseeding.
        if let clamshell = workspace.clamshell {
            do {
                let salvaged = try clamshell.resolveConflictVersions(
                    at: url,
                    againstLive: doc,
                    resolvingSubpageTitle: workspace.saveTitleResolver()
                )
                if salvaged > 0 {
                    if let raw = try? clamshell.readRawText(at: url) {
                        workspace.recordDiskText(raw, for: url)
                    }
                    doc.modificationDate = workspace.modificationDate(for: url)
                    cacheOpenDocument()
                    workspace.refreshTitleCache(from: doc)
                    let noun = salvaged == 1 ? "block" : "blocks"
                    workspace.banner = .init(message: "Merged \(salvaged) \(noun) from another device into \(doc.title)")
                    workspace.rescan()
                    return
                }
            } catch {
                Diag.merge.error("presenter resolve failed url=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }

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
        if documentCache[openDocument.url] !== openDocument {
            documentCache[openDocument.url] = openDocument
        }
        workspace.refreshTitleCache(from: openDocument)
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
