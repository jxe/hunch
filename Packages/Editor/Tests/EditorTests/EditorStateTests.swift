import Testing
@testable import Editor

@MainActor
@Suite("EditorState")
struct EditorStateTests {
    @Test func reorderStartOnUnselectedRowCollapsesSelection() {
        let state = EditorState()
        let selected = BlockID()
        let grabbed = BlockID()

        state.setCursor(selected)
        state.selectForReorderStart(on: grabbed)

        #expect(state.selection == [grabbed])
        #expect(state.anchor == grabbed)
        #expect(state.cursor == grabbed)
        #expect(state.reorderLift == nil)
    }

    @Test func reorderStartInsideMultiSelectionPreservesSelection() {
        let state = EditorState()
        let first = BlockID()
        let second = BlockID()
        let third = BlockID()
        let selected: Set<BlockID> = [first, second, third]

        state.setNavSelection(blocks: selected, anchor: first, cursor: third)
        state.selectForReorderStart(on: second)

        #expect(state.selection == selected)
        #expect(state.anchor == first)
        #expect(state.cursor == second)
    }

    @Test func reorderStartInsideMultiSelectionRepairsInvalidAnchor() {
        let state = EditorState()
        let first = BlockID()
        let second = BlockID()
        let staleAnchor = BlockID()

        state.setNavSelection(blocks: [first, second], anchor: staleAnchor, cursor: first)
        state.selectForReorderStart(on: second)

        #expect(state.selection == [first, second])
        #expect(state.anchor == second)
        #expect(state.cursor == second)
    }

    @Test func revalidateFlagsRepairWhenCursorVanishes() {
        let state = EditorState()
        let gone = BlockID()
        let survivor = BlockID()

        state.setCursor(gone)
        state.revalidate(against: [survivor], fallbackCursor: survivor)

        #expect(state.cursor == survivor)
        #expect(state.consumeSelectionRepairFlag() == true)
        // Consuming clears it.
        #expect(state.consumeSelectionRepairFlag() == false)
    }

    @Test func revalidateLeavesValidSelectionUnflagged() {
        let state = EditorState()
        let here = BlockID()
        let other = BlockID()

        state.setCursor(here)
        state.revalidate(against: [here, other], fallbackCursor: other)

        #expect(state.cursor == here)
        #expect(state.consumeSelectionRepairFlag() == false)
    }

    @Test func sessionStateReportsActiveTransientGesture() {
        let id = BlockID()
        let selection = Selection(blocks: [id], anchor: id, cursor: id)

        #expect(SessionState.navigating(selection, gesture: nil).hasActiveGesture == false)
        #expect(SessionState.editing(id, overlay: nil).hasActiveGesture == false)
        #expect(
            SessionState
                .navigating(selection, gesture: .pinchOpening(PinchPreviewState(insertIndex: 0, gapHeight: 10)))
                .hasActiveGesture == true
        )
    }
}
