import SwiftUI

/// Bridge for the host's menu bar (and any other out-of-editor surface) to call
/// into the currently-focused `EditorView`. EditorView creates one instance,
/// installs its `perform` / `can` handlers, and publishes via
/// `.focusedSceneValue(\.editorCommands, ...)`. Menu items read the focused
/// value and dispatch via `commands.perform(.someAction)` — no-op when no
/// editor is focused.
///
/// Mirrors the `DocumentUndoController` pattern: a class instance lets menu
/// commands act on whichever editor is frontmost without us having to plumb
/// per-window references everywhere.
@MainActor
public final class EditorCommands {
    public var perform: (EditorAction) -> Void = { _ in }
    /// Validity predicates for menu gray-out — defaults to `true` so menus
    /// stay enabled when no editor is focused (the menu item itself is
    /// disabled when `commands` is nil).
    public var can: (EditorPredicate) -> Bool = { _ in true }

    /// Neutral entry point for host-supplied block actions. Menus identify an
    /// action by the same stable id returned from `EditorHost.blockActions`.
    public var performBlockAction: (String) -> Void = { _ in }
    public var canPerformBlockAction: (String) -> Bool = { _ in false }

    public init() {}
}

/// Every void-returning command exposed to the menu bar. New shortcuts add a
/// case here, a switch arm in `EditorView.wireEditorCommands()`, and a menu
/// button in `HunchApp.swift` — three touch-points, all compile-checked.
///
/// Some cases are nav-mode only (page-focused, no editor mounted) — they're
/// dispatched both from the menu bar and from `EditorView.handleNavKeyPress`'s
/// binding table. They no-op safely when fired in edit mode.
public enum EditorAction: Sendable, Equatable {
    // Surfaces from the menu bar AND nav-mode keyboard. Same in both contexts.
    case openBlockActionMenu
    case openMoveTo
    case toggleLinkOrSubpage
    case toggleInlineMark(InlineMark)
    case indent
    case outdent
    case newBlockBelow
    case moveBlockUp
    case moveBlockDown

    // Nav-mode keyboard only (the menu bar uses the system equivalents directly).
    case copySelection
    case pasteFromPasteboard
    case cutSelection
    case deleteSelection
    case escape
    case navigateBack
    case moveCursor(delta: Int)
    case extendSelection(delta: Int)
    case enterEditOrOpenSubpage
    case navRightArrow
    case navLeftArrow
}

/// Predicates the menu uses to gray out items when the action wouldn't apply
/// (e.g. Indent on the first child of the document root).
public enum EditorPredicate: Sendable {
    case canIndent
    case canOutdent
}

struct EditorCommandsFocusKey: FocusedValueKey {
    typealias Value = EditorCommands
}

extension FocusedValues {
    public var editorCommands: EditorCommands? {
        get { self[EditorCommandsFocusKey.self] }
        set { self[EditorCommandsFocusKey.self] = newValue }
    }
}
