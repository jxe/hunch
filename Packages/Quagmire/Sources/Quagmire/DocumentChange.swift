import Foundation

/// One semantic block-tree change committed by a `Document` transaction.
///
/// The editor reports block snapshots and containment, not storage hashes or
/// journal operations. A host can persist these changes however its storage
/// model requires. Moves and reorders whose block content is unchanged do not
/// produce entries, but the surrounding transaction is still committed and
/// must still be persisted by the host.
public enum DocumentChange: Sendable, Equatable {
    case removed(block: Block)
    case inserted(block: Block, parent: Block?)
    /// The block itself is unchanged, but the content identity of its stable
    /// same-ID parent changed. Hosts whose placement records reference parent
    /// content can refresh that reference without treating this as a move.
    case placementUpdated(block: Block, previousParent: Block, parent: Block)
}

/// Pure pre-to-post semantic tree diff used by `Document.transaction`.
enum DocumentChangeDiff {
    /// Removes are emitted first in stable block-ID order, followed by inserts
    /// in post-tree preorder so parents precede descendants.
    ///
    /// Content comparison deliberately uses `Block.kind`, excluding children:
    /// tree position and child order are structural shape, while a block's kind
    /// is its own editable content. Hosts may further coalesce semantically
    /// equivalent content according to their storage identity rules.
    static func derive(pre: [Block], post: [Block]) -> [DocumentChange] {
        var preByID: [BlockID: Block] = [:]
        var preParentByID: [BlockID: Block] = [:]
        collect(pre, parent: nil, blocks: &preByID, parents: &preParentByID)

        var postByID: [BlockID: Block] = [:]
        var postParentByID: [BlockID: Block] = [:]
        collect(post, parent: nil, blocks: &postByID, parents: &postParentByID)

        var changes: [DocumentChange] = preByID
            .filter { id, block in
                guard let postBlock = postByID[id] else { return true }
                return block.kind != postBlock.kind
            }
            .sorted { lhs, rhs in lhs.key.value.uuidString < rhs.key.value.uuidString }
            .map { .removed(block: $0.value) }

        func walk(_ blocks: [Block], parent: Block?) {
            for block in blocks {
                let contentChanged = preByID[block.id]?.kind != block.kind
                let stableChangedParent: (Block, Block)? = {
                    guard !contentChanged,
                          let oldParent = preParentByID[block.id],
                          let newParent = postParentByID[block.id],
                          oldParent.id == newParent.id,
                          oldParent.kind != newParent.kind else { return nil }
                    return (oldParent, newParent)
                }()

                if contentChanged {
                    changes.append(.inserted(block: block, parent: parent))
                } else if let (previousParent, parent) = stableChangedParent {
                    changes.append(.placementUpdated(
                        block: block,
                        previousParent: previousParent,
                        parent: parent
                    ))
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
        parents: inout [BlockID: Block]
    ) {
        for block in blocks {
            blockMap[block.id] = block
            if let parent { parents[block.id] = parent }
            collect(block.children, parent: block, blocks: &blockMap, parents: &parents)
        }
    }
}
