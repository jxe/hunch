import Quagmire
import SwiftUI
import Testing

@MainActor
private final class MinimalHost: EditorHost {
    func persistCommit(changes: [DocumentChange], in document: Document) {}
    func flush(_ document: Document) async {}
}

@Suite("Public API consumer")
struct PublicAPIConsumerTests {
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
