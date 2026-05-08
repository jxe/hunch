import CoreGraphics
import Foundation

/// Editor session state, owned by the host and observed by `EditorView`. The host
/// constructs an `EditorState` per `EditorView` and can `@Bindable` it to read
/// what the user is doing (selection, cursor, edit mode) for sibling UI like a
/// status bar. Mutation stays inside the package — `internal(set)` blocks
/// external writes; transitions happen through named methods on the editor.
///
/// The state space is two orthogonal axes plus ambient annotations:
///
/// - `mode` — what the user is fundamentally doing (navigating between blocks vs.
///   editing the text of one block). The mention popover is a `.mention` overlay
///   *inside* `.editing`, not a peer mode, because the text view still has focus
///   and accepts keystrokes the same way.
/// - `gesture` — a transient manipulation riding on top of nav mode (drag-reorder,
///   pinch-to-insert). Invariant: a non-nil `gesture` only coexists with
///   `mode == .navigating(...)` — beginning a gesture commits or cancels any
///   active edit first.
///
/// Ambient state (hover, drop target, expanded toggles, action toast) coexists
/// with any combination of mode and gesture.
@Observable
@MainActor
public final class EditorState {
    public internal(set) var mode: Mode = .navigating(Selection())
    public internal(set) var gesture: Gesture? = nil

    /// Where the live editor should park the cursor on its next mount of the
    /// editing block. Set when transitioning into edit mode (click point, start
    /// of a split tail, merge join point) or mid-session for a structural shape
    /// change that re-mounts the editor (e.g. unbullet). Consumed-and-cleared
    /// atomically by `takePendingInitialCursor()`; `exitEditMode()` clears any
    /// uncomsumed value so a stale target can't leak across sessions. Nil means
    /// "seek to end".
    public internal(set) var pendingInitialCursor: InitialCursorTarget? = nil

    // Hover — visible across all modes/gestures, drives drag-handle reveal.
    public internal(set) var hoveredBlock: BlockID? = nil
    public internal(set) var hoveredHandle: BlockID? = nil

    // Drop target visualization. Updated during both in-app reorder and external
    // file drops. `currentDropTarget` is the source of truth; `dropHoverIndex`
    // and `dropOntoBlockID` are computed views below for sites that only care
    // about one shape of target.
    public internal(set) var currentDropTarget: DropTarget? = nil

    // Page-local view state — defaults to all closed every time the page opens.
    // Toggle expansion is intentionally not persisted to markdown.
    public internal(set) var expandedToggles: Set<BlockID> = []
    public internal(set) var expandedTemplates: Set<BlockID> = []

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

// MARK: - Mode

public enum Mode: Equatable, Sendable {
    /// Block-level selection, no caret. A `Selection` with empty `blocks` and
    /// nil cursor is the no-cursor variant (used briefly during document load
    /// and after a delete-everything).
    case navigating(Selection)
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

