import Quagmire
import SwiftUI
import Testing

@MainActor
private final class MinimalHost: EditorHostDefaults {
    func persistCommit(changes: [DocumentChange], in document: Document) {}
    func flush(_ document: Document) async {}
}

/// A host that overrides every requirement, each answering distinguishably from
/// the protocol default.
///
/// Every `EditorHost` requirement has a default implementation, which is what
/// lets a host adopt the protocol with two methods. The cost is that a
/// *mistyped* override is not an error — it is an overload, and the default
/// silently wins. Get one signature wrong and the editor quietly loses that
/// capability with nothing to show for it at build time. This suite is the
/// tripwire: if a signature in the protocol changes without this file changing
/// with it, the corresponding assertion below fails.
@MainActor
private final class FullHost: EditorHost {
    var supportsDocumentCreation: Bool { true }
    var supportsDocumentInlining: Bool { true }
    var supportsMoveDestinationPicker: Bool { true }

    func suggestDocuments(_ query: String, in document: Document) async -> [MentionItem] {
        [MentionItem(id: DocumentReference("d"), title: "D")]
    }
    func openDocument(_ reference: DocumentReference) { opened = reference }
    func setDocumentIcon(_ emoji: String, for reference: DocumentReference) async -> Bool { true }
    func lookupDocument(_ reference: DocumentReference) -> DocumentLookup { .present(title: "resolved") }
    func didDeleteDocumentLink(reference: DocumentReference, label: String, from document: Document) { deleted = reference }
    func resolveReference(from url: URL, in document: Document) -> DocumentReference? { DocumentReference("resolved") }
    func linkURL(for reference: DocumentReference, in document: Document) -> URL? { URL(string: "https://example.com") }
    func createDocument(title: String, requestedReference: DocumentReference?, initialContent: [Block]?) async -> DocumentReference? {
        DocumentReference("created")
    }
    func loadDocumentBlocks(_ reference: DocumentReference) async -> [Block]? { [] }
    func inlineAndRetireDocument(_ reference: DocumentReference, parent: Document) async -> Bool { true }
    func appendToDocument(_ reference: DocumentReference, _ blocks: [Block]) async -> Bool { true }
    func moveDestination(for blockIDs: [BlockID], candidates: [InDocMoveTarget]) async -> MoveDestination? {
        .document(DocumentReference("picked"))
    }
    func navigateBack() {}
    func persistCommit(changes: [DocumentChange], in document: Document) {}
    func flush(_ document: Document) async {}
    func serializeBlocksForPasteboard(_ blocks: [Block]) -> String { "serialized" }
    func parseBlocksFromPasteboard(_ string: String) -> [Block]? { [.paragraph(text: AttributedString("parsed"))] }
    func saveImages(_ items: [PastedImage]) -> [String] { ["saved"] }
    func linkPreview(for url: URL) async -> LinkPreview? { nil }
    func imageURL(for source: String) -> URL? { URL(string: "file:///image") }
    func blockActions(in document: Document) -> [EditorBlockAction] { [] }

    var opened: DocumentReference?
    var deleted: DocumentReference?
}

@Suite("Public API consumer")
struct PublicAPIConsumerTests {

    /// Each assertion here fails if the matching `FullHost` method stops
    /// satisfying its requirement — because then the default answers instead,
    /// and the default is deliberately the opposite value.
    @MainActor
    @Test func everyOverrideActuallySatisfiesItsRequirement() async {
        let document = Document(id: DocumentID("d"), children: [.paragraph(text: AttributedString("x"))])
        let host: any EditorHost = FullHost()

        #expect(host.supportsDocumentCreation)
        #expect(host.supportsDocumentInlining)
        #expect(host.supportsMoveDestinationPicker)
        #expect(await !host.suggestDocuments("q", in: document).isEmpty)
        #expect(host.lookupDocument(DocumentReference("d")).title == "resolved")
        #expect(host.resolveReference(from: URL(string: "x.md")!, in: document) != nil)
        #expect(host.linkURL(for: DocumentReference("d"), in: document) != nil)
        #expect(await host.setDocumentIcon("📕", for: DocumentReference("d")))
        #expect(await host.createDocument(title: "T", requestedReference: nil, initialContent: nil) != nil)
        #expect(await host.loadDocumentBlocks(DocumentReference("d")) != nil)
        #expect(await host.inlineAndRetireDocument(DocumentReference("d"), parent: document))
        #expect(await host.appendToDocument(DocumentReference("d"), []))
        #expect(await host.moveDestination(for: [], candidates: []) != nil)
        #expect(host.serializeBlocksForPasteboard([]) == "serialized")
        #expect(host.parseBlocksFromPasteboard("x") != nil)
        #expect(!host.saveImages([]).isEmpty)
        #expect(host.imageURL(for: "x") != nil)

        host.openDocument(DocumentReference("opened"))
        host.didDeleteDocumentLink(reference: DocumentReference("gone"), label: "L", from: document)
        #expect((host as? FullHost)?.opened?.rawValue == "opened")
        #expect((host as? FullHost)?.deleted?.rawValue == "gone")
    }

    @MainActor
    @Test func minimalHostConstructsEditorView() {
        let document = Document(
            id: DocumentID("in-memory-document"),
            children: [.paragraph(text: AttributedString("Hello"))]
        )
        let state = EditorState()
        let host = MinimalHost()

        let view = EditorView(document: document, state: state, host: host)

        #expect(document.title == "Untitled")
        _ = view
    }
}
