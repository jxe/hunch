import Foundation
import Testing
@testable import Quagmire

@MainActor
@Suite("Host-supplied block actions")
struct EditorBlockActionTests {
    @Test func selectionSnapshotsAreOrderedAndExcludeStructuralRows() {
        let first = Block.paragraph(text: AttributedString("First"))
        let divider = Block.divider()
        let nested = Block.bullet(text: AttributedString("Nested"))
        let parent = Block.toggle(title: AttributedString("Parent"), children: [nested])
        let blank = Block.paragraph(text: AttributedString("   "))
        let document = Document(
            id: DocumentID("actions"),
            children: [first, divider, parent, blank]
        )

        let context = BlockActionExecution.context(
            in: document,
            selection: [nested.id, divider.id, first.id, blank.id]
        )

        #expect(context.blocks.map(\.id) == [first.id, nested.id])
        #expect(context.blocks.map { String($0.text.characters) } == ["First", "Nested"])
    }

    @Test func fakeAsyncActionAppliesAllReplacementsInOneUndoTransaction() async throws {
        let first = Block.paragraph(text: AttributedString("um first"))
        let second = Block.quote(text: AttributedString("uh second"))
        let document = Document(id: DocumentID("actions"), children: [first, second])
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        document.undoManager = undoManager
        var commits = 0
        document.didCommitTransaction = { _ in commits += 1 }
        let context = BlockActionExecution.context(
            in: document,
            selection: [second.id, first.id]
        )
        let action = EditorBlockAction(
            id: "test.polish",
            title: "Polish",
            systemImage: "wand.and.sparkles",
            isApplicable: { !$0.blocks.isEmpty },
            perform: { context in
                await Task.yield()
                return context.blocks.map { snapshot in
                    let text = String(snapshot.text.characters)
                        .replacingOccurrences(of: "um ", with: "")
                        .replacingOccurrences(of: "uh ", with: "")
                    return BlockReplacement(
                        blockID: snapshot.id,
                        kind: Block(id: snapshot.id, kind: snapshot.kind)
                            .withText(AttributedString(text)).kind
                    )
                }
            }
        )

        #expect(action.isApplicable(to: context))
        let replacements = try await action.perform(in: context)
        undoManager.beginUndoGrouping()
        let applied = BlockActionExecution.apply(
            replacements,
            from: context,
            to: document,
            actionName: action.title
        )
        undoManager.endUndoGrouping()

        #expect(applied == 2)
        #expect(commits == 1)
        #expect(String(document.find(first.id)?.text.characters ?? AttributedString().characters) == "first")
        #expect(String(document.find(second.id)?.text.characters ?? AttributedString().characters) == "second")

        undoManager.undo()
        #expect(String(document.find(first.id)?.text.characters ?? AttributedString().characters) == "um first")
        #expect(String(document.find(second.id)?.text.characters ?? AttributedString().characters) == "uh second")
    }

    @Test func staleAndMissingBlocksAreSkippedWithoutACommit() {
        let block = Block.paragraph(text: AttributedString("Original"))
        let document = Document(id: DocumentID("actions"), children: [block])
        let context = BlockActionExecution.context(in: document, selection: [block.id])
        document.transaction(name: "Newer typing") {
            document.setText(block.id, AttributedString("Newer"))
        }
        var commits = 0
        document.didCommitTransaction = { _ in commits += 1 }

        let applied = BlockActionExecution.apply(
            [BlockReplacement(blockID: block.id, kind: .paragraph(text: AttributedString("Stale")))],
            from: context,
            to: document,
            actionName: "Action"
        )

        #expect(applied == 0)
        #expect(commits == 0)
        #expect(String(document.find(block.id)?.text.characters ?? AttributedString().characters) == "Newer")
    }
}
