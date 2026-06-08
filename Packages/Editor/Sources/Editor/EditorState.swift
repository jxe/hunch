import CoreGraphics
import Foundation

/// Editor session state, owned by the host and observed by `EditorView`. The host
/// constructs an `EditorState` per `EditorView` and can `@Bindable` it to read
/// what the user is doing (selection, cursor, edit mode) for sibling UI like a
/// status bar. Mutation stays inside the package — `internal(set)` blocks
/// external writes; transitions happen through named methods on the editor.
///
/// `sessionState` is what the user is fundamentally doing:
///
/// - `.navigating(Selection, gesture: Gesture?)` — block-level selection with no
///   live caret. The optional `gesture` carries a transient manipulation that
///   rides on top of nav mode (drag-reorder, pinch-to-insert). Beginning a
///   gesture commits or cancels any active edit first, so gestures are
///   structurally impossible in edit mode.
/// - `.editing(BlockID, overlay: Overlay?)` — one block has the live editor
///   mounted; cursor lives inside NSTextView/UITextView. The optional overlay is
///   a modal popover layered on top (currently only the @-mention menu) — the
///   text view still has focus and accepts keystrokes the same way.
///
/// Ambient state (hover, drop target, expanded toggles, action toast) coexists
/// with any session state.
@Observable
@MainActor
public final class EditorState {
    public internal(set) var sessionState: SessionState = .navigating(Selection(), gesture: nil)

    /// Where the live editor should park the cursor on its next mount of the
    /// editing block. Set when transitioning into edit mode (click point, start
    /// of a split tail, merge join point) or mid-session for a structural shape
    /// change that re-mounts the editor (e.g. unbullet). Consumed-and-cleared
    /// atomically by `takePendingInitialCursor()`; `exitEditModeWithoutCursor()`
    /// clears any unconsumed value so a stale target can't leak across sessions.
    /// Nil means
    /// "seek to end".
    internal(set) var pendingInitialCursor: InitialCursorTarget? = nil

    // Hover — visible across all modes/gestures, drives drag-handle reveal.
    //
    // Set ONLY via `setHoveredBlock` / `setHoveredHandle`: those setters no-op
    // on same-value writes, which protects against a hover→write→invalidate
    // →layout→hover-redispatch feedback loop. `@Observable` invalidates on
    // every setter call regardless of whether the value changed, and SwiftUI
    // redispatches hover whenever layout shifts row frames, so an unguarded
    // write reachable from `.onContinuousHover` / `.onHover` closes the loop.
    public private(set) var hoveredBlock: BlockID? = nil
    public private(set) var hoveredHandle: BlockID? = nil

    public func setHoveredBlock(_ id: BlockID?) {
        if hoveredBlock != id { hoveredBlock = id }
    }

    public func setHoveredHandle(_ id: BlockID?) {
        if hoveredHandle != id { hoveredHandle = id }
    }

    // Drop target visualization. Updated during both in-app reorder and external
    // file drops. `currentDropTarget` is the source of truth; `dropHoverIndex`
    // and `dropOntoBlockID` are computed views below for sites that only care
    // about one shape of target.
    public internal(set) var currentDropTarget: DropTarget? = nil

    // Page-local view state — defaults to all closed every time the page opens.
    // Toggle expansion is intentionally not persisted to markdown.
    //
    // The `didSet` observers fire `onStructureChange` so the editor's
    // layout cache can drop its cached `[VisibleRow]` — expand/collapse
    // changes which blocks are visible and thus which slots a drag/pinch
    // can land in. Set/Set mutations like `.insert(_:)` route through
    // Swift's `_modify` accessor, which runs `didSet` after each call.
    public internal(set) var expandedToggles: Set<BlockID> = [] {
        didSet { onStructureChange?() }
    }
    public internal(set) var expandedTemplates: Set<BlockID> = [] {
        didSet { onStructureChange?() }
    }

    /// Fired when state that affects the visible-row layout changes
    /// (toggle/templateButton expand/collapse). Wired by `EditorView`
    /// at mount; the editor invalidates its `BlockLayoutCache`'s
    /// structural-row cache from here.
    @ObservationIgnored
    internal var onStructureChange: (() -> Void)? = nil

