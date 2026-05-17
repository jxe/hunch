import Foundation
import Editor

/// `WorkspaceWindow` is the `EditorHost` for the editor mounted in this
/// window. The save lifecycle (debounce + per-URL coalescing) lives on
/// `Clamshell` — see `Clamshell+Saving.swift`. These methods route the
/// editor's integration surface — link dispatch, subpage lifecycle,
/// mention queries, pasteboard codec, image persistence — through
/// `Workspace` and the per-window navigation/file-presenter state, and
/// forward mutation/blur signals straight to Clamshell.
extension WorkspaceWindow: EditorHost {
    func suggestPages(_ query: String) -> [MentionItem] {
        workspace.pages(matching: query, excluding: openDocument?.url)
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
        return workspace.moveSubpageToTrash(relativePath: pageID)
    }

    func onAppendToSubpage(_ pageID: String, _ blocks: [Block]) -> Bool {
        appendToSubpage(relativePath: pageID, blocks: blocks)
    }

    func onRequestMoveDestination(_ blockIDs: [BlockID], _ inDocCandidates: [InDocMoveTarget], _ pick: @escaping (MoveDestination?) -> Void) {
        requestMoveDestination(blockIDs: blockIDs, inDocCandidates: inDocCandidates, completion: pick)
    }

    func onNavigateBack() {
        goBack()
    }

    func documentDidChange(ops: [EditorOp], on post: Document) {
        workspace.clamshell?.documentDidChange(ops: ops, in: post)
    }

    func onBlur() async {
        guard let clamshell = workspace.clamshell, let doc = openDocument else { return }
        await clamshell.flush(doc)
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
        // `assumeIsolated` is sound here.
        { [workspace] source in
            MainActor.assumeIsolated { workspace.imageURL(for: source) }
        }
    }
}
