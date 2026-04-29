import SwiftUI
import Core

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
        }
        #endif
    }
}
