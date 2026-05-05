import Foundation
import Editor
import Markdown

public enum BlockParser {
    public static func parse(_ source: String) -> [Block] {
        parseTemplateContainers(source, baseIndent: 0)
    }

    private static func parseMarkdown(_ source: String, baseIndent: Int) -> [Block] {
        let document = Markdown.Document(parsing: source, options: [.parseBlockDirectives])
        let children = Array(document.children)
        return assemble(children, indent: 0).blocks.map { $0.withIndent($0.indent + baseIndent) }
    }

    private struct SourceLine {
        let text: String
        let terminator: String

        var fullText: String { text + terminator }
    }

    private struct TemplateOpen {
        let fence: String
        let label: String
        let leadingSpaces: Int
    }

    private struct ToggleOpen {
        let leadingSpaces: Int
        let title: String
    }

    /// Pre-parse pass for `▸ Title` toggles. Lifts toggle paragraphs out of the source by
    /// indent — body extent is "subsequent lines blank OR indented strictly more than the
    /// toggle's leading spaces, stopping at the first non-blank line at-or-below that
    /// indent." Body is dedented one indent unit (2 spaces) and recursively parsed at
    /// `toggleIndent + 1`. Non-toggle text is passed to `parseMarkdown` (terminator);
    /// toggle body recurses through `parseTemplateContainers` so a `:::` template inside
    /// a toggle body is recognised.
    ///
    /// Fenced code blocks (``` `` ```) are treated as opaque both in the outer scan and in
    /// the body-extent scan, so a `▸ ` line inside fenced code is not lifted, and a code
    /// line outdented to column 0 inside the toggle's body code fence does not terminate
    /// the body.
    private static func parseToggleContainers(_ source: String, baseIndent: Int) -> [Block] {
        let lines = splitPreservingLineEndings(source)
        var out: [Block] = []
        var regular = ""
        var i = 0
        var fenceLength: Int? = nil

        func flushRegular() {
            guard !regular.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                regular = ""
                return
            }
            out.append(contentsOf: parseMarkdown(regular, baseIndent: baseIndent))
            regular = ""
        }

        while i < lines.count {
            let lineText = lines[i].text

            if let f = fenceLength {
                if isClosingFence(lineText, expectedLength: f) { fenceLength = nil }
                regular += lines[i].fullText
                i += 1
                continue
            }
            if let len = openingFenceLength(lineText) {
                fenceLength = len
                regular += lines[i].fullText
                i += 1
                continue
            }

            guard let open = parseToggleOpen(lineText) else {
                regular += lines[i].fullText
                i += 1
                continue
            }

            flushRegular()

            let toggleIndent = baseIndent + (open.leadingSpaces / 2)

            var j = i + 1
            var bodyFence: Int? = nil
            while j < lines.count {
                let bl = lines[j].text
                if let f = bodyFence {
                    if isClosingFence(bl, expectedLength: f) { bodyFence = nil }
                    j += 1
                    continue
                }
                let trimmed = bl.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    j += 1
                    continue
                }
                let leadingHere = bl.prefix { $0 == " " }.count
                if leadingHere <= open.leadingSpaces { break }
                if let len = openingFenceLength(bl) { bodyFence = len }
                j += 1
            }

            var bodyEnd = j
            while bodyEnd > i + 1 {
                let prev = lines[bodyEnd - 1].text.trimmingCharacters(in: .whitespaces)
                if prev.isEmpty { bodyEnd -= 1 } else { break }
            }

            let bodySource = lines[(i + 1)..<bodyEnd]
                .map { stripLeadingSpaces(open.leadingSpaces + 2, from: $0.fullText) }
                .joined()

            let body = parseTemplateContainers(bodySource, baseIndent: toggleIndent + 1)
            out.append(.toggle(title: inlineParse(open.title), indent: toggleIndent))
            out.append(contentsOf: body)

