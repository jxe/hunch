import SwiftUI
import Core
import UI
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
            }
            CommandGroup(after: .sidebar) {
                Button("Back") {
                    model.goBack()
                }
                .keyboardShortcut("[", modifiers: [.command])
                .disabled(!model.canGoBack)
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
#endif
