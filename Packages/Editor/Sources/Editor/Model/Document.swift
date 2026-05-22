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
/// External mutations must funnel through `transaction(name:_:)` (or its
/// primitives `mutate` / `setText` / `insertSubtree` / `replaceSubtree`),
/// which fires `preMutation` and registers undo. For bulk non-undoable
/// replacement (conflict resolution, reload), use `replaceChildren(_:)`.
@Observable @MainActor
public final class Document: @MainActor Identifiable {
    public let url: URL
    public internal(set) var children: [Block] {
        didSet { _parentCache = nil }
    }
    public var modificationDate: Date?

    public var id: URL { url }

    /// Derived from `children` (first top-level H1) with the URL's filename
    /// (sans extension) as fallback. Single source of truth — no separate
    /// stored field, no risk of drift after children mutate.
    public var title: String {
        Document.deriveTitle(from: children, fallback: url.deletingPathExtension().lastPathComponent)
    }

    @ObservationIgnored
    private var _parentCache: [BlockID: BlockID]?

    /// `UndoManager` to register transaction inverses against. Injected by the
    /// editor on mount; nil means transactions still run but don't accumulate
    /// undo history (useful for non-editor mutations like load).
    @ObservationIgnored
    public weak var undoManager: UndoManager?

    /// Editor-supplied hook fired before every transaction's `change` closure.
    /// Used to flush in-flight NSTextView text into the model so the snapshot
    /// captures it. Set by `EditorView` on mount.
    @ObservationIgnored
    public var preMutation: (() -> Void)?

    /// Editor-supplied hook fired after every `transaction` — forward, undo,
    /// or redo — with the diff that takes the doc *from* the prior state *to*
    /// the new state. Forward: the transaction's own pre→post ops. Undo: the
    /// inverted ops. Redo: the forward ops fire again. Same hook for all
    /// three flavours so the editor's emission to the host is symmetric
    /// across the round-trip, and `EditorState` revalidation happens once in
    /// one place regardless of direction.
    @ObservationIgnored
    public var didCommitTransaction: (([EditorOp]) -> Void)?

    /// Editor-supplied hook fired after `replaceChildren(_:)` swaps the tree
    /// wholesale (external-edit reloads, conflict merges). Fresh parse →
    /// fresh BlockIDs, so the editor needs to revalidate `EditorState`
    /// against the new id set. Set by `EditorView` on mount.
    @ObservationIgnored
    public var didReplaceChildren: (() -> Void)?

    /// Coalesce window — same `coalesceKey` within this interval is folded into
    /// the previous transaction's undo entry (no new entry registered).
    public static let coalesceInterval: TimeInterval = 1.0

    @ObservationIgnored
    private var lastTransactionKey: AnyHashable?

    @ObservationIgnored
    private var lastTransactionTime: Date?

    /// Set while a `transaction(...)` call is on the stack. A nested call
    /// (typically from inside `preMutation` — e.g. `BlockTextEditor`'s typing
    /// path opens its own transaction to flush text — but also any explicit
    /// nested call) collapses into the outer: it runs its `change` closure
    /// and returns without firing `preMutation`, without snapshotting, and
    /// without registering its own undo entry. The outer transaction's
    /// snapshot captures the post-inner state, so undo of the outer reverses
    /// both as one atomic action.
    @ObservationIgnored
    private var inTransaction: Bool = false

    public init(url: URL, children: [Block], modificationDate: Date? = nil) {
        self.url = url
        self.children = children
        self.modificationDate = modificationDate
    }

    // MARK: - Transaction (unified mutation + undo entry point)

