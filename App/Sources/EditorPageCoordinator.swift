import Foundation
import Editor

/// Per-page bridge between `EditorView` and the host's document/workspace
/// layer. One instance per `EditorPage` view-identity (held in `@State`), so
/// its identity is stable across SwiftUI re-renders — that's what lets
/// `EditorView` pass it through `.equatable()`-gated subviews without the
/// closure-identity churn that 17 individual `@escaping` callbacks caused.
@MainActor
final class EditorPageCoordinator: EditorHost {
    let url: URL
    let document: Document
    let workspace: Workspace
    let window: WorkspaceWindow

    init(url: URL, document: Document, workspace: Workspace, window: WorkspaceWindow) {
        self.url = url
        self.document = document
        self.workspace = workspace
        self.window = window
    }

    func suggestPages(_ query: String) -> [MentionItem] {
        workspace.pages(matching: query, excluding: window.openDocument?.url)
    }

    func onSubpageTap(_ pageID: String) {
        window.openSubpage(relativePath: pageID)
    }

    func pageTitle(_ pageID: String) -> String? {
        workspace.pageTitle(for: pageID)
    }

    func onCreateSubpage(_ title: String, _ requestedID: String?, _ initialContent: [Block]?) -> String? {
        workspace.createSubpage(title: title, requestedPath: requestedID, initialContent: initialContent)
    }

    func onLoadSubpage(_ pageID: String) -> [Block]? {
        workspace.loadSubpage(relativePath: pageID)
    }

    func onAbsorbSubpage(_ pageID: String) -> Bool {
        workspace.moveSubpageToTrash(relativePath: pageID)
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

    func onEdited() {
        window.markEdited()
    }

    func onBlur() {
        Task { await window.saveNow() }
    }

    func onRecordBlockDeletion(_ indices: [Int], _ blocks: [Block], _ actionName: String) {
        window.recordBlockDeletion(indices: indices, blocks: blocks, actionName: actionName)
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
