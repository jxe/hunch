import Testing
import Foundation
@testable import Editor

/// Covers the unified mutation/undo entry point `Document.transaction`,
/// including coalescing via `coalesceKey` and the `preMutation` /
/// `didCommitTransaction` hooks.
@MainActor
@Suite("Document.transaction — mutations, undo, coalescing")
struct DocumentTransactionTests {
    private func makeDoc() -> Document {
        Document(
            id: DocumentID("test"),
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

    @Test func documentIdentityAndFallbackTitleDoNotRequireStorage() {
        let document = Document(
            id: DocumentID("remote-document-42"),
            children: [],
            fallbackTitle: "Remote note"
        )

        #expect(document.id == DocumentID("remote-document-42"))
        #expect(document.title == "Remote note")

        let untitled = Document(id: DocumentID("memory-only"), children: [])
        #expect(untitled.title == "Untitled")
    }

    /// Run one transaction as its own undo group, so `mgr.undo()` pops exactly
    /// that group's registered entry.
    private func tx(
        _ doc: Document,
        _ mgr: UndoManager,
        name: String,
        coalesceKey: AnyHashable? = nil,
        _ change: () -> Void
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

        tx(doc, mgr, name: "Edit 1") { doc.setText(id, AttributedString("one")) }
        tx(doc, mgr, name: "Edit 2") { doc.setText(id, AttributedString("two")) }

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
        doc.transaction(name: "Type", coalesceKey: id) { doc.setText(id, AttributedString("a")) }
        doc.transaction(name: "Type", coalesceKey: id) { doc.setText(id, AttributedString("ab")) }
        doc.transaction(name: "Type", coalesceKey: id) { doc.setText(id, AttributedString("abc")) }
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
        doc.transaction(name: "Type", coalesceKey: id) { doc.setText(id, AttributedString("a")) }
        doc.transaction(name: "Type", coalesceKey: id) { doc.setText(id, AttributedString("ab")) }
        doc.transaction(name: "Type", coalesceKey: id) { doc.setText(id, AttributedString("abc")) }
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

        tx(doc, mgr, name: "Type", coalesceKey: firstID) { doc.setText(firstID, AttributedString("aa")) }
        tx(doc, mgr, name: "Type", coalesceKey: secondID) { doc.setText(secondID, AttributedString("bb")) }

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

        tx(doc, mgr, name: "Type", coalesceKey: id) { doc.setText(id, AttributedString("a")) }
        doc.breakCoalescing()
        tx(doc, mgr, name: "Type", coalesceKey: id) { doc.setText(id, AttributedString("ab")) }

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
        doc.transaction(name: "Type", coalesceKey: id) { doc.setText(id, AttributedString("a")) }
        doc.transaction(name: "Type", coalesceKey: id) { doc.setText(id, AttributedString("ab")) }
        mgr.endUndoGrouping()

        // Structural — own group.
        tx(doc, mgr, name: "Insert") {
            doc.children.append(.paragraph(text: AttributedString("charlie")))
        }

        #expect(doc.children.count == 3)
        mgr.undo() // undoes Insert
        #expect(doc.children.count == 2)
        mgr.undo() // undoes the burst
        #expect(plainText(doc.children[0]) == "alpha")
    }

    @Test func transactionFiresPreMutationBeforeChange() {
        let doc = makeDoc()
        var preFiredAt: Int? = nil
        var changeFiredAt: Int? = nil
        var tick = 0
        doc.preMutation = { tick += 1; preFiredAt = tick }
        doc.transaction(name: "x") { tick += 1; changeFiredAt = tick }

        #expect(preFiredAt == 1)
        #expect(changeFiredAt == 2)
    }

    @Test func didCommitTransactionFiresOnForwardUndoAndRedo() {
        // The unified commit hook fires on every transaction direction:
        // forward (the original mutation), undo (the inverse), redo (the
        // re-forward). One hook, three firings for the round-trip.
        let (doc, mgr) = makeDocWithUndo()
        let id = doc.children[0].id
        var fires = 0
        doc.didCommitTransaction = { _ in fires += 1 }

        tx(doc, mgr, name: "Edit") { doc.setText(id, AttributedString("xx")) }
        #expect(fires == 1, "forward fires once")

        mgr.undo()
        #expect(fires == 2, "undo fires again")

        mgr.redo()
        #expect(fires == 3, "redo fires again")
    }

    @Test func externalReloadInvalidatesWholeTreeUndoSnapshots() {
        let (doc, mgr) = makeDocWithUndo()
        let id = doc.children[0].id

        tx(doc, mgr, name: "Local edit") {
            doc.setText(id, AttributedString("locally edited"))
        }
        #expect(mgr.canUndo)

        let foreign = Block.paragraph(text: AttributedString("arrived elsewhere"))
        doc.replaceChildrenFromExternalReload([foreign])

        var emitted: [DocumentChange] = []
        doc.didCommitTransaction = { emitted = $0 }
        #expect(!mgr.canUndo, "an external tree replacement makes older whole-tree snapshots stale")
        mgr.undo()
        #expect(doc.children == [foreign])
        #expect(emitted.isEmpty, "stale undo must not report externally-arrived blocks as user removals")
    }

    @Test func transactionReturnsForwardDiff() {
        // The forward transaction returns semantic pre→post snapshots.
        let doc = makeDoc()
        let id = doc.children[0].id
        let before = doc.children[0]
        let changes = doc.transaction(name: "Edit") {
            doc.setText(id, AttributedString("changed"))
        }
        let after = doc.children[0]
        #expect(changes == [.removed(block: before), .inserted(block: after, parent: nil)])
    }

    @Test func undoFiresInvertedDiffThroughDidCommitTransaction() {
        // Undo and redo invert the semantic before/after snapshots.
        let (doc, mgr) = makeDocWithUndo()
        let id = doc.children[0].id
        let before = doc.children[0]
        var captured: [DocumentChange] = []
        doc.didCommitTransaction = { captured = $0 }

        tx(doc, mgr, name: "Edit") { doc.setText(id, AttributedString("changed")) }
        let after = doc.children[0]

        mgr.undo()
        #expect(captured == [.removed(block: after), .inserted(block: before, parent: nil)])

        mgr.redo()
        #expect(captured == [.removed(block: before), .inserted(block: after, parent: nil)])
    }

    @Test func nestedTransactionReturnsEmptyDiff() {
        // Nested transactions (typically from `preMutation` → typing flush)
        // absorb into the outer; their own return value is empty so callers
        // don't double-emit. The outer's snapshot captures the inner's
        // change as part of its single pre→post diff.
        let doc = makeDoc()
        let id = doc.children[0].id
        var innerChanges: [DocumentChange] = []
        doc.preMutation = {
            innerChanges = doc.transaction(name: "Inner", coalesceKey: id) {
                doc.setText(id, AttributedString("inner"))
            }
        }
        let outerChanges = doc.transaction(name: "Outer") {
            doc.setText(id, AttributedString("outer"))
        }
        #expect(innerChanges.isEmpty, "nested transaction returns no changes")
        #expect(!outerChanges.isEmpty, "outer captures the full change (typing flush + outer edit)")
    }

    @Test func transactionEnforcesHeadingContainment() {
        // A heading followed by a sibling paragraph at root should re-fold
        // the paragraph into the heading's children after a transaction.
        let doc = Document(
            id: DocumentID("h"),
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
        doc.transaction(name: "no-op") {
            doc.setText(doc.children[0].id, AttributedString("Title"))
        }
        #expect(doc.children.count == originalCount)
    }

    @Test func nestedTransactionCollapsesIntoOuter() {
        // Reproduces the typing-path-during-autotransform crash scenario, but
        // now asserts the production contract that prevents it: a nested
        // `transaction` call (typically from inside `preMutation` — e.g.
        // BlockTextEditor's typing path opens its own transaction to flush
        // live text) collapses into the outer. The inner runs its `change`
        // closure, does NOT re-fire `preMutation`, and does NOT register its
        // own undo entry. The outer's snapshot captures the post-inner state,
        // so undo reverses both as one atomic action.
        let (doc, mgr) = makeDocWithUndo()
        let id = doc.children[0].id

        var preMutationFires = 0
        doc.preMutation = {
            preMutationFires += 1
            // Open a nested transaction (typing path's typical shape).
            doc.transaction(name: "Inner", coalesceKey: id) {
                doc.setText(id, AttributedString("inner"))
            }
        }

        tx(doc, mgr, name: "Outer") {
            // Outer change runs AFTER preMutation (which fired inner first).
            // Append a paragraph rather than overwrite, so we can verify both
            // changes survive into the outer's undo entry.
            doc.children.append(.paragraph(text: AttributedString("outer-added")))
        }

        // preMutation fires exactly once — only for the outer.
        #expect(preMutationFires == 1)
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

        doc.transaction(name: "Edit") { doc.setText(id, AttributedString("zzz")) }
        #expect(plainText(doc.children[0]) == "zzz")
    }
}
