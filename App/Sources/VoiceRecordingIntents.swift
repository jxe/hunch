import AppIntents
import QuagmireExtras

/// App Shortcuts providers must be declared in the application target for
/// Xcode's metadata extractor to discover them. The intent and launch handoff
/// remain reusable in QuagmireExtras; Xcode requires this metadata to be literal.
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
