import AppIntents
import UI

struct StartVoiceRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Voice Recording"
    static let description = IntentDescription("Open Hunch and start recording audio for the current page.")
    static let supportedModes: IntentModes = .foreground(.dynamic)
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    func perform() async throws -> some IntentResult {
        VoiceRecordingLaunchRequest.requestStart()
        return .result()
    }
}

struct HunchAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartVoiceRecordingIntent(),
            phrases: [
                "Start recording in \(.applicationName)",
                "Record audio in \(.applicationName)",
                "Start a voice note in \(.applicationName)"
            ],
            shortTitle: "Record",
            systemImageName: "mic"
        )
    }

    static var shortcutTileColor: ShortcutTileColor {
        .blue
    }
}
