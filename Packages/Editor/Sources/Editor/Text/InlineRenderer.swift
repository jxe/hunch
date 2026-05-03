import SwiftUI

/// Translates a `Core.AttributedString` (with our custom inline marks) into a SwiftUI-renderable
/// `AttributedString` that uses Foundation/SwiftUI attributes (font weight, italic, link, etc.).
public enum InlineRenderer {
    public static func swiftUIAttributed(
        _ source: AttributedString,
        baseFont: Font = NotionStyle.body(),
        boldFont: Font = NotionStyle.body(weight: .semibold),
        resolvingPageTitle pageTitle: (String) -> String? = { _ in nil }
    ) -> AttributedString {
        var result = AttributedString()
        for run in source.runs {
            let segment = source[run.range]
            let link = run.link
            let display = link.flatMap { url -> String? in
                let destination = url.absoluteString
                guard destination.hasSuffix(".md") else { return nil }
                return pageTitle(destination)
            } ?? String(segment.characters)
            var attributed = AttributedString(display)

            let bold = run[InlineAttributes.BoldAttribute.self] == true
            let italic = run[InlineAttributes.ItalicAttribute.self] == true
            let code = run[InlineAttributes.CodeAttribute.self] == true
            let strike = run[InlineAttributes.StrikethroughAttribute.self] == true
            if code {
                attributed.font = NotionStyle.mono(size: NotionStyle.inlineCodeSize)
                attributed.foregroundColor = NotionStyle.codeForeground
                attributed.backgroundColor = NotionStyle.codeBackground
            } else {
                var font = bold ? boldFont : baseFont
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
                attributed.underlineStyle = .single
                attributed.foregroundColor = NotionStyle.linkForeground
            }

            result.append(attributed)
        }
        return result
    }
}
