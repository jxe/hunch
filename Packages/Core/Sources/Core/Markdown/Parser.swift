import Foundation
import Markdown

public enum BlockParser {
    public static func parse(_ source: String) -> [Block] {
        let document = Markdown.Document(parsing: source, options: [.parseBlockDirectives])
        let children = Array(document.children)
        return assemble(children, indent: 0).blocks
    }

    /// Walks a sibling list of markup nodes, lifting `<details>...</details>` runs into
    /// `.toggle` blocks. cmark-gfm closes an HTML block at a blank line, so a real-world
    /// `<details>` toggle with markdown children parses as: HTMLBlock(`<details>...<summary>`),
    /// then inner markdown nodes, then HTMLBlock(`</details>`). This pass stitches them back together.
    private static func assemble(_ nodes: [any Markup], indent: Int) -> (blocks: [Block], consumed: Int) {
        var i = 0
        var out: [Block] = []
        while i < nodes.count {
            let node = nodes[i]
            if let html = node as? HTMLBlock, isDetailsOpen(html.rawHTML) {
                let title = parseSummaryTitle(html.rawHTML)
                // Collect children until matching </details>
                var depth = 1
                var children: [any Markup] = []
                var j = i + 1
                while j < nodes.count {
                    if let h = nodes[j] as? HTMLBlock {
                        if isDetailsOpen(h.rawHTML) { depth += 1 }
                        if isDetailsClose(h.rawHTML) {
                            depth -= 1
                            if depth == 0 { break }
                        }
                    }
                    children.append(nodes[j])
                    j += 1
                }
                let inner = assemble(children, indent: indent).blocks
                out.append(.toggle(title: title, expanded: true, children: inner, indent: indent))
                i = j + 1   // skip past closing </details>
                continue
            }
            out.append(contentsOf: convertBlock(node, indent: indent))
            i += 1
        }
        return (out, i)
    }

    private static func isDetailsOpen(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.hasPrefix("<details")
    }

    private static func isDetailsClose(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.contains("</details>")
    }

    private static func parseSummaryTitle(_ raw: String) -> AttributedString {
        guard let sumStart = raw.range(of: "<summary", options: [.caseInsensitive]),
              let sumOpenEnd = raw.range(of: ">", range: sumStart.upperBound..<raw.endIndex),
              let sumEnd = raw.range(of: "</summary>", options: [.caseInsensitive])
        else { return AttributedString("") }
        let titleSrc = String(raw[sumOpenEnd.upperBound..<sumEnd.lowerBound])
        return inlineParse(titleSrc)
    }

    // MARK: - Block conversion

