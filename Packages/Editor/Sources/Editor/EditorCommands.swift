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
    public var toggleInlineMark: (InlineMark) -> Void = { _ in }
    public var toggleLinkOrSubpage: () -> Void = {}
    public var openBlockActionMenu: () -> Void = {}
    public var openMoveTo: () -> Void = {}
    public var indent: () -> Void = {}
    public var outdent: () -> Void = {}

    /// Validity predicates for gray-out. The menu bar reads these to disable
    /// `Indent` / `Outdent` items when no candidate block could perform the
    /// op (e.g. selection is at the document root with no previous sibling).
    /// Defaults return `true` so menus stay enabled when no editor is focused.
    public var canIndent: () -> Bool = { true }
    public var canOutdent: () -> Bool = { true }

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
