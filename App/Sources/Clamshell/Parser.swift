import Foundation
import Quagmire
import Markdown

enum BlockParser {
    /// ASCII-only whitespace — used in `flushRegular` so that NBSP-only buffers
    /// (the empty-paragraph spacer marker) fall through to swift-markdown rather
    /// than being skipped. Foundation's `.whitespacesAndNewlines` includes U+00A0.
    private static let asciiWhitespace = CharacterSet(charactersIn: " \t\r\n")

    /// Parse a markdown source into a tree-shaped block list. The pipeline is:
    /// 1. `parseTemplateContainers` — lifts `:::{template-button}` envelopes and
    ///    nests their bodies as `children`.
    /// 2. `parseToggleContainers` — lifts `▸ Title` toggle envelopes and nests
    ///    their bodies as `children`.
    /// 3. `parseMarkdown` → swift-markdown → `assemble` → `convertBlock` —
    ///    list items keep their nested children directly (no flattening).
    /// 4. `foldHeadings` — post-pass that collapses sibling sequences of
    ///    `[heading, …, heading, …]` into a tree where each heading owns the
    ///    blocks until the next heading at the same or higher level.
    static func parse(_ source: String) -> [Block] {
        let templated = parseTemplateContainers(source)
        return foldHeadings(templated)
    }

    private static func parseMarkdown(_ source: String) -> [Block] {
        // swift-markdown's `Markup.range` indexes into exactly the string handed
        // to the parser, so the *marked* source is what an unsupported block's
        // payload must be sliced from — not the caller's original.
        let marked = markingEmptyParagraphs(in: source)
        let document = Markdown.Document(parsing: marked, options: [.parseBlockDirectives])
        let children = Array(document.children)
        return assemble(children, source: SourceSlicer(marked)).blocks
    }

    /// Lets an unhandled node be carried through byte for byte.
    ///
    /// The alternative, and what this used to do, is `markup.format()` — but
    /// that re-renders from the AST, normalising pipe alignment, emphasis
    /// delimiters, escaping and wrapping. Round-tripping someone's table
    /// through a reformatter is better than dropping it, and worse than not
    /// touching it. `Markup.range` is populated during parsing and gives us the
    /// third option.
    ///
    /// Slicing is by whole lines. Every construct that reaches the unsupported
    /// path is block-level and line-aligned, and lines sidestep the question of
    /// what a `SourceLocation` column counts.
    struct SourceSlicer {
        private let lines: [String]

        init(_ source: String) {
            lines = source.components(separatedBy: "\n")
        }

        /// The exact source of `markup`, or nil when it carries no range (a node
        /// built programmatically rather than parsed).
        func slice(_ markup: any Markup) -> String? {
            guard let range = markup.range else { return nil }
            let first = range.lowerBound.line - 1
            // An end column of 1 means the range stops at the start of that
            // line, so the line itself is not part of the node.
            var last = range.upperBound.line - 1
            if range.upperBound.column <= 1 { last -= 1 }
            guard first >= 0, last >= first, last < lines.count else { return nil }
            let slice = lines[first...last].joined(separator: "\n")
            return slice.isEmpty ? nil : slice
        }
    }

    /// Short neutral label for a node this editor has no model for. Shown on the
    /// row so it reads as "there is a table here", not as broken text.
    private static func unsupportedLabel(for markup: any Markup) -> String {
        switch markup {
        case is Table: return "Table"
        case is HTMLBlock: return "HTML"
        case let directive as BlockDirective: return "Directive: \(directive.name)"
        case is BlockQuote: return "Block quote"
        default: return String(describing: type(of: markup))
        }
    }

