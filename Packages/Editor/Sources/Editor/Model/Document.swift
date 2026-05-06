import Foundation
import Observation

/// A tree-shaped insertion address: "before child[position] of `parent`".
/// `parent == nil` is the document root. `position` is in `0...parent.children.count`.
public struct DropPath: Hashable, Sendable {
    public let parent: BlockID?
    public let position: Int

    public init(parent: BlockID?, position: Int) {
        self.parent = parent
        self.position = position
    }

    public static func root(at position: Int) -> DropPath {
        DropPath(parent: nil, position: position)
    }
}

/// Document is a tree of blocks. Root-level siblings live in `children`.
/// Class-typed and `@Observable` so SwiftUI subscribes to mutations; Block
/// stays a value type so undo snapshots are cheap (just `children`).
///
/// Mutations funnel through the named methods on this class so the parent
/// cache stays consistent. Direct `children = …` assignment works but
/// invalidates the cache.
@Observable @MainActor
public final class Document: @MainActor Identifiable {
    public let url: URL
    public var title: String
    public var children: [Block] {
        didSet { _parentCache = nil }
    }
    public var modificationDate: Date?

    public var id: URL { url }

    @ObservationIgnored
    private var _parentCache: [BlockID: BlockID]?

    public init(url: URL, title: String, children: [Block], modificationDate: Date? = nil) {
        self.url = url
        self.title = title
        self.children = children
        self.modificationDate = modificationDate
    }

    /// Pulls a title out of the first top-level H1, falling back to the
    /// caller-provided default. Does not recurse into containers — a heading
    /// inside a toggle is body content, not the page title.
    public static func deriveTitle(from rootChildren: [Block], fallback: String) -> String {
        for block in rootChildren {
            if case .heading(.h1, let text) = block.kind {
                let s = String(text.characters)
                if !s.isEmpty { return s }
            }
        }
        return fallback
    }

    // MARK: - Snapshot for undo

    /// Snapshot the current tree as `[Block]`. Cheap because Block is a value
    /// type — only the spine of the tree (Array storage) is shallow-copied;
    /// payloads (AttributedString, etc.) are COW.
    public func snapshot() -> [Block] { children }

    /// Restore the tree from a previously-taken snapshot.
    public func restore(_ snapshot: [Block]) {
        children = snapshot
    }

    // MARK: - Find / walk

    /// Returns the block with the given id, anywhere in the tree.
    public func find(_ blockID: BlockID) -> Block? {
        Self.findRecursive(in: children, id: blockID)
    }

    private static func findRecursive(in blocks: [Block], id: BlockID) -> Block? {
        for block in blocks {
            if block.id == id { return block }
            if let found = findRecursive(in: block.children, id: id) { return found }
        }
        return nil
    }

    /// IndexPath from the root. `[0]` is the first top-level block; `[2, 1]`
    /// is `children[2].children[1]`.
    public func path(to blockID: BlockID) -> IndexPath? {
        var stack = IndexPath()
        if Self.searchPath(in: children, id: blockID, stack: &stack) { return stack }
        return nil
    }

    private static func searchPath(in blocks: [Block], id: BlockID, stack: inout IndexPath) -> Bool {
        for (i, block) in blocks.enumerated() {
            stack.append(i)
            if block.id == id { return true }
            if searchPath(in: block.children, id: id, stack: &stack) { return true }
            stack.removeLast()
        }
        return false
    }

    /// Returns the BlockID of `blockID`'s direct parent, or `nil` if it's a
    /// root-level block (or not in the tree).
    public func parent(of blockID: BlockID) -> BlockID? {
        ensureParentCache()
        return _parentCache?[blockID]
    }

    private func ensureParentCache() {
        if _parentCache != nil { return }
        var cache: [BlockID: BlockID] = [:]
        Self.fillParents(in: children, parent: nil, into: &cache)
        _parentCache = cache
    }

    private static func fillParents(in blocks: [Block], parent: BlockID?, into cache: inout [BlockID: BlockID]) {
        for block in blocks {
            if let parent { cache[block.id] = parent }
            fillParents(in: block.children, parent: block.id, into: &cache)
        }
    }