    public init(blockID: BlockID, trigger: MentionTrigger, selectedIndex: Int) {
        self.blockID = blockID
        self.trigger = trigger
        self.selectedIndex = selectedIndex
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
/// parent row, the chevron auto-expands. `intoSubpage` is a cross-document
/// move into a `.subpage`.
public enum DropTarget: Equatable, Sendable {
    case insertAt(DropPath)
    case asLastChildOf(BlockID)
    case intoSubpage(BlockID, String)
}

// MARK: - Read accessors (computed)

/// Convenience accessors that flatten `mode`/`gesture` cases back to the
/// individual fields the editor's internals (and most consumers) read. These
/// are derived; mutation goes through the named transition methods below.
public extension EditorState {
    /// Set of currently-selected blocks. In edit mode this is `[editingBlock]`
    /// for the host's purposes (the user is "selecting" that one block).
    var selection: Set<BlockID> {
        switch mode {
        case .navigating(let sel): return sel.blocks
        case .editing(let id, _): return [id]
        }
    }
    /// Anchor of a Shift-extend operation. nil in edit mode.
    var anchor: BlockID? {
        if case .navigating(let sel) = mode { return sel.anchor }
        return nil
    }
    /// Moving end of the selection / current focus block. In edit mode this
    /// is the editing block id.
    var cursor: BlockID? {
        switch mode {
        case .navigating(let sel): return sel.cursor
        case .editing(let id, _): return id
        }
    }
    /// The block whose text is currently mounted as a live editor; nil in
    /// nav mode.
    var editingBlock: BlockID? {
        if case .editing(let id, _) = mode { return id }
        return nil
    }
    /// Active mention popover, if any. Only set while `mode == .editing(...)`.
    var mentionMenu: MentionMenuState? {
        if case .editing(_, .some(.mention(let m))) = mode { return m }
        return nil
    }
    /// Active drag-reorder lift, if any.
    var reorderLift: ReorderLift? {
        if case .reordering(let lift) = gesture { return lift }
        return nil
    }
    /// Active pinch-open-to-insert preview, if any.
    var pinchPreview: PinchPreviewState? {
        if case .pinchOpening(let p) = gesture { return p }
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
    /// will pivot off this block.
    func setCursor(_ id: BlockID) {
        mode = .navigating(Selection(blocks: [id], anchor: id, cursor: id))
    }

    /// Drop to nav mode with no cursor / empty selection.
    func clearCursor() {
        mode = .navigating(Selection())
    }

    /// Set a multi-block nav-mode selection. The caller is responsible for
    /// ensuring `blocks` is contiguous in document order and `cursor ∈ blocks`.
    func setNavSelection(blocks: Set<BlockID>, anchor: BlockID, cursor: BlockID) {
        mode = .navigating(Selection(blocks: blocks, anchor: anchor, cursor: cursor))
    }

    /// Replace just the anchor — used when starting an extend operation from
    /// a single-block selection that has no anchor set yet.
    func updateNavSelection(_ update: (inout Selection) -> Void) {
        guard case .navigating(var sel) = mode else { return }
        update(&sel)
        mode = .navigating(sel)
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
        mode = .editing(id, overlay: nil)
        pendingInitialCursor = initialCursor
    }

    /// Drop back to nav mode with the previously-editing block as the cursor.
    /// No-op if not in edit mode.
    func exitEditMode() {
        guard case .editing(let id, _) = mode else { return }
        mode = .navigating(Selection(blocks: [id], anchor: id, cursor: id))
        pendingInitialCursor = nil
    }

    /// Drop edit mode AND any selection — page is unfocused entirely.
    func exitEditModeWithoutCursor() {
        mode = .navigating(Selection())
        pendingInitialCursor = nil
    }

    /// Update the pending initial cursor mid-session, e.g. when an unbullet
    /// converts the row's block type and the editor is about to re-mount. No-op
    /// outside edit mode.
    func setPendingInitialCursor(_ target: InitialCursorTarget) {
        guard case .editing = mode else { return }
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
        guard case .editing(let id, _) = mode, id == menu.blockID else { return }
        mode = .editing(id, overlay: .mention(menu))
    }

    /// Close the mention popover without exiting edit mode.
    func closeMentionMenu() {
        guard case .editing(let id, .mention) = mode else { return }
        mode = .editing(id, overlay: nil)
    }

    /// Close the mention popover only if it's attached to a specific block.
    func closeMentionMenu(forBlockID blockID: BlockID) {
        if case .editing(let id, .mention(let m)) = mode, m.blockID == blockID {
            mode = .editing(id, overlay: nil)
        }
    }
}

// MARK: - Gesture transitions

extension EditorState {
    /// Begin or update a reorder lift. Pass nil to clear.
    func setReorderLift(_ lift: ReorderLift?) {
        if let lift {
            gesture = .reordering(lift)
        } else if case .reordering = gesture {
            gesture = nil
        }
    }

    /// Begin or update a pinch-to-insert preview. Pass nil to clear.
    func setPinchPreview(_ preview: PinchPreviewState?) {
        if let preview {
            gesture = .pinchOpening(preview)
        } else if case .pinchOpening = gesture {
            gesture = nil
        }
    }
}

// MARK: - Cross-document validation

extension EditorState {
    /// Reconcile state against a new block set after `document.blocks` was
    /// replaced (e.g. by undo). Drops invalid IDs from selection, cursor,
    /// anchor; if the editing block disappeared, falls back to nav mode at
    /// `fallbackCursor`.
    func revalidate(against validIDs: Set<BlockID>, fallbackCursor: BlockID?) {
        switch mode {
        case .navigating(var sel):
            sel.blocks = sel.blocks.intersection(validIDs)
            if let c = sel.cursor, !validIDs.contains(c) { sel.cursor = fallbackCursor }
            if let a = sel.anchor, !validIDs.contains(a) { sel.anchor = sel.cursor }
            if sel.blocks.isEmpty, let c = sel.cursor { sel.blocks = [c] }
            mode = .navigating(sel)
        case .editing(let id, let overlay):
            if validIDs.contains(id) {
                mode = .editing(id, overlay: overlay)
            } else if let c = fallbackCursor {
                mode = .navigating(Selection(blocks: [c], anchor: c, cursor: c))
            } else {
                mode = .navigating(Selection())
            }
        }
    }
}
