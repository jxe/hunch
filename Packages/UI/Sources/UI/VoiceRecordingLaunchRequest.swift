import Foundation

public enum VoiceRecordingLaunchRequest {
    public static let notificationName = Notification.Name("HunchVoiceRecordingLaunchRequest")

    private static let pendingStartKey = "hunch.pendingVoiceRecordingStart"

    @MainActor
    public static func requestStart() {
        UserDefaults.standard.set(true, forKey: pendingStartKey)
        NotificationCenter.default.post(name: notificationName, object: nil)
    }

    @MainActor
    public static func consumePendingStart() -> Bool {
        guard UserDefaults.standard.bool(forKey: pendingStartKey) else { return false }
        UserDefaults.standard.set(false, forKey: pendingStartKey)
        return true
    }
}
