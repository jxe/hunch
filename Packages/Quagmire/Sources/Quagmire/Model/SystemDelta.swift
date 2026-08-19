import Foundation

/// The difference between the tree a host replaced and the tree it supplied,
/// expressed in terms the undo stack can be rebased against.
///
/// Why this exists: `Document`'s undo entries are whole-tree snapshots. That is
/// fine when every mutation is authored, but a host also replaces the tree for
/// reasons the user did not ask for — another window appended blocks, a peer's
/// journal restored a subtree, a provider completed the document on save. If
/// such a change lands while undo entries are outstanding, replaying one of
/// those snapshots would erase the arriving blocks and report them to the host
/// as user-authored removals. Clearing the whole undo stack avoids that, and is
/// what `Document.replaceChildren` does — but doing it on every append makes
/// undo unusable for any backend whose writes routinely come back changed.
///
/// So instead: describe the system's change once, and apply it to every
/// outstanding snapshot. An undo then restores the user's tree *plus* whatever
/// the system contributed since, which is what the user means by undo.
///
/// This is deliberately not a general three-way merge. It handles insertion,
/// removal, and in-place value changes. Anything that reparents a block that
/// already existed is not rebasable — `init?` returns nil and the caller falls
/// back to clearing undo. That covers the honest cases without pretending to
/// resolve ones it cannot.
struct SystemDelta {
    /// Roots of subtrees the system removed. Descendants are implied.
    let removed: Set<BlockID>
    /// Blocks that survived but whose own value the system changed.
    let kindChanges: [BlockID: BlockKind]
    /// Topmost new subtrees, in the order they appear in the new tree.
    let insertions: [Insertion]

    struct Insertion {
        let block: Block
        /// nil = root level.
        let parent: BlockID?
        /// The sibling this block follows in the new tree; nil = first child.
        let precedingSibling: BlockID?
    }

    var isEmpty: Bool {
        removed.isEmpty && kindChanges.isEmpty && insertions.isEmpty
    }

    /// Returns nil when the change is not rebasable, which means the caller
    /// must fall back to discarding undo.
    init?(from old: [Block], to new: [Block]) {
        let oldIndex = TreeIndex(old)
        let newIndex = TreeIndex(new)

        // A block that existed before and still exists must not have moved to a
        // different parent. Reparenting rewrites structure the snapshots also
        // describe, and merging those two descriptions is exactly the ambiguity
        // this type refuses to guess at.
        for (id, oldParent) in oldIndex.parent where newIndex.byID[id] != nil {
            if newIndex.parent[id] != oldParent { return nil }
        }

        // Nor may surviving siblings change their order relative to each other.
        // Insertions and removals are fine — those are what this type is for —
        // so the comparison drops anything that arrived or left and asks
        // whether what remains still reads the same way.
        //
        // A reorder is refused rather than modelled. Applying "the system moved
        // B before A" to a snapshot that may contain neither is the same guess
        // reparenting asks for. Left unrefused it is the more dangerous of the
        // two, because a pure reorder produces an *empty* delta: nothing to
        // rebase, snapshots left holding the old order, and the next undo
        // quietly reverting a change the user never made.
        for (scope, oldSiblings) in oldIndex.siblings {
            guard let newSiblings = newIndex.siblings[scope] else { continue }
            let oldSurvivors = oldSiblings.filter { newIndex.byID[$0] != nil }
            let newSurvivors = newSiblings.filter { oldIndex.byID[$0] != nil }
            if oldSurvivors != newSurvivors { return nil }
        }

        var removed: Set<BlockID> = []
        for (id, _) in oldIndex.byID where newIndex.byID[id] == nil {
            // Only record roots — removing a root takes its descendants along.
            let parent = oldIndex.parent[id] ?? nil
            if parent == nil || newIndex.byID[parent!] != nil {
                removed.insert(id)
            }
        }

        var kindChanges: [BlockID: BlockKind] = [:]
        for (id, oldBlock) in oldIndex.byID {
            guard let newBlock = newIndex.byID[id] else { continue }
            if newBlock.kind != oldBlock.kind {
                kindChanges[id] = newBlock.kind
            }
        }

        var insertions: [Insertion] = []
        var failed = false

        func scan(_ blocks: [Block], parent: BlockID?) {
            var preceding: BlockID?
            for block in blocks {
                if oldIndex.byID[block.id] == nil {
                    // A brand-new subtree may not smuggle in a block that
                    // already lives elsewhere in the old tree — that is a
                    // reparent wearing an insertion's clothes.
                    if TreeIndex.contains(anyOf: oldIndex.byID, in: block.children) {
                        failed = true
                        return
                    }
                    insertions.append(Insertion(block: block, parent: parent, precedingSibling: preceding))
                } else {
                    scan(block.children, parent: block.id)
                }
                preceding = block.id
            }
        }
        scan(new, parent: nil)
        if failed { return nil }

        self.removed = removed
        self.kindChanges = kindChanges
        self.insertions = insertions
    }

