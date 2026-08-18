import Foundation
import SwiftUI
import Testing
@testable import Quagmire

@MainActor
@Suite("EditorView indent commands")
struct EditorViewIndentTests {
    @Test func indentContiguousSelectionMovesSlabUnderPreviousSibling() {
        let container = Block.toggle(title: AttributedString("container"))
        let first = Block.paragraph(text: AttributedString("first"))
        let second = Block.bullet(text: AttributedString("second"))
        let after = Block.paragraph(text: AttributedString("after"))
        let doc = Document(
            id: DocumentID("test"),
            children: [container, first, second, after]
        )
        let state = EditorState()
        let editor = EditorView(document: doc, state: state, host: TestHost())
        editor.installUndoApply()

        #expect(editor.canChangeIndent(ids: [first.id, second.id], by: 1))
        #expect(editor.indentBlocks([first.id, second.id], by: 1))

        #expect(doc.children.map(\.id) == [container.id, after.id])
        #expect(doc.children[0].children.map(\.id) == [first.id, second.id])
        #expect(state.expandedToggles.contains(container.id))
    }

    @Test func outdentContiguousSelectionMovesSlabAfterParent() {
        let before = Block.paragraph(text: AttributedString("before"))
        let first = Block.paragraph(text: AttributedString("first"))
        let second = Block.bullet(text: AttributedString("second"))
        let parent = Block.bullet(text: AttributedString("parent"), children: [first, second])
        let after = Block.paragraph(text: AttributedString("after"))
        let doc = Document(
            id: DocumentID("test"),
            children: [before, parent, after]
        )
        let state = EditorState()
        let editor = EditorView(document: doc, state: state, host: TestHost())
        editor.installUndoApply()

        #expect(editor.canChangeIndent(ids: [first.id, second.id], by: -1))
        #expect(editor.indentBlocks([first.id, second.id], by: -1))

        #expect(doc.children.map(\.id) == [before.id, parent.id, first.id, second.id, after.id])
        #expect(doc.children[1].children.isEmpty)
    }

    @Test func indentRejectsSlabWithoutPreviousSibling() {
        let first = Block.paragraph(text: AttributedString("first"))
        let second = Block.bullet(text: AttributedString("second"))
        let after = Block.paragraph(text: AttributedString("after"))
        let doc = Document(
            id: DocumentID("test"),
            children: [first, second, after]
        )
        let state = EditorState()
        let editor = EditorView(document: doc, state: state, host: TestHost())
        editor.installUndoApply()

        #expect(!editor.canChangeIndent(ids: [first.id, second.id], by: 1))
        #expect(!editor.indentBlocks([first.id, second.id], by: 1))
        #expect(doc.children.map(\.id) == [first.id, second.id, after.id])
    }

    @Test func outdentRejectsChildrenOfHeading() {
        let first = Block.paragraph(text: AttributedString("first"))
        let second = Block.bullet(text: AttributedString("second"))
        let heading = Block.heading(level: .h2, text: AttributedString("heading"), children: [first, second])
        let after = Block.paragraph(text: AttributedString("after"))
        let doc = Document(
            id: DocumentID("test"),
            children: [heading, after]
        )
        let state = EditorState()
        let editor = EditorView(document: doc, state: state, host: TestHost())
        editor.installUndoApply()

        #expect(!editor.canChangeIndent(ids: [first.id, second.id], by: -1))
        #expect(!editor.indentBlocks([first.id, second.id], by: -1))
        #expect(doc.children.map(\.id) == [heading.id, after.id])
        #expect(doc.children[0].children.map(\.id) == [first.id, second.id])
    }
}

@MainActor
private final class TestHost: EditorHostDefaults {
    func suggestDocuments(_ query: String, in document: Document) -> [MentionItem] { [] }
    func openDocument(_ reference: DocumentReference) {}
    func lookupDocument(_ reference: DocumentReference) -> DocumentLookup { .present(title: nil) }
    func resolveReference(from url: URL, in document: Document) -> DocumentReference? { nil }
    func linkURL(for reference: DocumentReference, in document: Document) -> URL? { URL(string: reference.rawValue) }
    func createDocument(title: String, requestedReference: DocumentReference?, initialContent: [Block]?) async -> DocumentReference? { nil }
    func loadDocumentBlocks(_ reference: DocumentReference) async -> [Block]? { nil }
    func inlineAndRetireDocument(_ reference: DocumentReference, parent: Document) async -> Bool { true }
    func appendToDocument(_ reference: DocumentReference, _ blocks: [Block]) async -> Bool { true }
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
