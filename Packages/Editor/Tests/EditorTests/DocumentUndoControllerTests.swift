import Foundation
import SwiftUI
import Testing
@testable import Editor
#if os(macOS)
import AppKit
#endif

@MainActor
@Suite("DocumentUndoController — live text undo")
struct DocumentUndoControllerTests {
    private func makeDocument() -> Document {
        Document(
            id: DocumentID("undo-controller"),
            children: [.paragraph(text: AttributedString("alpha"))]
        )
    }

    private func plainText(_ document: Document) -> String {
        String(document.children[0].text.characters)
    }

    @Test func checkpointDelayIs750Milliseconds() {
        #expect(typingCheckpointDelay == .milliseconds(750))
    }

    #if os(macOS)
    @Test func macTextChangesCommitAfterCheckpointDelay() async throws {
        let document = makeDocument()
        let blockID = document.children[0].id
        let controller = DocumentUndoController()
        controller.document = document
        document.undoManager = controller.undoManager
        let parent = MacBlockTextEditor(
            text: Binding(
                get: { document.find(blockID)?.text ?? AttributedString() },
                set: { document.setText(blockID, $0) }
            ),
            fontSize: 16,
            bold: false,
            lineSpacing: 2,
            theme: .default,
            isFocused: true,
            onFocusChange: { _ in },
            onKey: { _ in .ignored },
            onAutotransform: { _, _ in },
            onOpenLink: { _ in false },
            onCompletionTriggerChange: { _ in },
            completionActive: false,
            consumeInitialCursor: { nil },
            blockID: blockID,
            documentUndoController: controller,
            activeView: nil
        )
        let coordinator = parent.makeCoordinator()
        let textView = NSTextView()
        textView.string = "alpha beta"

        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        #expect(plainText(document) == "alpha")

        try await Task.sleep(for: .milliseconds(850))
        #expect(plainText(document) == "alpha beta")

        controller.undo()
        #expect(plainText(document) == "alpha")
    }
    #endif

    @Test func undoFlushesDirtyLiveTextThenUndoesThatBurst() {
        let document = makeDocument()
        let controller = DocumentUndoController()
        controller.document = document
        document.undoManager = controller.undoManager

        var dirty = true
        var cancelCount = 0
        var synchronizeCount = 0
        controller.hasActiveTextChanges = { dirty }
        controller.cancelActiveTextCheckpoint = { cancelCount += 1 }
        controller.flushActiveText = {
            guard dirty else { return }
            dirty = false
            controller.transaction(name: "Type") {
                document.setText(document.children[0].id, AttributedString("alpha beta"))
            }
        }
        controller.synchronizeActiveText = { synchronizedDocument in
            #expect(synchronizedDocument === document)
            synchronizeCount += 1
        }

        #expect(controller.canUndo, "dirty live text is immediately undoable")
        controller.undo()

        #expect(plainText(document) == "alpha")
        #expect(cancelCount == 1)
        #expect(synchronizeCount == 1)
        #expect(controller.canRedo)

        controller.redo()
        #expect(plainText(document) == "alpha beta")
        #expect(synchronizeCount == 2)
    }

    @Test func newDirtyTextInvalidatesRedoBeforeRedoRuns() {
        let document = makeDocument()
        let controller = DocumentUndoController()
        controller.document = document
        document.undoManager = controller.undoManager

        controller.transaction(name: "Type") {
            document.setText(document.children[0].id, AttributedString("first burst"))
        }
        controller.undo()
        #expect(controller.canRedo)

        var dirty = true
        controller.hasActiveTextChanges = { dirty }
        controller.flushActiveText = {
            guard dirty else { return }
            dirty = false
            controller.transaction(name: "Type") {
                document.setText(document.children[0].id, AttributedString("new burst"))
            }
        }

        #expect(!controller.canRedo)
        controller.redo()
        #expect(plainText(document) == "new burst")
        #expect(!controller.canRedo)
    }

    @Test func separateTypingCheckpointsUndoIndependently() {
        let document = makeDocument()
        let controller = DocumentUndoController()
        controller.document = document
        document.undoManager = controller.undoManager

        controller.transaction(name: "Type") {
            document.setText(document.children[0].id, AttributedString("first burst"))
        }
        controller.transaction(name: "Type") {
            document.setText(document.children[0].id, AttributedString("second burst"))
        }

        controller.undo()
        #expect(plainText(document) == "first burst")
        controller.undo()
        #expect(plainText(document) == "alpha")
    }

    @Test func caretTracksRestoredChangedRange() {
        #expect(caretRangeAfterTextReplacement(
            current: "hello brave world",
            restored: "hello world",
            currentSelection: NSRange(location: 17, length: 0)
        ) == NSRange(location: 6, length: 0))

        #expect(caretRangeAfterTextReplacement(
            current: "hello world",
            restored: "hello brave world",
            currentSelection: NSRange(location: 6, length: 0)
        ) == NSRange(location: 12, length: 0))

        #expect(caretRangeAfterTextReplacement(
            current: "abcXYZdef",
            restored: "abcQdef",
            currentSelection: NSRange(location: 6, length: 0)
        ) == NSRange(location: 4, length: 0))
    }

    @Test func caretUsesUTF16AndPreservesSelectionForFormattingOnlyChanges() {
        #expect(caretRangeAfterTextReplacement(
            current: "a🙂bc",
            restored: "abc",
            currentSelection: NSRange(location: 3, length: 0)
        ) == NSRange(location: 1, length: 0))

        #expect(caretRangeAfterTextReplacement(
            current: "same text",
            restored: "same text",
            currentSelection: NSRange(location: 2, length: 4)
        ) == NSRange(location: 2, length: 4))
    }
}
