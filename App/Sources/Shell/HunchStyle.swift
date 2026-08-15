import Editor
import Foundation
import SwiftUI

/// Hunch-owned presentation policy for both the app shell and its Editor
/// instance. The reusable package itself defaults to system typography and
/// quiet feedback.
enum HunchStyle {
    static let editorTheme = EditorTheme(
        typography: EditorTheme.Typography(bodyFontFamily: "Inter Variable")
    )

    static var editorConfiguration: EditorConfiguration {
        editorConfiguration(userDefaults: .standard, loggingSubsystem: Bundle.main.bundleIdentifier)
    }

    static func editorConfiguration(
        userDefaults: UserDefaults,
        loggingSubsystem: String?
    ) -> EditorConfiguration {
        EditorConfiguration(
            theme: editorTheme,
            isAudioFeedbackEnabled: userDefaults.object(forKey: "uiSoundsEnabled") as? Bool ?? true,
            isHapticFeedbackEnabled: true,
            loggingSubsystem: loggingSubsystem
        )
    }

    static var bodyFontFamily: String { editorTheme.bodyFontFamily ?? "Inter Variable" }
    static var foreground: Color { editorTheme.foreground }
    static var mutedForeground: Color { editorTheme.mutedForeground }
    static var background: Color { editorTheme.background }
    static var linkForeground: Color { editorTheme.linkForeground }

    static func body(weight: Font.Weight = .regular) -> Font {
        editorTheme.body(weight: weight)
    }

    static func body(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        editorTheme.body(size: size, weight: weight)
    }
}
