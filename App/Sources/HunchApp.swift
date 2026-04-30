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
        Self.installSidebarShortcutMonitor()
        #endif
    }

    #if os(macOS)
    /// Locate `NavigationSplitView`'s underlying `NSSplitViewController` by walking
    /// the key window's view tree, then call `toggleSidebar(_:)` on it directly.
    ///
    /// `tryToPerform(#selector(toggleSidebar))` walks up the responder chain from
    /// `firstResponder`, which only reaches the split-view controller when focus is
    /// inside the detail (e.g. an NSTextView). In nav mode the focused view is
    /// `PageView`'s `.focusable()` host, whose chain doesn't go through the split
    /// VC — so the menu action and the keystroke would both no-op. Walking the
    /// view tree is independent of focus.
    static func toggleSidebarInKeyWindow() {
        guard let contentView = NSApp.keyWindow?.contentView else { return }
        findSplitViewController(in: contentView)?.toggleSidebar(nil)
    }

    private static func findSplitViewController(in view: NSView) -> NSSplitViewController? {
        if let split = view as? NSSplitView,
           let svc = split.delegate as? NSSplitViewController {
            return svc
        }
        for sub in view.subviews {
            if let svc = findSplitViewController(in: sub) { return svc }
        }
        return nil
    }

    /// Cmd-\ is also bound as the menu Toggle Sidebar shortcut, but in nav mode the
    /// `PageView`'s `.focusable()` + `.onKeyPress` host swallows the keystroke before
    /// NSMenu's `performKeyEquivalent` can fire. A local NSEvent monitor runs ahead
    /// of the responder chain, so it catches Cmd-\ regardless of focus.
    private static func installSidebarShortcutMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods == .command, event.charactersIgnoringModifiers == "\\" else {
                return event
            }
            toggleSidebarInKeyWindow()
            return nil
        }
    }
    #endif

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
                    HunchApp.toggleSidebarInKeyWindow()
                }
                .keyboardShortcut("\\", modifiers: .command)
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
