import Foundation
import Quagmire
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

// MARK: - WorkspaceWindow: EditorHost
//
// Most methods forward to `workspace.clamshell` or to stateless helpers.
// The ones that genuinely need per-window state — navigation, the move-to
// picker, the multi-window splice for `appendToDocument` — read
// `openDocument` and the per-window navigation primitives directly.

extension WorkspaceWindow: EditorHost {
    var supportsDocumentCreation: Bool { true }
    var supportsDocumentInlining: Bool { true }
    var supportsMoveDestinationPicker: Bool { true }

    // — Workspace-scoped forwarders —

    func blockActions(in document: Document) -> [EditorBlockAction] {
        HunchEditorActions.actions()
    }

    func suggestDocuments(_ query: String, in document: Document) async -> [MentionItem] {
        guard let clamshell = workspace.clamshell,
              let pageURL = pageURL(for: document) else { return [] }
        let home = clamshell.homeRelativePath
        return clamshell.pages(matching: query, excluding: pageURL)
            .map { $0.asMentionItem(homeRelativePath: home) }
    }

    func lookupDocument(_ reference: DocumentReference) -> DocumentLookup {
        workspace.clamshell?.lookupDocument(reference.rawValue) ?? .missing
    }

    func didDeleteDocumentLink(reference: DocumentReference, label: String, from document: Document) {
        let title = label
        guard let clamshell = workspace.clamshell,
              let sourceURL = pageURL(for: document),
              let pageID = clamshell.resolveSubpageTarget(reference.rawValue),
              clamshell.entry(at: pageID) != nil else {
            return
        }

        let sourcePageID = clamshell.relativePath(of: sourceURL)
        let sourceBlocksAfterDelete = document.children

        Task { @MainActor [weak self, pageID, title, sourcePageID, sourceURL, sourceBlocksAfterDelete] in
            guard let self else { return }

            // Make the deletion durable before acting on it. The prompt can end
            // with the target in Trash, and trashing a page because nothing
            // links to it any more is only sound once "nothing links to it" is
            // true on disk. Otherwise a crash between the two leaves the target
            // trashed and the link that justified trashing it still in the
            // file. Same invariant `trashAfterInlining` enforces by flushing
            // the parent before it moves the source page — this path had the
            // same shape and none of the protection.
            //
            // It also makes the reachability question well-posed: the link
            // graph is read from disk, so asking it about a page whose latest
            // edit is still in memory compares two different versions of the
            // workspace.
            await self.flush(document)

            guard let clamshell = self.workspace.clamshell,
                  clamshell.entry(at: pageID) != nil else {
                return
            }

            let graph: LinkGraph
            if let cached = clamshell.linkGraph {
                graph = cached
            } else {
                graph = await clamshell.buildLinkGraph()
            }
            guard graph.allPageIDs.contains(pageID) else { return }

            let classify: @Sendable (URL, URL) -> String? = { [clamshell] url, base in
                clamshell.pagePath(for: url, relativeTo: base)
            }
            let classifySubpage: @Sendable (String) -> String? = { [clamshell] dest in
                clamshell.resolveSubpageTarget(dest)
            }
            let sourceOutboundAfterDelete = outboundLinks(
                in: sourceBlocksAfterDelete,
                pageURL: sourceURL,
                classify: classify,
                classifySubpage: classifySubpage
            )

            guard SubpageTrashDecision.shouldPromptToTrash(
                targetPageID: pageID,
                sourcePageID: sourcePageID,
                sourceOutboundAfterDelete: sourceOutboundAfterDelete,
                graph: graph
            ) else {
                return
            }

            self.pendingSubpageTrashPrompt = .init(pageID: pageID, title: title)
        }
    }

    func resolveReference(from url: URL, in document: Document) -> DocumentReference? {
        guard let pageURL = pageURL(for: document) else { return nil }
        return workspace.clamshell?.pagePath(for: url, relativeTo: pageURL).map { DocumentReference($0) }
    }

