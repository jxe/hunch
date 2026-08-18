import Foundation
import Testing
@testable import Quagmire

/// The two system-replacement rows of the BlockID lifecycle contract.
///
/// A host replaces a document's tree for two quite different reasons, and the
/// editor has to tell them apart. A fresh parse (external edit, conflict merge)
/// invalidates everything. A splice into the open tree (another window
/// appending, a peer's journal restoring a subtree, a backend returning a
/// completed document on save) does not — and treating it as if it did is what
/// makes the undo stack evaporate during ordinary use.
@MainActor
@Suite("System replacement")
struct SystemReplacementTests {

    private static func undoableDocument(_ children: [Block]) -> (Document, UndoManager) {
        let doc = Document(id: DocumentID("t"), children: children)
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        doc.undoManager = undoManager
        return (doc, undoManager)
    }

    // MARK: - Appending to an open document

    @Test func appendKeepsUndoAndDoesNotEraseTheAppendedBlock() {
        let a = Block.paragraph(text: AttributedString("a"))
        let (doc, undoManager) = Self.undoableDocument([a])

        doc.transaction(name: "edit") {
            doc.setText(a.id, AttributedString("edited"))
        }
        #expect(undoManager.canUndo)

        // Another window appends. Every existing id survives.
        let appended = Block.paragraph(text: AttributedString("from elsewhere"))
        #expect(doc.replaceChildrenReconciled(doc.children + [appended]) == .reconciled)
        #expect(doc.children.map(\.id) == [a.id, appended.id])
        #expect(undoManager.canUndo, "a peer's append must not cost the user their undo history")

        undoManager.undo()

        #expect(String(doc.children[0].text.characters) == "a", "undo restores the user's edit")
        #expect(doc.children.map(\.id) == [a.id, appended.id], "undo must not erase the appended block")
    }

    @Test func redoAfterAnAppendAlsoKeepsTheAppendedBlock() {
        let a = Block.paragraph(text: AttributedString("a"))
        let (doc, undoManager) = Self.undoableDocument([a])

        doc.transaction(name: "edit") {
            doc.setText(a.id, AttributedString("edited"))
        }
        let appended = Block.paragraph(text: AttributedString("from elsewhere"))
        doc.replaceChildrenReconciled(doc.children + [appended])

        undoManager.undo()
        undoManager.redo()

        #expect(String(doc.children[0].text.characters) == "edited")
        #expect(doc.children.map(\.id) == [a.id, appended.id])
    }

    @Test func severalAppendsAllSurviveUndo() {
        let a = Block.paragraph(text: AttributedString("a"))
        let (doc, undoManager) = Self.undoableDocument([a])

        doc.transaction(name: "edit") {
            doc.setText(a.id, AttributedString("edited"))
        }
        let first = Block.paragraph(text: AttributedString("first"))
        let second = Block.paragraph(text: AttributedString("second"))
        doc.replaceChildrenReconciled(doc.children + [first])
        doc.replaceChildrenReconciled(doc.children + [second])

        undoManager.undo()

        #expect(doc.children.map(\.id) == [a.id, first.id, second.id])
        #expect(String(doc.children[0].text.characters) == "a")
    }

    // MARK: - Restoring a subtree mid-document

    @Test func aRestoredSubtreeSurvivesUndoAtItsOriginalPosition() {
        let a = Block.paragraph(text: AttributedString("a"))
        let c = Block.paragraph(text: AttributedString("c"))
        let (doc, undoManager) = Self.undoableDocument([a, c])

        doc.transaction(name: "edit") {
            doc.setText(c.id, AttributedString("c edited"))
        }

        // A peer's journal restores a block that belongs between a and c.
        let restored = Block.paragraph(text: AttributedString("b"))
        #expect(doc.replaceChildrenReconciled([a, restored, c]) == .reconciled)

        undoManager.undo()

        #expect(doc.children.map(\.id) == [a.id, restored.id, c.id])
        #expect(String(doc.children[2].text.characters) == "c")
    }

    @Test func aRestoredChildSurvivesUndo() {
        let child = Block.bullet(text: AttributedString("child"))
        let parent = Block.bullet(text: AttributedString("parent"), children: [child])
        let (doc, undoManager) = Self.undoableDocument([parent])

        doc.transaction(name: "edit") {
            doc.setText(child.id, AttributedString("child edited"))
        }

        let sibling = Block.bullet(text: AttributedString("restored"))
        let updated = [parent.withChildren([child, sibling])]
        #expect(doc.replaceChildrenReconciled(updated) == .reconciled)

        undoManager.undo()

        #expect(doc.children[0].children.map(\.id) == [child.id, sibling.id])
        #expect(String(doc.children[0].children[0].text.characters) == "child")
    }

