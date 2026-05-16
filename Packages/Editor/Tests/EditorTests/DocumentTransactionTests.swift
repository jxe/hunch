import Testing
import Foundation
@testable import Editor

/// Covers the unified mutation/undo entry point `Document.transaction`,
/// including coalescing via `coalesceKey` and the `preMutation` / `willMutate` /
/// `didApplyUndo` hooks.
@MainActor
@Suite("Document.transaction — mutations, undo, coalescing")
struct DocumentTransactionTests {
    private func makeDoc() -> Document {
        Document(
            url: URL(fileURLWithPath: "/tmp/test.md"),
            title: "Test",
            children: [
                .paragraph(text: AttributedString("alpha")),
                .paragraph(text: AttributedString("bravo"))
            ]
        )
    }

    private func makeDocWithUndo() -> (Document, UndoManager) {
        let doc = makeDoc()
        let mgr = UndoManager()
        mgr.levelsOfUndo = 100
        // Disable auto-grouping so each `tx(...)` call below explicitly bounds
        // its own undo action. Production keeps the default (groups-by-event)
        // since real user actions span run-loop iterations, but tests fire
        // multiple actions synchronously without an event boundary.
        mgr.groupsByEvent = false
        doc.undoManager = mgr
        return (doc, mgr)
    }

    /// Run one transaction as its own undo group, so `mgr.undo()` pops exactly
    /// that group's registered entry.
    private func tx(
        _ doc: Document,
        _ mgr: UndoManager,
        name: String,
        coalesceKey: AnyHashable? = nil,
        _ change: (Document) -> Void
    ) {
        mgr.beginUndoGrouping()
        doc.transaction(name: name, coalesceKey: coalesceKey, change)
        mgr.endUndoGrouping()
    }

    private func plainText(_ block: Block) -> String {
        switch block.kind {
        case .paragraph(let t), .heading(_, let t), .bullet(let t), .numbered(let t),
             .todo(let t, _), .quote(let t), .toggle(let t):
            return String(t.characters)
        case .code(let src, _):
            return src
        default:
            return ""
        }
    }

    @Test func transactionWithoutCoalesceKeyRegistersOneEntryPerCall() {
        let (doc, mgr) = makeDocWithUndo()
        let id = doc.children[0].id

        tx(doc, mgr, name: "Edit 1") { d in d.setText(id, AttributedString("one")) }
        tx(doc, mgr, name: "Edit 2") { d in d.setText(id, AttributedString("two")) }

        #expect(plainText(doc.children[0]) == "two")
        mgr.undo()
        #expect(plainText(doc.children[0]) == "one")
        mgr.undo()
        #expect(plainText(doc.children[0]) == "alpha")
    }

    @Test func coalesceWithinWindowFoldsIntoOneEntry() {
        let (doc, mgr) = makeDocWithUndo()
        let id = doc.children[0].id

        // Coalescing inside Document.transaction is what matters here, not
        // UndoManager grouping — share one group so that the second/third
        // transactions can't accidentally land in their own.
        mgr.beginUndoGrouping()
        doc.transaction(name: "Type", coalesceKey: id) { d in d.setText(id, AttributedString("a")) }
        doc.transaction(name: "Type", coalesceKey: id) { d in d.setText(id, AttributedString("ab")) }
        doc.transaction(name: "Type", coalesceKey: id) { d in d.setText(id, AttributedString("abc")) }
        mgr.endUndoGrouping()

        #expect(plainText(doc.children[0]) == "abc")
        mgr.undo()
        // One undo returns to the burst's start — the very first snapshot.
        #expect(plainText(doc.children[0]) == "alpha")
    }

    @Test func redoAfterCoalescedBurstAppliesBurstEndState() {
        let (doc, mgr) = makeDocWithUndo()
        let id = doc.children[0].id

        mgr.beginUndoGrouping()
        doc.transaction(name: "Type", coalesceKey: id) { d in d.setText(id, AttributedString("a")) }
        doc.transaction(name: "Type", coalesceKey: id) { d in d.setText(id, AttributedString("ab")) }
        doc.transaction(name: "Type", coalesceKey: id) { d in d.setText(id, AttributedString("abc")) }
        mgr.endUndoGrouping()

        mgr.undo()
        #expect(plainText(doc.children[0]) == "alpha")
        mgr.redo()
        #expect(plainText(doc.children[0]) == "abc")
    }

    @Test func differentCoalesceKeysBreakCoalescing() {
        let (doc, mgr) = makeDocWithUndo()
        let firstID = doc.children[0].id
        let secondID = doc.children[1].id

        tx(doc, mgr, name: "Type", coalesceKey: firstID) { d in d.setText(firstID, AttributedString("aa")) }
        tx(doc, mgr, name: "Type", coalesceKey: secondID) { d in d.setText(secondID, AttributedString("bb")) }

        #expect(plainText(doc.children[0]) == "aa")
        #expect(plainText(doc.children[1]) == "bb")

        mgr.undo() // undoes the second-block edit
        #expect(plainText(doc.children[0]) == "aa")
        #expect(plainText(doc.children[1]) == "bravo")

        mgr.undo() // undoes the first-block edit
        #expect(plainText(doc.children[0]) == "alpha")
    }

    @Test func breakCoalescingForcesFreshEntry() {
        let (doc, mgr) = makeDocWithUndo()
        let id = doc.children[0].id

        tx(doc, mgr, name: "Type", coalesceKey: id) { d in d.setText(id, AttributedString("a")) }
        doc.breakCoalescing()
        tx(doc, mgr, name: "Type", coalesceKey: id) { d in d.setText(id, AttributedString("ab")) }

        mgr.undo()
        #expect(plainText(doc.children[0]) == "a")
        mgr.undo()
        #expect(plainText(doc.children[0]) == "alpha")
    }

