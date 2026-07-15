import Foundation

/// Cross-process bridge for the Siri "start recording" intent. The intent handler
/// (`VoiceRecordingIntents`) calls `requestStart()` from a background process; the
/// app side reads `consumePendingStart()` once from `ContentView` and forwards the
/// request into the window's shared recording session.
enum VoiceRecordingLaunchRequest {
    static let notificationName = Notification.Name("HunchVoiceRecordingLaunchRequest")

    private static let pendingStartKey = "hunch.pendingVoiceRecordingStart"

    @MainActor
    static func requestStart() {
        UserDefaults.standard.set(true, forKey: pendingStartKey)
        NotificationCenter.default.post(name: notificationName, object: nil)
    }

    @MainActor
    static func consumePendingStart() -> Bool {
        guard UserDefaults.standard.bool(forKey: pendingStartKey) else { return false }
        UserDefaults.standard.set(false, forKey: pendingStartKey)
        return true
    }
}