            i = j
        }

        flushRegular()
        return out
    }

    private static func parseToggleOpen(_ line: String) -> ToggleOpen? {
        let leading = line.prefix { $0 == " " }.count
        let trimmed = line.dropFirst(leading)
        guard trimmed.hasPrefix("▸ ") else { return nil }
        let title = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        return ToggleOpen(leadingSpaces: leading, title: title)
    }

    private static func openingFenceLength(_ line: String) -> Int? {
        let trimmed = line.drop { $0 == " " }
        var count = 0
        for ch in trimmed {
            if ch == "`" { count += 1 } else { break }
        }
        return count >= 3 ? count : nil
    }

    private static func isClosingFence(_ line: String, expectedLength: Int) -> Bool {
        let trimmed = line.drop { $0 == " " }
        var count = 0
        for ch in trimmed {
            if ch == "`" { count += 1 } else { break }
        }
        if count < expectedLength { return false }
        return trimmed.dropFirst(count).allSatisfy { $0 == " " }
    }

    private static func parseTemplateContainers(_ source: String, baseIndent: Int) -> [Block] {
        let lines = splitPreservingLineEndings(source)
        var out: [Block] = []
        var regular = ""
        var i = 0

        func flushRegular() {
            guard !regular.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                regular = ""
                return
            }
            out.append(contentsOf: parseToggleContainers(regular, baseIndent: baseIndent))
            regular = ""
        }

        while i < lines.count {
            guard let open = parseTemplateOpen(lines[i].text) else {
                regular += lines[i].fullText
                i += 1
                continue
            }

            flushRegular()
            let closeIndex = findTemplateClose(in: lines, start: i + 1, fenceLength: open.fence.count)
            let bodyLines: ArraySlice<SourceLine>
            if let closeIndex {
                bodyLines = lines[(i + 1)..<closeIndex]
                i = closeIndex + 1
            } else {
                bodyLines = lines[(i + 1)..<lines.count]
                i = lines.count
            }

            let blockIndent = baseIndent + (open.leadingSpaces / 2)
            let bodySource = bodyLines
                .map { stripLeadingSpaces(open.leadingSpaces, from: $0.fullText) }
                .joined()
            let body = parseToggleContainers(bodySource, baseIndent: blockIndent + 1)
            out.append(.templateButton(label: open.label, indent: blockIndent))
            out.append(contentsOf: body)
        }

        flushRegular()
        return out
    }

    /// Legacy `<details>` parser — retained for files written before the `▸ Title`
    /// serialization. The serializer no longer emits `<details>`, but workspaces that
    /// predate the change still contain HTML-toggle envelopes; this pass continues to
    /// parse them so existing files load. **Do not delete** — files convert lazily on
    /// next save.
    ///
    /// Walks a sibling list of markup nodes, lifting `<details>...</details>` runs into
    /// a `.toggle` marker followed by the body blocks at `indent + 1`. cmark-gfm closes an
    /// HTML block at a blank line, so a real-world `<details>` toggle with markdown children
    /// parses as: HTMLBlock(`<details>...<summary>`), then inner markdown nodes, then
    /// HTMLBlock(`</details>`). This pass pairs the open/close tags so the inner blocks land
    /// as flat siblings whose section (via `Document.sectionRange`) is the toggle's body.
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
                let inner = assemble(children, indent: indent + 1).blocks
                out.append(.toggle(title: title, indent: indent))
                out.append(contentsOf: inner)
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
            if let image = detectBlockImage(inlines) {
                return [image.withIndent(indent)]
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

        case let directive as BlockDirective:
            if directive.name == "template-button" {
                let label = directive.argumentText.segments
                    .map(\.untrimmedText)
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let body = assemble(Array(directive.children), indent: indent + 1).blocks
                return [.templateButton(label: label, indent: indent)] + body
            }
            return [.paragraph(text: AttributedString(directive.format()), indent: indent)]

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
        return .subpage(title: title.isEmpty ? dest : title, pageID: dest)
    }

    // MARK: - Block image detection

    /// Recognise a paragraph whose only meaningful content is a single `![alt](src)`
    /// image as a block-level `.image`. Inline images that share a paragraph with
    /// other text fall through to the inline-fallback path in `renderInline` and
    /// stay as plain markdown — Hunch has no inline-image concept.
    private static func detectBlockImage(_ inlines: [any InlineMarkup]) -> Block? {
        var image: Markdown.Image?
        for inline in inlines {
            switch inline {
            case let img as Markdown.Image:
                guard image == nil else { return nil }
                image = img
            case let t as Markdown.Text where t.string.trimmingCharacters(in: .whitespaces).isEmpty:
                continue
            case _ as SoftBreak, _ as LineBreak:
                continue
            default:
                return nil
            }
        }
        guard let image, let source = image.source, !source.isEmpty else { return nil }
        let altParts: [String] = Array(image.inlineChildren).compactMap { ($0 as? Markdown.Text)?.string }
        return .image(source: source, alt: altParts.joined())
    }

    private static func inlineParse(_ source: String) -> AttributedString {
        let doc = Markdown.Document(parsing: source)
        if let p = doc.children.first(where: { $0 is Paragraph }) as? Paragraph {
            return inlineToAttributed(Array(p.inlineChildren))
        }
        return AttributedString(source)
    }

    private static func splitPreservingLineEndings(_ source: String) -> [SourceLine] {
        var lines: [SourceLine] = []
        var start = source.startIndex
        var i = source.startIndex
        while i < source.endIndex {
            if source[i] == "\n" {
                lines.append(SourceLine(text: String(source[start..<i]), terminator: "\n"))
                i = source.index(after: i)
                start = i
            } else {
                i = source.index(after: i)
            }
        }
        if start < source.endIndex {
            lines.append(SourceLine(text: String(source[start..<source.endIndex]), terminator: ""))
        }
        return lines
    }

    private static func parseTemplateOpen(_ line: String) -> TemplateOpen? {
        let leading = line.prefix { $0 == " " }.count
        let trimmed = line.dropFirst(leading)
        var fenceLength = 0
        for char in trimmed {
            guard char == ":" else { break }
            fenceLength += 1
        }
        guard fenceLength >= 3 else { return nil }
        let afterFence = trimmed.dropFirst(fenceLength)
        guard afterFence.hasPrefix("{template-button}") else { return nil }
        let label = afterFence
            .dropFirst("{template-button}".count)
            .trimmingCharacters(in: .whitespaces)
        return TemplateOpen(fence: String(repeating: ":", count: fenceLength), label: label, leadingSpaces: leading)
    }

    private static func findTemplateClose(in lines: [SourceLine], start: Int, fenceLength: Int) -> Int? {
        var i = start
        while i < lines.count {
            let trimmed = lines[i].text.trimmingCharacters(in: .whitespaces)
            if trimmed.count >= fenceLength && trimmed.allSatisfy({ $0 == ":" }) {
                return i
            }
            i += 1
        }
        return nil
    }

    private static func stripLeadingSpaces(_ count: Int, from line: String) -> String {
        guard count > 0 else { return line }
        var remaining = count
        var index = line.startIndex
        while remaining > 0, index < line.endIndex, line[index] == " " {
            index = line.index(after: index)
            remaining -= 1
        }
        return String(line[index...])
    }
}

