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
            #expect(fg == EditorTheme.default.platformForeground)
            // Font is normalized to the row's base size. The standalone Editor
            // test host does not register a custom font resource, so the family
            // may legitimately be the platform fallback here.
            if let font = attrs[.font] as? PlatformFont {
                #expect(font.pointSize == baseFontSize)
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
        // Links use the normal text color, no underline, and presentation-only
        // semibold that must not become a Markdown bold mark on round-trip.
        let fg = attrs[.foregroundColor] as? PlatformColor
        #expect(fg == EditorTheme.default.platformForeground)
        #expect(attrs[.underlineStyle] == nil)
        guard let font = attrs[.font] as? PlatformFont else {
            Issue.record("missing .font on link run")
            return
        }
        let traits = font.fontDescriptor.fontAttributes[.traits] as? [PlatformFontDescriptor.TraitKey: Any]
        let weight = traits?[.weight] as? CGFloat
        let isSemibold = font.fontDescriptor.symbolicTraits.contains(.boldTrait)
            || (weight ?? 0) >= PlatformFontWeight.semibold.rawValue
        #expect(isSemibold)

        let roundTripped = InlineMarksBridge.toModel(sanitized)
        #expect(roundTripped.runs.first?[InlineAttributes.BoldAttribute.self] != true)
    }

    @Test func preservesExplicitBoldOnLinkRoundTrip() {
        let url = URL(string: "https://example.com")!
        var linked = AttributedString("click")
        linked.link = url
        linked[InlineAttributes.BoldAttribute.self] = true

        let rendered = InlineMarksBridge.toNS(
            linked,
            baseFontSize: baseFontSize,
            baseBold: false,
            lineSpacing: lineSpacing
        )
        let roundTripped = InlineMarksBridge.toModel(rendered)

        #expect(roundTripped.runs.first?.link == url)
        #expect(roundTripped.runs.first?[InlineAttributes.BoldAttribute.self] == true)
    }

    @Test func bareHTTPURLBecomesLinkAttribute() {
        let linked = autoLinkBareURLs(in: AttributedString("visit https://example.com/docs now"))
        let linkedRuns = linked.runs.filter { $0.link?.absoluteString == "https://example.com/docs" }
        #expect(linkedRuns.count == 1)
        if let run = linkedRuns.first {
            #expect(String(linked[run.range].characters) == "https://example.com/docs")
        }
    }

    @Test func bareURLInsideInlineCodeIsNotLinked() {
        var code = AttributeContainer()
        code.inlineCode = true
        var text = AttributedString("https://example.com")
        text.mergeAttributes(code)

        let linked = autoLinkBareURLs(in: text)
        #expect(linked.runs.allSatisfy { $0.link == nil })
    }

    @Test func typingAttributesToggleEmptySelectionMarks() {
        let base = InlineMarksBridge.baseTypingAttributes(
            baseFontSize: baseFontSize,
            baseBold: false,
            lineSpacing: lineSpacing
        )

        let bold = InlineMarksBridge.typingAttributes(
            toggling: .bold,
            current: base,
            baseFontSize: baseFontSize,
            baseBold: false,
            lineSpacing: lineSpacing
        )
        let boldFont = bold[.font] as? PlatformFont
        #expect(boldFont?.fontDescriptor.symbolicTraits.contains(.boldTrait) == true)

        let code = InlineMarksBridge.typingAttributes(
            toggling: .code,
            current: base,
            baseFontSize: baseFontSize,
            baseBold: false,
            lineSpacing: lineSpacing
        )
        let codeFont = code[.font] as? PlatformFont
        #expect(codeFont?.fontDescriptor.symbolicTraits.contains(.monoSpaceTrait) == true)
        #expect(code[.backgroundColor] as? PlatformColor == EditorTheme.default.platformCodeBackground)
    }
}
