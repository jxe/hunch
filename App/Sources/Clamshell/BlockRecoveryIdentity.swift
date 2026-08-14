import CryptoKit
import Foundation
import Editor

/// Clamshell's stable on-disk identity for one atomic block record.
///
/// This is recovery-format policy, not editor identity. Existing JSONL logs
/// depend on the exact canonical strings and full SHA-256 values below.
extension Block {
    var atomicHash: String {
        BlockRecoveryHashing.sha256(self).map { String(format: "%02x", $0) }.joined()
    }

    var fingerprint: String {
        BlockRecoveryHashing.sha256(self).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

extension Document {
    func atomicHashSet() -> Set<String> {
        var out: Set<String> = []
        walk { block, _, _ in out.insert(block.atomicHash) }
        return out
    }
}

private enum BlockRecoveryHashing {
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

    private static func normalize(_ text: AttributedString) -> String {
        normalizeRaw(String(text.characters))
    }

    private static func normalizeRaw(_ string: String) -> String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        var collapsed = ""
        var previousWasSpace = false
        for scalar in trimmed.unicodeScalars {
            let isSpace = CharacterSet.whitespacesAndNewlines.contains(scalar)
            if isSpace {
                if !previousWasSpace { collapsed.append(" ") }
                previousWasSpace = true
            } else {
                collapsed.unicodeScalars.append(scalar)
                previousWasSpace = false
            }
        }
        return collapsed
    }
}

/// Projects editor-semantic changes onto Clamshell's existing recovery-log
/// add/purge semantics. Semantically different snapshots whose recovery hash
/// is unchanged (for example inline formatting or normalized whitespace) do
/// not churn the journal.
enum RecoveryChangeProjection {
    static func entries(for changes: [DocumentChange]) -> [Patch.Entry] {
        let removedByID = Dictionary(uniqueKeysWithValues: changes.compactMap { change in
            if case .removed(let block) = change { return (block.id, block) }
            return nil
        })
        let insertedByID = Dictionary(uniqueKeysWithValues: changes.compactMap { change in
            if case .inserted(let block, _) = change { return (block.id, block) }
            return nil
        })

        let purges = removedByID.values.compactMap { oldBlock -> String? in
            guard insertedByID[oldBlock.id]?.atomicHash != oldBlock.atomicHash else { return nil }
            return oldBlock.atomicHash
        }.sorted().map(Patch.Entry.purge(hash:))

        let adds = changes.compactMap { change -> Patch.Entry? in
            switch change {
            case .inserted(let block, let parent):
                if let oldBlock = removedByID[block.id], oldBlock.atomicHash == block.atomicHash {
                    return nil
                }
                return .add(
                    hash: block.atomicHash,
                    parent: parent?.atomicHash,
                    markdown: BlockSerializer.serializeAtomic(block)
                )
            case .placementUpdated(let block, let previousParent, let parent):
                guard previousParent.atomicHash != parent.atomicHash else { return nil }
                return .add(
                    hash: block.atomicHash,
                    parent: parent.atomicHash,
                    markdown: BlockSerializer.serializeAtomic(block)
                )
            case .removed:
                return nil
            }
        }
        return purges + adds
    }
}

/// Hunch-side exact semantic diff for non-editor system mutations. This keeps
/// recovery compatibility policy in Clamshell while sharing the editor's
/// public `DocumentChange` transport type.
enum RecoveryChangeDiff {
    static func derive(pre: [Block], post: [Block]) -> [DocumentChange] {
        var preByID: [BlockID: Block] = [:]
        var preParentID: [BlockID: BlockID] = [:]
        var preParentHash: [BlockID: String] = [:]
        collect(pre, parent: nil, blocks: &preByID, parentIDs: &preParentID, parentHashes: &preParentHash)

        var postByID: [BlockID: Block] = [:]
        var postParentID: [BlockID: BlockID] = [:]
        var postParentHash: [BlockID: String] = [:]
        collect(post, parent: nil, blocks: &postByID, parentIDs: &postParentID, parentHashes: &postParentHash)

        var changes = preByID.values
            .filter { postByID[$0.id]?.atomicHash != $0.atomicHash }
            .sorted { $0.atomicHash < $1.atomicHash }
            .map { DocumentChange.removed(block: $0) }

        func walk(_ blocks: [Block], parent: Block?) {
            for block in blocks {
                let parentRefChangedUnderSameParent =
                    preByID[block.id]?.atomicHash == block.atomicHash &&
                    preParentID[block.id] == postParentID[block.id] &&
                    preParentHash[block.id] != parent?.atomicHash
                if preByID[block.id]?.atomicHash != block.atomicHash || parentRefChangedUnderSameParent {
                    if parentRefChangedUnderSameParent,
                       let previousParentID = preParentID[block.id],
                       let previousParent = preByID[previousParentID],
                       let parent {
                        changes.append(.placementUpdated(
                            block: block,
                            previousParent: previousParent,
                            parent: parent
                        ))
                    } else {
                        changes.append(.inserted(block: block, parent: parent))
                    }
                }
                walk(block.children, parent: block)
            }
        }
        walk(post, parent: nil)
        return changes
    }

    private static func collect(
        _ blocks: [Block],
        parent: Block?,
        blocks blockMap: inout [BlockID: Block],
        parentIDs: inout [BlockID: BlockID],
        parentHashes: inout [BlockID: String]
    ) {
        for block in blocks {
            blockMap[block.id] = block
            if let parent {
                parentIDs[block.id] = parent.id
                parentHashes[block.id] = parent.atomicHash
            }
            collect(block.children, parent: block, blocks: &blockMap, parentIDs: &parentIDs, parentHashes: &parentHashes)
        }
    }
}