    // Transient bottom-of-page toast (e.g. "Deleted") with an Undo affordance.
    public internal(set) var actionToast: String? = nil

    /// Bumped by `appendBlocks(_:actionName:)`. EditorView observes via
    /// `.onChange` and consumes the buffered payload via `takePendingAppend()`.
    /// Counter (not a Bool) so two consecutive appends both fire even if the
    /// editor hasn't yet noticed the first.
    public internal(set) var pendingAppendTicket: Int = 0
    internal var pendingAppendBuffer: (blocks: [Block], actionName: String)? = nil

    public init() {}

    /// Append host-supplied blocks to the end of the document. Wraps the
    /// mutation in undo registration with `actionName` and transfers focus
    /// (nav-mode cursor) to the last appended block. Source-agnostic — used
    /// today by Hunch's voice-transcription pipeline, but the editor itself
    /// doesn't care where the blocks came from.
    public func appendBlocks(_ blocks: [Block], actionName: String = "Insert Blocks") {
        guard !blocks.isEmpty else { return }
        pendingAppendBuffer = (blocks, actionName)
        pendingAppendTicket &+= 1
    }

    internal func takePendingAppend() -> (blocks: [Block], actionName: String)? {
        let v = pendingAppendBuffer
        pendingAppendBuffer = nil
        return v
    }
}

// MARK: - SessionState

public enum SessionState: Equatable, Sendable {
    /// Block-level selection, no caret. A `Selection` with empty `blocks` and
    /// nil cursor is the no-cursor variant (used briefly during document load
    /// and after a delete-everything). The `gesture` rides on top of nav-mode
    /// selection — nil during normal navigation, non-nil during drag-reorder
    /// or pinch-to-insert.
    case navigating(Selection, gesture: Gesture?)
    /// One block has the live `BlockTextEditor` mounted; cursor lives inside
    /// NSTextView/UITextView. The optional overlay is a modal popover layered
    /// on top of the editor (currently only the @-mention menu).
    case editing(BlockID, overlay: Overlay?)
}

public enum Overlay: Equatable, Sendable {
    /// @-mention popover open on the editing block.
    case mention(MentionMenuState)
}

public enum Gesture: Equatable, Sendable {
    /// Drag-reorder: a block (or selection of blocks) lifted under the cursor.
    case reordering(ReorderLift)
    /// Pinch-to-insert: an inline gap is opening between two rows.
    case pinchOpening(PinchPreviewState)
}

public struct Selection: Equatable, Sendable {
    /// Selected block IDs in document order. Always contiguous (we only build
    /// it via cursor/anchor extension).
    public var blocks: Set<BlockID>
    /// Anchor end of a Shift-extend operation. Stays put while `cursor` moves.
    public var anchor: BlockID?
    /// Moving end of the selection. With no shift held, `anchor == cursor`
    /// and `blocks == [cursor]`.
    public var cursor: BlockID?

    public init(blocks: Set<BlockID> = [], anchor: BlockID? = nil, cursor: BlockID? = nil) {
        self.blocks = blocks
        self.anchor = anchor
        self.cursor = cursor
    }
}

// MARK: - Overlay payloads

public struct MentionMenuState: Equatable, Sendable {
    public let blockID: BlockID
    public var trigger: MentionTrigger
    public var selectedIndex: Int
    /// Match candidates for the current `trigger.query`, capped at 8.
    /// Filled by the editor on every trigger change so subsequent body
    /// renders and keyboard handlers read from state instead of re-asking
    /// the host (`EditorHost.suggestPages` walks the workspace page list
    /// and isn't free).
    public var matches: [MentionItem]

    public init(blockID: BlockID, trigger: MentionTrigger, selectedIndex: Int, matches: [MentionItem] = []) {
        self.blockID = blockID
        self.trigger = trigger
        self.selectedIndex = selectedIndex
        self.matches = matches
    }
}

// MARK: - Gesture payloads

