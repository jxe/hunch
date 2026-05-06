import Foundation
import CryptoKit
import Editor

/// Stable content-identity for a block. `BlockID` is a fresh UUID on every parse, so
/// it can't be used to ask "is this the same logical block as one in the previous
/// parse?" — fingerprinting builds a canonical string from the block's kind and
/// content, then SHA-256s it down to a 64-bit hex string.
///
/// Equal fingerprints ⇒ blocks are content-equivalent (modulo `BlockID` and tree
/// position). Depth is structural rather than content, so it's intentionally NOT
/// included — moving a paragraph up an indent level shouldn't change its identity.
enum BlockFingerprint {
    static func compute(_ block: Block) -> String {
        let canonical = canonicalString(block)
        let digest = SHA256.hash(data: Data(canonical.utf8))
        // Take the first 8 bytes → 16 hex chars → 64-bit identity. Plenty of entropy
        // for at most a few hundred records per page.
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalString(_ block: Block) -> String {
        switch block.kind {
        case .paragraph(let text):
            return "paragraph|t=\(normalize(text))"
        case .heading(let level, let text):
            return "heading|l=\(level.rawValue)|t=\(normalize(text))"
        case .bullet(let text):
            return "bullet|t=\(normalize(text))"
        case .numbered(let text):
            return "numbered|t=\(normalize(text))"
        case .todo(let text, let done):
            return "todo|d=\(done ? 1 : 0)|t=\(normalize(text))"
        case .quote(let text):
            return "quote|t=\(normalize(text))"
        case .code(let source, let language):
            return "code|lang=\(language ?? "")|s=\(normalizeRaw(source))"
        case .divider:
            return "divider"
        case .toggle(let title):
            return "toggle|t=\(normalize(title))"
        case .templateButton(let label):
            return "templateButton|l=\(normalizeRaw(label))"
        case .subpage(let title, let pageID):
            return "subpage|p=\(pageID)|t=\(normalizeRaw(title))"
        case .image(let source, let alt):
            return "image|s=\(source)|a=\(normalizeRaw(alt))"
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
