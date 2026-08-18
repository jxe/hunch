import Foundation
import CryptoKit
import Quagmire

enum ClamshellPageEnvelope {
    static let frontmatterKey = "clamshell"
    static let idKey = "clamshell-id"

    /// Page IDs are 6 chars of [a-z0-9]. The exact length matters: subpage
    /// detection treats `page.md#<id>` as an internal link only when the
    /// fragment has this exact shape, so a genuine section anchor like
    /// `#introduction` on an external `.md` link doesn't false-positive.
    static let pageIDLength = 6
    private static let pageIDAlphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")

    static func mintPageID() -> String {
        String((0..<pageIDLength).map { _ in pageIDAlphabet.randomElement()! })
    }

    static func isValidPageID(_ candidate: some StringProtocol) -> Bool {
        candidate.count == pageIDLength && candidate.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber) }
    }

    /// Split a link destination into its path part and a trailing page-ID
    /// fragment, when one is present. Fragments that don't have the page-ID
    /// shape stay attached to the path (they belong to whatever external
    /// target the link points at).
    static func splitPageFragment(_ dest: String) -> (path: String, id: String?) {
        guard let hash = dest.lastIndex(of: "#") else { return (dest, nil) }
        let fragment = dest[dest.index(after: hash)...]
        guard isValidPageID(fragment) else { return (dest, nil) }
        return (String(dest[..<hash]), String(fragment))
    }

    static func pageID(in frontmatterLines: [String]?) -> String? {
        guard let frontmatterLines else { return nil }
        for line in frontmatterLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\(idKey):") else { continue }
            let value = String(trimmed.dropFirst(idKey.count + 1)).trimmingCharacters(in: .whitespaces)
            return isValidPageID(value) ? value : nil
        }
        return nil
    }

    /// Add a `clamshell-id` line when none exists. Serialization preserves
    /// every non-stamp frontmatter line, so the ID survives all later saves
    /// without further handling.
    static func addingPageID(_ id: String, to frontmatterLines: [String]?) -> [String] {
        var lines = frontmatterLines ?? []
        guard pageID(in: lines) == nil else { return lines }
        lines.append("\(idKey): \(id)")
        return lines
    }

    struct Stamp: Codable, Equatable, Sendable {
        let v: Int
        let bodyHash: String
        let logFrontier: [String: UInt64]

        init(bodyHash: String, logFrontier: [String: UInt64]) {
            self.v = 1
            self.bodyHash = bodyHash
            self.logFrontier = logFrontier
        }
    }

    enum StampTrust: Equatable, Sendable {
        case none
        case trusted([String: UInt64])
        case invalid

        var trustedFrontier: [String: UInt64]? {
            if case .trusted(let frontier) = self { return frontier }
            return nil
        }
    }

    struct Parsed: Sendable {
        let body: String
        let blocks: [Block]
        let frontmatterLines: [String]?
        let stampTrust: StampTrust
        let pageID: String?
    }

    static func parse(_ source: String) -> Parsed {
        let split = splitFrontmatter(source)
        let blocks = BlockParser.parse(split.body)
        let trust = stampTrust(from: split.frontmatterLines, canonicalBody: BlockSerializer.serialize(blocks))
        return Parsed(
            body: split.body,
            blocks: blocks,
            frontmatterLines: split.frontmatterLines,
            stampTrust: trust,
            pageID: pageID(in: split.frontmatterLines)
        )
    }

    static func bodyHash(for body: String) -> String {
        let digest = SHA256.hash(data: Data(body.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    static func serialize(
        blocks: [Block],
        existingFrontmatterLines: [String]?,
        logFrontier: [String: UInt64],
        resolvingSubpageTitle titleForPath: (String) -> String? = { _ in nil }
    ) -> String {
        let body = BlockSerializer.serialize(blocks, resolvingSubpageTitle: titleForPath)
        let stamp = Stamp(bodyHash: bodyHash(for: body), logFrontier: logFrontier)
        let stampLine = "\(frontmatterKey): \(encodeStamp(stamp))"
        let lines = replacingClamshellLine(in: existingFrontmatterLines ?? [], with: stampLine)
        guard !lines.isEmpty else { return body }
        return "---\n" + lines.joined(separator: "\n") + "\n---\n" + body
    }

    private static func splitFrontmatter(_ source: String) -> (frontmatterLines: [String]?, body: String) {
        guard source.hasPrefix("---\n") || source.hasPrefix("---\r\n") else {
            return (nil, source)
        }
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        guard !lines.isEmpty, lines[0].trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            return (nil, source)
        }
        for i in 1..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
                let frontmatter = lines[1..<i].map { String($0).trimmingSuffix("\r") }
                let bodyStart = source.index(afterLine: i + 1)
                return (frontmatter, String(source[bodyStart...]))
            }
        }
        return (nil, source)
    }

    private static func stampTrust(from frontmatterLines: [String]?, canonicalBody: String) -> StampTrust {
        guard let frontmatterLines else { return .none }
        guard let rawValue = clamshellValue(in: frontmatterLines) else { return .none }
        guard let stamp = decodeStamp(rawValue),
              stamp.v == 1,
              stamp.bodyHash == bodyHash(for: canonicalBody) else {
            return .invalid
        }
        return .trusted(stamp.logFrontier)
    }

    private static func clamshellValue(in lines: [String]) -> String? {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\(frontmatterKey):") else { continue }
            return String(trimmed.dropFirst(frontmatterKey.count + 1)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func encodeStamp(_ stamp: Stamp) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(stamp),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private static func decodeStamp(_ text: String) -> Stamp? {
        try? JSONDecoder().decode(Stamp.self, from: Data(text.utf8))
    }

    private static func replacingClamshellLine(in lines: [String], with replacement: String) -> [String] {
        var out: [String] = []
        var didInsert = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\(frontmatterKey):") else {
                out.append(line)
                continue
            }
            if !didInsert {
                out.append(replacement)
                didInsert = true
            }
        }
        if !didInsert {
            out.append(replacement)
        }
        return out
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }

    func index(afterLine lineCount: Int) -> Index {
        var index = startIndex
        var remaining = lineCount
        while remaining > 0, index < endIndex {
            if self[index] == "\n" {
                remaining -= 1
            }
            index = self.index(after: index)
        }
        return index
    }
}

