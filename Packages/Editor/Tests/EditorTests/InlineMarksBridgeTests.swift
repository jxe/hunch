import Testing
import Foundation
@testable import Editor

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

@Suite("InlineMarksBridge.sanitize — keep only markdown-translatable marks")
struct InlineMarksBridgeSanitizeTests {

    private let baseFontSize: CGFloat = 16
    private let lineSpacing: CGFloat = 4

    /// Build an NSAttributedString that mimics what a browser/Pages copy looks like:
    /// foreign font family, custom size, foregroundColor, backgroundColor — plus a
    /// genuine bold run in the middle.
    private func styledSource() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let foreignFont = PlatformFont.systemFont(ofSize: 28)
        let foreignAttrs: [NSAttributedString.Key: Any] = [
            .font: foreignFont,
            .foregroundColor: PlatformColor.red,
            .backgroundColor: PlatformColor.yellow,
        ]
        result.append(NSAttributedString(string: "hello ", attributes: foreignAttrs))

        let boldDesc = foreignFont.fontDescriptor.withSymbolicTraits(.boldTrait)
        #if os(macOS)
        let boldFont = NSFont(descriptor: boldDesc, size: 28) ?? foreignFont
        #else
        let boldFont = UIFont(descriptor: boldDesc ?? foreignFont.fontDescriptor, size: 28)
        #endif
        var boldAttrs = foreignAttrs
        boldAttrs[.font] = boldFont
        result.append(NSAttributedString(string: "world", attributes: boldAttrs))
        return result
    }

    @Test func stripsForeignFontAndColors() {
        let sanitized = InlineMarksBridge.sanitize(
            styledSource(),
            baseFontSize: baseFontSize,
            baseBold: false,
            lineSpacing: lineSpacing)

        #expect(sanitized.string == "hello world")

        let full = NSRange(location: 0, length: sanitized.length)
        sanitized.enumerateAttributes(in: full, options: []) { attrs, _, _ in
            // Foreign yellow background was stripped — runs should not carry one.
            #expect(attrs[.backgroundColor] == nil)
            // Foreground is the editor's foreground (not the source's red).
            let fg = attrs[.foregroundColor] as? PlatformColor
            #expect(fg == NotionStyle.platformForeground)
            // Font is Inter at the row's base size (size came from sanitize, not source).
            if let font = attrs[.font] as? PlatformFont {
                #expect(font.pointSize == baseFontSize)
                #expect(font.fontName.lowercased().contains("inter"))
            } else {
                Issue.record("missing .font attribute on sanitized run")
            }
        }
    }

    @Test func preservesBoldRun() {
        let sanitized = InlineMarksBridge.sanitize(
            styledSource(),
            baseFontSize: baseFontSize,
            baseBold: false,
            lineSpacing: lineSpacing)

        // Walk to the "world" run and confirm its font has the bold trait.
        let nsString = sanitized.string as NSString
        let worldRange = nsString.range(of: "world")
        #expect(worldRange.location != NSNotFound)
        let attrs = sanitized.attributes(at: worldRange.location, effectiveRange: nil)
        guard let font = attrs[.font] as? PlatformFont else {
            Issue.record("missing .font on bold run")
            return
        }
        #expect(font.fontDescriptor.symbolicTraits.contains(.boldTrait))
    }

    @Test func preservesLink() {
        let url = URL(string: "https://example.com")!
        let attr = NSAttributedString(string: "click", attributes: [
            .font: PlatformFont.systemFont(ofSize: 28),
            .foregroundColor: PlatformColor.red,
            .link: url,
        ])
        let sanitized = InlineMarksBridge.sanitize(
            attr,
            baseFontSize: baseFontSize,
            baseBold: false,
            lineSpacing: lineSpacing)

        let attrs = sanitized.attributes(at: 0, effectiveRange: nil)
        #expect(attrs[.link] as? URL == url)
        // Link foreground overrides default — it's the link color, not red.
        let fg = attrs[.foregroundColor] as? PlatformColor
        #expect(fg == NotionStyle.platformLinkForeground)
    }
}
