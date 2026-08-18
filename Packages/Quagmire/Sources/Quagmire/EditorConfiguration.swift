import Foundation
import os

/// Per-editor host policy. The package defaults are quiet and use system
/// typography; product-specific visuals and feedback are supplied explicitly
/// by each host.
public struct EditorConfiguration: Equatable, Sendable {
    public var theme: EditorTheme
    public var isAudioFeedbackEnabled: Bool
    public var isHapticFeedbackEnabled: Bool
    public var loggingSubsystem: String?

    public init(
        theme: EditorTheme = .default,
        isAudioFeedbackEnabled: Bool = false,
        isHapticFeedbackEnabled: Bool = false,
        loggingSubsystem: String? = nil
    ) {
        self.theme = theme
        self.isAudioFeedbackEnabled = isAudioFeedbackEnabled
        self.isHapticFeedbackEnabled = isHapticFeedbackEnabled
        self.loggingSubsystem = loggingSubsystem
    }

    var diagnostics: EditorDiagnostics {
        EditorDiagnostics(
            subsystem: loggingSubsystem
                ?? Bundle.main.bundleIdentifier
                ?? "Quagmire"
        )
    }
}

struct EditorDiagnostics {
    let subsystem: String

    var navkey: Logger { Logger(subsystem: subsystem, category: "navkey") }
    var mode: Logger { Logger(subsystem: subsystem, category: "mode") }
    var documentLink: Logger { Logger(subsystem: subsystem, category: "documentLink") }
}