    /// Mutate the document atomically. Calls register an undo entry against
    /// `undoManager`. If `coalesceKey` matches the previous transaction's key
    /// within `coalesceInterval`, the mutation is applied without registering
    /// a new undo entry — the previous entry's pre-mutation snapshot already
    /// captures the burst's start. Use for typing (`coalesceKey = blockID`)
    /// and any other rapid-fire same-thing mutations; pass `nil` for one-shot
    /// structural edits.
    ///
    /// Fires `preMutation` (editor flush) before the change, then
    /// `enforceHeadingContainment` after — both inside the same atomic
    /// boundary so the registered undo restores a valid tree. Computes the
    /// pre→post `[EditorOp]` diff, fires `didCommitTransaction(ops)`, and
    /// returns the diff. Nested transactions absorb into the outer (no new
    /// undo entry, no diff fired) so callers don't double-emit.
    @discardableResult
    public func transaction(
        name: String,
        coalesceKey: AnyHashable? = nil,
        _ change: () -> Void
    ) -> [EditorOp] {
        // Nested call: absorb into the outer. The outer's snapshot already
        // covers everything before its `change` closure runs, and its
        // `preMutation` already fired. Just apply the change.
        if inTransaction {
            change()
            return []
        }
        inTransaction = true
        defer { inTransaction = false }

        let now = Date()
        let shouldCoalesce =
            coalesceKey != nil &&
            coalesceKey == lastTransactionKey &&
            (lastTransactionTime.map { now.timeIntervalSince($0) < Self.coalesceInterval } == true)

        // Capture `before` (the pre-mutation tree) BEFORE preMutation, so any
        // state mutations the hook triggers via nested transactions (e.g. the
        // typing path's `commitLiveText` flushing in-flight NSTextView text
        // through a nested `transaction`) are also captured in `before`. Undo
        // then reverts the whole logical action — flush + change — as one
        // atomic step. Coalesced transactions still snapshot for the diff;
        // they just skip registering a new undo entry (the burst's first
        // entry already captured the start). `Block` is a value type, so
        // capturing `children` is a cheap shallow Array copy with COW
        // payloads.
        let before = children
        preMutation?()
        change()
        enforceHeadingContainment()
        let ops = BlockTreeDiff.derive(pre: before, post: children)
        if !shouldCoalesce, let undoManager {
            // The inverse of any forward transaction is another transaction
            // that resets `children` to `before`. Routing through the same
            // entry point means undo, redo, and forward share one code path:
            // they each snapshot, diff, register their own inverse, and fire
            // `didCommitTransaction` with the resulting diff. UndoManager
            // tracks the undo/redo direction and routes each newly-registered
            // entry onto the right stack.
            undoManager.registerUndo(withTarget: self) { doc in
                doc.transaction(name: name) { doc.children = before }
            }
            undoManager.setActionName(name)
            lastTransactionKey = coalesceKey
        }
        lastTransactionTime = now
        didCommitTransaction?(ops)
        return ops
    }

    /// Break the coalesce window so the next transaction with a `coalesceKey`
    /// starts a fresh undo entry even if the key matches the previous. Called
    /// at edit-session boundaries (focus change, structural ops).
    public func breakCoalescing() {
        lastTransactionKey = nil
        lastTransactionTime = nil
    }

    /// Pulls a title out of the first top-level H1, falling back to the
    /// caller-provided default. Does not recurse into containers — a heading
    /// inside a toggle is body content, not the page title.
    /// `nonisolated` so the host can derive titles off MainActor (the body
    /// is pure: walks a `[Block]` and reads `Block.kind`).
    nonisolated public static func deriveTitle(from rootChildren: [Block], fallback: String) -> String {
        for block in rootChildren {
            if case .heading(.h1, let text) = block.kind {
                let s = String(text.characters)
                if !s.isEmpty { return s }
            }
        }
        return fallback
    }

    /// Bulk-replace the entire children list with a new tree. Bypasses undo
    /// and the `preMutation` hook — intended for non-user operations like
    /// conflict-resolution merges and external-edit reloads where the new
    /// content is the authoritative state. Clears the parent cache via the
    /// `children` setter's `didSet`. Fires `didReplaceChildren` so the editor
    /// can revalidate selection / cursor against the new BlockID set, and
    /// breaks coalescing so the next user transaction starts a fresh undo
    /// entry (a disk-driven swap shouldn't fold into the prior burst).
    public func replaceChildren(_ newChildren: [Block]) {
        children = newChildren
        lastTransactionKey = nil
        lastTransactionTime = nil
        didReplaceChildren?()
    }

