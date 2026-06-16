import Foundation

public func autoLinkBareURLs(in source: AttributedString) -> AttributedString {
    var result = AttributedString()
    for run in source.runs {
        let segment = source[run.range]
        guard run.link == nil,
              run[InlineAttributes.CodeAttribute.self] != true else {
            result.append(AttributedString(segment))
            continue
        }

        let text = String(segment.characters)
        let matches = BareURLDetector.matches(in: text)
        guard !matches.isEmpty else {
            result.append(AttributedString(segment))
            continue
        }

        let baseAttributes = inlineAttributes(from: run)
        var cursor = text.startIndex
        for match in matches {
            if cursor < match.range.lowerBound {
                append(String(text[cursor..<match.range.lowerBound]), attributes: baseAttributes, to: &result)
            }

            var linkAttributes = baseAttributes
            linkAttributes.link = match.url
            append(String(text[match.range]), attributes: linkAttributes, to: &result)
            cursor = match.range.upperBound
        }
        if cursor < text.endIndex {
            append(String(text[cursor..<text.endIndex]), attributes: baseAttributes, to: &result)
        }
    }
    return result
}

private enum BareURLDetector {
    struct Match {
        let range: Range<String.Index>
        let url: URL
    }

    static func matches(in text: String) -> [Match] {
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return [] }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.matches(in: text, options: [], range: nsRange).compactMap { result in
            guard let url = result.url,
                  isAutoLinkable(url),
                  let range = Range(result.range, in: text) else { return nil }
            return Match(range: range, url: url)
        }
    }

    private static func isAutoLinkable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}

private func inlineAttributes(from run: AttributedString.Runs.Run) -> AttributeContainer {
    var attributes = AttributeContainer()
    attributes.inlineBold = run[InlineAttributes.BoldAttribute.self]
    attributes.inlineItalic = run[InlineAttributes.ItalicAttribute.self]
    attributes.inlineCode = run[InlineAttributes.CodeAttribute.self]
    attributes.inlineStrikethrough = run[InlineAttributes.StrikethroughAttribute.self]
    attributes.link = run.link
    return attributes
}

private func append(_ text: String, attributes: AttributeContainer, to result: inout AttributedString) {
    guard !text.isEmpty else { return }
    var piece = AttributedString(text)
    piece.mergeAttributes(attributes)
    result.append(piece)
}
