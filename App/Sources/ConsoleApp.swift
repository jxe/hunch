import SwiftUI
import Core
import UI
#if os(macOS)
import AppKit
#endif

@main
struct ConsoleApp: App {
    @State private var model = WorkspaceModel()

    init() {
        FontRegistration.registerInter()
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
            }
            CommandGroup(after: .toolbar) {
                Button("Toggle Sidebar") {
                    NSApp.keyWindow?.firstResponder?.tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
            }
            // Replace the system Edit > Undo / Redo with bindings that route through the
            // currently-focused PageView's `DocumentUndoController`. Without this the
            // menu walks the responder chain and lands on NSTextView's local manager —
            // which we've disabled, so Cmd-Z would just beep.
            CommandGroup(replacing: .undoRedo) {
                UndoRedoMenuItems()
            }
        }
        #endif
    }
}

#if os(macOS)
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
#endif