    /// Apply this delta to a stale snapshot of the same document.
    ///
    /// Blocks the snapshot never knew about are left alone: an insertion whose
    /// parent is absent from the snapshot has nowhere to go, and a kind change
    /// for an absent block has nothing to change.
    func rebase(_ snapshot: [Block]) -> [Block] {
        var result = snapshot
        if !removed.isEmpty {
            result = Self.removing(removed, from: result)
        }
        if !kindChanges.isEmpty {
            result = Self.applyingKindChanges(kindChanges, to: result)
        }
        for insertion in insertions {
            result = Self.inserting(insertion, into: result)
        }
        return result
    }

    // MARK: - Tree surgery

    private static func removing(_ ids: Set<BlockID>, from blocks: [Block]) -> [Block] {
        blocks.compactMap { block in
            guard !ids.contains(block.id) else { return nil }
            guard !block.children.isEmpty else { return block }
            return block.withChildren(removing(ids, from: block.children))
        }
    }

    private static func applyingKindChanges(_ changes: [BlockID: BlockKind], to blocks: [Block]) -> [Block] {
        blocks.map { block in
            var updated = block
            if let kind = changes[block.id] { updated.kind = kind }
            if !updated.children.isEmpty {
                updated.children = applyingKindChanges(changes, to: updated.children)
            }
            return updated
        }
    }

    private static func inserting(_ insertion: Insertion, into blocks: [Block]) -> [Block] {
        // Already there (a snapshot taken after the insertion) — nothing to do.
        if TreeIndex.contains(insertion.block.id, in: blocks) { return blocks }

        guard let parentID = insertion.parent else {
            return spliced(insertion, into: blocks)
        }
        return mapping(blocks, id: parentID) { parent in
            parent.withChildren(spliced(insertion, into: parent.children))
        }
    }

    private static func spliced(_ insertion: Insertion, into siblings: [Block]) -> [Block] {
        var out = siblings
        let position: Int
        if let preceding = insertion.precedingSibling,
           let index = out.firstIndex(where: { $0.id == preceding }) {
            position = index + 1
        } else if insertion.precedingSibling == nil {
            position = 0
        } else {
            // The sibling it followed is not in this snapshot — the system's
            // ordering intent is unrecoverable, so append rather than guess a
            // position that would read as the user's own reordering.
            position = out.count
        }
        out.insert(insertion.block, at: position)
        return out
    }

    private static func mapping(_ blocks: [Block], id: BlockID, _ transform: (Block) -> Block) -> [Block] {
        blocks.map { block in
            if block.id == id { return transform(block) }
            guard !block.children.isEmpty else { return block }
            return block.withChildren(mapping(block.children, id: id, transform))
        }
    }
}

/// Flat views of a block tree, built once per delta.
private struct TreeIndex {
    var byID: [BlockID: Block] = [:]
    /// Present for every indexed block; the value is nil at root level, so this
    /// is read as `parent[id] ?? nil` when a plain optional is wanted.
    var parent: [BlockID: BlockID?] = [:]
    /// Child ids in order, per scope. The nil key is the root list.
    var siblings: [BlockID?: [BlockID]] = [:]

    init(_ blocks: [Block]) {
        func walk(_ blocks: [Block], parent parentID: BlockID?) {
            siblings[parentID] = blocks.map(\.id)
            for block in blocks {
                byID[block.id] = block
                parent[block.id] = parentID
                walk(block.children, parent: block.id)
            }
        }
        walk(blocks, parent: nil)
    }

    static func contains(_ id: BlockID, in blocks: [Block]) -> Bool {
        for block in blocks {
            if block.id == id { return true }
            if contains(id, in: block.children) { return true }
        }
        return false
    }

    static func contains(anyOf ids: [BlockID: Block], in blocks: [Block]) -> Bool {
        for block in blocks {
            if ids[block.id] != nil { return true }
            if contains(anyOf: ids, in: block.children) { return true }
        }
        return false
    }
}
