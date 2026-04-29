import Foundation

public enum BlockTransform: Equatable, Sendable {
    case heading(level: Int)
    case bullet
    case numbered
    case todo
    case quote
    case toggle
    case divider
    case codeFence
}

public struct AutotransformResult: Equatable, Sendable {
    public let transform: BlockTransform
    public let remainingText: AttributedString

    public init(transform: BlockTransform, remainingText: AttributedString) {
        self.transform = transform
        self.remainingText = remainingText
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
public func detectPrefixAutotransform(text: AttributedString, cursor: Int) -> AutotransformResult? {
    let plain = String(text.characters)
    for (prefix, transform) in prefixTriggers {
        guard cursor == prefix.count else { continue }
        guard plain.hasPrefix(prefix) else { continue }
        let remaining = String(plain.dropFirst(prefix.count))
        return AutotransformResult(transform: transform, remainingText: AttributedString(remaining))
    }
    return nil
}

/// Detects an Enter-completed whole-row trigger. Caller must already have established that
/// Enter is being pressed at the end of a row whose remaining-tail text is empty.
public func detectEnterAutotransform(text: AttributedString) -> AutotransformResult? {
    switch String(text.characters) {
    case "---":
        return AutotransformResult(transform: .divider, remainingText: AttributedString())
    case "```":
        return AutotransformResult(transform: .codeFence, remainingText: AttributedString())
    default:
        return nil
    }
}