    /// All ids in `blockID`'s subtree, including `blockID` itself.
    public func subtreeIDs(of blockID: BlockID) -> Set<BlockID> {
        var out: Set<BlockID> = []
        if let block = find(blockID) {
            collectIDs(of: block, into: &out)
        }
        return out
    }

    private func collectIDs(of block: Block, into out: inout Set<BlockID>) {
        out.insert(block.id)
        for child in block.children { collectIDs(of: child, into: &out) }
    }

    /// Preorder document-order index of `blockID` (0 = first top-level block).
    /// Used to sort selections that span subtrees.
    public func documentOrder(of blockID: BlockID) -> Int? {
        var index = 0
        if let order = Self.preorderIndex(in: children, id: blockID, counter: &index) {
            return order
        }
        return nil
    }

    private static func preorderIndex(in blocks: [Block], id: BlockID, counter: inout Int) -> Int? {
        for block in blocks {
            if block.id == id { return counter }
            counter += 1
            if let order = preorderIndex(in: block.children, id: id, counter: &counter) { return order }
        }
        return nil
    }

    /// The block immediately preceding `blockID` in preorder traversal — i.e.
    /// the block "above" it visually if everything is expanded. Used by the
    /// recovery layer to anchor lost-block records.
    public func preorderPredecessor(of blockID: BlockID) -> BlockID? {
        var previous: BlockID?
        var found: BlockID?
        Self.walkPreorder(in: children) { block, _, _ in
            if block.id == blockID { found = previous }
            previous = block.id
        }
        return found ?? nil
    }

    /// Preorder walk yielding (block, depth, parentID?) for every node.
    public func walk(_ visit: (_ block: Block, _ depth: Int, _ parent: BlockID?) -> Void) {
        Self.walkPreorder(in: children, depth: 0, parent: nil, visit: visit)
    }

    private static func walkPreorder(in blocks: [Block], depth: Int = 0, parent: BlockID? = nil, visit: (Block, Int, BlockID?) -> Void) {
        for block in blocks {
            visit(block, depth, parent)
            walkPreorder(in: block.children, depth: depth + 1, parent: block.id, visit: visit)
        }
    }

    // MARK: - Mutation primitives

    /// Apply a transform to the block at `blockID` in place. Returns `true` if
    /// the block was found and the transform applied. The transform receives
    /// an `inout Block` so callers can patch `kind` and/or `children`.
    @discardableResult
    public func mutate(_ blockID: BlockID, _ transform: (inout Block) -> Void) -> Bool {
        var didMutate = false
        Self.mutateRecursive(in: &children, id: blockID, transform: transform, didMutate: &didMutate)
        if didMutate { _parentCache = nil }
        return didMutate
    }

    private static func mutateRecursive(in blocks: inout [Block], id: BlockID, transform: (inout Block) -> Void, didMutate: inout Bool) {
        for i in blocks.indices {
            if blocks[i].id == id {
                transform(&blocks[i])
                didMutate = true
                return
            }
            mutateRecursive(in: &blocks[i].children, id: id, transform: transform, didMutate: &didMutate)
            if didMutate { return }
        }
    }

    /// Convenience: replace the text on `blockID` (uses `Block.withText`).
    @discardableResult
    public func setText(_ blockID: BlockID, _ newText: AttributedString) -> Bool {
        mutate(blockID) { $0 = $0.withText(newText) }
    }

    /// Remove the subtree rooted at `blockID` and return it. Returns `nil` if
    /// the id isn't found.
    @discardableResult
    public func removeSubtree(_ blockID: BlockID) -> Block? {
        var removed: Block?
        Self.removeRecursive(in: &children, id: blockID, removed: &removed)
        if removed != nil { _parentCache = nil }
        return removed
    }

    private static func removeRecursive(in blocks: inout [Block], id: BlockID, removed: inout Block?) {
        for i in blocks.indices {
            if blocks[i].id == id {
                removed = blocks.remove(at: i)
                return
            }
            removeRecursive(in: &blocks[i].children, id: id, removed: &removed)
            if removed != nil { return }
        }
    }

