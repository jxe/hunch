import Foundation
import SwiftUI
import Testing
@testable import Editor

@MainActor
@Suite("EditorView toggle expansion policy")
struct EditorViewToggleExpansionTests {
    @Test func turnIntoToggleStartsClosedAndClearsTemplateExpansion() {
        let doc = Document(
            id: DocumentID("test"),
            children: [
                .templateButton(label: "Details")
            ]
        )
        let state = EditorState()
        let id = doc.children[0].id
        state.expandedTemplates.insert(id)
        let editor = EditorView(document: doc, state: state, host: TestHost())
        editor.installUndoApply()

        #expect(editor.convert(blockIDs: [id], to: .toggle) == .handled)

        guard case .toggle(let title) = doc.children[0].kind else {
            Issue.record("expected toggle")
            return
        }
        #expect(String(title.characters) == "Details")
        #expect(!state.expandedToggles.contains(id))
        #expect(!state.expandedTemplates.contains(id))
    }

    @Test func autotransformToggleStartsClosed() {
        let doc = Document(
            id: DocumentID("test"),
            children: [
                .paragraph(text: AttributedString("> Details"))
            ]
        )
        let state = EditorState()
        let id = doc.children[0].id
        let editor = EditorView(document: doc, state: state, host: TestHost())
        editor.installUndoApply()

        editor.applyAutotransform(.toggle, remainingText: AttributedString("Details"), blockID: id)

        guard case .toggle(let title) = doc.children[0].kind else {
            Issue.record("expected toggle")
            return
        }
        #expect(String(title.characters) == "Details")
        #expect(state.expandedToggles.isEmpty)
    }

    @Test func subpageTurnIntoToggleStartsClosed() async {
        let doc = Document(
            id: DocumentID("test"),
            children: [
                .subpage(title: "Child", pageID: "child.md")
            ]
        )
        let state = EditorState()
        let id = doc.children[0].id
        let host = TestHost(loadedPageBlocks: [
            .paragraph(text: AttributedString("body"))
        ])
        let editor = EditorView(document: doc, state: state, host: host)
        editor.installUndoApply()

        #expect(editor.convert(blockIDs: [id], to: .toggle) == .handled)
        await Task.yield()

        guard case .toggle(let title) = doc.children[0].kind else {
            Issue.record("expected toggle")
            return
        }
        #expect(String(title.characters) == "Child")
        #expect(doc.children[0].children.count == 1)
        #expect(state.expandedToggles.isEmpty)
        #expect(host.didInlineAndTrashPage)
    }

    @Test func optionArrowMoveDoesNotRevealCollapsedAncestor() {
        let doc = Document(
            id: DocumentID("test"),
            children: [
                .toggle(title: AttributedString("Closed"), children: [
                    .paragraph(text: AttributedString("first")),
                    .paragraph(text: AttributedString("second"))
                ])
            ]
        )
        let state = EditorState()
        let secondID = doc.children[0].children[1].id
        let editor = EditorView(document: doc, state: state, host: TestHost())
        editor.installUndoApply()

        editor.moveBlocksInDocument(Set([secondID]), by: -1)

        #expect(doc.children[0].children.map { String($0.text.characters) } == ["second", "first"])
        #expect(state.expandedToggles.isEmpty)
    }

    @Test func dropIntoToggleDoesNotExpandDestination() {
        let moving = Block.paragraph(text: AttributedString("moving"))
        let toggle = Block.toggle(title: AttributedString("Closed"))
        let doc = Document(
            id: DocumentID("test"),
            children: [moving, toggle]
        )
        let state = EditorState()
        let editor = EditorView(document: doc, state: state, host: TestHost())
        editor.installUndoApply()

        editor.moveBlocks(ids: [moving.id], asChildrenOf: toggle.id, snapshot: [], hidden: [])

        #expect(doc.children.count == 1)
        #expect(doc.children[0].id == toggle.id)
        #expect(doc.children[0].children.map(\.id) == [moving.id])
        #expect(state.expandedToggles.isEmpty)
    }

