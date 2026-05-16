import Foundation
import CryptoKit

/// Stable content-identity for a block. `BlockID` is a fresh UUID on every parse,
/// so it can't be used to ask "is this the same logical block as one in the
/// previous parse?" — the hashes below build a canonical string from the block's
/// kind and content, then SHA-256 it.
///
/// Equal hashes ⇒ blocks are content-equivalent (modulo `BlockID` and tree
/// position). Depth is structural rather than content, so it's intentionally NOT
/// included — moving a paragraph up an indent level shouldn't change its identity.
public extension Block {
    /// Full SHA-256 hex of the block's canonical content — used as the on-disk
    /// identity for a block in the recovery log (`h` field).
    var atomicHash: String {
        BlockHashing.sha256(self).map { String(format: "%02x", $0) }.joined()
    }

    /// 16-char prefix of `atomicHash` — 64 bits of identity, enough for the
    /// few-hundred-records-per-page scale we hash at.
    var fingerprint: String {
        BlockHashing.sha256(self).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

public extension Document {
    /// Collect the atomic hashes of every block in the document (preorder).
    /// Used by save / conflict / recovery paths to compare against on-disk
    /// state without re-walking the tree at each call site.
    func atomicHashSet() -> Set<String> {
        var out: Set<String> = []
        walk { block, _, _ in out.insert(block.atomicHash) }
        return out
    }
}

enum BlockHashing {
    static func sha256(_ block: Block) -> SHA256.Digest {
        SHA256.hash(data: Data(canonicalString(block).utf8))
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