    // MARK: - System removals and in-place value changes

    @Test func aSystemRemovalIsNotResurrectedByUndo() {
        let a = Block.paragraph(text: AttributedString("a"))
        let b = Block.paragraph(text: AttributedString("b"))
        let (doc, undoManager) = Self.undoableDocument([a, b])

        doc.transaction(name: "edit") {
            doc.setText(a.id, AttributedString("edited"))
        }
        // A peer purged b. Undoing the local edit should not bring it back —
        // the removal was not the user's to undo.
        #expect(doc.replaceChildrenReconciled([doc.children[0]]) == .reconciled)

        undoManager.undo()

        #expect(doc.children.map(\.id) == [a.id])
        #expect(doc.find(b.id) == nil)
    }

    @Test func aSystemValueChangeSurvivesUndoOfAnUnrelatedEdit() {
        // Shaped the way heading containment leaves it: the body is the H1's
        // child, not its sibling.
        let body = Block.paragraph(text: AttributedString("body"))
        let title = Block.heading(level: .h1, text: AttributedString("Page"), children: [body])
        let (doc, undoManager) = Self.undoableDocument([title])

        doc.transaction(name: "edit") {
            doc.setText(body.id, AttributedString("body edited"))
        }
        // setIcon rewrites the H1's text in place.
        var iconised = doc.children
        iconised[0].kind = .heading(level: .h1, text: AttributedString("📄 Page"))
        #expect(doc.replaceChildrenReconciled(iconised) == .reconciled)

        undoManager.undo()

        #expect(String(doc.children[0].text.characters) == "📄 Page", "the icon must not be undone by an unrelated edit")
        #expect(String(doc.children[0].children[0].text.characters) == "body")
    }

    // MARK: - Degrading honestly

    @Test func reparentingIsNotRebasableAndFallsBackToWholesale() {
        let a = Block.paragraph(text: AttributedString("a"))
        let (doc, undoManager) = Self.undoableDocument([a])

        doc.transaction(name: "edit") {
            doc.setText(a.id, AttributedString("edited"))
        }
        #expect(undoManager.canUndo)

        // setIcon's no-H1 branch: wrap the whole body under a new heading.
        let wrapper = Block.heading(level: .h1, text: AttributedString("Page"), children: doc.children)
        #expect(doc.replaceChildrenReconciled([wrapper]) == .wholesale)
        #expect(!undoManager.canUndo)
        #expect(doc.children.map(\.id) == [wrapper.id])
    }

    @Test func aFreshParseIsWholesaleAndClearsUndo() {
        let a = Block.paragraph(text: AttributedString("a"))
        let (doc, undoManager) = Self.undoableDocument([a])

        doc.transaction(name: "edit") {
            doc.setText(a.id, AttributedString("edited"))
        }
        doc.replaceChildrenFromExternalReload([.paragraph(text: AttributedString("from disk"))])

        #expect(!undoManager.canUndo)
        #expect(doc.find(a.id) == nil)
    }

    // MARK: - What the editor is told

    @Test func replacementKindIsReportedToTheEditor() {
        let a = Block.paragraph(text: AttributedString("a"))
        let doc = Document(id: DocumentID("t"), children: [a])
        var reported: [DocumentReplacement] = []
        doc.didReplaceChildren = { reported.append($0) }

        doc.replaceChildrenReconciled(doc.children + [.paragraph(text: AttributedString("b"))])
        doc.replaceChildrenFromExternalReload([.paragraph(text: AttributedString("c"))])

        #expect(reported == [.reconciled, .wholesale])
    }

    @Test func reconciledReplacementEmitsNoAuthoredCommit() {
        let doc = Document(id: DocumentID("t"), children: [.paragraph(text: AttributedString("a"))])
        var commits: [[DocumentChange]] = []
        doc.didCommitTransaction = { commits.append($0) }

        doc.replaceChildrenReconciled(doc.children + [.paragraph(text: AttributedString("b"))])

        #expect(commits.isEmpty, "a system splice is not an authored edit")
    }