public struct ReorderLift: Equatable, Sendable {
    /// Lead block — what the lift overlay renders.
    public var block: Block
    /// All subtree-roots being reordered. Single-row drags carry one ID; drags
    /// initiated from a multi-block selection carry the whole selection.
    public var ids: [BlockID]
    /// The parent of the lifted blocks (`nil` for root). All `ids` share this
    /// parent — the gesture refuses to lift a selection that crosses parents.
    public var sourceParentID: BlockID?
    /// Range of positions occupied by `ids` under `sourceParentID` at lift
    /// time, in document order. Used by the drop validator to reject "drop
    /// onto yourself".
    public var sourcePositions: ClosedRange<Int>
    /// All ids in the lifted subtrees (roots + every descendant). Drop validator
    /// rejects targets whose `parent` is in this set (cycle prevention).
    public var draggedSubtreeIDs: Set<BlockID>
    public var sourceFrame: CGRect
    public var touchOffset: CGSize
    public var location: CGPoint
    /// True while the lift is mounted but `touchOffset` is a placeholder
    /// waiting for a real cursor location to re-anchor against. Used on iOS
    /// when the prelift state is mounted before the first concrete touch.
    public var pendingAnchor: Bool
    /// macOS Option-drag: drop performs a duplicate instead of a move, and
    /// the source rows stay at full opacity. Live-updated each gesture tick.
    public var isCopy: Bool

    public init(
        block: Block,
        ids: [BlockID],
        sourceParentID: BlockID?,
        sourcePositions: ClosedRange<Int>,
        draggedSubtreeIDs: Set<BlockID>,
        sourceFrame: CGRect,
        touchOffset: CGSize,
        location: CGPoint,
        pendingAnchor: Bool,
        isCopy: Bool = false
    ) {
        self.block = block
        self.ids = ids
        self.sourceParentID = sourceParentID
        self.sourcePositions = sourcePositions
        self.draggedSubtreeIDs = draggedSubtreeIDs
        self.sourceFrame = sourceFrame
        self.touchOffset = touchOffset
        self.location = location
        self.pendingAnchor = pendingAnchor
        self.isCopy = isCopy
    }
}

public struct PinchPreviewState: Equatable, Sendable {
    /// Visible-row slot index (0...visibleRows.count) where the gap is opening.
    /// Same space as `dropHoverPath` resolves into via `visibleSlotForCurrentDropPath` —
    /// nested rows participate so a pinch under a heading lands as a heading child.
    public var insertIndex: Int
    public var gapHeight: CGFloat

    public init(insertIndex: Int, gapHeight: CGFloat) {
        self.insertIndex = insertIndex
        self.gapHeight = gapHeight
    }
}

/// Resolved drop target. `insertAt(DropPath)` is the between-rows form (parent
/// id + position in that parent's children list). `asLastChildOf` is a
/// distinct case because the UX is different — drop highlight lives on the
/// parent row. `intoSubpage` is a cross-document move into a `.subpage`.
public enum DropTarget: Equatable, Sendable {
    case insertAt(DropPath)
    case asLastChildOf(BlockID)
    case intoSubpage(BlockID, String)
}

// MARK: - Read accessors (computed)

/// Convenience accessors that flatten `sessionState` cases back to the
/// individual fields the editor's internals (and most consumers) read. These
/// are derived; mutation goes through the named transition methods below.
public extension EditorState {
    /// Set of currently-selected blocks. In edit mode this is `[editingBlock]`
    /// for the host's purposes (the user is "selecting" that one block).
    var selection: Set<BlockID> {
        switch sessionState {
        case .navigating(let sel, _): return sel.blocks
        case .editing(let id, _): return [id]
        }
    }
    /// Anchor of a Shift-extend operation. nil in edit mode.
    var anchor: BlockID? {
        if case .navigating(let sel, _) = sessionState { return sel.anchor }
        return nil
    }
    /// Moving end of the selection / current focus block. In edit mode this
    /// is the editing block id.
    var cursor: BlockID? {
        switch sessionState {
        case .navigating(let sel, _): return sel.cursor
        case .editing(let id, _): return id
        }
    }
    /// The block whose text is currently mounted as a live editor; nil in
    /// nav mode.
    var editingBlock: BlockID? {
        if case .editing(let id, _) = sessionState { return id }
        return nil
    }
    /// Active mention popover, if any. Only set in edit mode.
    var mentionMenu: MentionMenuState? {
        if case .editing(_, .some(.mention(let m))) = sessionState { return m }
        return nil
    }
    /// Active drag-reorder lift, if any.
    var reorderLift: ReorderLift? {
        if case .navigating(_, .some(.reordering(let lift))) = sessionState { return lift }
        return nil
    }
    /// Active pinch-open-to-insert preview, if any.
    var pinchPreview: PinchPreviewState? {
        if case .navigating(_, .some(.pinchOpening(let p))) = sessionState { return p }
        return nil
    }
    /// Insertion-path view of `currentDropTarget` — non-nil only when the
    /// resolved target is a between-rows drop.
    var dropHoverPath: DropPath? {
        if case .insertAt(let p) = currentDropTarget { return p }
        return nil
    }
    /// Drop-on-row view of `currentDropTarget` — the row id we're hovering
    /// onto (closed parent or subpage); nil for between-rows targets.
    var dropOntoBlockID: BlockID? {
        switch currentDropTarget {
        case .asLastChildOf(let id), .intoSubpage(let id, _): return id
        default: return nil
        }
    }
}

