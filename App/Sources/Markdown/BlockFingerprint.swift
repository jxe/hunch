import Foundation
import CryptoKit
import Editor

/// Stable content-identity for a block. `BlockID` is a fresh UUID on every parse, so
/// it can't be used to ask "is this the same logical block as one in the previous
/// parse?" — fingerprinting builds a canonical string from the block's kind, indent,
/// and content, then SHA-256s it down to a 64-bit hex string.
///
/// Equal fingerprints ⇒ blocks are content-equivalent (modulo `BlockID`). Used by
/// `RecoveryStore` to decide which blocks disappeared between two saves and to find
/// the anchor when restoring a recovered block.
enum BlockFingerprint {
    static func compute(_ block: Block) -> String {
        let canonical = canonicalString(block)
        let digest = SHA256.hash(data: Data(canonical.utf8))
        // Take the first 8 bytes → 16 hex chars → 64-bit identity. Plenty of entropy
        // for at most a few hundred records per page.
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalString(_ block: Block) -> String {
        let indent = "i=\(block.indent)"
        switch block {
        case .paragraph(_, let text, _):
            return "paragraph|\(indent)|t=\(normalize(text))"
        case .heading(_, let level, let text, _):
            return "heading|l=\(level)|\(indent)|t=\(normalize(text))"
        case .bullet(_, let text, _):
            return "bullet|\(indent)|t=\(normalize(text))"
        case .numbered(_, let text, _):
            return "numbered|\(indent)|t=\(normalize(text))"
        case .todo(_, let text, let done, _):
            return "todo|d=\(done ? 1 : 0)|\(indent)|t=\(normalize(text))"
        case .quote(_, let text, _):
            return "quote|\(indent)|t=\(normalize(text))"
        case .code(_, let source, let language, _):
            return "code|lang=\(language ?? "")|\(indent)|s=\(normalizeRaw(source))"
        case .divider(_, _):
            return "divider|\(indent)"
        case .toggle(_, let title, _):
            return "toggle|\(indent)|t=\(normalize(title))"
        case .templateButton(_, let label, _):
            return "templateButton|\(indent)|l=\(normalizeRaw(label))"
        case .subpage(_, let title, let pageID, _):
            return "subpage|\(indent)|p=\(pageID)|t=\(normalizeRaw(title))"
        }
    }

    /// Whitespace-normalised plain text. Inline marks (bold/italic/etc.) are
    /// intentionally ignored — bolding a word doesn't change the block's identity.
    private static func normalize(_ text: AttributedString) -> String {
        normalizeRaw(String(text.characters))
    }

    private static func normalizeRaw(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        var collapsed = ""
        var prevSpace = false
        for ch in trimmed.unicodeScalars {
            let isSpace = CharacterSet.whitespacesAndNewlines.contains(ch)
            if isSpace {
                if !prevSpace { collapsed.append(" ") }
                prevSpace = true
            } else {
                collapsed.unicodeScalars.append(ch)
                prevSpace = false
            }
        }
        return collapsed
    }
}
