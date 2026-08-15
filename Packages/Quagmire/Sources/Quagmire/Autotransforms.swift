import Foundation

enum BlockTransform: Equatable, Sendable {
    case heading(level: Int)
    case bullet
    case numbered
    case todo
    case quote
    case toggle
    case divider
    case codeFence
}

struct AutotransformResult: Equatable, Sendable {
    let transform: BlockTransform
    let remainingText: AttributedString

    init(transform: BlockTransform, remainingText: AttributedString) {
        self.transform = transform
        self.remainingText = remainingText
    }
}

struct InlineAutotransformResult: Equatable, Sendable {
    let text: AttributedString
    let cursor: Int
}

extension BlockTransform {
    /// Returns the block(s) that replace the source row. Most transforms produce a single
    /// block. `divider` and `codeFence` produce two: the transform block plus a fresh empty
    /// paragraph for the cursor to land in.
    func apply(to remainingText: AttributedString) -> [Block] {
        switch self {
        case .heading(let level):
            return [.heading(level: level, text: remainingText)]
        case .bullet:
            return [.bullet(text: remainingText)]
        case .numbered:
            return [.numbered(text: remainingText)]
        case .todo:
            return [.todo(text: remainingText, done: false)]
        case .quote:
            return [.quote(text: remainingText)]
        case .toggle:
            return [.toggle(title: remainingText)]
        case .divider:
            return [.divider(), .paragraph(text: AttributedString())]
        case .codeFence:
            return [.code(source: "", language: nil), .paragraph(text: AttributedString())]
        }
    }

    /// Index into the result of `apply(to:)` where the cursor should land after the
    /// transform fires. For divider/codeFence we want the fresh paragraph (index 1) so the
    /// user can continue typing; everything else focuses the transformed block (index 0).
    var focusReplacementIndex: Int {
        switch self {
        case .divider, .codeFence: return 1
        default: return 0
        }
    }
}

/// Longer prefixes come first when triggers share a stem (`### ` before `## ` before `# `;
/// `[ ] ` before `[] `). The `" `/`" ` pair covers smart-quote substitution: NSTextView
/// turns plain `"` into U+201C by default, so the detector accepts both.
private let prefixTriggers: [(prefix: String, transform: BlockTransform)] = [
    ("### ", .heading(level: 3)),
    ("## ", .heading(level: 2)),
    ("# ", .heading(level: 1)),
    ("- ", .bullet),
    ("* ", .bullet),
    ("1. ", .numbered),
    ("[ ] ", .todo),
    ("[] ", .todo),
    ("> ", .toggle),
    ("\" ", .quote),
    ("\u{201C} ", .quote),
]

/// Returns a result when `text` begins with a prefix trigger AND `cursor` sits exactly at
/// the trigger's end. The trigger is consumed; any remaining text becomes the body of the
/// new block. `cursor` is the character offset (UTF-16-equivalent for ASCII triggers).
func detectPrefixAutotransform(text: AttributedString, cursor: Int) -> AutotransformResult? {
    let plain = String(text.characters)
    if cursor == 3, plain == "---" {
        return AutotransformResult(transform: .divider, remainingText: AttributedString())
    }
    for (prefix, transform) in prefixTriggers {
        guard cursor == prefix.count else { continue }
        guard plain.hasPrefix(prefix) else { continue }
        // Slice the AttributedString (not the plain String) so any inline marks
        // the user applied earlier in the edit — bold/italic/code/strike/link —
        // ride through into the transformed block.
        let cutIdx = text.index(text.startIndex, offsetByCharacters: prefix.count)
        let remaining = AttributedString(text[cutIdx..<text.endIndex])
        return AutotransformResult(transform: transform, remainingText: remaining)
    }
    return nil
}

/// Detects an Enter-completed whole-row trigger. Caller must already have established that
/// Enter is being pressed at the end of a row whose remaining-tail text is empty.
func detectEnterAutotransform(text: AttributedString) -> AutotransformResult? {
    switch String(text.characters) {
    case "---":
        return AutotransformResult(transform: .divider, remainingText: AttributedString())
    case "```":
        return AutotransformResult(transform: .codeFence, remainingText: AttributedString())
    default:
        return nil
    }
}

