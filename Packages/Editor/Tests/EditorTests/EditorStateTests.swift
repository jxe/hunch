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
}
