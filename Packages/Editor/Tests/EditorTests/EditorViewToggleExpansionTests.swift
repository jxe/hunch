import Foundation
import SwiftUI
import Testing
@testable import Editor

@MainActor
@Suite("EditorView toggle expansion policy")
struct EditorViewToggleExpansionTests {
    @Test func turnIntoToggleStartsClosedAndClearsTemplateExpansion() {
        let doc = Document(
            url: URL(fileURLWithPath: "/tmp/test.md"),
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
            url: URL(fileURLWithPath: "/tmp/test.md"),
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
            url: URL(fileURLWithPath: "/tmp/test.md"),
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
            url: URL(fileURLWithPath: "/tmp/test.md"),
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
            url: URL(fileURLWithPath: "/tmp/test.md"),
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
            url: URL(fileURLWithPath: "/tmp/test.md"),
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
}

@MainActor
private final class TestHost: EditorHost {
    var loadedPageBlocks: [Block]?
    var didInlineAndTrashPage = false

    init(loadedPageBlocks: [Block]? = nil) {
        self.loadedPageBlocks = loadedPageBlocks
    }

    func suggestPages(_ query: String, in document: Document) -> [MentionItem] { [] }
    func openPage(pageID: String) {}
    func lookupPage(_ pageID: String) -> PageLookup { .present(title: nil) }
    func resolvePageID(from url: URL, in document: Document) -> String? { nil }
    func createPage(title: String, requestedPath: String?, initialContent: [Block]?) async -> String? { nil }
    func loadPageBlocks(_ pageID: String) async -> [Block]? { loadedPageBlocks }
    func inlineAndTrashPage(_ pageID: String, parent: Document) async -> Bool {
        didInlineAndTrashPage = true
        return true
    }
    func appendToPage(_ pageID: String, _ blocks: [Block]) async -> Bool { true }
    func moveDestination(for blockIDs: [BlockID], candidates: [InDocMoveTarget]) async -> MoveDestination? { nil }
    func navigateBack() {}
    func persistCommit(ops: [EditorOp], in document: Document) {}
    func flush(_ document: Document) async {}
    func serializeBlocksForPasteboard(_ blocks: [Block]) -> String { "" }
    func parseBlocksFromPasteboard(_ string: String) -> [Block]? { nil }
    func saveImages(_ items: [PastedImage]) -> [String] { [] }
    func linkPreview(for url: URL) async -> LinkPreview? { nil }
    func imageURL(for source: String) -> URL? { nil }
}
