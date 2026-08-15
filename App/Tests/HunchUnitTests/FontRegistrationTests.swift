import Testing
@testable import Hunch
import Editor

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

@Suite("Bundled font registration")
struct FontRegistrationTests {
    @Test func hunchSuppliesEditorPresentationPolicy() {
        let suiteName = "FontRegistrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let defaultConfiguration = HunchStyle.editorConfiguration(
            userDefaults: defaults,
            loggingSubsystem: "HunchTests"
        )
        #expect(defaultConfiguration.theme.bodyFontFamily == "Inter Variable")
        #expect(defaultConfiguration.isAudioFeedbackEnabled)
        #expect(defaultConfiguration.isHapticFeedbackEnabled)
        #expect(defaultConfiguration.loggingSubsystem == "HunchTests")

        defaults.set(false, forKey: "uiSoundsEnabled")
        let mutedConfiguration = HunchStyle.editorConfiguration(
            userDefaults: defaults,
            loggingSubsystem: "HunchTests"
        )
        #expect(mutedConfiguration.isAudioFeedbackEnabled == false)
    }

    @Test func interVariableResolvesSemiboldWeight() {
        FontRegistration.registerInter()

        #expect(HunchStyle.editorConfiguration.theme.bodyFontFamily == "Inter Variable")

        #if os(macOS)
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: HunchStyle.bodyFontFamily,
            .traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.semibold.rawValue],
        ])
        let font = NSFont(descriptor: descriptor, size: 16)
        #expect(font?.fontName == "InterVariable-SemiBold")
        #else
        let descriptor = UIFontDescriptor(fontAttributes: [
            .family: HunchStyle.bodyFontFamily,
            .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.semibold.rawValue],
        ])
        let font = UIFont(descriptor: descriptor, size: 16)
        #expect(font.fontName == "InterVariable-SemiBold")
        #endif
    }
}
