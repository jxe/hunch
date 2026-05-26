import Foundation
import Editor

// MARK: - WorkspaceWindow: EditorHost
//
// Most methods forward to `workspace.clamshell` or to stateless helpers.
// The ones that genuinely need per-window state — navigation, the move-to
// picker, the multi-window splice for `appendToPage` — read
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

    func createPage(title: String, requestedPath: String?, initialContent: [Block]?) -> String? {
        guard let clamshell = workspace.clamshell else { return nil }
        do {
            return try clamshell.createPage(title: title, requestedPath: requestedPath, initialContent: initialContent)
        } catch {
            workspace.error = "Failed to create page: \(error.localizedDescription)"
            return nil
        }
    }

    func loadPageBlocks(_ pageID: String) async -> [Block]? {
        guard let clamshell = workspace.clamshell else { return nil }
        let target = clamshell.url(for: pageID)
        do {
            return try await clamshell.readBlocks(at: target)
        } catch {
            Diag.subpage.error("loadPageBlocks(_:): read(\(target.path, privacy: .public)) threw: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func persistCommit(ops: [EditorOp], in document: Document) {
        guard let clamshell = workspace.clamshell else { return }
        let commit = Commit.fromEditorOps(ops)
        // Editor's `didCommitTransaction` is sync (typing path can't
        // await). Spawn a Task that awaits durability; the host's
        // subsequent `flush(_:)` calls (blur, nav, scenePhase) await
        // the chain head and so will await this task too.
        Task { @MainActor in
            do { try await clamshell.commit(commit, to: document) }
            catch { showSaveFailure(for: document, error: error) }
        }
    }

    func flush(_ document: Document) async throws {
        guard let clamshell = workspace.clamshell else { return }
        do {
            try await clamshell.flush(document)
        } catch {
            showSaveFailure(for: document, error: error)
            throw error
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
        BlockSerializer.serialize(blocks, consecutiveNumbering: true)
    }

    func parseBlocksFromPasteboard(_ string: String) -> [Block]? {
        let blocks = BlockParser.parse(string)
        return blocks.isEmpty ? nil : blocks
    }

    // — Per-window navigation & durability —

    func openPage(pageID: String) {
        openSubpage(relativePath: pageID)
    }

    func inlineAndTrashPage(_ pageID: String) async -> Bool {
        guard let clamshell = workspace.clamshell, let parent = openDocument else { return false }
        do {
            try await clamshell.inlineAndTrash(pageID: pageID, parent: parent)
            return true
        } catch {
            workspace.error = "Failed to move \(pageID) to trash: \(error.localizedDescription)"
            return false
        }
    }

    func appendToPage(_ pageID: String, _ blocks: [Block]) async -> Bool {
        guard !blocks.isEmpty, let clamshell = workspace.clamshell else { return false }
        let target = clamshell.url(for: pageID)
        do {
            if let live = clamshell.liveDocument(at: target) {
                live.replaceChildrenFromSystemMutation(live.children + blocks)
                let appendCommit = Commit(logEntries: Patch.adds(from: blocks).entries)
                try await clamshell.commit(appendCommit, to: live)
                return true
            }

            let doc = try await clamshell.loadDocument(at: target)
            doc.transaction(name: "Append to subpage") {
                doc.insertSubtrees(blocks, at: DropPath(parent: nil, position: doc.children.count))
            }
            let appendCommit = Commit(logEntries: Patch.adds(from: blocks).entries)
            try await clamshell.commit(appendCommit, to: doc)
            // Multi-window splice: if this window has the subpage open,
            // copy the appended children into the live instance rather
            // than swapping doc identity — keeps editor state references
            // stable.
            if let live = openDocument, live.url == target, live !== doc {
                live.replaceChildrenFromSystemMutation(doc.children)
                live.modificationDate = doc.modificationDate
            }
            return true
        } catch {
            workspace.error = "Failed to move blocks into \(pageID): \(error.localizedDescription)"
            return false
        }
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
