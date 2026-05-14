import Foundation
import Editor

/// Pure block-tree merge for iCloud conflict resolution. Takes the survivor's
/// parsed blocks plus zero or more alternate-version block lists, and returns
/// the survivor's structure augmented with any block whose atomic hash exists
/// in an alternate but not in the survivor (and isn't tombstoned in the
/// recovery log). Spliced-in blocks land under their original parent in the
/// alternate when that parent is alive in the survivor, otherwise climb the
/// recorded parent chain via `parentHashLookup` to the nearest live ancestor,
/// otherwise top-level.
///
/// The merger is intentionally side-effect-free — no filesystem, no log
/// writes. The caller (`Clamshell.resolveConflictVersions`) is responsible
/// for parsing alternate URLs, pulling tombstones from the recovery log,
/// and writing the merged result.
@MainActor
enum ConflictMerger {
    struct Result {
        let merged: [Block]
        let salvagedHashes: [String]
    }

    static func merge(
        survivor: [Block],
        alternates: [[Block]],
        tombstones: Set<String>,
        parentHashLookup: (String) -> String?
    ) -> Result {
        var liveHashes: Set<String> = []
        collectAtomicHashes(survivor, into: &liveHashes)

        let doc = Document(
            url: URL(fileURLWithPath: "/conflict-merge"),
            title: "",
            children: survivor
        )

        var hashToID: [String: BlockID] = [:]
        rebuildHashToID(doc.children, into: &hashToID)

        var salvaged: [String] = []
        for alternate in alternates {
            walk(
                blocks: alternate,
                parentInAlternate: nil,
                doc: doc,
                liveHashes: &liveHashes,
                hashToID: &hashToID,
                tombstones: tombstones,
                parentHashLookup: parentHashLookup,
                salvaged: &salvaged
            )
        }

        doc.enforceHeadingContainment()
        return Result(merged: doc.children, salvagedHashes: salvaged)
    }

    private static func walk(
        blocks: [Block],
        parentInAlternate: String?,
        doc: Document,
        liveHashes: inout Set<String>,
        hashToID: inout [String: BlockID],
        tombstones: Set<String>,
        parentHashLookup: (String) -> String?,
        salvaged: inout [String]
    ) {
        for block in blocks {
            let hash = BlockFingerprint.atomicHash(block)
            if liveHashes.contains(hash) {
                walk(
                    blocks: block.children,
                    parentInAlternate: hash,
                    doc: doc,
                    liveHashes: &liveHashes,
                    hashToID: &hashToID,
                    tombstones: tombstones,
                    parentHashLookup: parentHashLookup,
                    salvaged: &salvaged
                )
                continue
            }
            if tombstones.contains(hash) {
                walk(
                    blocks: block.children,
                    parentInAlternate: hash,
                    doc: doc,
                    liveHashes: &liveHashes,
                    hashToID: &hashToID,
                    tombstones: tombstones,
                    parentHashLookup: parentHashLookup,
                    salvaged: &salvaged
                )
                continue
            }

            let parentID = resolveLiveParent(
                directParentHash: parentInAlternate,
                hashToID: hashToID,
                parentHashLookup: parentHashLookup
            )
            let shell = Block(id: BlockID(), kind: block.kind, children: [])
            let siblingCount = (parentID.flatMap { doc.find($0)?.children } ?? doc.children).count
            doc.insertSubtree(shell, at: DropPath(parent: parentID, position: siblingCount))

            liveHashes.insert(hash)
            hashToID[hash] = shell.id
            salvaged.append(hash)

            walk(
                blocks: block.children,
                parentInAlternate: hash,
                doc: doc,
                liveHashes: &liveHashes,
                hashToID: &hashToID,
                tombstones: tombstones,
                parentHashLookup: parentHashLookup,
                salvaged: &salvaged
            )
        }
    }

    /// Walk up the alternate's parent-hash chain (then the log union's chain
    /// once the alternate's chain falls off the end) until a hash is found
    /// that maps to a live block in the merged doc. Returns nil for top-level.
    private static func resolveLiveParent(
        directParentHash: String?,
        hashToID: [String: BlockID],
        parentHashLookup: (String) -> String?
    ) -> BlockID? {
        var current = directParentHash
        var safety = 64
        while let hash = current, safety > 0 {
            if let id = hashToID[hash] { return id }
            current = parentHashLookup(hash)
            safety -= 1
        }
        return nil
    }

    private static func collectAtomicHashes(_ blocks: [Block], into out: inout Set<String>) {
        for block in blocks {
            out.insert(BlockFingerprint.atomicHash(block))
            collectAtomicHashes(block.children, into: &out)
        }
    }

    private static func rebuildHashToID(_ blocks: [Block], into map: inout [String: BlockID]) {
        for block in blocks {
            map[BlockFingerprint.atomicHash(block)] = block.id
            rebuildHashToID(block.children, into: &map)
        }
    }
}