    @Test func aNoOpReconciliationIsStillReconciled() {
        let doc = Document(id: DocumentID("t"), children: [.paragraph(text: AttributedString("a"))])
        #expect(doc.replaceChildrenReconciled(doc.children) == .reconciled)
    }

    // MARK: - The snapshot registry does not leak

    @Test func snapshotsAreReleasedWithTheirUndoEntries() {
        let a = Block.paragraph(text: AttributedString("a"))
        let (doc, undoManager) = Self.undoableDocument([a])

        doc.transaction(name: "edit") {
            doc.setText(a.id, AttributedString("edited"))
        }
        #expect(doc.outstandingUndoSnapshotCount == 1)

        undoManager.removeAllActions()
        // The registry prunes lazily, on the next registration.
        doc.transaction(name: "edit again") {
            doc.setText(a.id, AttributedString("again"))
        }
        #expect(doc.outstandingUndoSnapshotCount == 1)
    }
}

/// Unit coverage for the rebase itself, independent of `Document`.
@MainActor
@Suite("SystemDelta")
struct SystemDeltaTests {

    @Test func insertionAtRootEndIsRebasable() {
        let a = Block.paragraph(text: AttributedString("a"))
        let b = Block.paragraph(text: AttributedString("b"))
        let delta = SystemDelta(from: [a], to: [a, b])
        #expect(delta != nil)
        #expect(delta?.rebase([a]).map(\.id) == [a.id, b.id])
    }

    @Test func insertionIntoASnapshotThatLacksThePrecedingSiblingAppends() {
        let a = Block.paragraph(text: AttributedString("a"))
        let b = Block.paragraph(text: AttributedString("b"))
        let c = Block.paragraph(text: AttributedString("c"))
        let delta = SystemDelta(from: [a, b], to: [a, b, c])
        // The snapshot predates b entirely.
        #expect(delta?.rebase([a]).map(\.id) == [a.id, c.id])
    }

    @Test func insertionWhoseParentIsAbsentFromTheSnapshotIsSkipped() {
        let child = Block.bullet(text: AttributedString("child"))
        let parent = Block.bullet(text: AttributedString("parent"), children: [child])
        let other = Block.paragraph(text: AttributedString("other"))
        let newChild = Block.bullet(text: AttributedString("new"))

        let delta = SystemDelta(from: [parent, other], to: [parent.withChildren([child, newChild]), other])
        #expect(delta != nil)
        // A snapshot from before `parent` existed has nowhere to put the child.
        #expect(delta?.rebase([other]).map(\.id) == [other.id])
    }

    @Test func alreadyPresentInsertionIsNotDuplicated() {
        let a = Block.paragraph(text: AttributedString("a"))
        let b = Block.paragraph(text: AttributedString("b"))
        let delta = SystemDelta(from: [a], to: [a, b])
        #expect(delta?.rebase([a, b]).map(\.id) == [a.id, b.id])
    }

    @Test func reparentingAnExistingBlockIsRejected() {
        let moving = Block.bullet(text: AttributedString("moving"))
        let container = Block.toggle(title: AttributedString("container"))
        #expect(SystemDelta(from: [container, moving], to: [container.withChildren([moving])]) == nil)
    }

    @Test func wrappingExistingBlocksUnderANewParentIsRejected() {
        let a = Block.paragraph(text: AttributedString("a"))
        let wrapper = Block.heading(level: .h1, text: AttributedString("Title"), children: [a])
        #expect(SystemDelta(from: [a], to: [wrapper]) == nil)
    }

    @Test func removalTakesDescendantsAlong() {
        let child = Block.bullet(text: AttributedString("child"))
        let parent = Block.bullet(text: AttributedString("parent"), children: [child])
        let keep = Block.paragraph(text: AttributedString("keep"))
        let delta = SystemDelta(from: [parent, keep], to: [keep])
        #expect(delta?.removed == [parent.id])
        #expect(delta?.rebase([parent, keep]).map(\.id) == [keep.id])
    }

    @Test func valueChangeAppliesToTheSnapshotCopy() {
        let a = Block.paragraph(text: AttributedString("a"))
        var changed = a
        changed.kind = .paragraph(text: AttributedString("system rewrote this"))
        let delta = SystemDelta(from: [a], to: [changed])

        var stale = a
        stale.kind = .paragraph(text: AttributedString("user was here"))
        let rebased = delta?.rebase([stale]) ?? []

        #expect(String(rebased[0].text.characters) == "system rewrote this")
    }
}