// MARK: - Selection / nav-mode transitions

extension EditorState {
    /// Collapse selection to a single block in nav mode. The next Shift-extend
    /// will pivot off this block. Clears any in-flight gesture.
    func setCursor(_ id: BlockID) {
        setSessionStateIfChanged(.navigating(Selection(blocks: [id], anchor: id, cursor: id), gesture: nil))
    }

    /// Drop to nav mode with no cursor / empty selection. Clears any in-flight gesture.
    func clearCursor() {
        setSessionStateIfChanged(.navigating(Selection(), gesture: nil))
    }

    /// Set a multi-block nav-mode selection. The caller is responsible for
    /// ensuring `blocks` is contiguous in document order and `cursor ∈ blocks`.
    /// Clears any in-flight gesture.
    func setNavSelection(blocks: Set<BlockID>, anchor: BlockID, cursor: BlockID) {
        setSessionStateIfChanged(.navigating(Selection(blocks: blocks, anchor: anchor, cursor: cursor), gesture: nil))
    }

    /// Select the row a reorder gesture started from before the lift is built.
    /// If the row is already inside a multi-selection, keep the group but make
    /// the grabbed row the cursor so macOS cursor-visibility scroll targets the
    /// drag source instead of a stale off-screen row.
    func selectForReorderStart(on id: BlockID) {
        guard case .navigating(let sel, _) = sessionState else { return }
        if sel.blocks.count > 1, sel.blocks.contains(id) {
            let anchor = sel.anchor.flatMap { sel.blocks.contains($0) ? $0 : nil } ?? id
            setSessionStateIfChanged(.navigating(
                Selection(blocks: sel.blocks, anchor: anchor, cursor: id),
                gesture: nil
            ))
        } else {
            setSessionStateIfChanged(.navigating(Selection(blocks: [id], anchor: id, cursor: id), gesture: nil))
        }
    }

}

// MARK: - Edit-mode transitions

extension EditorState {
    /// Enter edit mode on the given block, dropping any stale overlay. Pass
    /// `initialCursor` when there's a specific position the cursor should land on
    /// (click point, start of split tail, merge join point); leave it nil to seek
    /// to end. The pending-cursor channel is rewritten on every call so a target
    /// from a previous edit session can't leak into the next mount.
    func enterEditMode(on id: BlockID, initialCursor: InitialCursorTarget? = nil) {
        setSessionStateIfChanged(.editing(id, overlay: nil))
        pendingInitialCursor = initialCursor
    }

    /// Drop edit mode AND any selection — page is unfocused entirely.
    func exitEditModeWithoutCursor() {
        setSessionStateIfChanged(.navigating(Selection(), gesture: nil))
        pendingInitialCursor = nil
    }

    /// Update the pending initial cursor mid-session, e.g. when an unbullet
    /// converts the row's block type and the editor is about to re-mount. No-op
    /// outside edit mode.
    func setPendingInitialCursor(_ target: InitialCursorTarget) {
        guard case .editing = sessionState else { return }
        pendingInitialCursor = target
    }

    /// Atomically read and clear `pendingInitialCursor`. Called by the live
    /// editor exactly once during mount (`makeNSView` / `makeUIView`) so a
    /// re-mount within the same edit session — without an explicit
    /// `setPendingInitialCursor` to update it — falls back to seek-to-end
    /// rather than re-applying the original target.
    func takePendingInitialCursor() -> InitialCursorTarget? {
        let value = pendingInitialCursor
        pendingInitialCursor = nil
        return value
    }
}