enum BlockSerializer {
    /// Serialize a tree of blocks to markdown. The tree's depth is recursively
    /// translated into leading-space indentation (2 spaces per level). Each
    /// container kind owns its own envelope: toggles emit `▸ Title` + their
    /// children; templates wrap children in `:::{template-button}` fences;
    /// headings emit their hash-prefix line and recurse into children at the
    /// same depth (heading containment is purely a parser concern).
    static func serialize(_ blocks: [Block], resolvingSubpageTitle titleForPath: (String) -> String? = { _ in nil }, consecutiveNumbering: Bool = false) -> String {
        var out = ""
        serializeChildren(blocks, depth: 0, into: &out, titleForPath: titleForPath, consecutiveNumbering: consecutiveNumbering)
        if !out.hasSuffix("\n") { out += "\n" }
        return out
    }

    /// Serialize a single block to markdown WITHOUT its children. Used to
    /// store an atomic block in the per-page content pool — a toggle file
    /// holds just `▸ Title`, a heading just `# Heading`, etc. Restoration
    /// reattaches the block as a child of whatever ancestor is still live;
    /// orphaned descendants are restored separately.
    static func serializeAtomic(_ block: Block) -> String {
        // Full-page serialization represents an empty paragraph as spacing
        // between neighboring blocks. An isolated recovery-log snapshot has
        // no neighbors, so a bare newline would parse as zero blocks. Keep
        // the legacy NBSP marker only at this atomic boundary; the parser
        // normalizes it back to an empty paragraph and its original hash.
        if case .paragraph(let text) = block.kind,
           inlineString(text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\u{00A0}\n\n"
        }
        let bare = Block(id: block.id, kind: block.kind, children: [])
        return serializeBlock(bare, depth: 0, numberedIndex: 0, titleForPath: { _ in nil }, consecutiveNumbering: false)
    }

