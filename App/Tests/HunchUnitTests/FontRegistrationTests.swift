import Testing
@testable import Hunch
@testable import Editor

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

@Suite("Bundled font registration")
struct FontRegistrationTests {
    @Test func interVariableResolvesSemiboldWeight() {
        FontRegistration.registerInter()

        let descriptor = PlatformFontDescriptor(fontAttributes: [
            .family: NotionStyle.bodyFontFamily,
            .traits: [PlatformFontDescriptor.TraitKey.weight: PlatformFontWeight.semibold.rawValue],
        ])
        #if os(macOS)
        let font = NSFont(descriptor: descriptor, size: 16)
        #expect(font?.fontName == "InterVariable-SemiBold")
        #else
        let font = UIFont(descriptor: descriptor, size: 16)
        #expect(font.fontName == "InterVariable-SemiBold")
        #endif
    }
}
