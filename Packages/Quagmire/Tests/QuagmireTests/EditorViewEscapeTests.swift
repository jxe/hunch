import Foundation
import Testing
@testable import Quagmire

@MainActor
@Suite("EditorView Escape behavior")
struct EditorViewEscapeTests {
    @Test func repeatedEscapeKeepsEditedBlockSelected() {
        let block = Block.paragraph(text: AttributedString("Selected"))
        let document = Document(id: DocumentID("test"), children: [block])
        let state = EditorState()
        let editor = EditorView(document: document, state: state, host: EscapeTestHost())

        state.enterEditMode(on: block.id)

        editor.handleEscapeKey()
        #expect(state.editingBlock == nil)
        #expect(state.selection == [block.id])
        #expect(state.cursor == block.id)

        editor.handleEscapeKey()
        #expect(state.selection == [block.id])
        #expect(state.cursor == block.id)
    }
}

@MainActor
private final class EscapeTestHost: EditorHostDefaults {
    func persistCommit(changes: [DocumentChange], in document: Document) {}
    func flush(_ document: Document) async {}
}
