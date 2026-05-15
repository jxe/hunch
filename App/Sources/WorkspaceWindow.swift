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

    private var debounceTask: Task<Void, Never>?
    private var backstopTask: Task<Void, Never>?
    private var autoRestoreTask: Task<Void, Never>?
    private var filePresenter: DocumentFilePresenter?
    private var isDirty = false
    private var isSaving = false
    private var documentCache: [URL: Document] = [:]
    /// Hashes auto-restored into a page during this app session, per URL.
    /// Belt-and-braces against re-restore loops: if the post-save echo (or
    /// any other file-presenter wakeup) sees the same recovery-log entries
    /// surface as "lost" again — whether due to a race with the
    /// fire-and-forget `RecoveryLog.record`, an iCloud-Drive stomp that
    /// keeps reverting the `.md`, or a stale-cache read — we refuse the
    /// second pass. If the user genuinely wants the same content back after
    /// deleting it, that path goes through the manual Recover sheet (which
    /// also handles the "Deleted on purpose" surface).
    private var autoRestoredHashes: [URL: Set<String>] = [:]

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
            backstopTask?.cancel()
            backstopTask = nil
            return
        }
        if let cached = documentCache[url] {
            openDocument = cached
            installFilePresenter(for: url)
            startBackstop()
            scheduleAutoRestore(for: url)
            return
        }
        do {
            openDocument = try workspace.loadDocument(at: url)
            cacheOpenDocument()
            isDirty = false
            installFilePresenter(for: url)
            startBackstop()
            scheduleAutoRestore(for: url)
        } catch {
            workspace.error = "Failed to load \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Coalesce auto-restore invocations — cancels any pending pass and
    /// schedules a fresh one. Called from `handlePathChange` and after
    /// every file-presenter wakeup; idempotent against the in-memory doc.
    private func scheduleAutoRestore(for url: URL) {
        autoRestoreTask?.cancel()
        autoRestoreTask = Task { @MainActor [weak self] in
            await self?.autoRestoreLostBlocksOnOpen(for: url)
        }
    }

    /// Workspace was dropped (switchWorkspace, etc.). Clear all per-window
    /// state. Called by `ContentView` via `.onChange(of: workspace.workspaceURL)`.
    func reset() {
        flushAndClose()
        openDocument = nil
        path = []
        documentCache = [:]
        autoRestoredHashes = [:]
        isDirty = false
        isSaving = false
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
        let updated = documentWithCurrentTitle(document)
        if documentCache[updated.url] !== updated {
            documentCache[updated.url] = updated
        }
        let titleChanged = workspace.refreshTitleCache(from: updated)
        if openDocument?.url == updated.url, openDocument !== updated {
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
        let derived = Document.deriveTitle(from: document.children, fallback: fallback)
        if document.title != derived {
            document.title = derived
        }
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

    @discardableResult
    func saveNow(force: Bool = false) async -> Bool {
        debounceTask?.cancel()
        debounceTask = nil
        guard let doc = openDocument, let clamshell = workspace.clamshell else { return true }
        guard force || isDirty else { return true }
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
            return true
        } catch {
            workspace.error = "Save failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Cancel pending tasks and ensure any unsaved edits land on disk before
    /// returning. The save is enqueued through the per-URL coordinator (it
    /// survives this caller returning) so a rapid page switch doesn't drop
    /// the latest snapshot.
    func flushAndClose() {
        debounceTask?.cancel(); debounceTask = nil
        backstopTask?.cancel(); backstopTask = nil
        autoRestoreTask?.cancel(); autoRestoreTask = nil
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
        autoRestoredHashes.removeValue(forKey: entry.url)
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
        case .lostBlock(let group):
            return await restoreLostBlock(group.root)
        case .purgedBlock(let purged):
            return await restorePurgedBlock(purged)
        }
    }

    /// Splice in every non-tombstoned lost block the recovery log knows
    /// about for this page. Auto-tombstoning on save keeps this safe: any
    /// hash whose latest-record-in-union is `add` is a genuine recovery
    /// candidate. Lost blocks linked by `parentHash` are rebuilt as nested
    /// subtrees via `LostBlockForest.assemble` and inserted under the
    /// closest live ancestor, so a parent + children deleted together on
    /// another device restore as one tree, not as flat siblings.
    ///
    /// Re-triggered on every file-presenter wakeup; idempotent — blocks
    /// already live in `doc` are skipped via `findAtomicHash`. Held off
    /// while the local doc is dirty or a save is in flight to avoid
    /// fighting with user edits.
    @MainActor
    private func autoRestoreLostBlocksOnOpen(for url: URL) async {
        guard let clamshell = workspace.clamshell else { return }
        guard openDocument?.url == url, let doc = openDocument else { return }
        // Skip until the workspace-level migration has had a chance to run;
        // otherwise legacy orphan blocks across every page would resurrect.
        guard clamshell.autoTombstoneMigrationDone else { return }
        // Don't race with in-flight user edits or saves.
        if isDirty || isSaving { return }
        let rel = clamshell.relativePath(of: url)
        let lost = await clamshell.listLostBlocks(filter: .page(relativePath: rel))
        let alreadyRestored = autoRestoredHashes[url] ?? []
        let candidates = lost.filter {
            // Skip anything currently live in the doc (by content hash).
            findAtomicHash($0.hash, in: doc) == nil
                // Skip anything already auto-restored this session (memo
                // against re-fire loops from save echoes / iCloud stomps).
                && !alreadyRestored.contains($0.hash)
                // Skip anything that's ever been tombstoned. Intentional
                // deletions surface in the "Deleted on purpose" section
                // of the Recover sheet for explicit user action — never
                // auto-resurrected, even if a later `add` is currently
                // winning latest-`t` semantics.
                && !$0.everPurged
        }
        guard !candidates.isEmpty else { return }
        let roots = LostBlockForest.assemble(candidates)
        guard !roots.isEmpty else { return }
        guard openDocument?.url == url else { return }

        var restored = 0
        var restoredHashes: Set<String> = []
        for root in roots {
            guard openDocument?.url == url else { return }
            let fresh = root.block.withFreshIDs()
            let parentID = await resolveLiveAncestor(
                startingParentHash: root.lost.parentHash,
                pageRel: rel,
                in: doc,
                clamshell: clamshell
            )
            let siblings = parentID.flatMap(doc.find)?.children ?? doc.children
            doc.insertSubtrees([fresh], at: DropPath(parent: parentID, position: siblings.count))
            restored += root.hashes.count
            restoredHashes.formUnion(root.hashes)
        }
        // Remember these for the rest of the session so a re-fire (post-save
        // echo, iCloud stomp, file-presenter burst, …) can't re-insert them.
        autoRestoredHashes[url, default: []].formUnion(restoredHashes)
        guard restored > 0 else { return }
        doc.enforceHeadingContainment()
        doc.title = Document.deriveTitle(
            from: doc.children,
            fallback: url.deletingPathExtension().lastPathComponent
        )
        cacheOpenDocument()
        markEdited()
        let noun = restored == 1 ? "block" : "blocks"
        workspace.banner = .init(message: "Restored \(restored) \(noun) from another device into \(doc.title)")
        Diag.merge.log("auto-restore url=\(url.lastPathComponent, privacy: .public) restored=\(restored, privacy: .public) roots=\(roots.count, privacy: .public)")
    }

    @discardableResult
    func restoreLostBlock(_ entry: LostBlock) async -> Bool {
        guard let clamshell = workspace.clamshell, let workspaceURL = workspace.workspaceURL else { return false }
        let target = workspaceURL.appendingPathComponent(entry.source).standardizedFileURL
        guard FileManager.default.fileExists(atPath: target.path) else {
            workspace.error = "Original page no longer exists at \(entry.source)."
            return false
        }

        // Pull the full lost set for the page so we can rebuild the subtree
        // rooted at `entry.hash` — restoring a parent should also pull in
        // any descendants that landed in the same loss event.
        let allLost = await clamshell.listLostBlocks(filter: .page(relativePath: entry.source))
        let root: LostBlockForest.Root
        if let assembled = LostBlockForest.assemble(allLost, rootedAt: entry.hash) {
            root = assembled
        } else if let fallback = LostBlockForest.assemble([entry], rootedAt: entry.hash) {
            // The clicked entry no longer in the freshly-read list (rare
            // race with a refresh) — fall back to the entry passed in.
            root = fallback
        } else {
            workspace.error = "Couldn't parse the recovered block."
            return false
        }

        do {
            let restored = root.block.withFreshIDs()

            let useLiveDoc = (openDocument?.url == target)
            let doc: Document
            if useLiveDoc, let live = openDocument {
                doc = live
            } else {
                doc = try workspace.loadDocument(at: target)
            }

            // Climb the lost block's recorded parent chain in the recovery
            // log until we find a hash that's currently live in the doc —
            // append the restored subtree as a child of it. If we run out
            // of ancestors, append at the top of the page.
            let parentID = await resolveLiveAncestor(
                startingParentHash: root.lost.parentHash,
                pageRel: entry.source,
                in: doc,
                clamshell: clamshell
            )
            let siblings = parentID.flatMap(doc.find)?.children ?? doc.children
            doc.insertSubtrees([restored], at: DropPath(parent: parentID, position: siblings.count))

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
            // Purge every hash in the restored subtree so the Recover sheet
            // stops surfacing it. Includes the clicked entry's hash and any
            // descendants we pulled in.
            for hash in root.hashes {
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

        // Pull the full purged set for the page (no time cap — we know the
        // entry exists in the union or the row wouldn't have rendered) and
        // rebuild the subtree rooted at the clicked entry.
        let allPurged = await clamshell.listPurgedBlocks(
            filter: .page(relativePath: group.source),
            since: nil
        )
        let adapted: [LostBlock] = allPurged.map { p in
            LostBlock.adapt(
                hash: p.hash,
                parentHash: p.parentHash,
                markdown: p.markdown,
                source: p.source,
                recordedAt: p.purgedAt
            )
        }
        let purgedByHash = Dictionary(uniqueKeysWithValues: allPurged.map { ($0.hash, $0) })
        let root: LostBlockForest.Root
        if let assembled = LostBlockForest.assemble(adapted, rootedAt: group.hash) {
            root = assembled
        } else if let fallback = LostBlockForest.assemble(
            [LostBlock.adapt(
                hash: group.root.hash,
                parentHash: group.root.parentHash,
                markdown: group.root.markdown,
                source: group.root.source,
                recordedAt: group.root.purgedAt
            )],
            rootedAt: group.hash
        ) {
            root = fallback
        } else {
            workspace.error = "Couldn't parse the recovered block."
            return false
        }

        do {
            let restored = root.block.withFreshIDs()

            let useLiveDoc = (openDocument?.url == target)
            let doc: Document
            if useLiveDoc, let live = openDocument {
                doc = live
            } else {
                doc = try workspace.loadDocument(at: target)
            }

            let parentID = await resolveLiveAncestor(
                startingParentHash: group.root.parentHash,
                pageRel: group.source,
                in: doc,
                clamshell: clamshell
            )
            let siblings = parentID.flatMap(doc.find)?.children ?? doc.children
            doc.insertSubtrees([restored], at: DropPath(parent: parentID, position: siblings.count))

            doc.enforceHeadingContainment()
            doc.title = Document.deriveTitle(from: doc.children, fallback: target.deletingPathExtension().lastPathComponent)

            // Unpurge each restored hash BEFORE the save so the save's
            // auto-tombstone diff sees them as already-recorded (in the
            // device cache) and doesn't immediately re-purge.
            for hash in root.hashes {
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

    /// Walk up the recorded parent chain until we find a hash that's currently
    /// alive in `doc`, returning that block's ID; nil = top-level.
    private func resolveLiveAncestor(
        startingParentHash: String?,
        pageRel: String,
        in doc: Document,
        clamshell: Clamshell
    ) async -> BlockID? {
        var current = startingParentHash
        // Prevent unbounded climbs in the unlikely case of corrupt circular references.
        var safety = 64
        while let hash = current, safety > 0 {
            if let id = findAtomicHash(hash, in: doc) { return id }
            current = await clamshell.parentHash(forPage: pageRel, hash: hash)
            safety -= 1
        }
        return nil
    }

    /// Find a block whose atomic hash matches `hash` anywhere in the document
    /// tree. Returns the first match in preorder.
    private func findAtomicHash(_ hash: String, in doc: Document) -> BlockID? {
        var match: BlockID?
        doc.walk { block, _, _ in
            if match == nil, BlockFingerprint.atomicHash(block) == hash {
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
        // even if the `.md` hash hasn't changed. Re-run auto-restore on
        // every wakeup; the method is idempotent (already-live hashes are
        // skipped) and self-coalesced via `autoRestoreTask`.
        defer { scheduleAutoRestore(for: url) }

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

// MARK: - LostBlockForest

/// Pure transform from a flat list of `LostBlock` records into the roots of
/// a forest of `Block` trees. Each lost block whose recorded `parentHash`
/// points to another lost block becomes a child of that parent in the
/// assembled tree, so a parent + its descendants restore as one nested
/// subtree instead of N flat siblings. Cycle-safe.
struct LostBlockForest {
    struct Root {
        /// Originating record for the root (used by callers to look up the
        /// recorded `parentHash` for live-ancestor resolution).
        let lost: LostBlock
        /// Assembled tree with children attached. IDs are still the parser's;
        /// callers should `withFreshIDs()` once before inserting.
        let block: Block
        /// Atomic hashes covered by this root (including the root itself).
        /// Used by the manual-restore path to purge the whole subtree post-
        /// insert and by the Recover sheet to badge "+N more" affordances.
        let hashes: Set<String>
    }

    static func assemble(_ entries: [LostBlock]) -> [Root] {
        let (parsed, byHash) = buildIndex(entries)
        guard !byHash.isEmpty else { return [] }
        let childrenByParent = buildChildrenByParent(byHash: byHash)
        let rootHashes = byHash.values.compactMap { entry -> String? in
            if let p = entry.parentHash, byHash[p] != nil { return nil }
            return entry.hash
        }
        let sortedRoots = rootHashes.sorted { lhs, rhs in
            (byHash[lhs]?.recordedAt ?? .distantPast)
                < (byHash[rhs]?.recordedAt ?? .distantPast)
        }
        return sortedRoots.compactMap { hash in
            buildRoot(
                hash: hash,
                parsed: parsed,
                byHash: byHash,
                childrenByParent: childrenByParent
            )
        }
    }

    /// Single-root overload: assemble only the subtree rooted at `rootedAt`
    /// from the entries (descendants pulled in by parentHash linkage).
    /// Returns nil if `rootedAt` isn't in the entries.
    static func assemble(_ entries: [LostBlock], rootedAt: String) -> Root? {
        let (parsed, byHash) = buildIndex(entries)
        guard byHash[rootedAt] != nil else { return nil }
        let childrenByParent = buildChildrenByParent(byHash: byHash)
        return buildRoot(
            hash: rootedAt,
            parsed: parsed,
            byHash: byHash,
            childrenByParent: childrenByParent
        )
    }

    private static func buildChildrenByParent(byHash: [String: LostBlock]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for entry in byHash.values {
            guard let p = entry.parentHash, byHash[p] != nil else { continue }
            out[p, default: []].append(entry.hash)
        }
        return out
    }

    // MARK: - Internals

    private static func buildIndex(_ entries: [LostBlock])
        -> (parsed: [String: Block], byHash: [String: LostBlock])
    {
        var parsed: [String: Block] = [:]
        var byHash: [String: LostBlock] = [:]
        for entry in entries {
            guard let block = BlockParser.parse(entry.markdown).first else { continue }
            // Defensive: dupe hash → keep the latest recordedAt for ordering.
            if let existing = byHash[entry.hash], existing.recordedAt >= entry.recordedAt {
                continue
            }
            parsed[entry.hash] = block
            byHash[entry.hash] = entry
        }
        return (parsed, byHash)
    }

    private static func buildRoot(
        hash: String,
        parsed: [String: Block],
        byHash: [String: LostBlock],
        childrenByParent: [String: [String]]
    ) -> Root? {
        guard let lost = byHash[hash], let block = parsed[hash] else { return nil }
        var visited: Set<String> = []
        var hashes: Set<String> = []
        let assembled = attach(
            hash: hash,
            block: block,
            parsed: parsed,
            byHash: byHash,
            childrenByParent: childrenByParent,
            visited: &visited,
            hashes: &hashes
        )
        return Root(lost: lost, block: assembled, hashes: hashes)
    }

    private static func attach(
        hash: String,
        block: Block,
        parsed: [String: Block],
        byHash: [String: LostBlock],
        childrenByParent: [String: [String]],
        visited: inout Set<String>,
        hashes: inout Set<String>
    ) -> Block {
        guard visited.insert(hash).inserted else { return block }
        hashes.insert(hash)
        let childHashes = (childrenByParent[hash] ?? []).sorted { lhs, rhs in
            (byHash[lhs]?.recordedAt ?? .distantPast)
                < (byHash[rhs]?.recordedAt ?? .distantPast)
        }
        let children = childHashes.compactMap { childHash -> Block? in
            guard let childBlock = parsed[childHash] else { return nil }
            return attach(
                hash: childHash,
                block: childBlock,
                parsed: parsed,
                byHash: byHash,
                childrenByParent: childrenByParent,
                visited: &visited,
                hashes: &hashes
            )
        }
        return block.withChildren(children)
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
