import Foundation

/// Pure tree-walk helpers shared between the editor and the host. The host's
/// `EditorHost.didMutate(pre:post:name:)` implementation uses these to compute
/// recovery-log tombstones (block ids present before the mutation, absent
/// after → purge their atomic hashes).
public enum BlockTreeDiff {
    /// Walk the tree, mapping each `BlockID` to its current atomic hash.
    public static func idToAtomicHash(_ blocks: [Block]) -> [BlockID: String] {
        var out: [BlockID: String] = [:]
        collectIDHashes(blocks, into: &out)
        return out
    }

    /// All `BlockID`s in `blocks` and their descendants.
    public static func collectIDs(_ blocks: [Block]) -> Set<BlockID> {
        var out: Set<BlockID> = []
        collectIDs(blocks, into: &out)
        return out
    }

    /// Block ids that were present in `preByID` but are no longer present
    /// anywhere in `post`'s tree → their atomic hashes, in deterministic order.
    public static func removedHashes(preByID: [BlockID: String], post: [Block]) -> [String] {
        let postIDs = collectIDs(post)
        return preByID
            .filter { !postIDs.contains($0.key) }
            .sorted { $0.value < $1.value }
            .map(\.value)
    }

    private static func collectIDHashes(_ blocks: [Block], into out: inout [BlockID: String]) {
        for block in blocks {
            out[block.id] = block.atomicHash
            collectIDHashes(block.children, into: &out)
        }
    }

    private static func collectIDs(_ blocks: [Block], into out: inout Set<BlockID>) {
        for block in blocks {
            out.insert(block.id)
            collectIDs(block.children, into: &out)
        }
    }
}