// MARK: - Mention overlay transitions

extension EditorState {
    /// Open or update the mention popover on the currently-editing block.
    /// No-op if not in edit mode, or if the menu's blockID doesn't match.
    func setMentionMenu(_ menu: MentionMenuState) {
        guard case .editing(let id, _) = sessionState, id == menu.blockID else { return }
        setSessionStateIfChanged(.editing(id, overlay: .mention(menu)))
    }

    /// Close the mention popover without exiting edit mode.
    func closeMentionMenu() {
        guard case .editing(let id, .mention) = sessionState else { return }
        setSessionStateIfChanged(.editing(id, overlay: nil))
    }

    /// Close the mention popover only if it's attached to a specific block.
    func closeMentionMenu(forBlockID blockID: BlockID) {
        if case .editing(let id, .mention(let m)) = sessionState, m.blockID == blockID {
            setSessionStateIfChanged(.editing(id, overlay: nil))
        }
    }
}

// MARK: - Gesture transitions

extension EditorState {
    /// Begin or update a reorder lift. Pass nil to clear. No-op outside nav mode —
    /// the editor commits/cancels any active edit before lifting.
    func setReorderLift(_ lift: ReorderLift?) {
        guard case .navigating(let sel, let currentGesture) = sessionState else { return }
        if let lift {
            setSessionStateIfChanged(.navigating(sel, gesture: .reordering(lift)))
        } else if case .reordering = currentGesture {
            setSessionStateIfChanged(.navigating(sel, gesture: nil))
        }
    }

    /// Begin or update a pinch-to-insert preview. Pass nil to clear. No-op
    /// outside nav mode — the editor commits/cancels any active edit before
    /// the pinch starts.
    func setPinchPreview(_ preview: PinchPreviewState?) {
        guard case .navigating(let sel, let currentGesture) = sessionState else { return }
        if let preview {
            setSessionStateIfChanged(.navigating(sel, gesture: .pinchOpening(preview)))
        } else if case .pinchOpening = currentGesture {
            setSessionStateIfChanged(.navigating(sel, gesture: nil))
        }
    }
}

// MARK: - Cross-document validation

extension EditorState {
    /// Reconcile state against a new block set after `document.children` was
    /// replaced (e.g. by undo). Drops invalid IDs from selection, cursor,
    /// anchor; if the editing block disappeared, falls back to nav mode at
    /// `fallbackCursor`. Preserves any in-flight gesture.
    func revalidate(against validIDs: Set<BlockID>, fallbackCursor: BlockID?) {
        let next: SessionState
        switch sessionState {
        case .navigating(var sel, let gesture):
            sel.blocks = sel.blocks.intersection(validIDs)
            if let c = sel.cursor, !validIDs.contains(c) { sel.cursor = fallbackCursor }
            if let a = sel.anchor, !validIDs.contains(a) { sel.anchor = sel.cursor }
            if sel.blocks.isEmpty, let c = sel.cursor { sel.blocks = [c] }
            next = .navigating(sel, gesture: gesture)
        case .editing(let id, let overlay):
            if validIDs.contains(id) {
                next = .editing(id, overlay: overlay)
            } else if let c = fallbackCursor {
                next = .navigating(Selection(blocks: [c], anchor: c, cursor: c), gesture: nil)
            } else {
                next = .navigating(Selection(), gesture: nil)
            }
        }
        // Guard the same-value write — @Observable invalidates on every set,
        // even when the value is identical, and `revalidate` fires after every
        // `Document.transaction`. An unguarded write here primes a body-eval
        // for every mutation including ones that didn't change the selection.
        setSessionStateIfChanged(next)
    }

    /// `@Observable` emits invalidation on every setter call, even when the
    /// assigned value is identical. Centralize the equality guard so state
    /// transitions that converge through multiple paths in one event (for
    /// example delete -> transaction revalidation -> explicit cursor repair)
    /// don't dirty SwiftUI's graph twice for the same logical state.
    private func setSessionStateIfChanged(_ next: SessionState) {
        if sessionState != next { sessionState = next }
    }
}
