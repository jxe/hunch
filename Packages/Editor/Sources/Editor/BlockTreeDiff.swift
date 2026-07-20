import Foundation

/// One structural operation derived from a pre→post block-tree diff. The two
/// shapes correspond to the recovery log's `add`/`purge` records: an
/// `.insert` lifts a new (or content-changed) block's atomic hash into the
/// journal, a `.remove` tombstones a hash whose block-id disappeared.
///
/// Moves (same id, same hash, different parent or position) produce no op
/// — moves are unmodeled by design. The exception is a stable child whose
/// parent `BlockID` is unchanged but whose parent hash changed because the
/// parent was turned into another kind; that emits a fresh insert for the
/// child so recovery logs record the new parent hash. Typing inside a block
/// produces no op either: typing goes through `Document.transaction`
/// directly, not through the `mutate(_:_:)` wrapper, so no diff is computed
/// during a keystroke burst.
public enum EditorOp: Sendable, Equatable {
    /// A block whose `(id, hash)` pair was not present in pre. Covers two
    /// cases: a freshly created block (id is new), and a structurally
    /// edited block (id stayed, hash changed — e.g. autotransform turning a
    /// paragraph into a heading). The `block` carries the post-mutation
    /// content so the host can serialize it atomically when persisting.
    case insert(hash: String, parent: String?, block: Block)
    /// A hash that was present in pre and isn't the live hash of any block
    /// in post. Two cases: the id disappeared (block deleted), and the id
    /// stayed with a different hash (Turn Into or an autotransform that
    /// replaced kind in place). The second case has to tombstone too —
    /// otherwise the old hash stays `.alive` in the recovery journal and
    /// reconcile resurrects it as a "lost block" on the next open.
    case remove(hash: String)
}

public extension EditorOp {
    /// Atomic-hash identity of the affected block, useful for logging or
    /// dedup. Inserts use the new block's hash; removes use the prior hash.
    var hash: String {
        switch self {
        case .insert(let h, _, _): return h
        case .remove(let h): return h
        }
    }
}

/// Pre→post tree diff that produces the `EditorOp` stream
/// `EditorView.mutate(_:_:)` hands to the host. Pure; no I/O.
public enum BlockTreeDiff {
    /// Diff pre→post into a stream of `EditorOp`s the host can apply to its
    /// recovery log as one ordered batch. Walks post preorder so a parent
    /// insert always precedes its children's inserts; removes are emitted
    /// first (sorted by hash) so the log reads naturally as "tombstone the
    /// gone, then announce the new."
    ///
    /// Skips blocks whose `(id, hash)` pair is unchanged: no op, no log entry,
    /// no churn. This is the property that makes moves and reorders silent
    /// (id stable, hash stable — but tree position changed).
    public static func derive(pre: [Block], post: [Block]) -> [EditorOp] {
        var preIDToHash: [BlockID: String] = [:]
        var preIDToParentID: [BlockID: BlockID] = [:]
        var preIDToParentHash: [BlockID: String] = [:]
        collect(pre, parentID: nil, parentHash: nil, hashes: &preIDToHash, parentIDs: &preIDToParentID, parentHashes: &preIDToParentHash)
        var postIDToHash: [BlockID: String] = [:]
        var postIDToParentID: [BlockID: BlockID] = [:]
        var postIDToParentHash: [BlockID: String] = [:]
        collect(post, parentID: nil, parentHash: nil, hashes: &postIDToHash, parentIDs: &postIDToParentID, parentHashes: &postIDToParentHash)

        var ops: [EditorOp] = []

        let removedHashes = preIDToHash
            .filter { id, hash in postIDToHash[id] != hash }
            .sorted { $0.value < $1.value }
            .map(\.value)
        for hash in removedHashes {
            ops.append(.remove(hash: hash))
        }

        func walk(_ blocks: [Block], parentHash: String?) {
            for block in blocks {
                let h = block.atomicHash
                let parentRefChangedUnderSameParent =
                    preIDToHash[block.id] == h &&
                    preIDToParentID[block.id] == postIDToParentID[block.id] &&
                    preIDToParentHash[block.id] != parentHash
                if preIDToHash[block.id] != h || parentRefChangedUnderSameParent {
                    ops.append(.insert(hash: h, parent: parentHash, block: block))
                }
                walk(block.children, parentHash: h)
            }
        }
        walk(post, parentHash: nil)
        return ops
    }

    private static func collect(
        _ blocks: [Block],
        parentID: BlockID?,
        parentHash: String?,
        hashes: inout [BlockID: String],
        parentIDs: inout [BlockID: BlockID],
        parentHashes: inout [BlockID: String]
    ) {
        for block in blocks {
            let hash = block.atomicHash
            hashes[block.id] = hash
            if let parentID {
                parentIDs[block.id] = parentID
            }
            if let parentHash {
                parentHashes[block.id] = parentHash
            }
            collect(
                block.children,
                parentID: block.id,
                parentHash: hash,
                hashes: &hashes,
                parentIDs: &parentIDs,
                parentHashes: &parentHashes
            )
        }
    }
}
