import Foundation
import SwiftUI
import Testing
@testable import Quagmire

/// Executable form of the BlockID lifecycle contract documented in
/// `Packages/Quagmire/README.md` and `plans/quagmire-0.1-foundation.md`.
///
/// `BlockID` is *editor* identity, scoped to one live `Document`. It is not
/// storage identity: nothing here promises an id survives a process restart,
/// a second parse of the same file, or two independently opened documents.
/// What it does promise is that within one session every operation either
/// preserves an id deliberately or mints a fresh one deliberately — which is
/// what lets a host key a private source-reuse ledger on these ids.
///
/// One row per contract row. If you change an operation's identity behaviour,
/// the contract table has to change with it.
@MainActor
@Suite("BlockID lifecycle contract")
struct BlockIdentityLifecycleTests {

    // MARK: Helpers

    private static func ids(_ blocks: [Block]) -> [BlockID] {
        var out: [BlockID] = []
        func walk(_ bs: [Block]) {
            for b in bs {
                out.append(b.id)
                walk(b.children)
            }
        }
        walk(blocks)
        return out
    }

    private static func editor(_ doc: Document, _ state: EditorState = EditorState(), host: EditorHost = IdentityTestHost()) -> EditorView {
        let view = EditorView(document: doc, state: state, host: host)
        view.installUndoApply()
        return view
    }

    // MARK: - Row: in-place value edits preserve the id

    @Test func editingTextPreservesID() {
        let block = Block.paragraph(text: AttributedString("before"))
        let doc = Document(id: DocumentID("t"), children: [block])
        doc.transaction(name: "edit") {
            doc.setText(block.id, AttributedString("after"))
        }
        #expect(doc.children.map(\.id) == [block.id])
        #expect(String(doc.children[0].text.characters) == "after")
    }

    @Test func changingKindInPlacePreservesID() {
        let block = Block.paragraph(text: AttributedString("x"))
        let doc = Document(id: DocumentID("t"), children: [block])
        doc.transaction(name: "turn into") {
            doc.mutate(block.id) { $0.kind = .bullet(text: AttributedString("x")) }
        }
        #expect(doc.children.map(\.id) == [block.id])
        #expect(doc.children[0].isListItem)
    }

    @Test func togglingCheckboxPreservesID() {
        let block = Block.todo(text: AttributedString("task"), done: false)
        let doc = Document(id: DocumentID("t"), children: [block])
        doc.transaction(name: "check") {
            doc.mutate(block.id) { $0.kind = .todo(text: AttributedString("task"), done: true) }
        }
        #expect(doc.children.map(\.id) == [block.id])
    }

    // MARK: - Row: moves, reorders, indent/outdent, reparenting preserve every moved id

    @Test func indentPreservesMovedIDs() {
        let anchor = Block.bullet(text: AttributedString("anchor"))
        let moving = Block.bullet(text: AttributedString("moving"), children: [
            .bullet(text: AttributedString("descendant"))
        ])
        let doc = Document(id: DocumentID("t"), children: [anchor, moving])
        let before = Self.ids(doc.children)
        let editor = Self.editor(doc)

        #expect(editor.indentBlocks([moving.id], by: 1))

        #expect(doc.children.map(\.id) == [anchor.id])
        #expect(Set(Self.ids(doc.children)) == Set(before))
    }

    @Test func outdentPreservesMovedIDs() {
        let child = Block.bullet(text: AttributedString("child"))
        let parent = Block.bullet(text: AttributedString("parent"), children: [child])
        let doc = Document(id: DocumentID("t"), children: [parent])
        let before = Set(Self.ids(doc.children))
        let editor = Self.editor(doc)

        #expect(editor.indentBlocks([child.id], by: -1))

        #expect(doc.children.map(\.id) == [parent.id, child.id])
        #expect(Set(Self.ids(doc.children)) == before)
    }

    @Test func reorderPreservesIDs() {
        let a = Block.paragraph(text: AttributedString("a"))
        let b = Block.paragraph(text: AttributedString("b"))
        let doc = Document(id: DocumentID("t"), children: [a, b])
        let editor = Self.editor(doc)

        editor.moveBlocksInDocument([b.id], by: -1)

        #expect(doc.children.map(\.id) == [b.id, a.id])
    }

    @Test func reparentingOntoAContainerPreservesIDs() {
        let container = Block.toggle(title: AttributedString("container"))
        let moving = Block.paragraph(text: AttributedString("moving"))
        let doc = Document(id: DocumentID("t"), children: [container, moving])
        let editor = Self.editor(doc)

        editor.moveBlocks(ids: [moving.id], asChildrenOf: container.id, snapshot: [], hidden: [])

        #expect(doc.children.map(\.id) == [container.id])
        #expect(doc.children[0].children.map(\.id) == [moving.id])
    }

