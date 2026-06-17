import Foundation
import SwiftUI

#if os(macOS)
import AppKit
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
typealias PlatformFontDescriptor = NSFontDescriptor
typealias PlatformFontWeight = NSFont.Weight
#elseif os(iOS)
import UIKit
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
typealias PlatformFontDescriptor = UIFontDescriptor
typealias PlatformFontWeight = UIFont.Weight
#endif

/// `SymbolicTraits` is the same OptionSet shape on both platforms, but Apple spelled
/// the cases differently (macOS: `.bold`, iOS: `.traitBold`). These wrappers paper over
/// the discrepancy so call sites can stay platform-agnostic.
extension PlatformFontDescriptor.SymbolicTraits {
    static var boldTrait: Self {
        #if os(macOS)
        return .bold
        #else
        return .traitBold
        #endif
    }
    static var italicTrait: Self {
        #if os(macOS)
        return .italic
        #else
        return .traitItalic
        #endif
    }
    static var monoSpaceTrait: Self {
        #if os(macOS)
        return .monoSpace
        #else
        return .traitMonoSpace
        #endif
    }
}

public enum InlineMark: Sendable {
    case bold
    case italic
    case code
    case strikethrough
}

/// Bidirectional conversion between the model's `AttributedString` (custom inline-mark keys)
/// and `NSAttributedString` for live editing in the platform text view (NSTextView on
/// macOS, UITextView on iOS).
///
/// We deliberately drive bold/italic/code/strike off of platform attributes (font traits,
/// strikethrough style) when reading back, because that's what the platform text view
/// mutates during edits. The custom typed `AttributedStringKey`s live only in the model.
enum InlineMarksBridge {
    static func baseTypingAttributes(baseFontSize: CGFloat, baseBold: Bool, lineSpacing: CGFloat) -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        return [
            .font: interFont(size: baseFontSize, bold: baseBold, italic: false),
            .paragraphStyle: paragraphStyle,
            .foregroundColor: NotionStyle.platformForeground
        ]
    }

    /// Convert a model `AttributedString` into the `NSAttributedString` for textStorage.
    /// `baseFontSize` and `baseBold` come from the row's typography (e.g. an H2 row has
    /// `baseFontSize=24, baseBold=true`); inline marks layer on top of that base.
    static func toNS(_ source: AttributedString, baseFontSize: CGFloat, baseBold: Bool, lineSpacing: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing

        if source.characters.isEmpty {
            // Empty AttributedString — return an empty NSAttributedString. Typing attributes
            // (set separately on the text view) will provide the font / paragraph style.
            return result
        }

        for run in source.runs {
            let segment = source[run.range]
            let plain = String(segment.characters)
            let bold = (run[InlineAttributes.BoldAttribute.self] == true) || baseBold
            let italic = run[InlineAttributes.ItalicAttribute.self] == true
            let code = run[InlineAttributes.CodeAttribute.self] == true
            let strike = run[InlineAttributes.StrikethroughAttribute.self] == true
            let link = run.link

            var attrs: [NSAttributedString.Key: Any] = [
                .paragraphStyle: paragraphStyle,
                .foregroundColor: NotionStyle.platformForeground
            ]

            if code {
                attrs[.font] = monoFont(size: NotionStyle.inlineCodeSize)
                attrs[.foregroundColor] = NotionStyle.platformCodeForeground
                attrs[.backgroundColor] = NotionStyle.platformCodeBackground
            } else {
                attrs[.font] = interFont(size: baseFontSize, bold: bold, italic: italic)
            }
            if strike {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link {
                attrs[.link] = link
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attrs[.foregroundColor] = NotionStyle.platformLinkForeground
            }
            result.append(NSAttributedString(string: plain, attributes: attrs))
        }
        return result
    }

    /// Read NSAttributedString from textStorage and reconstruct the model AttributedString.
    /// Bold/italic/code are derived from the run's font traits; strikethrough from the
    /// strikethroughStyle attribute; link from .link.
    static func toModel(_ source: NSAttributedString) -> AttributedString {
        var result = AttributedString()
        guard source.length > 0 else { return result }

        let full = NSRange(location: 0, length: source.length)
        source.enumerateAttributes(in: full, options: []) { attrs, range, _ in
            let segment = source.attributedSubstring(from: range).string
            var piece = AttributedString(segment)

            var bold = false
            var italic = false
            var code = false
            if let font = attrs[.font] as? PlatformFont {
                let traits = font.fontDescriptor.symbolicTraits
                bold = traits.contains(.boldTrait) || isFontSemiboldOrHeavier(font)
                italic = traits.contains(.italicTrait)
                code = traits.contains(.monoSpaceTrait)
            }
            if bold {
                piece[InlineAttributes.BoldAttribute.self] = true
            }
            if italic {
                piece[InlineAttributes.ItalicAttribute.self] = true
            }
            if code {
                piece[InlineAttributes.CodeAttribute.self] = true
            }
            if let style = attrs[.strikethroughStyle] as? Int, style != 0 {
                piece[InlineAttributes.StrikethroughAttribute.self] = true
            }
            if let linkValue = attrs[.link] {
                if let url = linkValue as? URL {
                    piece.link = url
                } else if let s = linkValue as? String, let url = URL(string: s) {
                    piece.link = url
                }
            }
            result.append(piece)
        }
        return autoLinkBareURLs(in: result)
    }

    /// Strip every attribute that doesn't round-trip to markdown (bold/italic/code/
    /// strike/link survive; font, size, color, background, paragraph style do not),
    /// then re-render with the row's typography so pasted text matches the surrounding
    /// block. `toModel` already discards everything but the four custom mark keys and
    /// `.link`; `toNS` re-applies Inter / NotionStyle colors.
    static func sanitize(_ source: NSAttributedString, baseFontSize: CGFloat, baseBold: Bool, lineSpacing: CGFloat) -> NSAttributedString {
        let model = toModel(source)
        return toNS(model, baseFontSize: baseFontSize, baseBold: baseBold, lineSpacing: lineSpacing)
    }

    /// Toggle a single inline mark on the given range of an NSTextStorage. After this
    /// returns, the textStorage's `didChangeText()` should be called by the caller so
    /// SwiftUI sees the update.
    static func toggleMark(_ mark: InlineMark, on range: NSRange, in storage: NSTextStorage, baseFontSize: CGFloat, baseBold: Bool) {
        guard range.length > 0 else { return }

        // Decide whether to set or clear by looking at the start of the range.
        let setting = !rangeHasMark(mark, range: range, storage: storage)

        storage.beginEditing()
        storage.enumerateAttributes(in: range, options: []) { attrs, subrange, _ in
            var newAttrs = attrs
            switch mark {
            case .bold:
                let font = (attrs[.font] as? PlatformFont) ?? interFont(size: baseFontSize, bold: baseBold, italic: false)
                let traits = font.fontDescriptor.symbolicTraits
                let italic = traits.contains(.italicTrait)
                let isCode = traits.contains(.monoSpaceTrait)
                if !isCode {
                    newAttrs[.font] = interFont(size: baseFontSize, bold: setting, italic: italic)
                }
            case .italic:
                let font = (attrs[.font] as? PlatformFont) ?? interFont(size: baseFontSize, bold: baseBold, italic: false)
                let traits = font.fontDescriptor.symbolicTraits
                let bold = traits.contains(.boldTrait) || isFontSemiboldOrHeavier(font) || baseBold
                let isCode = traits.contains(.monoSpaceTrait)
                if !isCode {
                    newAttrs[.font] = interFont(size: baseFontSize, bold: bold, italic: setting)
                }
            case .code:
                if setting {
                    newAttrs[.font] = monoFont(size: NotionStyle.inlineCodeSize)
                    newAttrs[.foregroundColor] = NotionStyle.platformCodeForeground
                    newAttrs[.backgroundColor] = NotionStyle.platformCodeBackground
                } else {
                    newAttrs[.font] = interFont(size: baseFontSize, bold: baseBold, italic: false)
                    newAttrs[.foregroundColor] = NotionStyle.platformForeground
                    newAttrs.removeValue(forKey: .backgroundColor)
                }
            case .strikethrough:
                if setting {
                    newAttrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                } else {
                    newAttrs.removeValue(forKey: .strikethroughStyle)
                }
            }
            storage.setAttributes(newAttrs, range: subrange)
        }
        storage.endEditing()
    }

    static func rangeHasMark(_ mark: InlineMark, range: NSRange, storage: NSTextStorage) -> Bool {
        // Mark is "set" if the first character in the range has it. Mirrors Notion's toggle
        // behavior — a mixed range becomes uniformly the toggle's new state.
        let probeRange = NSRange(location: range.location, length: min(1, range.length))
        let attrs = storage.attributes(at: probeRange.location, effectiveRange: nil)
        switch mark {
        case .bold:
            if let font = attrs[.font] as? PlatformFont {
                let traits = font.fontDescriptor.symbolicTraits
                return traits.contains(.boldTrait) || isFontSemiboldOrHeavier(font)
            }
            return false
        case .italic:
            if let font = attrs[.font] as? PlatformFont {
                return font.fontDescriptor.symbolicTraits.contains(.italicTrait)
            }
            return false
        case .code:
            if let font = attrs[.font] as? PlatformFont {
                return font.fontDescriptor.symbolicTraits.contains(.monoSpaceTrait)
            }
            return false
        case .strikethrough:
            if let style = attrs[.strikethroughStyle] as? Int { return style != 0 }
            return false
        }
    }

    static func typingAttributes(
        toggling mark: InlineMark,
        current attrs: [NSAttributedString.Key: Any],
        baseFontSize: CGFloat,
        baseBold: Bool,
        lineSpacing: CGFloat
    ) -> [NSAttributedString.Key: Any] {
        var newAttrs = attrs
        if newAttrs[.paragraphStyle] == nil {
            newAttrs[.paragraphStyle] = baseTypingAttributes(
                baseFontSize: baseFontSize,
                baseBold: baseBold,
                lineSpacing: lineSpacing
            )[.paragraphStyle]
        }

        let font = (attrs[.font] as? PlatformFont) ?? interFont(size: baseFontSize, bold: baseBold, italic: false)
        let traits = font.fontDescriptor.symbolicTraits
        let isCode = traits.contains(.monoSpaceTrait)

        switch mark {
        case .bold:
            guard !isCode else { return newAttrs }
            let italic = traits.contains(.italicTrait)
            let currentlyBold = traits.contains(.boldTrait) || isFontSemiboldOrHeavier(font)
            let setting = !currentlyBold
            newAttrs[.font] = interFont(size: baseFontSize, bold: setting, italic: italic)
            newAttrs[.foregroundColor] = NotionStyle.platformForeground
            newAttrs.removeValue(forKey: .backgroundColor)
        case .italic:
            guard !isCode else { return newAttrs }
            let bold = traits.contains(.boldTrait) || isFontSemiboldOrHeavier(font) || baseBold
            let setting = !traits.contains(.italicTrait)
            newAttrs[.font] = interFont(size: baseFontSize, bold: bold, italic: setting)
            newAttrs[.foregroundColor] = NotionStyle.platformForeground
            newAttrs.removeValue(forKey: .backgroundColor)
        case .code:
            if isCode {
                newAttrs[.font] = interFont(size: baseFontSize, bold: baseBold, italic: false)
                newAttrs[.foregroundColor] = NotionStyle.platformForeground
                newAttrs.removeValue(forKey: .backgroundColor)
            } else {
                newAttrs[.font] = monoFont(size: NotionStyle.inlineCodeSize)
                newAttrs[.foregroundColor] = NotionStyle.platformCodeForeground
                newAttrs[.backgroundColor] = NotionStyle.platformCodeBackground
            }
        case .strikethrough:
            if let style = attrs[.strikethroughStyle] as? Int, style != 0 {
                newAttrs.removeValue(forKey: .strikethroughStyle)
            } else {
                newAttrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
        }
        return newAttrs
    }

    // MARK: - Font resolution

    static func interFont(size: CGFloat, bold: Bool, italic: Bool) -> PlatformFont {
        let weight: PlatformFontWeight = bold ? .semibold : .regular
        var attributes: [PlatformFontDescriptor.AttributeName: Any] = [
            .family: "Inter",
            .traits: [PlatformFontDescriptor.TraitKey.weight: weight.rawValue]
        ]
        if italic {
            attributes[.traits] = [
                PlatformFontDescriptor.TraitKey.weight: weight.rawValue,
                PlatformFontDescriptor.TraitKey.slant: 1.0
            ]
        }
        let descriptor = PlatformFontDescriptor(fontAttributes: attributes)

        #if os(macOS)
        if italic {
            let italicized = descriptor.withSymbolicTraits(.italicTrait)
            if let font = NSFont(descriptor: italicized, size: size) {
                return font
            }
        }
        if let font = NSFont(descriptor: descriptor, size: size) {
            return font
        }
        return NSFont.systemFont(ofSize: size, weight: weight)
        #else
        if italic, let italicized = descriptor.withSymbolicTraits(.italicTrait) {
            return UIFont(descriptor: italicized, size: size)
        }
        return UIFont(descriptor: descriptor, size: size)
        #endif
    }

    static func monoFont(size: CGFloat) -> PlatformFont {
        PlatformFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private static func isFontSemiboldOrHeavier(_ font: PlatformFont) -> Bool {
        let traits = font.fontDescriptor.fontAttributes[.traits] as? [PlatformFontDescriptor.TraitKey: Any]
        if let weight = traits?[.weight] as? CGFloat {
            return weight >= PlatformFontWeight.semibold.rawValue
        }
        return false
    }
}
