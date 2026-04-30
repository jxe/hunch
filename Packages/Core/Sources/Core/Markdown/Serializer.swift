import Foundation

public enum BlockSerializer {
    public static func serialize(_ blocks: [Block]) -> String {
        var out = ""
        var i = 0
        while i < blocks.count {
            let block = blocks[i]
            let chunk: String
            let consumed: Int
            if case .toggle(_, let title, let indent) = block {
                // A toggle "owns" the immediately following blocks at greater indent — those
                // are its body. Wrap them in <details>/</details> on disk so the file shape
                // is unchanged from before flat-toggles. cmark-gfm closes <details> at blank
                // lines, but the parser's `assemble` pass stitches it back on read.
                //
                // Body blocks are normalised to indent 0 inside the envelope: a 4-space
                // (i.e. indent ≥ 2) leading-whitespace line would otherwise be parsed back
                // as a code block. The parser re-adds `toggle.indent + 1` when it descends.
                var end = i + 1
                while end < blocks.count, blocks[end].indent > indent {
                    end += 1
                }
                let body = blocks[(i + 1)..<end].map { $0.withIndent($0.indent - (indent + 1)) }
                var inner = serialize(body)
                while inner.hasSuffix("\n\n") { inner.removeLast() }
                if body.isEmpty {
                    inner = ""
                } else if !inner.hasSuffix("\n") {
                    inner += "\n"
                }
                let raw = "<details><summary>" + inlineString(title) + "</summary>\n\n" + inner + "\n</details>\n\n"
                chunk = indentLines(raw, indent: indent)
                consumed = end - i
            } else {
                chunk = serialize(block)
                consumed = 1
            }
            out += chunk
            let isLast = (i + consumed) >= blocks.count
            if !isLast {
                if !chunk.hasSuffix("\n\n") {
                    if chunk.hasSuffix("\n") {
                        out += "\n"
                    } else {
                        out += "\n\n"
                    }
                }
            }
            i += consumed
        }
        if !out.hasSuffix("\n") { out += "\n" }
        return out
    }

    /// Per-block serialization. `.toggle` is handled in the array form because its body
    /// lives in subsequent sibling blocks (via `Document.sectionRange`), so a single-block
    /// serialize emits only the title row's HTML envelope with an empty body.
    public static func serialize(_ block: Block) -> String {
        switch block {
        case .paragraph(_, let text, let indent):
            return indentPrefix(indent) + inlineString(text) + "\n\n"

        case .heading(_, let level, let text, let indent):
            return indentPrefix(indent) + String(repeating: "#", count: level) + " " + inlineString(text) + "\n\n"

        case .bullet(_, let text, let indent):
            return indentPrefix(indent) + "- " + inlineString(text) + "\n"

        case .numbered(_, let text, let indent):
            return indentPrefix(indent) + "1. " + inlineString(text) + "\n"

        case .todo(_, let text, let done, let indent):
            return indentPrefix(indent) + "- [" + (done ? "x" : " ") + "] " + inlineString(text) + "\n"

        case .quote(_, let text, let indent):
            return indentPrefix(indent) + "> " + inlineString(text) + "\n\n"

        case .code(_, let source, let language, let indent):
            let fence = "```" + (language ?? "")
            let body = source.hasSuffix("\n") ? source : source + "\n"
            return indentLines(fence + "\n" + body + "```\n\n", indent: indent)

        case .divider(_, let indent):
            return indentPrefix(indent) + "---\n\n"

        case .toggle(_, let title, let indent):
            let raw = "<details><summary>" + inlineString(title) + "</summary>\n\n</details>\n\n"
            return indentLines(raw, indent: indent)

        case .subpage(_, let title, let path, let indent):
            return indentPrefix(indent) + "[" + title + "](" + path + ")\n\n"
        }
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
        var body = s
        if marks.strike { body = "~~" + body + "~~" }
        if marks.italic { body = "*" + body + "*" }
        if marks.bold { body = "**" + body + "**" }
        return wrapLink(body, link: marks.link)
    }

    private static func wrapLink(_ s: String, link: URL?) -> String {
        guard let link else { return s }
        return "[" + s + "](" + link.absoluteString + ")"
    }
}
