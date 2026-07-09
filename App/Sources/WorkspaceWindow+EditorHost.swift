import Foundation
import Editor
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

// MARK: - WorkspaceWindow: EditorHost
//
// Most methods forward to `workspace.clamshell` or to stateless helpers.
// The ones that genuinely need per-window state — navigation, the move-to
// picker, the multi-window splice for `appendToPage` — read
// `openDocument` and the per-window navigation primitives directly.

extension WorkspaceWindow: EditorHost {
    // — Workspace-scoped forwarders —

    func suggestPages(_ query: String, in document: Document) -> [MentionItem] {
        guard let clamshell = workspace.clamshell else { return [] }
        let home = clamshell.homeRelativePath
        return clamshell.pages(matching: query, excluding: document.url)
            .map { $0.asMentionItem(homeRelativePath: home) }
    }

    func lookupPage(_ pageID: String) -> PageLookup {
        workspace.clamshell?.lookupPage(pageID) ?? .missing
    }

    func didDeleteSubpageLink(pageID: String, title: String, from document: Document) {
        guard let clamshell = workspace.clamshell,
              clamshell.entry(at: pageID) != nil else {
            return
        }

        let sourcePageID = clamshell.relativePath(of: document.url)
        let sourceURL = document.url
        let sourceBlocksAfterDelete = document.children

        Task { @MainActor [weak self, pageID, title, sourcePageID, sourceURL, sourceBlocksAfterDelete] in
            guard let self,
                  let clamshell = self.workspace.clamshell,
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
                clamshell.pageID(for: url, relativeTo: base)
            }
            let sourceOutboundAfterDelete = outboundLinks(
                in: sourceBlocksAfterDelete,
                pageURL: sourceURL,
                classify: classify
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

    func resolvePageID(from url: URL, in document: Document) -> String? {
        workspace.clamshell?.pageID(for: url, relativeTo: document.url)
    }

    func linkURL(forPageID pageID: String, in document: Document) -> URL? {
        guard let clamshell = workspace.clamshell else { return nil }
        return relativeMarkdownURL(
            from: document.url.deletingLastPathComponent(),
            to: clamshell.url(for: pageID)
        )
    }

    func createPage(title: String, requestedPath: String?, initialContent: [Block]?) async -> String? {
        workspace.createPage(title: title, requestedPath: requestedPath, initialContent: initialContent)
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
        // Editor's `didCommitTransaction` is sync (typing path can't
        // await). The enqueue is synchronous too, so the save chain
        // reflects this commit before we return — `flush(_:)` callers
        // (blur, nav, scenePhase) can never observe false quiescence.
        // The Task only awaits durability for the failure banner.
        let task = clamshell.enqueueCommit(.fromEditorOps(ops), to: document)
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
        guard let clamshell = workspace.clamshell else { return }
        defer { if openDocument === document { refreshCloudSyncSnapshot() } }
        do {
            try await clamshell.flush(document)
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

    func inlineAndTrashPage(_ pageID: String, parent: Document) async -> Bool {
        guard let clamshell = workspace.clamshell else { return false }
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
        do {
            try await clamshell.appendBlocks(blocks, toPage: pageID)
            return true
        } catch {
            workspace.error = "Failed to move blocks into \(pageID): \(error.localizedDescription)"
            return false
        }
    }

    func appendCurrentPageLink(to pageID: String) async -> Bool {
        guard let source = openDocument,
              let sourcePageID = currentPageRelativePath,
              sourcePageID != pageID,
              let clamshell = workspace.clamshell else {
            return false
        }

        let linkBlock = Block.subpage(title: source.title, pageID: sourcePageID)
        do {
            try await clamshell.appendBlocks([linkBlock], toPage: pageID)
            return true
        } catch {
            workspace.error = "Failed to add \(source.title) to \(pageID): \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func copyCurrentPageLinkToPasteboard() -> Bool {
        guard let source = openDocument,
              let sourcePageID = currentPageRelativePath else {
            return false
        }

        let linkBlock = Block.subpage(title: source.title, pageID: sourcePageID)
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

private func relativeMarkdownURL(from baseDirectory: URL, to target: URL) -> URL? {
    let baseComponents = baseDirectory.standardizedFileURL.pathComponents
    let targetComponents = target.standardizedFileURL.pathComponents
    var commonCount = 0
    while commonCount < baseComponents.count,
          commonCount < targetComponents.count,
          baseComponents[commonCount] == targetComponents[commonCount] {
        commonCount += 1
    }

    let up = Array(repeating: "..", count: baseComponents.count - commonCount)
    let down = Array(targetComponents.dropFirst(commonCount))
    let components = up + down
    guard !components.isEmpty else { return nil }
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    let encoded = components
        .map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }
        .joined(separator: "/")
    return URL(string: encoded)
}
