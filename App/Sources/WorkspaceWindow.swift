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
    private func reconcileOpenDocumentAgainstLog(_ doc: Document) {
        guard let clamshell = workspace.clamshell else { return }
        // The doc must still be the open one — navigation can swap underneath
        // a pending reconcile from a presenter wakeup.
        guard openDocument === doc else { return }
        // Don't race with in-flight user edits or saves. The engine assumes
        // `doc.children == parsed(.md)` — only true when the page is clean.
        if !clamshell.isClean(at: doc.url) { return }

        let url = doc.url
        let rel = clamshell.relativePath(of: url)
        let journal = clamshell.readJournal(forPage: rel)
        let intent = PatchEngine.intent(from: journal)
        let recon = PatchEngine.reconcile(intent: intent, doc: doc.children)

        // Reconcile produces two intent transitions:
        //   - `toAppend`: lift bare-md / external-edit content into the log
        //                 as fresh adds (engine already filtered against the
        //                 union, so no duplicates).
        //   - `unrestorable`: quarantine hashes the engine can't turn into
        //                     valid Inserts (markdown won't parse, or parses
        //                     to a different hash — typically a
        //                     serialization-format drift). Without the
        //                     quarantine, those hashes stay `.alive` in
        //                     intent forever and reconcile re-fires.
        var entries: [Patch.Entry] = []
        for obs in recon.toAppend {
            entries.append(.add(hash: obs.hash, parent: obs.parent, markdown: obs.markdown))
        }
        for entry in recon.unrestorable {
            entries.append(.purge(hash: entry.hash))
        }
        if !recon.unrestorable.isEmpty {
            let hashList = recon.unrestorable.map(\.hash).joined(separator: ",")
            Diag.merge.error("reconcile quarantining url=\(url.lastPathComponent, privacy: .public) count=\(recon.unrestorable.count, privacy: .public) hashes=\(hashList, privacy: .public)")
            for entry in recon.unrestorable {
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
        if !entries.isEmpty {
            let patch = Patch(entries: entries)
            Task { [clamshell, rel] in
                do {
                    try await clamshell.applyPatch(patch, forPage: rel)
                } catch {
                    Diag.merge.error("reconcile patch apply failed page=\(rel, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                }
            }
        }

        guard recon.didChange else { return }
        guard openDocument === doc else { return }

        PatchEngine.apply(recon, to: doc)
        clamshell.documentDidChange(ops: [], in: doc)
        let restored = recon.restoredHashes.count
        let noun = restored == 1 ? "block" : "blocks"
        workspace.banner = .init(message: "Restored \(restored) \(noun) from another device into \(doc.title)")
        Diag.merge.log("auto-restore url=\(url.lastPathComponent, privacy: .public) restored=\(restored, privacy: .public) roots=\(recon.inserts.count, privacy: .public) hashes=\(recon.restoredHashes.joined(separator: ","), privacy: .public)")
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
            let (doc, isLive) = try openDocForRestore(at: target)

            // Engine input: the page's journal + the current doc. Falls back
            // to the entry passed in if the freshly-read journal no longer
            // surfaces the hash (rare race with a refresh).
            let journal = clamshell.readJournal(forPage: entry.source)
            let intent = PatchEngine.intent(from: journal)
            let candidates = intent.lostEntries(notIn: [], source: entry.source)
            guard let insert = PatchEngine.insertion(
                rootHash: entry.hash,
                candidates: candidates,
                intent: intent,
                doc: doc.children
            ) ?? PatchEngine.insertion(
                rootHash: entry.hash,
                candidates: [entry],
                intent: intent,
                doc: doc.children
            ) else {
                workspace.error = "Couldn't parse the recovered block."
                return false
            }

            PatchEngine.apply(
                PatchEngine.Reconciliation(
                    inserts: [insert],
                    restoredHashes: Array(insert.coveredHashes)
                ),
                to: doc
            )
            try persistRestoredDoc(doc, isLive: isLive, target: target)

            // Purge every hash in the restored subtree so the Recover sheet
            // stops surfacing it. Includes the clicked entry's hash and any
            // descendants we pulled in. One batched log write instead of N.
            let purgePatch = Patch(entries: insert.coveredHashes.map { .purge(hash: $0) })
            do {
                try await clamshell.applyPatch(purgePatch, forPage: entry.source)
            } catch {
                Diag.merge.error("restore purge failed page=\(entry.source, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
            return true
        } catch {
            workspace.error = "Restore failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Load the destination doc for a restore. Reuses the in-memory live
    /// document when the target is currently open (so `PatchEngine.apply`
    /// mutates the same object the editor renders); otherwise reads from
    /// disk. The `isLive` flag tells `persistRestoredDoc` which save path
    /// to take.
    private func openDocForRestore(at target: URL) throws -> (doc: Document, isLive: Bool) {
        if let live = openDocument, live.url == target {
            return (live, true)
        }
        return (try workspace.loadDocument(at: target), false)
    }

    /// Persist a restore that just mutated `doc`. Live docs go through the
    /// debounced save by way of `clamshell.documentDidChange`; closed docs
    /// are written synchronously and the page list is rescanned so
    /// titles/mtimes refresh.
    private func persistRestoredDoc(_ doc: Document, isLive: Bool, target: URL) throws {
        guard let clamshell = workspace.clamshell else { return }
        if isLive {
            clamshell.documentDidChange(ops: [], in: doc)
        } else {
            try clamshell.writeExternal(doc)
            doc.modificationDate = workspace.modificationDate(for: target)
            workspace.rescan()
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
            let (doc, isLive) = try openDocForRestore(at: target)

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
            guard let insert = PatchEngine.insertion(
                rootHash: group.hash,
                candidates: candidates,
                intent: intent,
                doc: doc.children
            ) ?? PatchEngine.insertion(
                rootHash: group.hash,
                candidates: [fallbackCandidate],
                intent: intent,
                doc: doc.children
            ) else {
                workspace.error = "Couldn't parse the recovered block."
                return false
            }

            PatchEngine.apply(
                PatchEngine.Reconciliation(
                    inserts: [insert],
                    restoredHashes: Array(insert.coveredHashes)
                ),
                to: doc
            )

            // Fresh `add` per restored hash so each one's latest record in
            // the union is no longer a `purge`. Counter mint > prior purge,
            // so intent flips back to alive. One batched log write.
            var unpurgeEntries: [Patch.Entry] = []
            for hash in insert.coveredHashes {
                guard let purgedRecord = purgedByHash[hash],
                      let parsed = BlockParser.parse(purgedRecord.markdown).first else { continue }
                unpurgeEntries.append(.add(
                    hash: parsed.atomicHash,
                    parent: purgedRecord.parentHash,
                    markdown: BlockSerializer.serializeAtomic(parsed)
                ))
            }
            if !unpurgeEntries.isEmpty {
                do {
                    try await clamshell.applyPatch(Patch(entries: unpurgeEntries), forPage: group.source)
                } catch {
                    Diag.merge.error("unpurge failed page=\(group.source, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                }
            }

            try persistRestoredDoc(doc, isLive: isLive, target: target)
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
                    doc.modificationDate = workspace.modificationDate(for: url)
                    workspace.refreshTitleCache(from: doc)
                    let noun = resolution.salvaged == 1 ? "block" : "blocks"
                    workspace.banner = .init(message: "Merged \(resolution.salvaged) \(noun) from another device into \(doc.title)")
                    workspace.rescan()
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
            if clamshell.isClean(at: url), let doc = openDocument {
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
            guard clamshell.isClean(at: url), let doc = openDocument else { workspace.rescan(); return }
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
