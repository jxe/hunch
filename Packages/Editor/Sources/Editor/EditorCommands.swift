import SwiftUI

/// Bridge for the host's menu bar (and any other out-of-editor surface) to call
/// into the currently-focused `EditorView`. EditorView creates one instance,
/// fills in the closures with handlers that dispatch to its private state, and
/// publishes via `.focusedSceneValue(\.editorCommands, ...)`. Menu items read
/// the focused value and call closures — no-op when no editor is focused.
///
/// Mirrors the `DocumentUndoController` pattern: a class instance lets menu
/// commands act on whichever editor is frontmost without us having to plumb
/// per-window references everywhere.
@MainActor
public final class EditorCommands {
    /// Toggle an inline mark (bold/italic/code/strike) on the active selection.
    /// Routes to the active block's text view in edit mode, or to the nav-mode
    /// block-level toggle when not actively editing.
    public var toggleInlineMark: (InlineMark) -> Void = { _ in }
    /// Convert the focused single-selected block into a subpage link, optionally
    /// using the current text selection as the new page title (Cmd-K).
    public var toggleLinkOrSubpage: () -> Void = {}
    /// Open the per-block action menu (turn-into / move / copy / etc) for the
    /// current selection (Cmd-/).
    public var openBlockActionMenu: () -> Void = {}
    /// Show the destination picker for moving the current block selection to
    /// another page (Cmd-Shift-Return).
    public var openMoveTo: () -> Void = {}
    /// Indent the current block selection one level (Tab).
    public var indent: () -> Void = {}
    /// Outdent the current block selection one level (Shift+Tab).
    public var outdent: () -> Void = {}

    public init() {}
}

public struct EditorCommandsFocusKey: FocusedValueKey {
    public typealias Value = EditorCommands
}

extension FocusedValues {
    public var editorCommands: EditorCommands? {
        get { self[EditorCommandsFocusKey.self] }
        set { self[EditorCommandsFocusKey.self] = newValue }
    }
}
