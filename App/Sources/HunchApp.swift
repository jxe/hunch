import SwiftUI
import Editor
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
import Darwin
import Security
#endif

@main
struct HunchApp: App {
    @State private var workspace = Workspace()
    #if os(iOS)
    @UIApplicationDelegateAdaptor(HunchAppDelegate.self) private var appDelegate
    @State private var quickActions = QuickActionRouter.shared
    #endif

    init() {
        #if os(macOS)
        SingleInstanceGuard.activateExistingInstanceAndExitIfNeeded()
        StartupDiagnostics.logLaunchIdentity()
        EscapeKeyMonitor.install()
        #endif
        FontRegistration.registerInter()
    }

    var body: some Scene {
        WindowGroup {
            #if os(iOS)
            ContentView(workspace: workspace, quickActions: quickActions)
            #else
            ContentView(workspace: workspace)
            #endif
        }
        #if os(macOS)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(after: .newItem) {
                Button("Reload Pages") {
                    workspace.rescan(includeConflictSweep: true)
                }
                .keyboardShortcut("r", modifiers: [.command])

                SwitchWorkspaceMenuButton(workspace: workspace)
                    .keyboardShortcut("o", modifiers: [.command, .shift])

                Divider()

                SearchMenuButton(workspaceURL: workspace.workspaceURL)
                    .keyboardShortcut("p", modifiers: [.command])
                AddToPageMenuButton(workspaceURL: workspace.workspaceURL)
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                MoveCurrentPageToTrashMenuButton(workspaceURL: workspace.workspaceURL)

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

#if os(iOS)
@MainActor
@Observable
final class QuickActionRouter {
    static let shared = QuickActionRouter()

    private var hasPendingIconPickerRequest = false
    private(set) var iconPickerRequestID = 0

    func requestIconPicker() {
        hasPendingIconPickerRequest = true
        iconPickerRequestID += 1
    }

    func consumeIconPickerRequest() -> Bool {
        guard hasPendingIconPickerRequest else { return false }
        hasPendingIconPickerRequest = false
        return true
    }
}

@MainActor
private enum HunchQuickAction {
    static let appIconType = "org.nxhx.Hunch.appIcon"

    static func handle(_ shortcutItem: UIApplicationShortcutItem) -> Bool {
        guard shortcutItem.type == appIconType else { return false }
        QuickActionRouter.shared.requestIconPicker()
        return true
    }
}

@MainActor
final class HunchAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if let shortcutItem = options.shortcutItem {
            _ = HunchQuickAction.handle(shortcutItem)
        }

        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = HunchSceneDelegate.self
        return configuration
    }

    func application(
        _ application: UIApplication,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(HunchQuickAction.handle(shortcutItem))
    }
}

@MainActor
final class HunchSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(HunchQuickAction.handle(shortcutItem))
    }
}
#endif

#if os(macOS)
private enum StartupDiagnostics {
    static func logLaunchIdentity() {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "unknown"
        let homeDirectory = NSHomeDirectory()
        let deviceID = DeviceID.current

        Diag.log.log("startup identity bundle=\(bundleIdentifier, privacy: .public) deviceID=\(deviceID, privacy: .public) home=\(homeDirectory, privacy: .public)")

        let hasSandboxEntitlement = sandboxEntitlementIsEnabled()
        let expectedContainerSuffix = "/Library/Containers/\(bundleIdentifier)/Data"
        let hasContainerHome = homeDirectory.hasSuffix(expectedContainerSuffix)

        if !hasSandboxEntitlement || !hasContainerHome {
            Diag.log.warning(
                "startup sandbox warning bundle=\(bundleIdentifier, privacy: .public) deviceID=\(deviceID, privacy: .public) sandboxEntitlement=\(hasSandboxEntitlement, privacy: .public) containerHome=\(hasContainerHome, privacy: .public) home=\(homeDirectory, privacy: .public) expectedSuffix=\(expectedContainerSuffix, privacy: .public)"
            )
        }
    }

    private static func sandboxEntitlementIsEnabled() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.security.app-sandbox" as CFString,
                nil
              ) else {
            return false
        }
        return (value as? Bool) == true
    }
}

@MainActor
private enum SingleInstanceGuard {
    static func activateExistingInstanceAndExitIfNeeded() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let existing = NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier != currentPID && $0.bundleIdentifier == bundleIdentifier
        }

        guard let existing else { return }
        existing.activate(options: [.activateAllWindows])
        exit(0)
    }
}

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

private struct AddToPageMenuButton: View {
    let workspaceURL: URL?
    @FocusedValue(\.workspaceWindow) private var window

    var body: some View {
        Button("Add This Page to…") {
            window?.showAddToPageSearch = true
        }
        .disabled(workspaceURL == nil || window?.currentPageRelativePath == nil)
    }
}

private struct MoveCurrentPageToTrashMenuButton: View {
    let workspaceURL: URL?
    @FocusedValue(\.workspaceWindow) private var window

    var body: some View {
        Button("Move Current Page to Trash", role: .destructive) {
            guard let window else { return }
            Task { await window.moveCurrentPageToTrash() }
        }
        .disabled(workspaceURL == nil || window?.currentPageRelativePath == nil)
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
            window?.navigateBack()
        }
        .disabled(window?.canNavigateBack != true)
    }
}
#endif