    /// Insert a subtree at the given drop path. Returns `false` if the parent
    /// id is unknown or the position is out of range.
    @discardableResult
    public func insertSubtree(_ block: Block, at path: DropPath) -> Bool {
        let success = insertSubtrees([block], at: path)
        return success
    }

    @discardableResult
    public func insertSubtrees(_ blocks: [Block], at path: DropPath) -> Bool {
        if blocks.isEmpty { return true }
        let success: Bool
        if let parentID = path.parent {
            success = mutate(parentID) { parent in
                let pos = max(0, min(path.position, parent.children.count))
                parent.children.insert(contentsOf: blocks, at: pos)
            }
        } else {
            let pos = max(0, min(path.position, children.count))
            children.insert(contentsOf: blocks, at: pos)
            success = true
        }
        if success { _parentCache = nil }
        return success
    }

    /// Replace the subtree at `blockID` with `replacements` (a flat list that
    /// becomes the new sibling sequence at that position). Used by mention
    /// commit, autotransforms, and turn-into.
    @discardableResult
    public func replaceSubtree(_ blockID: BlockID, with replacements: [Block]) -> Bool {
        var success = false
        Self.replaceRecursive(in: &children, id: blockID, with: replacements, success: &success)
        if success { _parentCache = nil }
        return success
    }

    private static func replaceRecursive(in blocks: inout [Block], id: BlockID, with replacements: [Block], success: inout Bool) {
        for i in blocks.indices {
            if blocks[i].id == id {
                blocks.replaceSubrange(i...i, with: replacements)
                success = true
                return
            }
            replaceRecursive(in: &blocks[i].children, id: id, with: replacements, success: &success)
            if success { return }
        }
    }

    // MARK: - Selection helpers

    /// Reduce a selection to its minimal subtree-roots (drop any id that's a
    /// descendant of another selected id). Returned in document order.
    public func selectionSubtreeRoots(_ ids: Set<BlockID>) -> [BlockID] {
        guard !ids.isEmpty else { return [] }
        var coveredDescendants: Set<BlockID> = []
        for id in ids {
            guard let block = find(id) else { continue }
            for child in block.children {
                collectIDs(of: child, into: &coveredDescendants)
            }
        }
        let roots = ids.subtracting(coveredDescendants)
        return roots.sorted { (a, b) in
            (documentOrder(of: a) ?? .max) < (documentOrder(of: b) ?? .max)
        }
    }

    // MARK: - Validity predicates

    /// Can this block be indented? True iff it has a previous sibling under
    /// its current parent that is structurally permitted to contain it.
    public func canIndent(_ blockID: BlockID) -> Bool {
        guard let block = find(blockID),
              let (siblings, indexInParent) = sibling(of: blockID),
              indexInParent > 0 else { return false }
        let prevSibling = siblings[indexInParent - 1]
        return prevSibling.canContain(block)
    }

    /// Can this block be outdented? True iff its parent isn't the root, AND
    /// the grandparent (or root) can structurally contain this block.
    /// Heading-containment caveat: outdenting a child of a heading would
    /// land it as a sibling of the heading, but the heading-containment
    /// invariant immediately re-folds it back. So refuse the op upfront —
    /// `Tab`/`Shift-Tab` on a heading-child grays out instead of no-op'ing.
    public func canOutdent(_ blockID: BlockID) -> Bool {
        guard let block = find(blockID),
              let parentID = parent(of: blockID),
              let parentBlock = find(parentID) else { return false }
        if parentBlock.isHeading {
            return false
        }
        // Grandparent: if parent is itself root-level, "outdent to root" is
        // always allowed. Otherwise the grandparent must structurally accept.
        if let grandparentID = parent(of: parentBlock.id) {
            guard let grand = find(grandparentID) else { return false }
            return grand.canContain(block)
        }
        return true
    }