    @Test func indentStillRevealsCollapsedToggleAncestor() {
        let toggle = Block.toggle(title: AttributedString("Closed"))
        let child = Block.paragraph(text: AttributedString("child"))
        let doc = Document(
            id: DocumentID("test"),
            children: [toggle, child]
        )
        let state = EditorState()
        let editor = EditorView(document: doc, state: state, host: TestHost())
        editor.installUndoApply()

        #expect(editor.indentBlocks([child.id], by: 1))

        #expect(doc.children.count == 1)
        #expect(doc.children[0].id == toggle.id)
        #expect(doc.children[0].children.map(\.id) == [child.id])
        #expect(state.expandedToggles.contains(toggle.id))
    }

    @Test func indentingSelectedClosedToggleDoesNotExpandItsBody() {
        let parent = Block.bullet(text: AttributedString("parent"))
        let child = Block.paragraph(text: AttributedString("child"))
        let toggle = Block.toggle(title: AttributedString("Closed"), children: [child])
        let doc = Document(
            id: DocumentID("test"),
            children: [parent, toggle]
        )
        let state = EditorState()
        let editor = EditorView(document: doc, state: state, host: TestHost())
        editor.installUndoApply()

        #expect(editor.indentBlocks([toggle.id, child.id], by: 1))

        #expect(doc.children.map(\.id) == [parent.id])
        #expect(doc.children[0].children.map(\.id) == [toggle.id])
        #expect(doc.children[0].children[0].children.map(\.id) == [child.id])
        #expect(state.expandedToggles.isEmpty)
    }

    @Test func crossPageMoveCollapsesCoveredToggleDescendants() async {
        let toggle = Block.toggle(
            title: AttributedString("Details"),
            children: [.paragraph(text: AttributedString("child"))]
        )
        let doc = Document(
            id: DocumentID("test"),
            children: [toggle]
        )
        let host = TestHost()
        let editor = EditorView(document: doc, state: EditorState(), host: host)
        editor.installUndoApply()

        await editor.moveBlocks(ids: [toggle.id, toggle.children[0].id], intoSubpagePath: "target.md")

        #expect(host.appendedPageID == "target.md")
        #expect(host.appendedBlocks.map(\.id) == [toggle.id])
        #expect(host.appendedBlocks.first?.children.map(\.id) == [toggle.children[0].id])
        #expect(doc.children.isEmpty)
    }
}

@MainActor
private final class TestHost: EditorHost {
    var supportsSubpageInlining: Bool { true }
    var loadedPageBlocks: [Block]?
    var didInlineAndTrashPage = false
    var appendedPageID: String?
    var appendedBlocks: [Block] = []

    init(loadedPageBlocks: [Block]? = nil) {
        self.loadedPageBlocks = loadedPageBlocks
    }

    func suggestPages(_ query: String, in document: Document) -> [MentionItem] { [] }
    func openPage(pageID: String) {}
    func lookupPage(_ pageID: String) -> PageLookup { .present(title: nil) }
    func resolvePageID(from url: URL, in document: Document) -> String? { nil }
    func linkURL(forPageID pageID: String, in document: Document) -> URL? { URL(string: pageID) }
    func createPage(title: String, requestedPath: String?, initialContent: [Block]?) async -> String? { nil }
    func loadPageBlocks(_ pageID: String) async -> [Block]? { loadedPageBlocks }
    func inlineAndTrashPage(_ pageID: String, parent: Document) async -> Bool {
        didInlineAndTrashPage = true
        return true
    }
    func appendToPage(_ pageID: String, _ blocks: [Block]) async -> Bool {
        appendedPageID = pageID
        appendedBlocks = blocks
        return true
    }
    func moveDestination(for blockIDs: [BlockID], candidates: [InDocMoveTarget]) async -> MoveDestination? { nil }
    func navigateBack() {}
    func persistCommit(changes: [DocumentChange], in document: Document) {}
    func flush(_ document: Document) async {}
    func serializeBlocksForPasteboard(_ blocks: [Block]) -> String { "" }
    func parseBlocksFromPasteboard(_ string: String) -> [Block]? { nil }
    func saveImages(_ items: [PastedImage]) -> [String] { [] }
    func linkPreview(for url: URL) async -> LinkPreview? { nil }
    func imageURL(for source: String) -> URL? { nil }
}
