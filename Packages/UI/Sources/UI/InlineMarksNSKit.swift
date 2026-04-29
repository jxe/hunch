import Foundation
import SwiftUI
import Core

#if os(macOS)
import AppKit
#endif

enum InlineMark {
    case bold
    case italic
    case code
    case strikethrough
}

#if os(macOS)
/// Bidirectional conversion between the model's `AttributedString` (custom inline-mark keys)
/// and `NSAttributedString` for live editing in NSTextView.
///
/// We deliberately drive bold/italic/code/strike off of *Cocoa* attributes (font traits,
/// strikethrough style) when reading back, because that's what NSTextView mutates during
/// edits and via its built-in `toggleBold(_:)` / `toggleItalic(_:)` actions. The custom
/// attribute keys live only in the model.
enum InlineMarksNSKit {

    /// Convert a model `AttributedString` into the `NSAttributedString` for textStorage.
    /// `baseFontSize` and `baseBold` come from the row's typography (e.g. an H2 row has
    /// `baseFontSize=24, baseBold=true`); inline marks layer on top of that base.
    static func toNS(_ source: AttributedString, baseFontSize: CGFloat, baseBold: Bool, lineSpacing: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing

        if source.characters.isEmpty {
            // Empty AttributedString — return an empty NSAttributedString. Typing attributes
            // (set separately on the NSTextView) will provide the font / paragraph style.
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
                .foregroundColor: NSColor(NotionStyle.foreground)
            ]

            if code {
                attrs[.font] = monoFont(size: NotionStyle.inlineCodeSize)
                attrs[.foregroundColor] = NSColor(NotionStyle.codeForeground)
                attrs[.backgroundColor] = NSColor(NotionStyle.codeBackground)
            } else {
                attrs[.font] = interFont(size: baseFontSize, bold: bold, italic: italic)
            }
            if strike {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link {
                attrs[.link] = link
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attrs[.foregroundColor] = NSColor.systemBlue
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
            if let font = attrs[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                bold = traits.contains(.bold) || isFontSemiboldOrHeavier(font)
                italic = traits.contains(.italic)
                code = traits.contains(.monoSpace)
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
        return result
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
                let font = (attrs[.font] as? NSFont) ?? interFont(size: baseFontSize, bold: baseBold, italic: false)
                let traits = font.fontDescriptor.symbolicTraits
                let italic = traits.contains(.italic)
                let isCode = traits.contains(.monoSpace)
                if !isCode {
                    newAttrs[.font] = interFont(size: baseFontSize, bold: setting, italic: italic)
                }
            case .italic:
                let font = (attrs[.font] as? NSFont) ?? interFont(size: baseFontSize, bold: baseBold, italic: false)
                let traits = font.fontDescriptor.symbolicTraits
                let bold = traits.contains(.bold) || isFontSemiboldOrHeavier(font) || baseBold
                let isCode = traits.contains(.monoSpace)
                if !isCode {
                    newAttrs[.font] = interFont(size: baseFontSize, bold: bold, italic: setting)
                }
            case .code:
                if setting {
                    newAttrs[.font] = monoFont(size: NotionStyle.inlineCodeSize)
                    newAttrs[.foregroundColor] = NSColor(NotionStyle.codeForeground)
                    newAttrs[.backgroundColor] = NSColor(NotionStyle.codeBackground)
                } else {
                    newAttrs[.font] = interFont(size: baseFontSize, bold: baseBold, italic: false)
                    newAttrs[.foregroundColor] = NSColor(NotionStyle.foreground)
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
            if let font = attrs[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                return traits.contains(.bold) || isFontSemiboldOrHeavier(font)
            }
            return false
        case .italic:
            if let font = attrs[.font] as? NSFont {
                return font.fontDescriptor.symbolicTraits.contains(.italic)
            }
            return false
        case .code:
            if let font = attrs[.font] as? NSFont {
                return font.fontDescriptor.symbolicTraits.contains(.monoSpace)
            }
            return false
        case .strikethrough:
            if let style = attrs[.strikethroughStyle] as? Int { return style != 0 }
            return false
        }
    }

    // MARK: - Font resolution

    static func interFont(size: CGFloat, bold: Bool, italic: Bool) -> NSFont {
        let weight: NSFont.Weight = bold ? .semibold : .regular
        var attributes: [NSFontDescriptor.AttributeName: Any] = [
            .family: "Inter",
            .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue]
        ]
        if italic {
            attributes[.traits] = [
                NSFontDescriptor.TraitKey.weight: weight.rawValue,
                NSFontDescriptor.TraitKey.slant: 1.0
            ]
        }
        let descriptor = NSFontDescriptor(fontAttributes: attributes)
        if italic {
            let italicized = descriptor.withSymbolicTraits(.italic)
            if let font = NSFont(descriptor: italicized, size: size) {
                return font
            }
        }
        if let font = NSFont(descriptor: descriptor, size: size) {
            return font
        }
        return NSFont.systemFont(ofSize: size, weight: weight)
    }

    static func monoFont(size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private static func isFontSemiboldOrHeavier(_ font: NSFont) -> Bool {
        let traits = font.fontDescriptor.fontAttributes[.traits] as? [NSFontDescriptor.TraitKey: Any]
        if let weight = traits?[.weight] as? CGFloat {
            return weight >= NSFont.Weight.semibold.rawValue
        }
        return false
    }
}

#endif
