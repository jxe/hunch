import Foundation
import SwiftUI
import Testing
@testable import Quagmire

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

    @Test func documentLinkTurnIntoToggleStartsClosed() async {
        let doc = Document(
            id: DocumentID("test"),
            children: [
                .documentLink(label: AttributedString("Child"), reference: DocumentReference("child.md"))
            ]
        )
        let state = EditorState()
        let id = doc.children[0].id
        let host = TestHost(loadedDocumentBlocks: [
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
        #expect(host.didInlineAndRetireDocument)
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

        await editor.moveBlocks(ids: [toggle.id, toggle.children[0].id], intoDocument: DocumentReference("target.md"))

        #expect(host.appendedReference?.rawValue == "target.md")
        #expect(host.appendedBlocks.map(\.id) == [toggle.id])
        #expect(host.appendedBlocks.first?.children.map(\.id) == [toggle.children[0].id])
        #expect(doc.children.isEmpty)
    }

    @Test func crossPageCopyUsesFreshIDsAndKeepsSourceSubtree() async {
        let child = Block.paragraph(text: AttributedString("child"))
        let toggle = Block.toggle(
            title: AttributedString("Details"),
            children: [child]
        )
        let doc = Document(
            id: DocumentID("test"),
            children: [toggle]
        )
        let state = EditorState()
        let host = TestHost()
        let editor = EditorView(document: doc, state: state, host: host)
        editor.installUndoApply()

        await editor.copyBlocks(ids: [toggle.id, child.id], intoDocument: DocumentReference("target.md"))

        #expect(host.appendedReference?.rawValue == "target.md")
        #expect(host.appendedBlocks.count == 1)
        #expect(host.appendedBlocks[0].id != toggle.id)
        #expect(host.appendedBlocks[0].kind == toggle.kind)
        #expect(host.appendedBlocks[0].children.count == 1)
        #expect(host.appendedBlocks[0].children[0].id != child.id)
        #expect(host.appendedBlocks[0].children[0].kind == child.kind)
        #expect(doc.children == [toggle])
        #expect(state.actionToast == "Copied")
    }

    @Test func failedCrossPageCopyKeepsSourceUntouched() async {
        let block = Block.paragraph(text: AttributedString("source"))
        let doc = Document(
            id: DocumentID("test"),
            children: [block]
        )
        let state = EditorState()
        let host = TestHost()
        host.appendSucceeds = false
        let editor = EditorView(document: doc, state: state, host: host)
        editor.installUndoApply()

        await editor.copyBlocks(ids: [block.id], intoDocument: DocumentReference("target.md"))

        #expect(doc.children == [block])
        #expect(state.actionToast == nil)
    }
}

@MainActor
private final class TestHost: EditorHost {
    var supportsDocumentInlining: Bool { true }
    var loadedDocumentBlocks: [Block]?
    var didInlineAndRetireDocument = false
    var appendedReference: DocumentReference?
    var appendedBlocks: [Block] = []
    var appendSucceeds = true

    init(loadedDocumentBlocks: [Block]? = nil) {
        self.loadedDocumentBlocks = loadedDocumentBlocks
    }

    func suggestDocuments(_ query: String, in document: Document) -> [MentionItem] { [] }
    func openDocument(_ reference: DocumentReference) {}
    func lookupDocument(_ reference: DocumentReference) -> DocumentLookup { .present(title: nil) }
    func resolveReference(from url: URL, in document: Document) -> DocumentReference? { nil }
    func linkURL(for reference: DocumentReference, in document: Document) -> URL? { URL(string: reference.rawValue) }
    func createDocument(title: String, requestedReference: DocumentReference?, initialContent: [Block]?) async -> DocumentReference? { nil }
    func loadDocumentBlocks(_ reference: DocumentReference) async -> [Block]? { loadedDocumentBlocks }
    func inlineAndRetireDocument(_ reference: DocumentReference, parent: Document) async -> Bool {
        didInlineAndRetireDocument = true
        return true
    }
    func appendToDocument(_ reference: DocumentReference, _ blocks: [Block]) async -> Bool {
        appendedReference = reference
        appendedBlocks = blocks
        return appendSucceeds
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