    @Test func structuralTransactionRegistersFreshEntryRegardlessOfPriorCoalesceKey() {
        let (doc, mgr) = makeDocWithUndo()
        let id = doc.children[0].id

        // Burst (one group). Two coalesce-key transactions register one entry.
        mgr.beginUndoGrouping()
        doc.transaction(name: "Type", coalesceKey: id) { d in d.setText(id, AttributedString("a")) }
        doc.transaction(name: "Type", coalesceKey: id) { d in d.setText(id, AttributedString("ab")) }
        mgr.endUndoGrouping()

        // Structural — own group.
        tx(doc, mgr, name: "Insert") { d in
            d.children.append(.paragraph(text: AttributedString("charlie")))
        }

        #expect(doc.children.count == 3)
        mgr.undo() // undoes Insert
        #expect(doc.children.count == 2)
        mgr.undo() // undoes the burst
        #expect(plainText(doc.children[0]) == "alpha")
    }

    @Test func transactionFiresPreMutationAndWillMutateBeforeChange() {
        let doc = makeDoc()
        var preFiredAt: Int? = nil
        var willFiredAt: Int? = nil
        var changeFiredAt: Int? = nil
        var tick = 0
        doc.preMutation = { tick += 1; preFiredAt = tick }
        doc.willMutate = { _ in tick += 1; willFiredAt = tick }
        doc.transaction(name: "x") { _ in tick += 1; changeFiredAt = tick }

        #expect(preFiredAt == 1)
        #expect(willFiredAt == 2)
        #expect(changeFiredAt == 3)
    }

    @Test func didApplyUndoFiresOnUndoAndRedo() {
        let (doc, mgr) = makeDocWithUndo()
        let id = doc.children[0].id
        var applyFires = 0
        doc.didApplyUndo = { applyFires += 1 }

        tx(doc, mgr, name: "Edit") { d in d.setText(id, AttributedString("xx")) }
        #expect(applyFires == 0) // Doesn't fire on direct mutation.

        mgr.undo()
        #expect(applyFires == 1)

        mgr.redo()
        #expect(applyFires == 2)
    }

    @Test func transactionEnforcesHeadingContainment() {
        // A heading followed by a sibling paragraph at root should re-fold
        // the paragraph into the heading's children after a transaction.
        let doc = Document(
            url: URL(fileURLWithPath: "/tmp/h.md"),
            title: "H",
            children: [
                .heading(level: .h1, text: AttributedString("Title")),
                .paragraph(text: AttributedString("body"))
            ]
        )
        // The constructor's initial state may or may not already be folded;
        // calling enforce directly normalises before we exercise.
        doc.enforceHeadingContainment()
        let originalCount = doc.children.count

        // A no-op-ish edit triggers enforce again. Should not double-fold.
        doc.transaction(name: "no-op") { d in
            d.setText(d.children[0].id, AttributedString("Title"))
        }
        #expect(doc.children.count == originalCount)
    }

    @Test func nestedTransactionCollapsesIntoOuter() {
        // Reproduces the typing-path-during-autotransform crash scenario, but
        // now asserts the production contract that prevents it: a nested
        // `transaction` call (typically from inside `preMutation` — e.g.
        // BlockTextEditor's typing path opens its own transaction to flush
        // live text) collapses into the outer. The inner runs its `change`
        // closure, does NOT re-fire `preMutation`/`willMutate`, and does NOT
        // register its own undo entry. The outer's snapshot captures the
        // post-inner state, so undo reverses both as one atomic action.
        let (doc, mgr) = makeDocWithUndo()
        let id = doc.children[0].id

        var preMutationFires = 0
        var willMutateFires = 0
        doc.preMutation = {
            preMutationFires += 1
            // Open a nested transaction (typing path's typical shape).
            doc.transaction(name: "Inner", coalesceKey: id) { d in
                d.setText(id, AttributedString("inner"))
            }
        }
        doc.willMutate = { _ in willMutateFires += 1 }

        tx(doc, mgr, name: "Outer") { d in
            // Outer change runs AFTER preMutation (which fired inner first).
            // Append a paragraph rather than overwrite, so we can verify both
            // changes survive into the outer's undo entry.
            d.children.append(.paragraph(text: AttributedString("outer-added")))
        }

        // preMutation/willMutate fire exactly once — only for the outer.
        #expect(preMutationFires == 1)
        #expect(willMutateFires == 1)
        // Both the inner and outer changes are visible after the transaction.
        #expect(plainText(doc.children[0]) == "inner")
        #expect(doc.children.count == 3)
        #expect(plainText(doc.children.last!) == "outer-added")

        // ONE undo entry covers both changes (collapsed). Cmd-Z reverts
        // everything back to the pre-outer state in one step.
        mgr.undo()
        #expect(plainText(doc.children[0]) == "alpha")
        #expect(doc.children.count == 2)
    }

    @Test func undoWithoutManagerStillApplies() {
        // No UndoManager wired — transaction should still mutate; just no
        // undo history accumulates.
        let doc = makeDoc()
        let id = doc.children[0].id

        doc.transaction(name: "Edit") { d in d.setText(id, AttributedString("zzz")) }
        #expect(plainText(doc.children[0]) == "zzz")
    }
}