    /// Can the given subtree-roots be dropped at this path? Rejects:
    /// - dropping any moving id into its own descendants (cycle),
    /// - dropping into a leaf (parent must be a container),
    /// - dropping a heading where containment-by-level is violated.
    public func canDrop(ids: [BlockID], to path: DropPath) -> Bool {
        guard !ids.isEmpty else { return false }
        // Cycle check: target.parent must not be inside any moving subtree.
        if let targetParentID = path.parent {
            for id in ids {
                if subtreeIDs(of: id).contains(targetParentID) { return false }
            }
        }
        // Containment check: each moved subtree-root must be acceptable to
        // the target parent.
        if let parentID = path.parent {
            guard let parentBlock = find(parentID), parentBlock.isContainer else { return false }
            for id in ids {
                guard let block = find(id), parentBlock.canContain(block) else { return false }
            }
        }
        return true
    }

    // MARK: - Indent / outdent / slide

    /// Move `blockID` to be the last child of its previous sibling under the
    /// same parent. Returns `true` on success.
    @discardableResult
    public func indent(_ blockID: BlockID) -> Bool {
        guard canIndent(blockID),
              let (_, indexInParent) = sibling(of: blockID) else { return false }
        let parentID = parent(of: blockID)
        guard let block = removeFromParent(blockID) else { return false }
        // After removal, the previous sibling is at indexInParent - 1 in the
        // (now shorter) list. Append to that sibling's children.
        let prevSiblingIndex = indexInParent - 1
        let prevSibling: Block
        if let parentID {
            guard let parentBlock = find(parentID) else { return false }
            prevSibling = parentBlock.children[prevSiblingIndex]
        } else {
            prevSibling = children[prevSiblingIndex]
        }
        let drop = DropPath(parent: prevSibling.id, position: prevSibling.children.count)
        return insertSubtree(block, at: drop)
    }

    /// Move `blockID` to be the next sibling of its parent. Returns `true` on success.
    @discardableResult
    public func outdent(_ blockID: BlockID) -> Bool {
        guard canOutdent(blockID),
              let parentID = parent(of: blockID),
              let parentBlock = find(parentID) else { return false }
        let grandparentID = parent(of: parentID)
        guard let block = removeFromParent(blockID) else { return false }
        // Find parent's position under grandparent (or root) and insert after it.
        let siblingsAtGrandparent: [Block]
        if let grandparentID {
            guard let grandparentBlock = find(grandparentID) else { return false }
            siblingsAtGrandparent = grandparentBlock.children
        } else {
            siblingsAtGrandparent = children
        }
        guard let parentIndex = siblingsAtGrandparent.firstIndex(where: { $0.id == parentBlock.id }) else { return false }
        let drop = DropPath(parent: grandparentID, position: parentIndex + 1)
        return insertSubtree(block, at: drop)
    }

    /// Returns the (siblings, indexInParent) for `blockID`, looking at root if
    /// the block is top-level.
    private func sibling(of blockID: BlockID) -> (siblings: [Block], indexInParent: Int)? {
        if let parentID = parent(of: blockID), let parentBlock = find(parentID) {
            guard let i = parentBlock.children.firstIndex(where: { $0.id == blockID }) else { return nil }
            return (parentBlock.children, i)
        }
        if let i = children.firstIndex(where: { $0.id == blockID }) {
            return (children, i)
        }
        return nil
    }

    private func removeFromParent(_ blockID: BlockID) -> Block? {
        removeSubtree(blockID)
    }