    /// Wrap an unhandled node, preferring its exact source. Falls back to the
    /// reformatted text when the node has no range, which keeps the content
    /// rather than dropping it — the old behaviour, now only a fallback.
    private static func unsupportedBlock(_ markup: any Markup, source: SourceSlicer) -> [Block] {
        let payload = source.slice(markup) ?? markup.format()
        guard !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return [.unsupported(payload: payload, display: unsupportedLabel(for: markup))]
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
    /// indent." Body is dedented one indent unit (2 spaces) and recursively parsed.
    /// Toggle's body becomes its `children`.
    ///
    /// Fenced code blocks (``` `` ```) are treated as opaque both in the outer scan and in
    /// the body-extent scan, so a `▸ ` line inside fenced code is not lifted, and a code
    /// line outdented to column 0 inside the toggle's body code fence does not terminate
    /// the body.
    private static func parseToggleContainers(_ source: String) -> [Block] {
        let lines = splitPreservingLineEndings(source)
        var out: [Block] = []
        var regular = ""
        var i = 0
        var fenceLength: Int? = nil

        func flushRegular() {
            guard !regular.trimmingCharacters(in: BlockParser.asciiWhitespace).isEmpty else {
                regular = ""
                return
            }
            appendRegularBlocks(from: regular, into: &out)
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

            // Recursively parse the toggle body with the full pipeline so nested
            // toggles, templates, and headings within the body all fold correctly.
            let body = parse(bodySource)
            let toggle = Block.toggle(title: inlineParse(open.title), children: body)
            if open.leadingSpaces > 0,
               appendToLastContainer(&out, atDepth: parentDepth(forChildLeadingSpaces: open.leadingSpaces), child: toggle) {
                // attached to the list/toggle/template container it was indented under
            } else {
                out.append(toggle)
            }
            appendEmptyParagraphsFromTrailingBlankLines(
                j - bodyEnd,
                beforeNextLine: j < lines.count ? lines[j].text : nil,
                into: &out
            )

            i = j
        }

        flushRegular()
        return out
    }

    private static func appendRegularBlocks(from source: String, into out: inout [Block]) {
        let lines = splitPreservingLineEndings(source)
        var i = 0

        while i < lines.count {
            while i < lines.count, isBlankMarkdownLine(lines[i].text) {
                i += 1
            }
            guard i < lines.count else { break }

            let leading = lines[i].text.prefix { $0 == " " }.count
            if leading == 0 {
                let chunk = lines[i..<lines.count].map(\.fullText).joined()
                out.append(contentsOf: parseMarkdown(chunk))
                break
            }

            let start = i
            i += 1
            var fenceLength: Int? = openingFenceLength(lines[start].text)
            while i < lines.count {
                let text = lines[i].text
                if let f = fenceLength {
                    if isClosingFence(text, expectedLength: f) { fenceLength = nil }
                    i += 1
                    continue
                }
                if let len = openingFenceLength(text) {
                    fenceLength = len
                    i += 1
                    continue
                }
                if isBlankMarkdownLine(text) {
                    i += 1
                    continue
                }
                let here = text.prefix { $0 == " " }.count
                if here < leading { break }
                i += 1
            }

            let stripped = lines[start..<i]
                .map { stripLeadingSpaces(leading, from: $0.fullText) }
                .joined()
            let blocks = parseMarkdown(stripped)
            let parentDepth = parentDepth(forChildLeadingSpaces: leading)
            for block in blocks {
                if appendToLastContainer(&out, atDepth: parentDepth, child: block) {
                    continue
                }
                out.append(block)
            }
        }
    }

    private static func parentDepth(forChildLeadingSpaces spaces: Int) -> Int {
        max(0, spaces / 2 - 1)
    }

    private static func appendToLastContainer(_ blocks: inout [Block], atDepth depth: Int, child: Block) -> Bool {
        guard !blocks.isEmpty else { return false }
        let index = blocks.index(before: blocks.endIndex)
        if depth == 0 {
            guard blocks[index].canContain(child) else { return false }
            blocks[index].children.append(child)
            return true
        }
        return appendToLastContainer(&blocks[index].children, atDepth: depth - 1, child: child)
    }

    private static func appendEmptyParagraphsFromTrailingBlankLines(_ blankLineCount: Int, beforeNextLine nextLine: String?, into out: inout [Block]) {
        guard let nextLine, blankLineCount > 1 else { return }
        let emptyCount = blankLineCount - 1
        let nextLeading = nextLine.prefix { $0 == " " }.count
        for _ in 0..<emptyCount {
            let empty = Block.paragraph(text: AttributedString(""))
            if nextLeading > 0,
               appendToLastContainer(&out, atDepth: parentDepth(forChildLeadingSpaces: nextLeading), child: empty) {
                continue
            }
            out.append(empty)
        }
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

    /// CommonMark discards blank lines, but Hunch has a real empty-paragraph
    /// block. Treat a single blank line as ordinary markdown separation and
    /// each additional blank line in the same run as one empty paragraph.
    /// The injected NBSP marker reuses the legacy empty-paragraph parser path
    /// while keeping newly serialized files free of visible NBSP rows.
    private static func markingEmptyParagraphs(in source: String) -> String {
        let lines = splitPreservingLineEndings(source)
        guard !lines.isEmpty else { return source }

        var out = ""
        var i = 0
        var fenceLength: Int? = nil
        var sawNonBlank = false

        while i < lines.count {
            let line = lines[i]

            if let f = fenceLength {
                if isClosingFence(line.text, expectedLength: f) { fenceLength = nil }
                out += line.fullText
                i += 1
                continue
            }

            if let len = openingFenceLength(line.text) {
                fenceLength = len
                sawNonBlank = true
                out += line.fullText
                i += 1
                continue
            }

            if isBlankMarkdownLine(line.text) {
                let start = i
                while i < lines.count, isBlankMarkdownLine(lines[i].text) {
                    i += 1
                }

                let count = i - start
                let hasNonBlankAfter = i < lines.count
                if sawNonBlank, hasNonBlankAfter, count > 1 {
                    out += lines[start].fullText
                    let markerIndent = leadingSpaces(in: lines[i].text)
                    for _ in 1..<count {
                        out += markerIndent + "\u{00A0}\n\n"
                    }
                } else {
                    out += lines[start..<i].map(\.fullText).joined()
                }
                continue
            }

            sawNonBlank = true
            out += line.fullText
            i += 1
        }

        return out
    }

    private static func isBlankMarkdownLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r")).isEmpty
    }

    private static func leadingSpaces(in line: String) -> String {
        String(line.prefix { $0 == " " })
    }

    private static func parseTemplateContainers(_ source: String) -> [Block] {
        let lines = splitPreservingLineEndings(source)
        var out: [Block] = []
        var regular = ""
        var i = 0

        func flushRegular() {
            guard !regular.trimmingCharacters(in: BlockParser.asciiWhitespace).isEmpty else {
                regular = ""
                return
            }
            out.append(contentsOf: parseToggleContainers(regular))
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

            let bodySource = bodyLines
                .map { stripLeadingSpaces(open.leadingSpaces, from: $0.fullText) }
                .joined()
            // Recursively run the full pipeline so nested toggles and headings
            // inside the body fold correctly.
            let body = parse(bodySource)
            out.append(.templateButton(label: open.label, children: body))
        }

        flushRegular()
        return out
    }

    /// Heading-fold post-pass. Takes a flat sibling sequence emitted by the
    /// markdown stage and folds each heading's "body" (subsequent blocks until
    /// the next heading at same-or-higher level) into the heading's `children`.
    /// Run recursively on every container's children list so headings inside
    /// toggles / template-buttons organize their bodies without escaping.
    private static func foldHeadings(_ blocks: [Block]) -> [Block] {
        // First, recurse into any container's children. We must fold headings
        // *inside* containers before folding at the current scope, because a
        // toggle's body can contain its own heading hierarchy.
        let recursed: [Block] = blocks.map { block in
            switch block.kind {
            case .heading, .toggle, .templateButton, .bullet, .numbered, .todo:
                return block.withChildren(foldHeadings(block.children))
            default:
                return block
            }
        }

        var rootChildren: [Block] = []
        // Stack of (heading, level) pairs — the heading mutates as we accrue
        // body children. We carry the heading by VALUE on the stack and
        // reattach to its parent when popped.
        var stack: [(block: Block, level: HeadingLevel)] = []

        func appendChild(_ child: Block) {
            if stack.isEmpty {
                rootChildren.append(child)
            } else {
                stack[stack.count - 1].block.children.append(child)
            }
        }

        func popOne() {
            let popped = stack.removeLast()
            if stack.isEmpty {
                rootChildren.append(popped.block)
            } else {
                stack[stack.count - 1].block.children.append(popped.block)
            }
        }

        for block in recursed {
            if case .heading(let level, _) = block.kind {
                while let top = stack.last, top.level.rawValue >= level.rawValue {
                    popOne()
                }
                stack.append((block: block, level: level))
            } else {
                appendChild(block)
            }
        }
        while !stack.isEmpty { popOne() }
        return rootChildren
    }

    private static func assemble(_ nodes: [any Markup], source: SourceSlicer) -> (blocks: [Block], consumed: Int) {
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
                let inner = assemble(children, source: source).blocks
                out.append(.toggle(title: title, children: inner))
                i = j + 1   // skip past closing </details>
                continue
            }
            out.append(contentsOf: convertBlock(node, source: source))
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

    private static func convertBlock(_ markup: any Markup, source: SourceSlicer) -> [Block] {
        switch markup {
        case let heading as Heading:
            return [.heading(level: heading.level, text: inlineToAttributed(Array(heading.inlineChildren)))]

        case let paragraph as Paragraph:
            let inlines = Array(paragraph.inlineChildren)
            if let subpage = detectSubpage(inlines) {
                return [subpage]
            }
            if let image = detectBlockImage(inlines) {
                return [image]
            }
            let attr = inlineToAttributed(inlines)
            if isEmptySpacerParagraph(attr) {
                return [.paragraph(text: AttributedString(""))]
            }
            return [.paragraph(text: attr)]

        case let blockQuote as BlockQuote:
            // Each paragraph child becomes a separate `.quote` block in our model.
            var out: [Block] = []
            for child in blockQuote.children {
                if let p = child as? Paragraph {
                    out.append(.quote(text: inlineToAttributed(Array(p.inlineChildren))))
                } else {
                    out.append(contentsOf: convertBlock(child, source: source))
                }
            }
            return out

        case let list as UnorderedList:
            return convertList(list, ordered: false, source: source)

        case let list as OrderedList:
            return convertList(list, ordered: true, source: source)

        case let codeBlock as CodeBlock:
            return [.code(source: codeBlock.code, language: codeBlock.language)]

        case _ as ThematicBreak:
            return [.divider()]

        case is HTMLBlock:
            // Toggle HTML blocks (<details>) are handled by `assemble`; any
            // HTMLBlock reaching here is unrecognised, so it is carried through
            // untouched rather than flattened into a paragraph of raw source
            // that the serializer would then escape.
            return unsupportedBlock(markup, source: source)

        case let directive as BlockDirective:
            if directive.name == "template-button" {
                let label = directive.argumentText.segments
                    .map(\.untrimmedText)
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let body = assemble(Array(directive.children), source: source).blocks
                return [.templateButton(label: label, children: body)]
            }
            return unsupportedBlock(markup, source: source)

        default:
            // Tables and anything else this editor has no model for are carried
            // through verbatim. Flattening them into a paragraph lost them on
            // the next save, because the serializer has no way to tell a
            // paragraph that happens to contain pipes from a table.
            return unsupportedBlock(markup, source: source)
        }
    }

    // MARK: - Lists

    private static func convertList(_ list: any ListItemContainer, ordered: Bool, source: SourceSlicer) -> [Block] {
        var out: [Block] = []
        for child in list.children {
            guard let item = child as? ListItem else { continue }
            out.append(contentsOf: convertListItem(item, ordered: ordered, source: source))
        }
        return out
    }

    private static func convertListItem(_ item: ListItem, ordered: Bool, source: SourceSlicer) -> [Block] {
        // Extract leading paragraph text (the item's own line)
        var leadingText = AttributedString()
        var nested: [Block] = []
        for child in item.children {
            if let p = child as? Paragraph, leadingText.characters.isEmpty {
                var inlines = Array(p.inlineChildren)
                // Heal pre-fix files: serializers before the blank-line fix
                // emitted `- text\n  [Sub](sub.md)\n`, which CommonMark folds
                // into one paragraph via softbreak. Peel a trailing softbreak +
                // `.md` link off and restore it as a `.subpage` child.
                if let recovered = peelTrailingSubpage(&inlines) {
                    nested.append(recovered)
                }
                leadingText = inlineToAttributed(inlines)
            } else if let nestedList = child as? UnorderedList {
                nested.append(contentsOf: convertList(nestedList, ordered: false, source: source))
            } else if let nestedList = child as? OrderedList {
                nested.append(contentsOf: convertList(nestedList, ordered: true, source: source))
            } else {
                nested.append(contentsOf: convertBlock(child, source: source))
            }
        }

        let head: Block
        if let checkbox = item.checkbox {
            head = .todo(text: leadingText, done: checkbox == .checked, children: nested)
        } else if ordered {
            head = .numbered(text: leadingText, children: nested)
        } else {
            head = .bullet(text: leadingText, children: nested)
        }
        return [head]
    }

    // MARK: - Inline → AttributedString

    private static func inlineToAttributed(_ inlines: [any InlineMarkup]) -> AttributedString {
        var result = AttributedString()
        for inline in inlines {
            result.append(renderInline(inline, attributes: AttributeContainer()))
        }
        return autoLinkBareURLs(in: result)
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

    // MARK: - Empty-paragraph spacer detection

    /// Recognise a paragraph whose only character is U+00A0 — the marker
    /// `BlockSerializer` emits for empty paragraphs. CommonMark has no syntax
    /// for blank-line *content*, so this round-trips intentional empty paragraphs
    /// the user inserted between siblings.
    private static func isEmptySpacerParagraph(_ attr: AttributedString) -> Bool {
        let chars = attr.characters
        guard chars.count == 1, let first = chars.first else { return false }
        return first == "\u{00A0}"
    }

    // MARK: - Subpage detection

    /// Pop a trailing `<softbreak | linebreak><[…](path.md)>` pair off the end
    /// of a list-item's leading paragraph and return it as a `.subpage` block.
    /// Used to recover bullet+subpage structure from files written by the
    /// pre-blank-line serializer, where the indented subpage line got folded
    /// into the bullet's paragraph via CommonMark lazy continuation.
    private static func peelTrailingSubpage(_ inlines: inout [any InlineMarkup]) -> Block? {
        guard inlines.count >= 2,
              inlines[inlines.count - 2] is SoftBreak || inlines[inlines.count - 2] is LineBreak,
              let link = inlines.last as? Markdown.Link,
              let dest = link.destination, isSubpageDestination(dest)
        else { return nil }
        let titleParts: [String] = Array(link.inlineChildren).compactMap { ($0 as? Markdown.Text)?.string }
        let title = titleParts.joined()
        inlines.removeLast(2)
        return .subpage(title: title.isEmpty ? dest : title, pageID: dest)
    }

    /// A subpage destination is a `.md` path, optionally carrying a page-ID
    /// fragment (`page.md#x7f3q2`). Other fragments belong to external
    /// targets and don't make the link a subpage.
    private static func isSubpageDestination(_ dest: String) -> Bool {
        ClamshellPageEnvelope.splitPageFragment(dest).path.hasSuffix(".md")
    }

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
        guard let link, let dest = link.destination, isSubpageDestination(dest) else { return nil }
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
