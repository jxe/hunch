import Testing
import SwiftUI
@testable import Editor

/// Pure-function checks against `EditorView.navBindings` — the (key,
/// modifiers) → `EditorAction` table that drives nav-mode keyboard input.
/// These tests don't stand up an EditorView; they only exercise the table
/// + matcher.
@MainActor
@Suite("Nav-mode key bindings")
struct NavKeyBindingTests {
    @Test func cmdCMapsToCopySelection() {
        #expect(EditorView.navAction(for: "c", modifiers: .command) == .copySelection)
    }

    @Test func cmdVMapsToPaste() {
        #expect(EditorView.navAction(for: "v", modifiers: .command) == .pasteFromPasteboard)
    }

    @Test func cmdXMapsToCut() {
        #expect(EditorView.navAction(for: "x", modifiers: .command) == .cutSelection)
    }

    @Test func cmdBMapsToBold() {
        #expect(EditorView.navAction(for: "b", modifiers: .command) == .toggleInlineMark(.bold))
    }

    @Test func cmdIMapsToItalic() {
        #expect(EditorView.navAction(for: "i", modifiers: .command) == .toggleInlineMark(.italic))
    }

    @Test func cmdShiftSMapsToStrikethrough() {
        #expect(EditorView.navAction(for: "s", modifiers: [.command, .shift]) == .toggleInlineMark(.strikethrough))
    }

    @Test func cmdBAloneIsNotCmdShiftB() {
        // Cmd-B and Cmd-Shift-B should NOT collide. The matcher requires exact
        // modifier match — Cmd-B fires bold, Cmd-Shift-B has no binding.
        #expect(EditorView.navAction(for: "b", modifiers: .command) == .toggleInlineMark(.bold))
        #expect(EditorView.navAction(for: "b", modifiers: [.command, .shift]) == nil)
    }

    @Test func cmdSlashOpensActionMenu() {
        #expect(EditorView.navAction(for: "/", modifiers: .command) == .openBlockActionMenu)
    }

    @Test func cmdKMapsToToggleLink() {
        #expect(EditorView.navAction(for: "k", modifiers: .command) == .toggleLinkOrSubpage)
    }

    @Test func cmdReturnMapsToNewBlockBelow() {
        #expect(EditorView.navAction(for: .return, modifiers: .command) == .newBlockBelow)
    }

    @Test func plainReturnEntersEdit() {
        #expect(EditorView.navAction(for: .return, modifiers: []) == .enterEditOrOpenSubpage)
    }

    @Test func tabIndents() {
        #expect(EditorView.navAction(for: .tab, modifiers: []) == .indent)
    }

    @Test func backTabOutdents() {
        // Shift+Tab arrives as the BackTab character (U+0019), not .tab + .shift.
        #expect(EditorView.navAction(for: KeyEquivalent("\u{19}"), modifiers: []) == .outdent)
    }

    @Test func plainArrowsMoveCursor() {
        #expect(EditorView.navAction(for: .upArrow, modifiers: []) == .moveCursor(delta: -1))
        #expect(EditorView.navAction(for: .downArrow, modifiers: []) == .moveCursor(delta: +1))
    }

    @Test func shiftArrowsExtendSelection() {
        #expect(EditorView.navAction(for: .upArrow, modifiers: .shift) == .extendSelection(delta: -1))
        #expect(EditorView.navAction(for: .downArrow, modifiers: .shift) == .extendSelection(delta: +1))
    }

    @Test func optionArrowsMoveBlock() {
        #expect(EditorView.navAction(for: .upArrow, modifiers: .option) == .moveBlockUp)
        #expect(EditorView.navAction(for: .downArrow, modifiers: .option) == .moveBlockDown)
    }

    @Test func leftRightArrows() {
        #expect(EditorView.navAction(for: .leftArrow, modifiers: []) == .navLeftArrow)
        #expect(EditorView.navAction(for: .rightArrow, modifiers: []) == .navRightArrow)
    }

    @Test func deleteAndBackspaceMapToDelete() {
        #expect(EditorView.navAction(for: .delete, modifiers: []) == .deleteSelection)
        #expect(EditorView.navAction(for: KeyEquivalent("\u{8}"), modifiers: []) == .deleteSelection)
        #expect(EditorView.navAction(for: KeyEquivalent("\u{7F}"), modifiers: []) == .deleteSelection)
    }

    @Test func escapeMapsToEscape() {
        #expect(EditorView.navAction(for: .escape, modifiers: []) == .escape)
    }

    @Test func cmdBracketNavigatesBack() {
        #expect(EditorView.navAction(for: "[", modifiers: .command) == .navigateBack)
    }

    @Test func unboundChordReturnsNil() {
        // Cmd-Q (or anything not in the table) returns nil so SwiftUI can pass
        // the press through to other handlers.
        #expect(EditorView.navAction(for: "q", modifiers: .command) == nil)
        #expect(EditorView.navAction(for: "z", modifiers: .command) == nil) // Cmd-Z is handled separately by the menu
    }
}