    /// Move a contiguous slab of sibling subtrees up or down by one position.
    /// Requires all `ids` to be siblings under one parent. Returns `false`
    /// otherwise. At a parent boundary, the slab is reparented to be a
    /// sibling of its parent (matches today's slide-out-of-parent behavior).
    @discardableResult
    public func slideSiblings(_ ids: Set<BlockID>, by delta: Int) -> Bool {
        guard delta == -1 || delta == 1, !ids.isEmpty else { return false }
        // Roots that share a parent
        let parentID = parent(of: ids.first!)
        for id in ids {
            if parent(of: id) != parentID { return false }
        }
        let siblings: [Block] = parentID.flatMap(find)?.children ?? children
        let positions = ids.compactMap { id in siblings.firstIndex { $0.id == id } }.sorted()
        guard positions.count == ids.count else { return false }
        // Contiguous?
        guard positions == Array(positions.first!...positions.last!) else { return false }

        let first = positions.first!
        let last = positions.last!

        if delta < 0 {
            if first == 0 {
                // At top of parent — reparent slab to grandparent (just before parent).
                guard let parentID, let parentBlock = find(parentID) else { return false }
                let grandparentID = parent(of: parentID)
                let movedBlocks = positions.map { siblings[$0] }
                for id in ids { removeSubtree(id) }
                // Find parent position under its grandparent (or root)
                let outerSiblings: [Block]
                if let grandparentID {
                    outerSiblings = find(grandparentID)?.children ?? []
                } else {
                    outerSiblings = children
                }
                guard let parentIndexUnderGrand = outerSiblings.firstIndex(where: { $0.id == parentBlock.id }) else { return false }
                return insertSubtrees(movedBlocks, at: DropPath(parent: grandparentID, position: parentIndexUnderGrand))
            }
            // Swap with previous sibling (single-position slide)
            let movedBlocks = positions.map { siblings[$0] }
            for id in ids { removeSubtree(id) }
            let drop = DropPath(parent: parentID, position: first - 1)
            return insertSubtrees(movedBlocks, at: drop)
        } else {
            let nextPosition = last + 1
            if nextPosition >= siblings.count {
                // At end of parent — reparent slab to grandparent (just after parent).
                guard let parentID, let parentBlock = find(parentID) else { return false }
                let grandparentID = parent(of: parentID)
                let movedBlocks = positions.map { siblings[$0] }
                for id in ids { removeSubtree(id) }
                let outerSiblings: [Block]
                if let grandparentID {
                    outerSiblings = find(grandparentID)?.children ?? []
                } else {
                    outerSiblings = children
                }
                guard let parentIndexUnderGrand = outerSiblings.firstIndex(where: { $0.id == parentBlock.id }) else { return false }
                return insertSubtrees(movedBlocks, at: DropPath(parent: grandparentID, position: parentIndexUnderGrand + 1))
            }
            // Slide down: remove slab, insert at first + 1 (so next-sibling lands before the slab)
            let movedBlocks = positions.map { siblings[$0] }
            for id in ids { removeSubtree(id) }
            // After removal, original `first+1` (the next sibling) is now at index `first`.
            // To slide one position, insert moved blocks at index `first + 1`.
            let drop = DropPath(parent: parentID, position: first + 1)
            return insertSubtrees(movedBlocks, at: drop)
        }
    }

    // MARK: - Bulk move (drop)

    /// Move the given subtrees to `target` in one go. Validates with
    /// `canDrop` first. Preserves document order of the moved blocks.
    @discardableResult
    public func moveSubtrees(_ ids: [BlockID], to target: DropPath) -> Bool {
        guard canDrop(ids: ids, to: target) else { return false }
        // Collect the subtrees in document order before removing them.
        let ordered = ids.sorted { (a, b) in
            (documentOrder(of: a) ?? .max) < (documentOrder(of: b) ?? .max)
        }
        var collected: [Block] = []
        for id in ordered {
            if let removed = removeSubtree(id) {
                collected.append(removed)
            }
        }
        // After removals, target.position may have shifted. Adjust if any of
        // the removed siblings lived under target.parent at a position ≤ the
        // requested target.position.
        var adjustedPosition = target.position
        if let targetParent = target.parent {
            // Count how many of the collected blocks were originally under targetParent
            // at a position less than the original target.position. Without the original
            // positions captured pre-removal we approximate by clamping; the caller is
            // expected to compute target on a snapshot they took before the drag.
            if let parentBlock = find(targetParent) {
                adjustedPosition = max(0, min(adjustedPosition, parentBlock.children.count))
            }
        } else {
            adjustedPosition = max(0, min(adjustedPosition, children.count))
        }
        let dropPath = DropPath(parent: target.parent, position: adjustedPosition)
        return insertSubtrees(collected, at: dropPath)
    }

