import Foundation
import Editor

/// `WorkspaceWindow` is the `EditorHost` for the editor mounted in this
/// window. The save lifecycle, page list, title cache, file presenter,
/// and image / page operations all live on `Clamshell` — these methods
/// route the editor's integration surface straight to it, with per-window
/// navigation and the move-to picker handled on the window itself.
extension WorkspaceWindow: EditorHost {
    func suggestPages(_ query: String) -> [MentionItem] {
        workspace.clamshell?.pages(matching: query, excluding: openDocument?.url) ?? []
    }

    @discardableResult
    func openLink(_ target: LinkTarget) -> Bool {
        switch target {
        case .workspacePage(let pageID):
            openSubpage(relativePath: pageID)
            return true
        case .url(let url):
            // Workspace-relative `*.md` links resolve against the open doc's
            // URL (or home if we're at the root) and navigate internally.
            // Everything else falls through to the system handler.
            let currentDocURL = path.last ?? workspace.homeURL
            if let rel = workspace.workspaceRelativeMarkdownPath(for: url, currentDocURL: currentDocURL) {
                openSubpage(relativePath: rel)
                return true
            }
            return false
        }
    }

    func lookupPage(_ pageID: String) -> PageLookup {
        workspace.clamshell?.lookupPage(pageID) ?? .missing
    }

    func onCreateSubpage(_ title: String, _ requestedID: String?, _ initialContent: [Block]?) -> String? {
        guard let clamshell = workspace.clamshell else { return requestedID }
        do {
            return try clamshell.createPage(title: title, requestedPath: requestedID, blocks: initialContent)
        } catch {
            workspace.error = "Failed to create page: \(error.localizedDescription)"
            return requestedID
        }
    }

    func onLoadSubpage(_ pageID: String) -> [Block]? {
        guard let clamshell = workspace.clamshell else { return nil }
        let target = clamshell.url(for: pageID)
        do {
            return try clamshell.loadDocument(at: target).children
        } catch {
            Diag.subpage.error("onLoadSubpage: load(\(target.path, privacy: .public)) threw: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func onAbsorbSubpage(_ pageID: String) async -> Bool {
        // The editor calls this immediately after the inline-content mutation
        // and relies on the host to durably persist the parent doc before the
        // source file is trashed. Without the flush here, the autosave is
        // still debounced — and a crash in that window would leave the source
        // gone and the inlined content unpersisted.
        guard let clamshell = workspace.clamshell, let parent = openDocument else { return false }
        let target = clamshell.url(for: pageID)
        guard FileManager.default.fileExists(atPath: target.path) else { return false }
        guard await clamshell.flush(parent) else {
            Diag.subpage.error("onAbsorbSubpage: flush failed; skipping trash of \(pageID, privacy: .public) to avoid data loss")
            return false
        }
        do {
            _ = try clamshell.moveToTrash(at: target)
            return true
        } catch {
            workspace.error = "Failed to move \(pageID) to trash: \(error.localizedDescription)"
            return false
        }
    }

    func onAppendToSubpage(_ pageID: String, _ blocks: [Block]) async -> Bool {
        await appendToSubpage(relativePath: pageID, blocks: blocks)
    }

    func onRequestMoveDestination(_ blockIDs: [BlockID], _ inDocCandidates: [InDocMoveTarget]) async -> MoveDestination? {
        await requestMoveDestination(blockIDs: blockIDs, inDocCandidates: inDocCandidates)
    }

    func onNavigateBack() {
        goBack()
    }

    func documentDidChange(ops: [EditorOp], on post: Document) {
        workspace.clamshell?.documentDidChange(ops: ops, in: post)
    }

    func flush() async {
        guard let clamshell = workspace.clamshell, let doc = openDocument else { return }
        _ = await clamshell.flush(doc)
    }

    func serializeBlocksForPasteboard(_ blocks: [Block]) -> String {
        BlockSerializer.serialize(blocks, consecutiveNumbering: true)
    }

    func parseBlocksFromPasteboard(_ string: String) -> [Block]? {
        let blocks = BlockParser.parse(string)
        return blocks.isEmpty ? nil : blocks
    }

    func onSaveImages(_ items: [PastedImage]) -> [String] {
        guard let clamshell = workspace.clamshell else { return [] }
        var paths: [String] = []
        paths.reserveCapacity(items.count)
        for item in items {
            do {
                paths.append(try clamshell.writeImage(item))
            } catch {
                workspace.error = "Failed to save pasted image: \(error.localizedDescription)"
            }
        }
        return paths
    }

    var linkPreviewProvider: LinkPreviewProvider? {
        workspace.linkPreviewService.provider()
    }

    var imageURLResolver: ImageURLResolver? {
        // ImageURLResolver is `@Sendable`, so the closure can't directly call
        // a MainActor method on `workspace`. The renderer always invokes the
        // resolver on the main thread (image rows render in SwiftUI body), so
        // `assumeIsolated` is sound here.
        { [workspace] source in
            MainActor.assumeIsolated { workspace.clamshell?.resolveImage(source: source) }
        }
    }
}
