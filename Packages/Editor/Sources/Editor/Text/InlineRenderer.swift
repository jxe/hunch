import SwiftUI

/// Translates a `Core.AttributedString` (with our custom inline marks) into SwiftUI `Text`
/// that uses Foundation/SwiftUI attributes (font weight, italic, link, etc.).
enum InlineRenderer {
    private static let inlineCodePaddingText = "\u{2005}"

    static func swiftUIText(
        _ source: AttributedString,
        theme: EditorTheme,
        baseFont: Font,
        boldFont: Font? = nil,
        resolvingPageTitle pageTitle: (String) -> String? = { _ in nil }
    ) -> Text {
        let boldFont = boldFont ?? theme.body(weight: .semibold)
        var result = Text("")
        for run in source.runs {
            let segment = source[run.range]
            let link = run.link
            // pageTitle returns nil for any URL the caller doesn't consider
            // a workspace-page reference (the BlockRow caller pre-filters via
            // `resolvePageLookups`, which consults the host's classifier);
            // a non-nil result is the resolved title to display in place of
            // the raw link text.
            let display = link.flatMap { pageTitle($0.absoluteString) } ?? String(segment.characters)

            let bold = run[InlineAttributes.BoldAttribute.self] == true
            let italic = run[InlineAttributes.ItalicAttribute.self] == true
            let code = run[InlineAttributes.CodeAttribute.self] == true
            let strike = run[InlineAttributes.StrikethroughAttribute.self] == true
            let renderedDisplay = code ? Self.inlineCodePaddingText + display + Self.inlineCodePaddingText : display
            var attributed = AttributedString(renderedDisplay)
            if code {
                attributed.font = theme.mono(size: theme.inlineCodeSize)
                attributed.foregroundColor = theme.codeForeground
            } else {
                var font = (bold || link != nil) ? boldFont : baseFont
                if italic {
                    font = font.italic()
                }
                attributed.font = font
            }

            if strike {
                attributed.strikethroughStyle = .single
            }
            if let link {
                attributed.link = link
                attributed.foregroundColor = theme.foreground
            }

            var text = Text(attributed)
            if code {
                text = text.customAttribute(InlineCodeChipAttribute())
            }
            result = result + text
        }
        return result
    }
}
