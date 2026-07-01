import Foundation
import Testing
@testable import Editor

@MainActor
@Suite("EditorView subpage delete callback")
struct EditorViewSubpageDeleteTests {
    @Test func deletingSelectedSubpageNotifiesHostOnce() {
        let subpage = Block.subpage(title: "Child", pageID: "Child.md")
        let doc = Document(
            url: URL(fileURLWithPath: "/tmp/test.md"),
            children: [
                subpage,
                .paragraph(text: AttributedString("after"))
            ]
        )
        let state = EditorState()
        let host = RecordingHost()
        let editor = EditorView(document: doc, state: state, host: host)
        editor.installUndoApply()

        state.setCursor(subpage.id)
        editor.deleteSelection()

        #expect(host.deletedLinks.map(\.pageID) == ["Child.md"])
        #expect(host.deletedLinks.map(\.title) == ["Child"])
        #expect(host.deletedLinks.first?.documentStillContainsTarget == false)
    }

    @Test func deletingParentSubtreeReportsNestedSubpage() {
        let child = Block.subpage(title: "Nested", pageID: "Nested.md")
        let parent = Block.toggle(title: AttributedString("Parent"), children: [child])
        let doc = Document(
            url: URL(fileURLWithPath: "/tmp/test.md"),
            children: [
                parent,
                .paragraph(text: AttributedString("after"))
            ]
        )
        let state = EditorState()
        let host = RecordingHost()
        let editor = EditorView(document: doc, state: state, host: host)
        editor.installUndoApply()

        state.setCursor(parent.id)
        editor.deleteSelection()

        #expect(host.deletedLinks.map(\.pageID) == ["Nested.md"])
        #expect(host.deletedLinks.map(\.title) == ["Nested"])
    }

    @Test func cuttingSubpageDoesNotNotifyHost() {
        let subpage = Block.subpage(title: "Child", pageID: "Child.md")
        let doc = Document(
            url: URL(fileURLWithPath: "/tmp/test.md"),
            children: [
                subpage,
                .paragraph(text: AttributedString("after"))
            ]
        )
        let state = EditorState()
        let host = RecordingHost()
        let editor = EditorView(document: doc, state: state, host: host)
        editor.installUndoApply()

        state.setCursor(subpage.id)
        #expect(editor.cutSelectionToPasteboard())

        #expect(host.deletedLinks.isEmpty)
    }
}

@MainActor
private final class RecordingHost: EditorHost {
    struct DeletedLink {
        let pageID: String
        let title: String
        let documentStillContainsTarget: Bool
    }

    var deletedLinks: [DeletedLink] = []

    func suggestPages(_ query: String, in document: Document) -> [MentionItem] { [] }
    func openPage(pageID: String) {}
    func lookupPage(_ pageID: String) -> PageLookup { .present(title: nil) }
    func didDeleteSubpageLink(pageID: String, title: String, from document: Document) {
        deletedLinks.append(.init(
            pageID: pageID,
            title: title,
            documentStillContainsTarget: containsSubpageTarget(pageID, in: document.children)
        ))
    }
    func resolvePageID(from url: URL, in document: Document) -> String? { nil }
    func linkURL(forPageID pageID: String, in document: Document) -> URL? { URL(string: pageID) }
    func createPage(title: String, requestedPath: String?, initialContent: [Block]?) async -> String? { nil }
    func loadPageBlocks(_ pageID: String) async -> [Block]? { nil }
    func inlineAndTrashPage(_ pageID: String, parent: Document) async -> Bool { false }
    func appendToPage(_ pageID: String, _ blocks: [Block]) async -> Bool { false }
    func moveDestination(for blockIDs: [BlockID], candidates: [InDocMoveTarget]) async -> MoveDestination? { nil }
    func navigateBack() {}
    func persistCommit(ops: [EditorOp], in document: Document) {}
    func flush(_ document: Document) async {}
    func serializeBlocksForPasteboard(_ blocks: [Block]) -> String { "blocks" }
    func parseBlocksFromPasteboard(_ string: String) -> [Block]? { nil }
    func saveImages(_ items: [PastedImage]) -> [String] { [] }
    func linkPreview(for url: URL) async -> LinkPreview? { nil }
    func imageURL(for source: String) -> URL? { nil }

    private func containsSubpageTarget(_ pageID: String, in blocks: [Block]) -> Bool {
        for block in blocks {
            if case .subpage(_, let target) = block.kind, target == pageID {
                return true
            }
            if containsSubpageTarget(pageID, in: block.children) {
                return true
            }
        }
        return false
    }
}
