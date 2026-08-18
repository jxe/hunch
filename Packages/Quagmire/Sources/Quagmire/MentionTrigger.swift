import Foundation

/// An active `@mention` trigger detected in a block's text. The popover stays open as long
/// as detection keeps returning a non-nil trigger from `detectMentionTrigger`; on every
/// keystroke / cursor move the editor re-runs detection and reports the new trigger (or
/// nil) to the page-level state.
struct MentionTrigger: Equatable, Sendable {
    /// Range covering the literal `@` plus any chars typed after it, in NSString (UTF-16)
    /// units — caller will splice the menu's selected link into this range on commit.
    let nsRange: NSRange
    /// Plain text after the `@`. Empty string is valid (cursor sits right after `@`).
    let query: String

    init(nsRange: NSRange, query: String) {
        self.nsRange = nsRange
        self.query = query
    }
}

/// Detects whether `cursor` (a UTF-16 offset into `plain`) sits immediately after an
/// in-progress `@query`. Returns nil when:
///   * The query crosses a hard stop (newline / tab) — clearly the user moved on
///   * The `@` is glued to a word character (so `email@host` doesn't trigger)
///   * No `@` is found before hitting a hard stop or the start of the string
func detectMentionTrigger(plain: String, cursor: Int) -> MentionTrigger? {
    let ns = plain as NSString
    guard cursor >= 0, cursor <= ns.length else { return nil }

    var i = cursor
    while i > 0 {
        let prev = ns.character(at: i - 1)
        guard let scalar = Unicode.Scalar(prev) else { return nil }

        if scalar == "@" {
            let atIndex = i - 1
            // The @ only triggers at a word boundary — start-of-string, or preceded by
            // whitespace / punctuation. Without this `email@host` would pop the menu.
            if atIndex > 0 {
                let beforeAt = ns.character(at: atIndex - 1)
                guard let beforeScalar = Unicode.Scalar(beforeAt),
                      isMentionWordBoundary(beforeScalar) else {
                    return nil
                }
            }
            let queryRange = NSRange(location: i, length: cursor - i)
            let query = ns.substring(with: queryRange)
            return MentionTrigger(
                nsRange: NSRange(location: atIndex, length: cursor - atIndex),
                query: query
            )
        }
        if isMentionStop(scalar) {
            return nil
        }
        i -= 1
    }
    return nil
}

/// Whether a mention whose `@` starts at `triggerStart` should commit as a
/// block-level documentLink row. Real content before the `@` means inline mention;
/// only whitespace or a markdown-style row marker counts as line-leading.
func mentionStartsDocumentLinkBlock(plain: String, triggerStart: Int) -> Bool {
    guard triggerStart >= 0, triggerStart <= plain.count else { return false }
    let atIndex = plain.index(plain.startIndex, offsetBy: triggerStart)
    let prefix = String(plain[..<atIndex]).trimmingCharacters(in: .whitespaces)
    if prefix.isEmpty { return true }
    if ["-", "*", ">", "\"", "\u{201C}", "[]", "[ ]",
        "#", "##", "###", "####", "#####", "######"].contains(prefix) {
        return true
    }
    return prefix.range(of: #"^\d+\.$"#, options: .regularExpression) != nil
}

/// Chars that terminate an in-progress mention query when walking back from the cursor.
/// Newlines and tabs are hard stops; the `@` can't legitimately have crossed them.
private func isMentionStop(_ scalar: Unicode.Scalar) -> Bool {
    return scalar == "\n" || scalar == "\r" || scalar == "\t"
}

/// Whether `scalar` is a word boundary — i.e. the char preceding `@` may be this and the
/// `@` will still trigger a mention. Whitespace and most punctuation count; alphanumerics
/// don't (so `you@example.com` won't pop the menu mid-edit).
private func isMentionWordBoundary(_ scalar: Unicode.Scalar) -> Bool {
    if CharacterSet.whitespacesAndNewlines.contains(scalar) { return true }
    if CharacterSet.punctuationCharacters.contains(scalar) { return true }
    return false
}
