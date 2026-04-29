import SwiftUI

@main
struct ConsoleApp: App {
    init() {
        FontRegistration.registerInter()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(macOS)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        #endif
    }
}
