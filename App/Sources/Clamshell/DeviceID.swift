import Foundation

/// Per-install device identifier used to name this device's recovery log file
/// inside a Clamshell. Stored in `UserDefaults` (per app + device, doesn't
/// sync with iCloud) so each install gets one stable ID for its lifetime; a
/// reinstall produces a new ID and a new log file alongside the existing
/// ones — old logs stay readable for recovery.
enum DeviceID {
    private static let userDefaultsKey = "com.joeedelman.console.deviceID"

    static let current: String = {
        if let existing = UserDefaults.standard.string(forKey: userDefaultsKey) {
            return existing
        }
        let new = UUID().uuidString.lowercased()
        UserDefaults.standard.set(new, forKey: userDefaultsKey)
        return new
    }()
}
