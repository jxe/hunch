import Foundation
import Testing
@testable import Quagmire
#if os(macOS)
import AppKit
#endif

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

    #if os(macOS)
    @Test func localMonitorInterceptsEscapeOnlyInFullscreen() {
        #expect(EditorView.monitoredMacAction(keyCode: 53, modifiers: [], isFullscreen: true) == .escape)
        #expect(EditorView.monitoredMacAction(keyCode: 53, modifiers: [], isFullscreen: false) == nil)
        #expect(EditorView.monitoredMacAction(keyCode: 53, modifiers: .command, isFullscreen: true) == nil)
    }

    @Test func localMonitorStillInterceptsShiftTabForOutdent() {
        #expect(EditorView.monitoredMacAction(keyCode: 48, modifiers: .shift, isFullscreen: false) == .outdent)
    }
    #endif
}

@MainActor
private final class EscapeTestHost: EditorHostDefaults {
    func persistCommit(changes: [DocumentChange], in document: Document) {}
    func flush(_ document: Document) async {}
}
