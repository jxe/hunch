import SwiftUI
import Editor
#if os(macOS)
import AppKit
#endif

@main
struct HunchApp: App {
    @State private var model = WorkspaceModel()

    init() {
        FontRegistration.registerInter()
        #if os(macOS)
        EscapeKeyMonitor.install()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        #if os(macOS)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(after: .newItem) {
                Button("Reload Pages") {
                    model.rescan()
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button("Switch Workspace…") {
                    model.switchWorkspace()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Divider()

                Button("Jump to Page…") {
                    model.showJumpTo = true
                }
                .keyboardShortcut("p", modifiers: [.command])
                .disabled(model.workspaceURL == nil)

                Button("Show Page List…") {
                    model.showPageList = true
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(model.workspaceURL == nil)

                Divider()

                Button("Recently Deleted…") {
                    model.recoveryFilter = .all
                }
                .keyboardShortcut("\\", modifiers: [.command, .shift])
                .disabled(model.workspaceURL == nil)

                Button("Recover Lost Blocks on This Page…") {
                    if let rel = model.currentPageRelativePath {
                        model.recoveryFilter = .page(relativePath: rel)
                    }
                }
                .disabled(model.currentPageRelativePath == nil)
            }
            CommandGroup(after: .sidebar) {
                Button("Back") {
                    model.goBack()
                }
                .keyboardShortcut("[", modifiers: [.command])
                .disabled(!model.canGoBack)
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

private struct EditorBlockMenuItems: View {
    @FocusedValue(\.editorCommands) private var commands

    var body: some View {
        Button("Turn Into…") {
            commands?.openBlockActionMenu()
        }
        .keyboardShortcut("/", modifiers: .command)
        .disabled(commands == nil)

        Button("Make Subpage / Link…") {
            commands?.toggleLinkOrSubpage()
        }
        .keyboardShortcut("k", modifiers: .command)
        .disabled(commands == nil)

        Button("Move Block to Page…") {
            commands?.openMoveTo()
        }
        .keyboardShortcut(.return, modifiers: [.command, .shift])
        .disabled(commands == nil)

        Divider()

        // Tab / Shift+Tab are the editor's real indent shortcuts. Registered as
        // menu equivalents so they appear in the menu the way users expect.
        // `.disabled(commands == nil)` means the menu does NOT swallow Tab when
        // no editor is focused (a disabled menu item with a key equivalent
        // doesn't intercept the key on macOS), so Tab keeps its normal focus-
        // traversal behavior in sheets and other UI.
        Button("Indent") {
            commands?.indent()
        }
        .keyboardShortcut(.tab, modifiers: [])
        .disabled(commands == nil)

        Button("Outdent") {
            commands?.outdent()
        }
        .keyboardShortcut(.tab, modifiers: .shift)
        .disabled(commands == nil)
    }
}

private struct EditorFormatMenuItems: View {
    @FocusedValue(\.editorCommands) private var commands

    var body: some View {
        Button("Bold") {
            commands?.toggleInlineMark(.bold)
        }
        .keyboardShortcut("b", modifiers: .command)
        .disabled(commands == nil)

        Button("Italic") {
            commands?.toggleInlineMark(.italic)
        }
        .keyboardShortcut("i", modifiers: .command)
        .disabled(commands == nil)

        Button("Inline Code") {
            commands?.toggleInlineMark(.code)
        }
        .keyboardShortcut("e", modifiers: .command)
        .disabled(commands == nil)

        Button("Strikethrough") {
            commands?.toggleInlineMark(.strikethrough)
        }
        .keyboardShortcut("s", modifiers: [.command, .shift])
        .disabled(commands == nil)
    }
}
#endif