    // MARK: - Heading-containment invariant

    /// Re-fold the tree so every heading owns its body (subsequent siblings
    /// up to the next heading at same-or-higher level), and every leaf has
    /// no orphan children. Idempotent: a tree that already satisfies the
    /// invariants survives unchanged.
    ///
    /// Called by the editor's `mutate(_:_:)` after every structural change so
    /// the user can't observe an intermediate state where, e.g., a paragraph
    /// is a sibling of a heading instead of its child. Cheap on small docs
    /// (single tree walk).
    public func enforceHeadingContainment() {
        let lifted = Self.liftLeafOrphans(children)
        children = Self.applyHeadingContainment(lifted)
        _parentCache = nil
    }

    /// Promote any orphan children of leaf blocks (paragraphs, code blocks,
    /// dividers, subpages, images, quotes) to siblings just after the leaf.
    /// Recursive — children are normalized before checking the parent's
    /// leaf-status, so a deeply-nested orphan bubbles up cleanly.
    private static func liftLeafOrphans(_ blocks: [Block]) -> [Block] {
        let recursed: [Block] = blocks.map { block in
            block.children.isEmpty ? block : block.withChildren(liftLeafOrphans(block.children))
        }
        var out: [Block] = []
        for block in recursed {
            if !block.isContainer && !block.children.isEmpty {
                out.append(block.withChildren([]))
                out.append(contentsOf: block.children)
            } else {
                out.append(block)
            }
        }
        return out
    }

    /// Re-apply heading containment scope-by-scope. Each scope (root or any
    /// container's children list) is flattened across heading boundaries,
    /// then re-folded so headings capture exactly their valid body.
    private static func applyHeadingContainment(_ blocks: [Block]) -> [Block] {
        // Recurse into every container's children so each subscope is fixed
        // before we re-fold at this scope. Both heading containers and
        // structural containers participate — a structural container's
        // children might also need heading-fold.
        let recursed: [Block] = blocks.map { block in
            block.children.isEmpty ? block : block.withChildren(applyHeadingContainment(block.children))
        }
        return foldHeadings(flattenHeadings(recursed))
    }

    /// Walk siblings; for every heading, emit the heading (with its children
    /// stripped) followed by the recursively-flattened original children.
    /// Non-heading containers (toggle/list-item/template) keep their fixed
    /// children intact — they're opaque from heading-fold's perspective.
    private static func flattenHeadings(_ blocks: [Block]) -> [Block] {
        var out: [Block] = []
        for block in blocks {
            if case .heading = block.kind {
                out.append(block.withChildren([]))
                out.append(contentsOf: flattenHeadings(block.children))
            } else {
                out.append(block)
            }
        }
        return out
    }

    /// Fold a flat sibling sequence into a tree by heading containment: a
    /// heading at level L captures every subsequent sibling until the next
    /// heading at level ≤ L. (Higher rawValue = deeper level; H1 = 1, H2 = 2.)
    /// Same algorithm the parser uses post-`parseMarkdown`; exposed here so
    /// the editor can re-apply it after live mutations.
    public static func foldHeadings(_ blocks: [Block]) -> [Block] {
        var rootChildren: [Block] = []
        var stack: [(block: Block, level: HeadingLevel)] = []

        func appendChild(_ child: Block) {
            if stack.isEmpty {
                rootChildren.append(child)
            } else {
                stack[stack.count - 1].block.children.append(child)
            }
        }
        func popOne() {
            let popped = stack.removeLast()
            if stack.isEmpty {
                rootChildren.append(popped.block)
            } else {
                stack[stack.count - 1].block.children.append(popped.block)
            }
        }

        for block in blocks {
            if case .heading(let level, _) = block.kind {
                while let top = stack.last, top.level.rawValue >= level.rawValue {
                    popOne()
                }
                stack.append((block: block, level: level))
            } else {
                appendChild(block)
            }
        }
        while !stack.isEmpty { popOne() }
        return rootChildren
    }
}