    // MARK: - Row: forward / undo / redo restore the ids of the matching snapshot

    @Test func undoAndRedoRestoreExactIDs() {
        let a = Block.paragraph(text: AttributedString("a"))
        let b = Block.paragraph(text: AttributedString("b"))
        let doc = Document(id: DocumentID("t"), children: [a, b])
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        doc.undoManager = undoManager
        let idsBefore = Self.ids(doc.children)

        doc.transaction(name: "delete") {
            doc.removeSubtree(b.id)
        }
        #expect(doc.children.map(\.id) == [a.id])

        undoManager.undo()
        #expect(Self.ids(doc.children) == idsBefore)

        undoManager.redo()
        #expect(doc.children.map(\.id) == [a.id])

        undoManager.undo()
        #expect(Self.ids(doc.children) == idsBefore)
    }

    @Test func undoOfAMoveRestoresTheSameIDsNotCopies() {
        let a = Block.bullet(text: AttributedString("a"))
        let b = Block.bullet(text: AttributedString("b"))
        let doc = Document(id: DocumentID("t"), children: [a, b])
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        doc.undoManager = undoManager

        doc.transaction(name: "indent") {
            doc.indent(b.id)
        }
        #expect(doc.children[0].children.map(\.id) == [b.id])

        undoManager.undo()
        #expect(doc.children.map(\.id) == [a.id, b.id])
        #expect(doc.children[0].children.isEmpty)
    }

    // MARK: - Row: split — original id stays with the leading row, trailing row is fresh

    @Test func splitKeepsOriginalIDOnTheLeadingRow() {
        let block = Block.paragraph(text: AttributedString("headtail"))
        let doc = Document(id: DocumentID("t"), children: [block])
        let editor = Self.editor(doc)

        #expect(editor.splitBlock(block.id, selectionStart: 4, selectionEnd: 4) == .handled)

        #expect(doc.children.count == 2)
        #expect(doc.children[0].id == block.id)
        #expect(doc.children[1].id != block.id)
        #expect(String(doc.children[0].text.characters) == "head")
        #expect(String(doc.children[1].text.characters) == "tail")
    }

    @Test func splitOverASelectionStillKeepsTheOriginalIDLeading() {
        let block = Block.paragraph(text: AttributedString("headMIDDLEtail"))
        let doc = Document(id: DocumentID("t"), children: [block])
        let editor = Self.editor(doc)

        #expect(editor.splitBlock(block.id, selectionStart: 4, selectionEnd: 10) == .handled)

        #expect(doc.children.count == 2)
        #expect(doc.children[0].id == block.id)
        #expect(doc.children[1].id != block.id)
        #expect(String(doc.children[0].text.characters) == "head")
        #expect(String(doc.children[1].text.characters) == "tail")
    }

    // MARK: - Row: merge — survivor keeps its id, the removed row's id dies

    @Test func mergeKeepsTheSurvivingRowID() {
        let first = Block.paragraph(text: AttributedString("head"))
        let second = Block.paragraph(text: AttributedString("tail"))
        let doc = Document(id: DocumentID("t"), children: [first, second])
        let editor = Self.editor(doc)

        #expect(editor.deleteEmptyBlock(second.id) == .handled)

        #expect(doc.children.map(\.id) == [first.id])
        #expect(String(doc.children[0].text.characters) == "headtail")
        #expect(doc.find(second.id) == nil)
    }

    @Test func deletingAnEmptyRowDropsOnlyThatID() {
        let first = Block.paragraph(text: AttributedString("keep"))
        let empty = Block.paragraph(text: AttributedString(""))
        let doc = Document(id: DocumentID("t"), children: [first, empty])
        let editor = Self.editor(doc)

        #expect(editor.deleteEmptyBlock(empty.id) == .handled)

        #expect(doc.children.map(\.id) == [first.id])
        #expect(doc.find(empty.id) == nil)
    }

    // MARK: - Row: in-place row replacement (mention / Turn Into) keeps the source id

    @Test func lineLeadingMentionKeepsTheSourceRowID() {
        let block = Block.paragraph(text: AttributedString("@que"))
        let doc = Document(id: DocumentID("t"), children: [block])
        let editor = Self.editor(doc)
        let menu = MentionMenuState(
            blockID: block.id,
            trigger: MentionTrigger(nsRange: NSRange(location: 0, length: 4), query: "que"),
            selectedIndex: 0
        )

        editor.commitMention(MentionItem(id: DocumentReference("target.md"), title: "Target"), menu: menu)

        #expect(doc.children.map(\.id) == [block.id])
        if case .documentLink(let label, let reference) = doc.children[0].kind {
            #expect(String(label.characters) == "Target")
            #expect(reference.rawValue == "target.md")
        } else {
            Issue.record("expected a documentLink row, got \(doc.children[0].kind)")
        }
    }

