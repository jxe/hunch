import Foundation
import Editor

// MARK: - WorkspaceWindow: EditorHost
//
// Most methods forward to `workspace.clamshell` or to stateless helpers.
// The ones that genuinely need per-window state — navigation, the move-to
// picker, the multi-window splice for `appendToSubpage` — read
// `openDocument` and the per-window navigation primitives directly.

extension WorkspaceWindow: EditorHost {
    // — Workspace-scoped forwarders —

    func suggestPages(_ query: String) -> [MentionItem] {
        workspace.clamshell?.pages(matching: query, excluding: openDocument?.url) ?? []
    }

    func lookupPage(_ pageID: String) -> PageLookup {
        workspace.clamshell?.lookupPage(pageID) ?? .missing
    }

    func resolvePageID(from url: URL) -> String? {
        workspace.clamshell?.pageID(for: url, relativeTo: openDocument?.url)
    }

    func createSubpage(title: String, requestedPath: String?, initialContent: [Block]?) -> String? {
        guard let clamshell = workspace.clamshell else { return nil }
        do {
            return try clamshell.createPage(title: title, requestedPath: requestedPath, initialContent: initialContent)
        } catch {
            workspace.error = "Failed to create page: \(error.localizedDescription)"
            return nil
        }
    }

    func loadSubpageBlocks(_ pageID: String) async -> [Block]? {
        guard let clamshell = workspace.clamshell else { return nil }
        let target = clamshell.url(for: pageID)
        do {
            return try await clamshell.readBlocks(at: target)
        } catch {
            Diag.subpage.error("loadSubpageBlocks(_:): read(\(target.path, privacy: .public)) threw: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func persistCommit(ops: [EditorOp], in document: Document) {
        workspace.clamshell?.persistCommit(ops: ops, in: document)
    }

    func flush(_ document: Document) async {
        guard let clamshell = workspace.clamshell else { return }
        await clamshell.flush(document)
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
        BlockSerializer.serialize(blocks, consecutiveNumbering: true)
    }

    func parseBlocksFromPasteboard(_ string: String) -> [Block]? {
        let blocks = BlockParser.parse(string)
        return blocks.isEmpty ? nil : blocks
    }

    // — Per-window navigation & durability —

    @discardableResult
    func didActivateLink(_ target: LinkTarget) -> Bool {
        switch target {
        case .page(let pageID):
            openSubpage(relativePath: pageID)
            return true
        case .url(let url):
            // Workspace-internal links resolve via the host classifier
            // (same hook used for inline-link decoration at render time);
            // everything else falls through to the system handler.
            if let pageID = resolvePageID(from: url) {
                openSubpage(relativePath: pageID)
                return true
            }
            return false
        }
    }

    func inlineAndTrashSubpage(_ pageID: String) async -> Bool {
        guard let clamshell = workspace.clamshell, let parent = openDocument else { return false }
        do {
            try await clamshell.inlineAndTrash(pageID: pageID, parent: parent)
            return true
        } catch {
            workspace.error = "Failed to move \(pageID) to trash: \(error.localizedDescription)"
            return false
        }
    }

    func appendToSubpage(_ pageID: String, _ blocks: [Block]) async -> Bool {
        guard !blocks.isEmpty, let clamshell = workspace.clamshell else { return false }
        let target = clamshell.url(for: pageID)
        let doc: Document
        do {
            doc = try await clamshell.append(blocks, toPage: pageID)
        } catch {
            workspace.error = "Failed to move blocks into \(pageID): \(error.localizedDescription)"
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
}