/// Detects inline Markdown-style mark delimiters ending exactly at `cursor`, removes the
/// delimiters, and applies the corresponding attributed mark to the enclosed text.
func detectInlineStyleAutotransform(text: AttributedString, cursor: Int) -> InlineAutotransformResult? {
    let plain = String(text.characters)
    guard cursor > 0, cursor <= plain.count else { return nil }
    let beforeCursor = String(plain.prefix(cursor))

    if beforeCursor.hasSuffix(")"),
       let result = detectInlineLinkAutotransform(text: text, plain: plain, cursor: cursor) {
        return result
    }
    if beforeCursor.hasSuffix("**"),
       let result = detectDelimitedInlineAutotransform(
        text: text,
        plain: plain,
        cursor: cursor,
        delimiter: "**",
        apply: { $0[InlineAttributes.BoldAttribute.self] = true }) {
        return result
    }
    if beforeCursor.hasSuffix("~~"),
       let result = detectDelimitedInlineAutotransform(
        text: text,
        plain: plain,
        cursor: cursor,
        delimiter: "~~",
        apply: { $0[InlineAttributes.StrikethroughAttribute.self] = true }) {
        return result
    }
    if beforeCursor.hasSuffix("`"),
       let result = detectDelimitedInlineAutotransform(
        text: text,
        plain: plain,
        cursor: cursor,
        delimiter: "`",
        apply: { $0[InlineAttributes.CodeAttribute.self] = true }) {
        return result
    }
    if beforeCursor.hasSuffix("*"), !beforeCursor.hasSuffix("**"),
       let result = detectDelimitedInlineAutotransform(
        text: text,
        plain: plain,
        cursor: cursor,
        delimiter: "*",
        apply: { $0[InlineAttributes.ItalicAttribute.self] = true }) {
        return result
    }
    if beforeCursor.hasSuffix("_"),
       let result = detectDelimitedInlineAutotransform(
        text: text,
        plain: plain,
        cursor: cursor,
        delimiter: "_",
        apply: { $0[InlineAttributes.ItalicAttribute.self] = true }) {
        return result
    }
    return nil
}

private func detectDelimitedInlineAutotransform(
    text: AttributedString,
    plain: String,
    cursor: Int,
    delimiter: String,
    apply: (inout AttributedString) -> Void
) -> InlineAutotransformResult? {
    let delimiterLength = delimiter.count
    guard cursor >= delimiterLength * 2 else { return nil }

    let searchEnd = cursor - delimiterLength
    let beforeClosing = String(plain.prefix(searchEnd))
    guard let openerRange = beforeClosing.range(of: delimiter, options: .backwards) else { return nil }

    let opener = plain.distance(from: plain.startIndex, to: openerRange.lowerBound)
    let contentStart = opener + delimiterLength
    let contentEnd = searchEnd
    guard contentStart < contentEnd else { return nil }

    if delimiter == "*" || delimiter == "_" {
        guard isSingleDelimiter(in: plain, at: opener, delimiter: delimiter) else { return nil }
        guard isSingleDelimiter(in: plain, at: searchEnd, delimiter: delimiter) else { return nil }
    }

    let prefix = attributedSlice(text, 0..<opener)
    var inner = attributedSlice(text, contentStart..<contentEnd)
    apply(&inner)
    let suffix = attributedSlice(text, cursor..<plain.count)
    let newText = prefix + inner + suffix
    return InlineAutotransformResult(
        text: newText,
        cursor: characterCount(prefix) + characterCount(inner)
    )
}

private func detectInlineLinkAutotransform(
    text: AttributedString,
    plain: String,
    cursor: Int
) -> InlineAutotransformResult? {
    let beforeCursor = String(plain.prefix(cursor))
    guard let closeTextRange = beforeCursor.range(of: "](", options: .backwards),
          let openTextRange = beforeCursor[..<closeTextRange.lowerBound].range(of: "[", options: .backwards) else {
        return nil
    }

    let openText = plain.distance(from: plain.startIndex, to: openTextRange.lowerBound)
    let closeText = plain.distance(from: plain.startIndex, to: closeTextRange.lowerBound)
    let urlStart = closeText + 2
    let urlEnd = cursor - 1
    let textStart = openText + 1
    guard textStart < closeText, urlStart < urlEnd else { return nil }

    let urlString = String(plain[plainIndex(plain, offset: urlStart)..<plainIndex(plain, offset: urlEnd)])
    guard let url = URL(string: urlString) else { return nil }

    let prefix = attributedSlice(text, 0..<openText)
    var linked = attributedSlice(text, textStart..<closeText)
    linked.link = url
    let suffix = attributedSlice(text, cursor..<plain.count)
    let newText = prefix + linked + suffix
    return InlineAutotransformResult(
        text: newText,
        cursor: characterCount(prefix) + characterCount(linked)
    )
}

private func isSingleDelimiter(in plain: String, at offset: Int, delimiter: String) -> Bool {
    if offset > 0 {
        let previous = plainIndex(plain, offset: offset - 1)
        if plain[previous] == Character(delimiter) { return false }
    }
    let nextOffset = offset + delimiter.count
    if nextOffset < plain.count {
        let next = plainIndex(plain, offset: nextOffset)
        if plain[next] == Character(delimiter) { return false }
    }
    return true
}

private func attributedSlice(_ text: AttributedString, _ bounds: Range<Int>) -> AttributedString {
    let lower = text.index(text.startIndex, offsetByCharacters: bounds.lowerBound)
    let upper = text.index(text.startIndex, offsetByCharacters: bounds.upperBound)
    return AttributedString(text[lower..<upper])
}

private func characterCount(_ text: AttributedString) -> Int {
    String(text.characters).count
}

private func plainIndex(_ plain: String, offset: Int) -> String.Index {
    plain.index(plain.startIndex, offsetBy: offset)
}
