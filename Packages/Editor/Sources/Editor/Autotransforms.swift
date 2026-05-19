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