    private static func convertBlock(_ markup: any Markup, indent: Int) -> [Block] {
        switch markup {
        case let heading as Heading:
            let level = max(1, min(3, heading.level))
            return [.heading(level: level, text: inlineToAttributed(Array(heading.inlineChildren)), indent: indent)]

        case let paragraph as Paragraph:
            let inlines = Array(paragraph.inlineChildren)
            if let subpage = detectSubpage(inlines) {
                return [subpage.withIndent(indent)]
            }
            return [.paragraph(text: inlineToAttributed(inlines), indent: indent)]

        case let blockQuote as BlockQuote:
            // Each paragraph child becomes a separate `.quote` block in our model.
            var out: [Block] = []
            for child in blockQuote.children {
                if let p = child as? Paragraph {
                    out.append(.quote(text: inlineToAttributed(Array(p.inlineChildren)), indent: indent))
                } else {
                    out.append(contentsOf: convertBlock(child, indent: indent))
                }
            }
            return out

        case let list as UnorderedList:
            return convertList(list, ordered: false, indent: indent)

        case let list as OrderedList:
            return convertList(list, ordered: true, indent: indent)

        case let codeBlock as CodeBlock:
            return [.code(source: codeBlock.code, language: codeBlock.language, indent: indent)]

        case _ as ThematicBreak:
            return [.divider(indent: indent)]

        case let html as HTMLBlock:
            // Toggle HTML blocks (<details>) are handled by `assemble`; any HTMLBlock that reaches
            // here is unrecognised — round-trip it as a paragraph of its raw source.
            return [.paragraph(text: AttributedString(html.rawHTML), indent: indent)]

        default:
            // Tables, images-as-blocks, and other unsupported nodes fall back to plain text.
            let plain = markup.format()
            if plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return []
            }
            return [.paragraph(text: AttributedString(plain), indent: indent)]
        }
    }

    // MARK: - Lists

    private static func convertList(_ list: any ListItemContainer, ordered: Bool, indent: Int) -> [Block] {
        var out: [Block] = []
        for child in list.children {
            guard let item = child as? ListItem else { continue }
            out.append(contentsOf: convertListItem(item, ordered: ordered, indent: indent))
        }
        return out
    }

    private static func convertListItem(_ item: ListItem, ordered: Bool, indent: Int) -> [Block] {
        // Extract leading paragraph text (the item's own line)
        var leadingText = AttributedString()
        var nested: [Block] = []
        for child in item.children {
            if let p = child as? Paragraph, leadingText.characters.isEmpty {
                leadingText = inlineToAttributed(Array(p.inlineChildren))
            } else if let nestedList = child as? UnorderedList {
                nested.append(contentsOf: convertList(nestedList, ordered: false, indent: indent + 1))
            } else if let nestedList = child as? OrderedList {
                nested.append(contentsOf: convertList(nestedList, ordered: true, indent: indent + 1))
            } else {
                nested.append(contentsOf: convertBlock(child, indent: indent + 1))
            }
        }

        let head: Block
        if let checkbox = item.checkbox {
            head = .todo(text: leadingText, done: checkbox == .checked, indent: indent)
        } else if ordered {
            head = .numbered(text: leadingText, indent: indent)
        } else {
            head = .bullet(text: leadingText, indent: indent)
        }
        return [head] + nested
    }

    // MARK: - Inline → AttributedString

    private static func inlineToAttributed(_ inlines: [any InlineMarkup]) -> AttributedString {
        var result = AttributedString()
        for inline in inlines {
            result.append(renderInline(inline, attributes: AttributeContainer()))
        }
        return result
    }

    private static func renderInline(_ inline: any InlineMarkup, attributes: AttributeContainer) -> AttributedString {
        switch inline {
        case let text as Markdown.Text:
            var s = AttributedString(text.string)
            s.mergeAttributes(attributes)
            return s

        case let strong as Strong:
            var attrs = attributes
            attrs.inlineBold = true
            return concat(strong.inlineChildren, attributes: attrs)

        case let emphasis as Emphasis:
            var attrs = attributes
            attrs.inlineItalic = true
            return concat(emphasis.inlineChildren, attributes: attrs)

        case let strike as Strikethrough:
            var attrs = attributes
            attrs.inlineStrikethrough = true
            return concat(strike.inlineChildren, attributes: attrs)

        case let code as InlineCode:
            var s = AttributedString(code.code)
            var attrs = attributes
            attrs.inlineCode = true
            s.mergeAttributes(attrs)
            return s

        case let link as Markdown.Link:
            var attrs = attributes
            if let dest = link.destination, let url = URL(string: dest) {
                attrs.link = url
            }
            return concat(link.inlineChildren, attributes: attrs)

        case _ as SoftBreak:
            return AttributedString(" ")

        case _ as LineBreak:
            return AttributedString("\n")

        case let inlineHTML as InlineHTML:
            var s = AttributedString(inlineHTML.rawHTML)
            s.mergeAttributes(attributes)
            return s

        default:
            // Images and other inline kinds: emit their plain text so nothing is silently dropped.
            var s = AttributedString(inline.format())
            s.mergeAttributes(attributes)
            return s
        }
    }

    private static func concat(_ inlines: some Sequence<any InlineMarkup>, attributes: AttributeContainer) -> AttributedString {
        var result = AttributedString()
        for inline in inlines {
            result.append(renderInline(inline, attributes: attributes))
        }
        return result
    }

    // MARK: - Subpage detection

    private static func detectSubpage(_ inlines: [any InlineMarkup]) -> Block? {
        // A paragraph is treated as a subpage if it contains exactly one link whose
        // destination ends in `.md` and there is no other meaningful text around it.
        var link: Markdown.Link?
        for inline in inlines {
            switch inline {
            case let l as Markdown.Link:
                guard link == nil else { return nil }
                link = l
            case let t as Markdown.Text where t.string.trimmingCharacters(in: .whitespaces).isEmpty:
                continue
            case _ as SoftBreak, _ as LineBreak:
                continue
            default:
                return nil
            }
        }
        guard let link, let dest = link.destination, dest.hasSuffix(".md") else { return nil }
        let titleParts: [String] = Array(link.inlineChildren).compactMap { ($0 as? Markdown.Text)?.string }
        let title = titleParts.joined()
        return .subpage(title: title.isEmpty ? dest : title, path: dest)
    }

    private static func inlineParse(_ source: String) -> AttributedString {
        let doc = Markdown.Document(parsing: source)
        if let p = doc.children.first(where: { $0 is Paragraph }) as? Paragraph {
            return inlineToAttributed(Array(p.inlineChildren))
        }
        return AttributedString(source)
    }
}

// MARK: - Custom inline attributes

public enum InlineAttributes {
    public enum BoldAttribute: AttributedStringKey {
        public typealias Value = Bool
        public static let name = "Console.Bold"
    }
    public enum ItalicAttribute: AttributedStringKey {
        public typealias Value = Bool
        public static let name = "Console.Italic"
    }
    public enum CodeAttribute: AttributedStringKey {
        public typealias Value = Bool
        public static let name = "Console.InlineCode"
    }
    public enum StrikethroughAttribute: AttributedStringKey {
        public typealias Value = Bool
        public static let name = "Console.Strikethrough"
    }
}

public extension AttributeContainer {
    var inlineBold: Bool? {
        get { self[InlineAttributes.BoldAttribute.self] }
        set { self[InlineAttributes.BoldAttribute.self] = newValue }
    }
    var inlineItalic: Bool? {
        get { self[InlineAttributes.ItalicAttribute.self] }
        set { self[InlineAttributes.ItalicAttribute.self] = newValue }
    }
    var inlineCode: Bool? {
        get { self[InlineAttributes.CodeAttribute.self] }
        set { self[InlineAttributes.CodeAttribute.self] = newValue }
    }
    var inlineStrikethrough: Bool? {
        get { self[InlineAttributes.StrikethroughAttribute.self] }
        set { self[InlineAttributes.StrikethroughAttribute.self] = newValue }
    }
}