    // MARK: - Generic preorder walkers
    //
    // Read-only walks share `walk(_:visit:)`; mutating ops (mutate / remove /
    // replace) share `mutateFirst(in:id:transform:)`. Together these subsume
    // what used to be 8 near-identical recursive helpers. Public lookups
    // (find / documentOrder / path / preorderPredecessor / subtreeIDs / walk)
    // and the mutation primitives below all build on this pair.

    /// Per-visit signal returned by the read-only walker.
    /// - `continue`: visit children, then continue with the next sibling.
    /// - `skip`: don't visit children of the current block; continue with the next sibling.
    /// - `stop`: terminate the walk immediately.
    enum WalkAction { case `continue`, skip, stop }

    /// Generic preorder walker with early-exit semantics. Returns `true` iff
    /// the walk was stopped (`.stop` returned by `visit`); `false` if it
    /// completed naturally.
    @discardableResult
    private static func walk(
        _ blocks: [Block],
        depth: Int = 0,
        parent: BlockID? = nil,
        visit: (Block, Int, BlockID?) -> WalkAction
    ) -> Bool {
        for block in blocks {
            switch visit(block, depth, parent) {
            case .stop:
                return true
            case .skip:
                continue
            case .continue:
                if walk(block.children, depth: depth + 1, parent: block.id, visit: visit) {
                    return true
                }
            }
        }
        return false
    }

    /// Find the first node with `id` and run `transform` against its enclosing
    /// `siblings` array and `index`. Returns `true` on a match. Used by the
    /// in-place mutation primitives below (`mutate`, `removeSubtree`,
    /// `replaceSubtree`).
    @discardableResult
    private static func mutateFirst(
        in blocks: inout [Block],
        id: BlockID,
        transform: (_ siblings: inout [Block], _ index: Int) -> Void
    ) -> Bool {
        for i in blocks.indices {
            if blocks[i].id == id {
                transform(&blocks, i)
                return true
            }
            if mutateFirst(in: &blocks[i].children, id: id, transform: transform) {
                return true
            }
        }
        return false
    }

    // MARK: - Find / walk

    /// Returns the block with the given id, anywhere in the tree.
    public func find(_ blockID: BlockID) -> Block? {
        var found: Block?
        Self.walk(children) { block, _, _ in
            if block.id == blockID {
                found = block
                return .stop
            }
            return .continue
        }
        return found
    }

    /// IndexPath from the root. `[0]` is the first top-level block; `[2, 1]`
    /// is `children[2].children[1]`.
    public func path(to blockID: BlockID) -> IndexPath? {
        var found: IndexPath?
        Self.walkWithIndices(children) { block, indices in
            if block.id == blockID {
                found = IndexPath(indexes: indices)
                return .stop
            }
            return .continue
        }
        return found
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
        Self.walk(children) { block, _, parent in
            if let parent { cache[block.id] = parent }
            return .continue
        }
        _parentCache = cache
    }

    /// All ids in `blockID`'s subtree, including `blockID` itself.
    public func subtreeIDs(of blockID: BlockID) -> Set<BlockID> {
        guard let block = find(blockID) else { return [] }
        var out: Set<BlockID> = []
        Self.walk([block]) { b, _, _ in
            out.insert(b.id)
            return .continue
        }
        return out
    }

    /// Preorder document-order index of `blockID` (0 = first top-level block).
    /// Used to sort selections that span subtrees.
    public func documentOrder(of blockID: BlockID) -> Int? {
        var counter = 0
        var found: Int?
        Self.walk(children) { block, _, _ in
            if block.id == blockID {
                found = counter
                return .stop
            }
            counter += 1
            return .continue
        }
        return found
    }