    @Test func mentionWithTrailingTextKeepsSourceIDAndMintsOnlyTheTail() {
        let block = Block.paragraph(text: AttributedString("@que trailing"))
        let doc = Document(id: DocumentID("t"), children: [block])
        let editor = Self.editor(doc)
        let menu = MentionMenuState(
            blockID: block.id,
            trigger: MentionTrigger(nsRange: NSRange(location: 0, length: 4), query: "que"),
            selectedIndex: 0
        )

        editor.commitMention(MentionItem(id: DocumentReference("target.md"), title: "Target"), menu: menu)

        #expect(doc.children.count == 2)
        #expect(doc.children[0].id == block.id)
        #expect(doc.children[1].id != block.id)
    }

    @Test func inlineMentionKeepsTheRowIDAndDoesNotSplit() {
        let block = Block.paragraph(text: AttributedString("see @que"))
        let doc = Document(id: DocumentID("t"), children: [block])
        let editor = Self.editor(doc)
        let menu = MentionMenuState(
            blockID: block.id,
            trigger: MentionTrigger(nsRange: NSRange(location: 4, length: 4), query: "que"),
            selectedIndex: 0
        )

        editor.commitMention(MentionItem(id: DocumentReference("target.md"), title: "Target"), menu: menu)

        #expect(doc.children.map(\.id) == [block.id])
        #expect(String(doc.children[0].text.characters) == "see Target")
    }

    // MARK: - Row: paste / duplicate recursively mint fresh ids

    @Test func pasteRemintsEvenWhenTheHostReturnsIDsAlreadyInTheDocument() {
        let existing = Block.bullet(text: AttributedString("existing"))
        let doc = Document(id: DocumentID("t"), children: [existing])
        let editor = Self.editor(doc)

        // A hostile (or merely careless) host parser: hands back blocks carrying
        // ids that are already live in this document. Hunch's parser mints fresh
        // ids so this cannot happen today, which is exactly why the guarantee has
        // to live at the receiving boundary rather than in the host.
        // A bullet rather than a paragraph so the nesting survives
        // `liftLeafOrphans` — a leaf kind cannot keep children.
        let colliding = [
            Block(id: existing.id, kind: .bullet(text: AttributedString("pasted")), children: [
                Block(id: existing.id, kind: .bullet(text: AttributedString("nested")))
            ])
        ]

        #expect(editor.spliceParsedBlocksAfter(existing.id, parsed: colliding, focusLast: false))

        let all = Self.ids(doc.children)
        #expect(all.count == Set(all).count, "paste must not introduce duplicate BlockIDs")
        #expect(doc.children.count == 2)
        #expect(doc.children[1].id != existing.id)
        #expect(doc.children[1].children[0].id != existing.id)
    }

    @Test func pasteRemintsDistinctlyForEachSubtreeNode() {
        let anchor = Block.paragraph(text: AttributedString("anchor"))
        let doc = Document(id: DocumentID("t"), children: [anchor])
        let editor = Self.editor(doc)

        let shared = BlockID()
        let parsed = [
            Block(id: shared, kind: .bullet(text: AttributedString("one"))),
            Block(id: shared, kind: .bullet(text: AttributedString("two")))
        ]

        #expect(editor.spliceParsedBlocksAfter(anchor.id, parsed: parsed, focusLast: false))

        let pastedIDs = doc.children.dropFirst().map(\.id)
        #expect(pastedIDs.count == 2)
        #expect(pastedIDs[0] != pastedIDs[1])
        #expect(!pastedIDs.contains(shared))
    }

    @Test func withFreshIDsRemintsRecursively() {
        let original = Block.bullet(text: AttributedString("root"), children: [
            .bullet(text: AttributedString("child"), children: [
                .bullet(text: AttributedString("grandchild"))
            ])
        ])
        let copy = original.withFreshIDs()

        let originalIDs = Set(Self.ids([original]))
        let copyIDs = Set(Self.ids([copy]))

        #expect(originalIDs.count == 3)
        #expect(copyIDs.count == 3)
        #expect(originalIDs.isDisjoint(with: copyIDs))
        #expect(copy.kind == original.kind)
    }

    // MARK: - Row: cross-document inline of loaded blocks gets fresh ids

