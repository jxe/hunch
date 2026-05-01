import AudioToolbox
import Foundation

@MainActor
enum SoundFX {
    enum Effect: String {
        case pinchOpen = "pinch-open"
        case drop
        case delete
    }

    static func play(_ effect: Effect) {
        let enabled = UserDefaults.standard.object(forKey: "uiSoundsEnabled") as? Bool ?? true
        guard enabled, let id = soundID(for: effect) else { return }
        AudioServicesPlaySystemSound(id)
    }

    private static var cache: [Effect: SystemSoundID] = [:]

    private static func soundID(for effect: Effect) -> SystemSoundID? {
        if let cached = cache[effect] { return cached }
        guard let url = Bundle.module.url(forResource: effect.rawValue, withExtension: "caf") else { return nil }
        var id: SystemSoundID = 0
        AudioServicesCreateSystemSoundID(url as CFURL, &id)
        cache[effect] = id
        return id
    }
}