    /// The block immediately preceding `blockID` in preorder traversal — i.e.
    /// the block "above" it visually if everything is expanded. Used by the
    /// recovery layer to anchor lost-block records.
    public func preorderPredecessor(of blockID: BlockID) -> BlockID? {
        var previous: BlockID?
        var found: BlockID?
        Self.walk(children) { block, _, _ in
            if block.id == blockID {
                found = previous
                return .stop
            }
            previous = block.id
            return .continue
        }
        return found
    }

    /// Preorder walk yielding (block, depth, parentID?) for every node.
    public func walk(_ visit: (_ block: Block, _ depth: Int, _ parent: BlockID?) -> Void) {
        Self.walk(children) { block, depth, parent in
            visit(block, depth, parent)
            return .continue
        }
    }

    /// Internal walker variant that exposes the `[Int]` child-index stack so
    /// `path(to:)` can reconstruct an `IndexPath`. Kept fileprivate — the
    /// public `walk(_:)` and the `WalkAction`-returning `walk(_:visit:)` are
    /// the two ergonomic surfaces.
    @discardableResult
    private static func walkWithIndices(
        _ blocks: [Block],
        indices: [Int] = [],
        visit: (Block, [Int]) -> WalkAction
    ) -> Bool {
        for (i, block) in blocks.enumerated() {
            let here = indices + [i]
            switch visit(block, here) {
            case .stop:
                return true
            case .skip:
                continue
            case .continue:
                if walkWithIndices(block.children, indices: here, visit: visit) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Mutation primitives

    /// Apply a transform to the block at `blockID` in place. Returns `true` if
    /// the block was found and the transform applied. The transform receives
    /// an `inout Block` so callers can patch `kind` and/or `children`.
    @discardableResult
    public func mutate(_ blockID: BlockID, _ transform: (inout Block) -> Void) -> Bool {
        let didMutate = Self.mutateFirst(in: &children, id: blockID) { siblings, i in
            transform(&siblings[i])
        }
        if didMutate { _parentCache = nil }
        return didMutate
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
        Self.mutateFirst(in: &children, id: blockID) { siblings, i in
            removed = siblings.remove(at: i)
        }
        if removed != nil { _parentCache = nil }
        return removed
    }

    /// Remove the block at `blockID` and splice its children into its place
    /// in the parent's children array. Returns the removed block with its
    /// children stripped (so callers recording a deletion don't double-count
    /// the lifted body). Returns `nil` if the id isn't found.
    @discardableResult
    public func removeBlockLiftingChildren(_ blockID: BlockID) -> Block? {
        var husk: Block?
        Self.mutateFirst(in: &children, id: blockID) { siblings, i in
            var removed = siblings.remove(at: i)
            let lifted = removed.children
            removed.children = []
            siblings.insert(contentsOf: lifted, at: i)
            husk = removed
        }
        if husk != nil { _parentCache = nil }
        return husk
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
        let success = Self.mutateFirst(in: &children, id: blockID) { siblings, i in
            siblings.replaceSubrange(i...i, with: replacements)
        }
        if success { _parentCache = nil }
        return success
    }

    // MARK: - Selection helpers

    /// Reduce a selection to its minimal subtree-roots (drop any id that's a
    /// descendant of another selected id). Returned in document order.
    public func selectionSubtreeRoots(_ ids: Set<BlockID>) -> [BlockID] {
        guard !ids.isEmpty else { return [] }
        var coveredDescendants: Set<BlockID> = []
        for id in ids {
            guard let block = find(id) else { continue }
            Self.walk(block.children) { b, _, _ in
                coveredDescendants.insert(b.id)
                return .continue
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
    /// otherwise. At a parent boundary, the slab tries to migrate into the
    /// adjacent sibling-parent (end → first child of next sibling, top →
    /// last child of previous sibling) when that sibling is a container that
    /// accepts the slab; otherwise it reparents to the grandparent (the
    /// classic outdent-at-boundary).
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
        let orderedIDs = positions.map { siblings[$0].id }

        if delta < 0 {
            if first == 0 {
                // At top of parent: prefer migrating into the previous sibling
                // parent's tail (so the slab descends rather than popping out).
                // Falls through to outdent if there's no previous sibling or
                // it can't accept these blocks.
                guard let parentID, let parentBlock = find(parentID) else { return false }
                let grandparentID = parent(of: parentID)
                let outerSiblings: [Block] = grandparentID.flatMap(find)?.children ?? children
                guard let parentIndexUnderGrand = outerSiblings.firstIndex(where: { $0.id == parentBlock.id }) else { return false }
                let movedBlocks = positions.map { siblings[$0] }
                if parentIndexUnderGrand > 0 {
                    let prevSibling = outerSiblings[parentIndexUnderGrand - 1]
                    let migrationTarget = DropPath(parent: prevSibling.id, position: prevSibling.children.count)
                    if canDrop(ids: orderedIDs, to: migrationTarget) {
                        for id in ids { removeSubtree(id) }
                        return insertSubtrees(movedBlocks, at: migrationTarget)
                    }
                }
                // Outdent: reparent slab to grandparent just before parent.
                for id in ids { removeSubtree(id) }
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
                // At end of parent: prefer migrating into the next sibling
                // parent's head. Falls through to outdent if there's no next
                // sibling or it can't accept these blocks.
                guard let parentID, let parentBlock = find(parentID) else { return false }
                let grandparentID = parent(of: parentID)
                let outerSiblings: [Block] = grandparentID.flatMap(find)?.children ?? children
                guard let parentIndexUnderGrand = outerSiblings.firstIndex(where: { $0.id == parentBlock.id }) else { return false }
                let movedBlocks = positions.map { siblings[$0] }
                if parentIndexUnderGrand + 1 < outerSiblings.count {
                    let nextSibling = outerSiblings[parentIndexUnderGrand + 1]
                    let migrationTarget = DropPath(parent: nextSibling.id, position: 0)
                    if canDrop(ids: orderedIDs, to: migrationTarget) {
                        for id in ids { removeSubtree(id) }
                        return insertSubtrees(movedBlocks, at: migrationTarget)
                    }
                }
                // Outdent: reparent slab to grandparent just after parent.
                for id in ids { removeSubtree(id) }
                return insertSubtrees(movedBlocks, at: DropPath(parent: grandparentID, position: parentIndexUnderGrand + 1))
            }
            let movedBlocks = positions.map { siblings[$0] }
            let nextSibling = siblings[nextPosition]
            if nextSibling.isContainer {
                let migrationTarget = DropPath(parent: nextSibling.id, position: 0)
                if canDrop(ids: orderedIDs, to: migrationTarget) {
                    for id in ids { removeSubtree(id) }
                    return insertSubtrees(movedBlocks, at: migrationTarget)
                }
            }
            // Slide down: remove slab, insert at first + 1 (so next-sibling lands before the slab)
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
    ///
    /// Adjusts `target.position` for source blocks that lived under
    /// `target.parent` at a position before the drop slot — without this,
    /// dragging a block forward within the same parent lands it one slot
    /// later than intended (because removing the source shifts the trailing
    /// siblings down by one before the insert).
    @discardableResult
    public func moveSubtrees(_ ids: [BlockID], to target: DropPath) -> Bool {
        guard canDrop(ids: ids, to: target) else { return false }

        // Snapshot the source positions in target.parent BEFORE removal so
        // we can compute "how many source blocks were before the target".
        let preSiblings: [Block] = target.parent.flatMap(find)?.children ?? children
        let removalsBeforeTarget = ids.compactMap { id -> Int? in
            preSiblings.firstIndex(where: { $0.id == id })
        }.filter { $0 < target.position }.count

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

        // Apply the pre-removal adjustment, then clamp to the now-shorter
        // children count.
        let postCount: Int
        if let targetParent = target.parent {
            postCount = find(targetParent)?.children.count ?? 0
        } else {
            postCount = children.count
        }
        let adjustedPosition = max(0, min(target.position - removalsBeforeTarget, postCount))
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