    @Test func inliningALoadedDocumentRemintsTheLoadedBlocks() async {
        let sharedID = BlockID()
        let host = IdentityTestHost()
        // The host returns blocks whose ids collide with the row being replaced
        // *and* with each other — the worst case a third-party parser can hand us.
        host.loadedBlocks = [
            Block(id: sharedID, kind: .paragraph(text: AttributedString("loaded one"))),
            Block(id: sharedID, kind: .paragraph(text: AttributedString("loaded two")))
        ]

        let link = Block.documentLink(label: AttributedString("Target"), reference: DocumentReference("target.md"))
        let doc = Document(id: DocumentID("t"), children: [link])
        let editor = Self.editor(doc, host: host)

        #expect(editor.convertDocumentLink(blockID: link.id, to: .toggle) == .handled)
        await host.awaitInlineCompletion()

        let all = Self.ids(doc.children)
        #expect(all.count == Set(all).count, "inline must not introduce duplicate BlockIDs")
        #expect(doc.children.count == 1)
        #expect(doc.children[0].id == link.id, "the converted row keeps the source id")
        let loadedIDs = doc.children[0].children.map(\.id)
        #expect(loadedIDs.count == 2)
        #expect(loadedIDs[0] != loadedIDs[1])
        #expect(!loadedIDs.contains(sharedID))
        #expect(!loadedIDs.contains(link.id))
    }

    // MARK: - Row: unreconciled system replacement

    @Test func systemReplacementTakesHostSuppliedIDsAndClearsUndo() {
        let original = Block.paragraph(text: AttributedString("original"))
        let doc = Document(id: DocumentID("t"), children: [original])
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        doc.undoManager = undoManager

        doc.transaction(name: "edit") {
            doc.setText(original.id, AttributedString("edited"))
        }
        #expect(undoManager.canUndo)

        let replacement = Block.paragraph(text: AttributedString("from disk"))
        doc.replaceChildrenFromExternalReload([replacement])

        #expect(doc.children.map(\.id) == [replacement.id])
        #expect(doc.find(original.id) == nil)
        #expect(!undoManager.canUndo, "an external reload must not leave an undo entry that would erase it")
    }

    @Test func systemReplacementDoesNoSourceMatching() {
        // Same content, different id: Quagmire does not try to recognise it.
        // Reconciling ids is the host's job, not the editor's.
        let original = Block.paragraph(text: AttributedString("same text"))
        let doc = Document(id: DocumentID("t"), children: [original])
        let reparsed = Block.paragraph(text: AttributedString("same text"))

        doc.replaceChildrenFromExternalReload([reparsed])

        #expect(doc.children.map(\.id) == [reparsed.id])
        #expect(doc.children[0].id != original.id)
    }

    @Test func systemReplacementEmitsNoAuthoredCommit() {
        let doc = Document(id: DocumentID("t"), children: [.paragraph(text: AttributedString("a"))])
        var commits: [[DocumentChange]] = []
        doc.didCommitTransaction = { commits.append($0) }

        doc.replaceChildrenFromSystemMutation([.paragraph(text: AttributedString("b"))])

        #expect(commits.isEmpty, "a system replacement is not an authored edit")
    }
}

// MARK: - Test host

@MainActor
private final class IdentityTestHost: EditorHost {
    var loadedBlocks: [Block] = []
    private var inlineFinished: CheckedContinuation<Void, Never>?
    private var inlineAlreadyFinished = false

    var supportsDocumentCreation: Bool { true }
    var supportsDocumentInlining: Bool { true }
    var supportsMoveDestinationPicker: Bool { true }

    func lookupDocument(_ reference: DocumentReference) -> DocumentLookup { .present(title: nil) }
    func linkURL(for reference: DocumentReference, in document: Document) -> URL? { URL(string: reference.rawValue) }
    func loadDocumentBlocks(_ reference: DocumentReference) async -> [Block]? { loadedBlocks }

    func inlineAndRetireDocument(_ reference: DocumentReference, parent: Document) async -> Bool {
        if let continuation = inlineFinished {
            inlineFinished = nil
            continuation.resume()
        } else {
            inlineAlreadyFinished = true
        }
        return true
    }

    func persistCommit(changes: [DocumentChange], in document: Document) {}
    func flush(_ document: Document) async {}

    /// The inline flow runs inside a detached `Task`; wait for it to reach its
    /// final host call rather than yielding a guessed number of times.
    func awaitInlineCompletion() async {
        if inlineAlreadyFinished {
            inlineAlreadyFinished = false
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            inlineFinished = continuation
        }
    }
}
