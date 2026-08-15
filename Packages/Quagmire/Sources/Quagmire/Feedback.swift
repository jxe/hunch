import AudioToolbox
import Foundation
#if os(iOS)
import UIKit
#endif

@MainActor
enum SoundFX {
    enum Effect: String {
        case pinchOpen = "pinch-open"
        case drop
        case delete
    }

    static func play(_ effect: Effect, enabled: Bool) {
        guard enabled, let id = soundID(for: effect) else { return }
        AudioServicesPlaySystemSound(id)
    }

    static func resourceURL(for effect: Effect) -> URL? {
        Bundle.module.url(forResource: effect.rawValue, withExtension: "caf")
    }

    private static var cache: [Effect: SystemSoundID] = [:]

    private static func soundID(for effect: Effect) -> SystemSoundID? {
        if let cached = cache[effect] { return cached }
        guard let url = resourceURL(for: effect) else { return nil }
        var id: SystemSoundID = 0
        AudioServicesCreateSystemSoundID(url as CFURL, &id)
        cache[effect] = id
        return id
    }
}

#if os(iOS)
private typealias ImpactStyle = UIImpactFeedbackGenerator.FeedbackStyle
#else
private enum ImpactStyle {
    case light
    case medium
    case heavy
}
#endif

@MainActor
enum Haptics {
    static func light(enabled: Bool) {
        impact(.light, enabled: enabled)
    }

    static func medium(enabled: Bool) {
        impact(.medium, enabled: enabled)
    }

    static func heavy(enabled: Bool) {
        impact(.heavy, enabled: enabled)
    }

    private static func impact(_ style: ImpactStyle, enabled: Bool) {
        guard enabled else { return }
        #if os(iOS)
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
        #endif
    }
}