    private static func serializeChildren(_ blocks: [Block], depth: Int, into out: inout String, titleForPath: (String) -> String?, consecutiveNumbering: Bool) {
        var numberedIndex = 0
        for (i, block) in blocks.enumerated() {
            if case .numbered = block.kind {
                numberedIndex += 1
            } else {
                numberedIndex = 0
            }
            let chunk = serializeBlock(block, depth: depth, numberedIndex: numberedIndex, titleForPath: titleForPath, consecutiveNumbering: consecutiveNumbering)
            out += chunk
            let isLast = i == blocks.count - 1
            if !isLast {
                let next = blocks[i + 1]
                if !chunk.hasSuffix("\n\n"), needsBlankLineBetween(block, and: next) {
                    if chunk.hasSuffix("\n") {
                        out += "\n"
                    } else {
                        out += "\n\n"
                    }
                }
            }
        }
    }

    private static func serializeBlock(_ block: Block, depth: Int, numberedIndex: Int, titleForPath: (String) -> String?, consecutiveNumbering: Bool) -> String {
        let prefix = indentPrefix(depth)
        switch block.kind {
        case .paragraph(let text):
            let body = inlineString(text)
            if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "\n"
            }
            // Paragraphs cannot contain children today, but defensively serialize
            // any descendant tree for forward-compat.
            var s = prefix + body + "\n\n"
            if !block.children.isEmpty {
                s += serializeContainerBody(block.children, depth: depth + 1, titleForPath: titleForPath, consecutiveNumbering: consecutiveNumbering)
            }
            return s

        case .heading(let level, let text):
            let line = prefix + String(repeating: "#", count: level.rawValue) + " " + inlineString(text) + "\n\n"
            // Headings own their body at the SAME depth: a top-level H2 with
            // body paragraphs serializes the H2 then the paragraphs at depth 0,
            // not depth 1. The parser's heading-fold pass reconstructs the
            // ownership purely from sibling order + level comparison.
            if !block.children.isEmpty {
                return line + serializeContainerBody(block.children, depth: depth, titleForPath: titleForPath, consecutiveNumbering: consecutiveNumbering)
            }
            return line

        case .bullet(let text):
            return listItemLine(marker: "- ", contentColumn: 2, prefix: prefix, text: text, children: block.children, titleForPath: titleForPath, consecutiveNumbering: consecutiveNumbering)

        case .numbered(let text):
            let n = consecutiveNumbering && numberedIndex > 0 ? numberedIndex : 1
            let marker = "\(n). "
            return listItemLine(marker: marker, contentColumn: marker.count, prefix: prefix, text: text, children: block.children, titleForPath: titleForPath, consecutiveNumbering: consecutiveNumbering)

        case .todo(let text, let done):
            // The `[ ]` / `[x]` is content per GFM — the actual list marker is
            // just `- `, so children indent to column 2, not column 6.
            let mark = "- [" + (done ? "x" : " ") + "] "
            return listItemLine(marker: mark, contentColumn: 2, prefix: prefix, text: text, children: block.children, titleForPath: titleForPath, consecutiveNumbering: consecutiveNumbering)

        case .quote(let text):
            return prefix + "> " + inlineString(text) + "\n\n"

        case .code(let source, let language):
            let fence = "```" + (language ?? "")
            let body = source.hasSuffix("\n") ? source : source + "\n"
            return indentLines(fence + "\n" + body + "```\n\n", indent: depth)

        case .divider:
            return prefix + "---\n\n"

        case .toggle(let title):
            let titleLine = prefix + "▸ " + inlineString(title) + "\n"
            let bodyText = serializeContainerBody(block.children, depth: depth + 1, titleForPath: titleForPath, consecutiveNumbering: consecutiveNumbering)
            return titleLine + bodyText

        case .templateButton(let label):
            // Body is serialized as if it were top-level (depth 0) and then
            // every line indented by `depth` spaces. The fence pair sits at
            // `depth`. Body trailing blank lines are trimmed.
            var inner = serializeContainerBody(block.children, depth: 0, titleForPath: titleForPath, consecutiveNumbering: consecutiveNumbering)
            while inner.hasSuffix("\n\n") { inner.removeLast() }
            if block.children.isEmpty {
                inner = ""
            } else if !inner.hasSuffix("\n") {
                inner += "\n"
            }
            let fence = templateFence(for: inner)
            let raw = fence + "{template-button} " + templateLabel(label) + "\n" + inner + fence + "\n\n"
            return indentLines(raw, indent: depth)

        case .subpage(let title, let path):
            let displayTitle = titleForPath(path) ?? title
            return prefix + "[" + displayTitle + "](" + path + ")\n\n"

        case .image(let source, let alt):
            return prefix + "![" + escapeMarkdownLinkText(alt) + "](" + source + ")\n\n"

        case .unsupported(let payload, _):
            // Verbatim, at this block's indent depth. The payload is the exact
            // source slice the parser took, so a construct this editor has no
            // model for (a table, a raw HTML block) comes back out byte for
            // byte instead of being flattened into a paragraph and lost.
            let body = payload.hasSuffix("\n") ? payload : payload + "\n"
            return indentLines(body, indent: depth) + "\n"
        }
    }

    /// Serialize a container's children list with proper inter-block
    /// separation. Used by every container kind that has a body.
    private static func serializeContainerBody(_ blocks: [Block], depth: Int, titleForPath: (String) -> String?, consecutiveNumbering: Bool) -> String {
        var out = ""
        serializeChildren(blocks, depth: depth, into: &out, titleForPath: titleForPath, consecutiveNumbering: consecutiveNumbering)
        return out
    }

    private static func needsBlankLineBetween(_ current: Block, and next: Block) -> Bool {
        if isListItem(current), isListItem(next) {
            return false
        }
        if isToggle(current), isToggle(next) {
            return false
        }
        if isEmptyParagraph(current) {
            return false
        }
        if isEmptyParagraph(next) {
            return true
        }
        return true
    }

    private static func isListItem(_ block: Block) -> Bool {
        switch block.kind {
        case .bullet, .numbered, .todo:
            return true
        default:
            return false
        }
    }

    private static func isToggle(_ block: Block) -> Bool {
        if case .toggle = block.kind { return true }
        return false
    }

    private static func isSubpage(_ block: Block) -> Bool {
        if case .subpage = block.kind { return true }
        return false
    }

    private static func isEmptyParagraph(_ block: Block) -> Bool {
        guard case .paragraph(let text) = block.kind else { return false }
        return inlineString(text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// List items terminate with `\n` (not `\n\n`) so successive siblings stay
    /// in the same list. When the item has paragraph-like children, two things
    /// have to be right for CommonMark to keep the body inside the item on
    /// reparse:
    ///
    /// 1. The body is separated from the marker line by a blank line only when
    ///    the first child is not itself a list item or subpage row. Without
    ///    it, an indented paragraph, quote, … folds into the leading paragraph
    ///    via lazy continuation and the nested-child structure is lost. A
    ///    subpage row is safe because the parser peels a trailing softbreak +
    ///    `.md` link back into a child block.
    /// 2. The body indents to the marker's *content column* — `prefix.count +
    ///    marker.count` spaces. That's 2 for a bullet, 3 for `1. `, 6 for a
    ///    todo's `- [ ] `. A shallower indent ends the list on reparse and the
    ///    child becomes a sibling block.
    ///
    /// We serialize the body at depth 0 and prefix every non-empty line with
    /// the content-column indent — same approach `templateButton` uses for its
    /// fenced body. `contentColumn` is the offset of the list-syntax content
    /// position from the item's start; the printed marker (`marker`) may be
    /// wider (todos render `- [ ] ` but the GFM list marker is just `- `).
    private static func listItemLine(marker: String, contentColumn: Int, prefix: String, text: AttributedString, children: [Block], titleForPath: (String) -> String?, consecutiveNumbering: Bool) -> String {
        let line = prefix + marker + inlineString(text) + "\n"
        if children.isEmpty { return line }
        let body = serializeContainerBody(children, depth: 0, titleForPath: titleForPath, consecutiveNumbering: consecutiveNumbering)
        let childIndent = String(repeating: " ", count: prefix.count + contentColumn)
        let indented = body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : childIndent + $0 }
            .joined(separator: "\n")
        let separator = children.first.map(canStartListBodyTight) == true ? "" : "\n"
        return line + separator + indented
    }

    private static func canStartListBodyTight(_ block: Block) -> Bool {
        isListItem(block) || isToggle(block) || isSubpage(block)
    }

    /// Escape `]`, `\`, and newlines inside the alt text so the bracket pair
    /// stays well-formed when round-tripped through cmark. Empty / typical alts
    /// have nothing to escape.
    private static func escapeMarkdownLinkText(_ alt: String) -> String {
        var out = ""
        out.reserveCapacity(alt.count)
        for c in alt {
            switch c {
            case "\\", "]":
                out.append("\\")
                out.append(c)
            case "\n", "\r":
                out.append(" ")
            default:
                out.append(c)
            }
        }
        return out
    }

    private static func indentPrefix(_ indent: Int) -> String {
        String(repeating: "  ", count: max(0, indent))
    }

    private static func indentLines(_ source: String, indent: Int) -> String {
        let prefix = indentPrefix(indent)
        guard !prefix.isEmpty else { return source }
        return source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.isEmpty ? "" : prefix + line }
            .joined(separator: "\n")
    }

    private static func templateLabel(_ label: String) -> String {
        label.replacingOccurrences(of: "\n", with: " ")
    }

    private static func templateFence(for body: String) -> String {
        var longest = 0
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            var count = 0
            for char in trimmed {
                guard char == ":" else { break }
                count += 1
            }
            if count >= 3 {
                longest = max(longest, count)
            }
        }
        return String(repeating: ":", count: max(3, longest + 1))
    }

    // MARK: - AttributedString → markdown inline

    static func inlineString(_ attributed: AttributedString) -> String {
        var out = ""
        for run in attributed.runs {
            let segment = String(attributed[run.range].characters)
            out += wrap(segment, with: attributesFor(run))
        }
        return out
    }

    private struct InlineMarks {
        var bold: Bool = false
        var italic: Bool = false
        var code: Bool = false
        var strike: Bool = false
        var link: URL?
    }

    private static func attributesFor(_ run: AttributedString.Runs.Run) -> InlineMarks {
        var marks = InlineMarks()
        marks.bold = run[InlineAttributes.BoldAttribute.self] == true
        marks.italic = run[InlineAttributes.ItalicAttribute.self] == true
        marks.code = run[InlineAttributes.CodeAttribute.self] == true
        marks.strike = run[InlineAttributes.StrikethroughAttribute.self] == true
        marks.link = run.link
        return marks
    }

    private static func wrap(_ s: String, with marks: InlineMarks) -> String {
        if s.isEmpty { return s }
        // Code is exclusive: don't apply other marks inside `code`.
        if marks.code {
            let body = "`" + s + "`"
            return wrapLink(body, link: marks.link)
        }
        // CommonMark won't recognize `**foo **` or `* foo*` as emphasis —
        // the closing/opening delimiter must be adjacent to a non-whitespace
        // character. Peel any whitespace off the run and re-attach it outside
        // the emphasis (and outside the link wrapper, so the bracket text
        // doesn't gain semantically meaningless trailing space either).
        let (leading, core, trailing) = splitEdgeWhitespace(s)
        if core.isEmpty { return s }
        var body = core
        if marks.strike { body = "~~" + body + "~~" }
        if marks.italic { body = "*" + body + "*" }
        if marks.bold { body = "**" + body + "**" }
        return leading + wrapLink(body, link: marks.link) + trailing
    }

    private static func splitEdgeWhitespace(_ s: String) -> (leading: String, core: String, trailing: String) {
        let scalars = Array(s.unicodeScalars)
        var start = 0
        while start < scalars.count, scalars[start].properties.isWhitespace { start += 1 }
        var end = scalars.count
        while end > start, scalars[end - 1].properties.isWhitespace { end -= 1 }
        let leading = String(String.UnicodeScalarView(scalars[0..<start]))
        let core = String(String.UnicodeScalarView(scalars[start..<end]))
        let trailing = String(String.UnicodeScalarView(scalars[end..<scalars.count]))
        return (leading, core, trailing)
    }

    private static func wrapLink(_ s: String, link: URL?) -> String {
        guard let link else { return s }
        return "[" + s + "](" + link.absoluteString + ")"
    }
}