    func linkURL(for reference: DocumentReference, in document: Document) -> URL? {
        guard let clamshell = workspace.clamshell,
              let pageURL = pageURL(for: document) else { return nil }
        let pageID = reference.rawValue
        let (rawPath, destID) = ClamshellPageEnvelope.splitPageFragment(pageID)
        let rel = clamshell.resolvePageTarget(pageID) ?? rawPath
        let id = destID ?? clamshell.knownPageID(forRel: rel)
        if id == nil {
            // Legacy target without an ID yet: mint in the background so the
            // heal pass can add the fragment later; today's link stays
            // fragment-less and resolves by path.
            Task { [clamshell] in await clamshell.ensurePageID(forRel: rel) }
        }
        return clamshell.relativeMarkdownURL(
            from: pageURL.deletingLastPathComponent(),
            to: clamshell.url(for: rel),
            fragment: id
        )
    }

    func createDocument(
        title: String,
        requestedReference: DocumentReference?,
        initialContent: [Block]?
    ) async -> DocumentReference? {
        workspace.createDocument(
            title: title,
            requestedPath: requestedReference?.rawValue,
            initialContent: initialContent
        ).map { DocumentReference($0) }
    }

    func loadDocumentBlocks(_ reference: DocumentReference) async -> [Block]? {
        guard let clamshell = workspace.clamshell else { return nil }
        let pageID = reference.rawValue
        let page = clamshell.page(atPath: clamshell.resolvePageTarget(pageID) ?? pageID)
        do {
            return try await page.readBlocks()
        } catch {
            Diag.subpage.error("loadDocumentBlocks(_:): read(\(page.url.path, privacy: .public)) threw: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func persistCommit(changes: [DocumentChange], in document: Document) {
        guard let session = session(for: document) else { return }
        // Editor's `didCommitTransaction` is sync (typing path can't
        // await). The enqueue is synchronous too, so the page coordinator
        // reflects this commit before we return — `PageSession.flush()` callers
        // (blur, nav, scenePhase) can never observe false quiescence.
        // The Task only awaits durability for the failure banner.
        let task = session.enqueueEditorChanges(changes)
        Task { @MainActor in
            defer { if openDocument === document { refreshCloudSyncSnapshot() } }
            do {
                try await task.value
            } catch {
                showSaveFailure(for: document, error: error)
            }
        }
    }

    func flush(_ document: Document) async {
        guard let session = session(for: document) else { return }
        defer { if openDocument === document { refreshCloudSyncSnapshot() } }
        do {
            try await session.flush()
        } catch {
            showSaveFailure(for: document, error: error)
        }
    }

    func saveImages(_ items: [PastedImage]) -> [String] {
        guard let clamshell = workspace.clamshell else { return [] }
        var paths: [String] = []
        var failures: [String] = []
        paths.reserveCapacity(items.count)
        for item in items {
            do {
                paths.append(try clamshell.writeImage(item))
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        if !failures.isEmpty {
            let summary = failures.count == 1
                ? "Failed to save pasted image: \(failures[0])"
                : "Failed to save \(failures.count) pasted images: \(failures.joined(separator: "; "))"
            workspace.error = summary
        }
        return paths
    }

    func linkPreview(for url: URL) async -> LinkPreview? {
        await workspace.linkPreviewService.preview(for: url)
    }

    func imageURL(for source: String) -> URL? {
        workspace.clamshell?.resolveImage(source: source)
    }

    // — Stateless app conventions —

    func serializeBlocksForPasteboard(_ blocks: [Block]) -> String {
        // Resolve subpage titles against the live workspace. The title stored
        // on the block is a cache that only refreshes when its own page is
        // saved, so copying a link to a page renamed since could paste the old
        // name. `serializeAtomic` deliberately does *not* do this — see there.
        guard let clamshell = workspace.clamshell else {
            return BlockSerializer.serialize(blocks, consecutiveNumbering: true)
        }
        return BlockSerializer.serialize(
            blocks,
            resolvingSubpageTitle: { clamshell.lookupDocument($0).title },
            consecutiveNumbering: true
        )
    }

    func parseBlocksFromPasteboard(_ string: String) -> [Block]? {
        let blocks = BlockParser.parse(string)
        return blocks.isEmpty ? nil : blocks
    }

    // — Per-window navigation & durability —

    func openDocument(_ reference: DocumentReference) {
        let pageID = reference.rawValue
        let resolved = workspace.clamshell?.resolvePageTarget(pageID) ?? pageID
        openSubpage(relativePath: resolved)
    }

    func setDocumentIcon(_ emoji: String, for reference: DocumentReference) async -> Bool {
        guard let clamshell = workspace.clamshell else { return false }
        let pageID = reference.rawValue
        let relativePath = clamshell.resolvePageTarget(pageID) ?? pageID
        do {
            try await clamshell.page(atPath: relativePath).setIcon(emoji)
            return true
        } catch {
            workspace.error = "Couldn't set the page icon: \(error.localizedDescription)"
            return false
        }
    }

    func inlineAndRetireDocument(_ reference: DocumentReference, parent: Document) async -> Bool {
        guard let clamshell = workspace.clamshell,
              let parentSession = session(for: parent) else { return false }
        let pageID = reference.rawValue
        do {
            try await clamshell.page(atPath: clamshell.resolvePageTarget(pageID) ?? pageID).trashAfterInlining(into: parentSession)
            return true
        } catch {
            workspace.error = "Failed to move \(pageID) to trash: \(error.localizedDescription)"
            return false
        }
    }

    func appendToDocument(_ reference: DocumentReference, _ blocks: [Block]) async -> Bool {
        guard !blocks.isEmpty, let clamshell = workspace.clamshell else { return false }
        let pageID = reference.rawValue
        let rel = clamshell.resolvePageTarget(pageID) ?? pageID
        do {
            try await clamshell.page(atPath: rel).append(blocks)
            return true
        } catch {
            workspace.error = "Failed to add blocks to \(rel): \(error.localizedDescription)"
            return false
        }
    }

    func appendCurrentPageLink(to pageID: String) async -> Bool {
        guard let source = openDocument,
              let sourcePageID = currentPageRelativePath,
              let clamshell = workspace.clamshell else {
            return false
        }
        let rel = clamshell.resolvePageTarget(pageID) ?? pageID
        guard sourcePageID != rel else { return false }

        let linkBlock = Block.documentLink(label: AttributedString(source.title), reference: DocumentReference(sourcePageID))
        do {
            try await clamshell.page(atPath: rel).append([linkBlock])
            return true
        } catch {
            workspace.error = "Failed to add \(source.title) to \(rel): \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func copyCurrentPageLinkToPasteboard() -> Bool {
        guard let source = openDocument,
              let sourcePageID = currentPageRelativePath else {
            return false
        }

        let linkBlock = Block.documentLink(label: AttributedString(source.title), reference: DocumentReference(sourcePageID))
        let markdown = serializeBlocksForPasteboard([linkBlock])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !markdown.isEmpty else { return false }

        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
        #else
        UIPasteboard.general.string = markdown
        #endif
        return true
    }

    /// Editor's async move-destination call site: store a continuation,
    /// drive the sheet via `moveRequest`, resume from `resolveMoveRequest`.
    func moveDestination(for blockIDs: [BlockID], candidates: [InDocMoveTarget]) async -> MoveDestination? {
        await withCheckedContinuation { (continuation: CheckedContinuation<MoveDestination?, Never>) in
            moveRequest = MoveRequest(
                inDocCandidates: candidates,
                completion: { destination in continuation.resume(returning: destination) }
            )
        }
    }

    private func showSaveFailure(for document: Document, error: Error) {
        workspace.banner = .saveFailed(page: document.title, error: error)
    }
}
