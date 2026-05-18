import SwiftUI
import Editor
#if os(macOS)
import AppKit
#endif

@main
struct HunchApp: App {
    @State private var workspace = Workspace()

    init() {
        FontRegistration.registerInter()
        #if os(macOS)
        EscapeKeyMonitor.install()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView(workspace: workspace)
        }
        #if os(macOS)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(after: .newItem) {
                Button("Reload Pages") {
                    workspace.rescan()
                }
                .keyboardShortcut("r", modifiers: [.command])

                SwitchWorkspaceMenuButton(workspace: workspace)
                    .keyboardShortcut("o", modifiers: [.command, .shift])

                Divider()

                SearchMenuButton(workspaceURL: workspace.workspaceURL)
                    .keyboardShortcut("p", modifiers: [.command])

                Divider()

                RecoverMenuButton(workspaceURL: workspace.workspaceURL)
                    .keyboardShortcut("\\", modifiers: [.command, .shift])
            }
            CommandGroup(after: .sidebar) {
                BackMenuButton()
                    .keyboardShortcut("[", modifiers: [.command])
            }
            // Replace the system Edit > Undo / Redo with bindings that route through the
            // currently-focused EditorView's `DocumentUndoController`. Without this the
            // menu walks the responder chain and lands on NSTextView's local manager —
            // which we've disabled, so Cmd-Z would just beep.
            CommandGroup(replacing: .undoRedo) {
                UndoRedoMenuItems()
            }
            // Block-level actions live in Edit (after Cut/Copy/Paste) — they
            // operate on the current selection, like the system pasteboard ops.
            CommandGroup(after: .pasteboard) {
                Divider()
                EditorBlockMenuItems()
            }
            CommandMenu("Format") {
                EditorFormatMenuItems()
            }
        }
        #endif
    }
}

#if os(macOS)
@MainActor
private enum EscapeKeyMonitor {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                  event.keyCode == 53,
                  NSApp.keyWindow?.styleMask.contains(.fullScreen) == true else {
                return event
            }
            NotificationCenter.default.post(name: .hunchEscapeKeyDown, object: nil)
            return nil
        }
    }
}

private struct UndoRedoMenuItems: View {
    @FocusedValue(\.documentUndoController) private var undoController

    var body: some View {
        Button("Undo") {
            undoController?.undoManager.undo()
        }
        .keyboardShortcut("z", modifiers: .command)
        .disabled(undoController == nil)

        Button("Redo") {
            undoController?.undoManager.redo()
        }
        .keyboardShortcut("z", modifiers: [.command, .shift])
        .disabled(undoController == nil)
    }
}

private struct EditorCommandButton: View {
    let title: LocalizedStringKey
    let key: KeyEquivalent
    var modifiers: EventModifiers = .command
    /// Optional validity predicate. Menu item grays out when this is set and
    /// `commands.can(predicate)` returns false. Nil means "always enabled
    /// when an editor is focused."
    var requires: EditorPredicate? = nil
    let action: EditorAction
    @FocusedValue(\.editorCommands) private var commands

    var body: some View {
        Button(title) { commands?.perform(action) }
            .keyboardShortcut(key, modifiers: modifiers)
            .disabled(isDisabled)
    }

    private var isDisabled: Bool {
        guard let commands else { return true }
        if let requires, !commands.can(requires) { return true }
        return false
    }
}

private struct EditorBlockMenuItems: View {
    var body: some View {
        EditorCommandButton(title: "Turn Into…", key: "/", action: .openBlockActionMenu)
        EditorCommandButton(title: "Make Subpage / Link…", key: "k", action: .toggleLinkOrSubpage)
        EditorCommandButton(title: "New Block Below", key: .return, action: .newBlockBelow)
        // ⇧⌘M to dodge the system Window > Minimize on plain ⌘M — that
        // collision made the shortcut not display in the menu and not fire
        // outside the popover (which has its own .keyboardShortcut binding).
        EditorCommandButton(title: "Move to Page…", key: "m", modifiers: [.command, .shift], action: .openMoveTo)
        Divider()
        // Tab / Shift+Tab are the editor's real indent shortcuts; registering them
        // here surfaces them in the menu without intercepting Tab elsewhere — a
        // disabled menu item with a key equivalent doesn't consume the key on macOS.
        // The enabled-predicates gray out the items when no candidate block can
        // perform the op (root-level first child, etc.), driven by the tree
        // model's `canIndent` / `canOutdent` predicates.
        EditorCommandButton(title: "Indent", key: .tab, modifiers: [], requires: .canIndent, action: .indent)
        EditorCommandButton(title: "Outdent", key: .tab, modifiers: .shift, requires: .canOutdent, action: .outdent)
        Divider()
        EditorCommandButton(title: "Move Block Up", key: .upArrow, modifiers: .option, action: .moveBlockUp)
        EditorCommandButton(title: "Move Block Down", key: .downArrow, modifiers: .option, action: .moveBlockDown)
    }
}

private struct EditorFormatMenuItems: View {
    var body: some View {
        EditorCommandButton(title: "Bold", key: "b", action: .toggleInlineMark(.bold))
        EditorCommandButton(title: "Italic", key: "i", action: .toggleInlineMark(.italic))
        EditorCommandButton(title: "Inline Code", key: "e", action: .toggleInlineMark(.code))
        EditorCommandButton(title: "Strikethrough", key: "s", modifiers: [.command, .shift], action: .toggleInlineMark(.strikethrough))
    }
}

// MARK: - Per-window menu buttons (route to focused window via FocusedValue)

private struct SwitchWorkspaceMenuButton: View {
    let workspace: Workspace
    @FocusedValue(\.workspaceWindow) private var window

    var body: some View {
        Button("Switch Workspace…") {
            window?.reset()
            workspace.switchWorkspace()
        }
    }
}

private struct SearchMenuButton: View {
    let workspaceURL: URL?
    @FocusedValue(\.workspaceWindow) private var window

    var body: some View {
        Button("Search…") {
            window?.showSearch = true
        }
        .disabled(workspaceURL == nil || window == nil)
    }
}

private struct RecoverMenuButton: View {
    let workspaceURL: URL?
    @FocusedValue(\.workspaceWindow) private var window

    var body: some View {
        Button("Recover…") {
            // Default to the current page when one's open; otherwise show
            // workspace-wide. The Recover sheet exposes a segmented control
            // to flip between scopes inline.
            if let rel = window?.currentPageRelativePath {
                window?.recoveryFilter = .page(relativePath: rel)
            } else {
                window?.recoveryFilter = .all
            }
        }
        .disabled(workspaceURL == nil || window == nil)
    }
}

private struct BackMenuButton: View {
    @FocusedValue(\.workspaceWindow) private var window

    var body: some View {
        Button("Back") {
            window?.goBack()
        }
        .disabled(window?.canGoBack != true)
    }
}
#endif
