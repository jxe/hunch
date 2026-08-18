import Foundation
import Testing
@testable import Quagmire

@MainActor
@Suite("EditorView documentLink delete callback")
struct EditorViewDocumentLinkDeleteTests {
    @Test func deletingSelectedDocumentLinkNotifiesHostOnce() {
        let documentLink = Block.documentLink(label: AttributedString("Child"), reference: DocumentReference("Child.md"))
        let doc = Document(
            id: DocumentID("test"),
            children: [
                documentLink,
                .paragraph(text: AttributedString("after"))
            ]
        )
        let state = EditorState()
        let host = RecordingHost()
        let editor = EditorView(document: doc, state: state, host: host)
        editor.installUndoApply()

        state.setCursor(documentLink.id)
        editor.deleteSelection()

        #expect(host.deletedLinks.map(\.reference.rawValue) == ["Child.md"])
        #expect(host.deletedLinks.map(\.label) == ["Child"])
        #expect(host.deletedLinks.first?.documentStillContainsTarget == false)
    }

    @Test func deletingParentSubtreeReportsNestedDocumentLink() {
        let child = Block.documentLink(label: AttributedString("Nested"), reference: DocumentReference("Nested.md"))
        let parent = Block.toggle(title: AttributedString("Parent"), children: [child])
        let doc = Document(
            id: DocumentID("test"),
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

        #expect(host.deletedLinks.map(\.reference.rawValue) == ["Nested.md"])
        #expect(host.deletedLinks.map(\.label) == ["Nested"])
    }

    @Test func cuttingDocumentLinkDoesNotNotifyHost() {
        let documentLink = Block.documentLink(label: AttributedString("Child"), reference: DocumentReference("Child.md"))
        let doc = Document(
            id: DocumentID("test"),
            children: [
                documentLink,
                .paragraph(text: AttributedString("after"))
            ]
        )
        let state = EditorState()
        let host = RecordingHost()
        let editor = EditorView(document: doc, state: state, host: host)
        editor.installUndoApply()

        state.setCursor(documentLink.id)
        #expect(editor.cutSelectionToPasteboard())

        #expect(host.deletedLinks.isEmpty)
    }
}

@MainActor
private final class RecordingHost: EditorHostDefaults {
    struct DeletedLink {
        let reference: DocumentReference
        let label: String
        let documentStillContainsTarget: Bool
    }

    var deletedLinks: [DeletedLink] = []

    func suggestDocuments(_ query: String, in document: Document) async -> [MentionItem] { [] }
    func openDocument(_ reference: DocumentReference) {}
    func lookupDocument(_ reference: DocumentReference) -> DocumentLookup { .present(title: nil) }
    func didDeleteDocumentLink(reference: DocumentReference, label: String, from document: Document) {
        deletedLinks.append(.init(
            reference: reference,
            label: label,
            documentStillContainsTarget: containsTarget(reference, in: document.children)
        ))
    }
    func resolveReference(from url: URL, in document: Document) -> DocumentReference? { nil }
    func linkURL(for reference: DocumentReference, in document: Document) -> URL? { URL(string: reference.rawValue) }
    func createDocument(title: String, requestedReference: DocumentReference?, initialContent: [Block]?) async -> DocumentReference? { nil }
    func loadDocumentBlocks(_ reference: DocumentReference) async -> [Block]? { nil }
    func inlineAndRetireDocument(_ reference: DocumentReference, parent: Document) async -> Bool { false }
    func appendToDocument(_ reference: DocumentReference, _ blocks: [Block]) async -> Bool { false }
    func moveDestination(for blockIDs: [BlockID], candidates: [InDocMoveTarget]) async -> MoveDestination? { nil }
    func navigateBack() {}
    func persistCommit(changes: [DocumentChange], in document: Document) {}
    func flush(_ document: Document) async {}
    func serializeBlocksForPasteboard(_ blocks: [Block]) -> String { "blocks" }
    func parseBlocksFromPasteboard(_ string: String) -> [Block]? { nil }
    func saveImages(_ items: [PastedImage]) -> [String] { [] }
    func linkPreview(for url: URL) async -> LinkPreview? { nil }
    func imageURL(for source: String) -> URL? { nil }

    private func containsTarget(_ reference: DocumentReference, in blocks: [Block]) -> Bool {
        for block in blocks {
            if case .documentLink(_, let target) = block.kind, target == reference {
                return true
            }
            if containsTarget(reference, in: block.children) {
                return true
            }
        }
        return false
    }
}
