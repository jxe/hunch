import SwiftUI
import Core

public struct PageView: View {
    @Binding public var document: Document
    public let onSubpageTap: (String) -> Void
    public let onEdited: () -> Void
    public let onBlur: () -> Void
    public let onPinchClose: () -> Void

    /// Set of currently-selected blocks in nav mode. Always contiguous in document order
    /// (we only build it via cursor/anchor extension). Empty in edit mode.
    @State private var selection: Set<BlockID> = []
    /// Anchor end of a Shift-extend operation. Stays put while `cursor` moves.
    @State private var anchor: BlockID?
    /// Moving end of the selection. With no shift held, `anchor == cursor` and the selection
    /// is a single block. Used as the focus point for Enter→edit, Option+arrow move, etc.
    @State private var cursor: BlockID?
    /// The single block whose text is currently mounted as a `BlockTextEditor`. nil = nav mode.
    @State private var editingBlock: BlockID?
    /// Drives the active editor's `.focused()` (iOS path; macOS uses NSResponder directly).
    @FocusState private var editorFocused: BlockID?
    /// Drives the page container's focusability for nav-mode key handling.
    @FocusState private var pageFocused: Bool
    /// Click point captured the moment a non-editing row was tapped. Forwarded to the
    /// editor on its first mount so the cursor lands where the user clicked. Stale values
    /// are harmless — the editor only consumes the point once on `makeNSView`.
    @State private var pendingCursorPoint: (id: BlockID, point: CGPoint)?
    /// Document-level undo coordinator. Owns the shared `UndoManager` that NSTextView
    /// typing-undo and structural ops (split/merge/indent/slide/delete/autotransform/
    /// drag-drop) all register against. Recreated implicitly when PageView's identity
    /// resets; explicitly cleared on document switch via `.onChange(of: document.id)`.
    @State private var undoController = DocumentUndoController()
    /// The block whose row currently has cursor hover. Combined with
    /// `hoveredHandleBlockID` to decide whether to reveal the drag handle — needs
    /// two signals because the handle is an overlay positioned in the leading gutter
    /// (outside the row's hit area), so the cursor leaves the row when it moves
    /// onto the handle.
    @State private var hoveredBlockID: BlockID?
    /// The block whose drag handle currently has cursor hover. The handle's own
    /// `.onHover` keeps the reveal state alive while the cursor is over it, even
    /// though `hoveredBlockID` has gone nil.
    @State private var hoveredHandleBlockID: BlockID?
    /// Insertion index between rows where a drop is currently being targeted. Drives
    /// the visual drop indicator. nil when no drop is in progress.
    @State private var dropHoverIndex: Int?
    @State private var rowFrames: [BlockID: CGRect] = [:]
    @State private var actionToast: String?

    public init(
        document: Binding<Document>,
        onSubpageTap: @escaping (String) -> Void = { _ in },
        onEdited: @escaping () -> Void = {},
        onBlur: @escaping () -> Void = {},
        onPinchClose: @escaping () -> Void = {}
    ) {
        self._document = document
        self.onSubpageTap = onSubpageTap
        self.onEdited = onEdited
        self.onBlur = onBlur
        self.onPinchClose = onPinchClose
    }

    public var body: some View {
        GeometryReader { geometry in
            let numbering = NumberingContext.compute(document.blocks)
            let snapshot = document.blocks
            let horizontalPadding = NotionStyle.pageHorizontalPadding(for: geometry.size.width)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(snapshot.enumerated()), id: \.element.id) { (i, block) in
                        let gap = BlockSpacing.gap(
                            before: block,
                            after: previousBlock(before: block.id, in: snapshot)
                        )
                        rowView(for: $document.blocks[i], snapshot: snapshot, numberingIndex: numbering[block.id])
                            .padding(.top, gap)
                            .background(rowFrameReporter(id: block.id))
                            .overlay(alignment: .top) {
                                if dropHoverIndex == i {
                                    Rectangle()
                                        .fill(Color.accentColor)
                                        .frame(height: 2)
                                        .offset(y: -gap / 2)
                                        .allowsHitTesting(false)
                                }
                            }
                            .dropDestination(for: BlockDragPayload.self) { payloads, _ in
                                guard let payload = payloads.first else { return false }
                                moveBlocks(ids: payload.ids, toIndexBefore: i)
                                dropHoverIndex = nil
                                return true
                            } isTargeted: { hovering in
                                if hovering {
                                    dropHoverIndex = i
                                } else if dropHoverIndex == i {
                                    dropHoverIndex = nil
                                }
                            }
                    }
                    // Trailing slot for "insert at end" — claims the existing bottom 32pt
                    // page padding. Total visual spacing unchanged: the outer
                    // `.padding(.vertical, 32)` becomes `.padding(.top, 32)` only.
                    gapDropTarget(at: snapshot.count, height: 32)
                }
                .frame(maxWidth: NotionStyle.maxContentWidth, alignment: .leading)
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 32)
                .frame(maxWidth: .infinity, alignment: .center)
                .onPreferenceChange(RowFramePreferenceKey.self) { frames in
                    rowFrames = frames
                }
            }
            .coordinateSpace(name: PageHoverCoordinateSpace.name)
            .macNearestRowHover(rowFrames: rowFrames, hoveredBlockID: $hoveredBlockID)
            .background(NotionStyle.background)
            .iosPinchCloseToPageList(onPinchClose)
            .overlay(alignment: .bottom) {
                if let actionToast {
                    HStack(spacing: 12) {
                        Text(actionToast)
                        Button("Undo") {
                            undoController.undoManager.undo()
                            self.actionToast = nil
                        }
                    }
                    .font(NotionStyle.body(size: 13))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 18)
                }
            }
            // Hand the shared UndoManager + controller down through the environment.
            // BlockTextEditor reads the controller to register a typing-session snapshot
            // when an editor loses focus; the manager is used to route Cmd-Z through the
            // shared timeline.
            .environment(\.documentUndoManager, undoController.undoManager)
            .environment(\.documentUndoController, undoController)
            // Publish for App-level CommandGroup so Cmd-Z routes through this PageView's
            // undo manager regardless of where focus actually lives. Uses scene-level
            // exposure (rather than `.focusedValue`) because in edit mode the NSTextView
            // holds AppKit-level focus, which SwiftUI's per-view focus tracking misses —
            // scene-level remains visible to the menu commands.
            .focusedSceneValue(\.documentUndoController, undoController)
            .focusable()
            .focused($pageFocused)
            .onAppear {
                if cursor == nil, let first = document.blocks.first {
                    setCursor(first.id)
                }
                pageFocused = true
                installUndoApply()
            }
            .onChange(of: editorFocused) { old, new in
                if new == nil && old != nil {
                    onBlur()
                }
            }
            .onChange(of: document.id) { _, _ in
                editingBlock = nil
                editorFocused = nil
                if let first = document.blocks.first {
                    setCursor(first.id)
                } else {
                    selection = []
                    anchor = nil
                    cursor = nil
                }
                pageFocused = true
                // Captured undo entries reference the previous document's blocks — drop them.
                undoController.reset()
            }
            .onKeyPress(keys: [
                .upArrow, .downArrow, .return, .escape, .tab,
                KeyEquivalent("\u{19}"),  // NSBackTabCharacter — Shift+Tab on macOS
                .delete,
                KeyEquivalent("\u{8}"),
                KeyEquivalent("\u{7F}"),
                KeyEquivalent("k")
            ]) { press in
                guard editingBlock == nil else { return .ignored }
                let modifiers = press.modifiers

                if press.key == .delete || press.key == KeyEquivalent("\u{8}") || press.key == KeyEquivalent("\u{7F}") {
                    deleteSelection()
                    return .handled
                }
                // Shift+Tab arrives as a distinct character (BackTab, U+0019), not as
                // .tab + shift modifier — SwiftUI's `.onKeyPress(.tab)` won't match it.
                if press.key == KeyEquivalent("\u{19}") {
                    indentSelection(by: -1)
                    return .handled
                }

                switch press.key {
                case .upArrow:
                    if modifiers.contains(.option) {
                        moveSelectionInDocument(by: -1)
                    } else if modifiers.contains(.shift) {
                        extendSelection(by: -1)
                    } else {
                        moveCursor(by: -1)
                    }
                    return .handled
                case .downArrow:
                    if modifiers.contains(.option) {
                        moveSelectionInDocument(by: +1)
                    } else if modifiers.contains(.shift) {
                        extendSelection(by: +1)
                    } else {
                        moveCursor(by: +1)
                    }
                    return .handled
                case .tab:
                    indentSelection(by: modifiers.contains(.shift) ? -1 : +1)
                    return .handled
                case .return:
                    if let id = cursor, selection.count == 1 {
                        enterEditMode(on: id)
                    }
                    return .handled
                case .escape:
                    selection = []
                    anchor = nil
                    cursor = nil
                    return .handled
                default:
                    if press.key == KeyEquivalent("k"), modifiers.contains(.command) {
                        return .handled
                    }
                    return .ignored
                }
            }
        }
    }

    // MARK: - Row builder

    @ViewBuilder
    private func rowView(for binding: Binding<Block>, snapshot: [Block], numberingIndex: Int?) -> some View {
        let block = binding.wrappedValue
        let isSelected = selection.contains(block.id)
        let isEditing = editingBlock == block.id

        if case .subpage(_, _, let path) = block {
            Button {
                onSubpageTap(path)
            } label: {
                BlockRow(
                    block: binding,
                    editorFocused: $editorFocused,
                    isPageTitle: false,
                    numberingIndex: numberingIndex,
                    isSelected: isSelected,
                    isEditing: false
                )
            }
            .buttonStyle(.plain)
        } else {
            BlockRow(
                block: binding,
                editorFocused: $editorFocused,
                isPageTitle: isPageTitleBlock(block, snapshot: snapshot),
                numberingIndex: numberingIndex,
                isSelected: isSelected,
                isEditing: isEditing,
                onKey: { key in handleEditorKey(key, blockID: block.id) },
                onEdited: onEdited,
                onAutotransform: { transform, remainingText in
                    applyAutotransform(transform, remainingText: remainingText, blockID: block.id)
                },
                onClickAtPoint: { point in
                    pendingCursorPoint = (block.id, point)
                    enterEditMode(on: block.id)
                },
                initialCursorPoint: (pendingCursorPoint?.id == block.id) ? pendingCursorPoint?.point : nil
            )
            .macBlockDragSource(
                payload: BlockDragPayload(ids: dragIDs(for: block.id)),
                isEnabled: !isEditing
            )
            .iosBlockTouchActions(
                payload: BlockDragPayload(ids: dragIDs(for: block.id)),
                isEnabled: !isEditing,
                onDelete: {
                    deleteBlocks(ids: dragIDs(for: block.id), actionName: "Delete")
                    showActionToast("Deleted")
                },
                onCycleIndent: {
                    cycleIndent(blockID: block.id)
                }
            )
            .contentShape(Rectangle())
            .onTapGesture {
                // Clicks outside the editable text region (markers, paddings) — no
                // position info, cursor lands at end via the editor's default behavior.
                pendingCursorPoint = nil
                enterEditMode(on: block.id)
            }
            .overlay(alignment: .topLeading) {
                DragHandle()
                    .opacity(showHandleOverlay(for: block.id) && !isEditing ? 1 : 0)
                    .offset(x: -DragHandle.gutterWidth, y: 2)
                    .onHover { hovering in
                        if hovering {
                            hoveredHandleBlockID = block.id
                        } else if hoveredHandleBlockID == block.id {
                            hoveredHandleBlockID = nil
                        }
                    }
                    .draggable(BlockDragPayload(ids: dragIDs(for: block.id))) {
                        DragPreviewChip(count: dragIDs(for: block.id).count)
                    }
                    .allowsHitTesting(showHandleOverlay(for: block.id))
            }
        }
    }

    private func topSelectedBlockID() -> BlockID? {
        for block in document.blocks where selection.contains(block.id) {
            return block.id
        }
        return nil
    }

    private func showHandleOverlay(for id: BlockID) -> Bool {
        if selection.count > 1 {
            return id == topSelectedBlockID()
        }
        return hoveredBlockID == id || hoveredHandleBlockID == id
    }

    private func rowFrameReporter(id: BlockID) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: RowFramePreferenceKey.self,
                value: [id: proxy.frame(in: .named(PageHoverCoordinateSpace.name))]
            )
        }
    }

    /// Drop target rendered inside a row's existing top-gap area (or the trailing
    /// page-bottom area). Adds no layout space — the hit area is provided by an
    /// in-flow `Color.clear` whose vertical extent exactly matches the existing gap.
    /// A 2pt accent line shows while this slot is being targeted.
    @ViewBuilder
    private func gapDropTarget(at index: Int, height: CGFloat) -> some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .contentShape(Rectangle())
            .overlay(alignment: .center) {
                if dropHoverIndex == index {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(height: 2)
                }
            }
            .dropDestination(for: BlockDragPayload.self) { payloads, _ in
                guard let payload = payloads.first else { return false }
                moveBlocks(ids: payload.ids, toIndexBefore: index)
                dropHoverIndex = nil
                return true
            } isTargeted: { hovering in
                if hovering {
                    dropHoverIndex = index
                } else if dropHoverIndex == index {
                    dropHoverIndex = nil
                }
            }
            .iosPinchOpenToInsert {
                insertParagraph(at: index)
            }
    }

    /// Compute the BlockIDs to include in a drag started from `blockID`. If the row
    /// is part of a multi-block selection, drag the whole selection (in document
    /// order); otherwise just the single row.
    private func dragIDs(for blockID: BlockID) -> [BlockID] {
        if selection.contains(blockID) && selection.count > 1 {
            return document.blocks.compactMap { selection.contains($0.id) ? $0.id : nil }
        }
        return [blockID]
    }

    /// Move the contiguous-or-not set of blocks identified by `ids` so they're
    /// inserted starting at `target` (an index in the *current* document blocks). The
    /// dragged blocks come out of the old positions and go in at `target`, with `target`
    /// adjusted for the count of dragged blocks that came from before it. No-op if the
    /// drop is into the dragged range itself.
    private func moveBlocks(ids: [BlockID], toIndexBefore target: Int) {
        let idSet = Set(ids)
        let sourceIndices = document.blocks.enumerated()
            .compactMap { (i, block) in idSet.contains(block.id) ? i : nil }
        guard !sourceIndices.isEmpty else { return }

        // Reject drops onto the dragged range — would be a visual no-op anyway and
        // saves a useless undo entry.
        if let first = sourceIndices.first, let last = sourceIndices.last,
           target >= first && target <= last + 1 {
            return
        }

        let removalsBeforeTarget = sourceIndices.filter { $0 < target }.count
        let adjustedTarget = target - removalsBeforeTarget

        // Suppress SwiftUI's default ForEach move-animation. Without this, the row
        // crawls to its new position over the default animation duration after the
        // drop completes, which feels sluggish for a discrete reorder.
        withAnimation(nil) {
            mutate("Move Block") {
                let movingBlocks = sourceIndices.map { document.blocks[$0] }
                var blocks = document.blocks
                for i in sourceIndices.reversed() {
                    blocks.remove(at: i)
                }
                blocks.insert(contentsOf: movingBlocks, at: adjustedTarget)
                document.blocks = blocks
            }
        }
    }

    private func insertParagraph(at index: Int) {
        let newBlock = Block.paragraph(text: AttributedString())
        let insertionIndex = max(0, min(index, document.blocks.count))
        mutate("Insert Block") {
            document.blocks.insert(newBlock, at: insertionIndex)
        }
        setCursor(newBlock.id)
        editingBlock = newBlock.id
        editorFocused = newBlock.id
    }

    private func showActionToast(_ message: String) {
        actionToast = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if actionToast == message {
                actionToast = nil
            }
        }
    }

    private func isPageTitleBlock(_ block: Block, snapshot: [Block]) -> Bool {
        guard case .heading(_, 1, _) = block else { return false }
        guard let first = snapshot.first else { return false }
        return first.id == block.id
    }

    // MARK: - Undo

    /// Wrap a structural mutation so its inverse is registered with `undoController`.
    /// Callers must only call `mutate` when actually changing something — the helper
    /// doesn't equality-check. Snapshots `document.blocks` before the change, runs
    /// the change, then registers the previous snapshot as the undo. Redo is
    /// re-registered by the apply closure during `isUndoing`.
    private func mutate(_ name: String, _ change: () -> Void) {
        let before = document.blocks
        change()
        undoController.register(before, name: name)
        onEdited()
    }

    /// Install the closure that the undo controller calls on Cmd-Z (and on redo).
    /// Restores `document.blocks` and fixes up cursor/selection against the new
    /// block set. Re-registers the inverse so redo works.
    private func installUndoApply() {
        undoController.apply = { newBlocks in
            let beforeRedo = document.blocks
            document.blocks = newBlocks

            // Validate cursor/selection against the new block set.
            let validIDs = Set(newBlocks.map { $0.id })
            selection = selection.intersection(validIDs)
            if let c = cursor, !validIDs.contains(c) { cursor = newBlocks.first?.id }
            if let a = anchor, !validIDs.contains(a) { anchor = cursor }
            if let e = editingBlock, !validIDs.contains(e) {
                // The block under edit is gone. Exit edit mode and bounce focus through
                // false→true so SwiftUI re-binds the page as first responder — same dance
                // exitEditMode uses, for the same reason (NSTextView's responder slot
                // doesn't release otherwise).
                editingBlock = nil
                editorFocused = nil
                pageFocused = false
                DispatchQueue.main.async {
                    pageFocused = true
                }
            }
            if selection.isEmpty, let c = cursor { selection = [c] }

            // Re-register inverse — when this runs during isUndoing, UndoManager pushes
            // it to the redo stack; during isRedoing, it goes back on the undo stack.
            undoController.register(beforeRedo, name: undoController.undoManager.undoActionName)
            onEdited()
        }
        undoController.applyTextChange = { blockID, oldText in
            guard let i = document.blocks.firstIndex(where: { $0.id == blockID }) else { return }
            let beforeRedoText = document.blocks[i].text
            document.blocks[i] = document.blocks[i].withText(oldText)
            undoController.registerTextChange(blockID: blockID, oldText: beforeRedoText)
            onEdited()
        }
    }

    // MARK: - Selection state helpers

    /// Collapse selection to a single block. The next Shift-extend will pivot off this block.
    private func setCursor(_ id: BlockID) {
        cursor = id
        anchor = id
        selection = [id]
    }

    /// Move the cursor by `delta` rows; collapse to a single-block selection at the new cursor.
    private func moveCursor(by delta: Int) {
        let blocks = document.blocks
        guard !blocks.isEmpty else { return }
        let currentIndex = cursor.flatMap { id in blocks.firstIndex(where: { $0.id == id }) } ?? 0
        let nextIndex = max(0, min(blocks.count - 1, currentIndex + delta))
        setCursor(blocks[nextIndex].id)
    }

    /// Extend the selection in the direction of `delta`. The anchor stays put; the cursor
    /// moves; `selection` becomes every block between anchor and cursor inclusive.
    private func extendSelection(by delta: Int) {
        let blocks = document.blocks
        guard !blocks.isEmpty else { return }

        if anchor == nil {
            anchor = cursor ?? blocks.first?.id
        }
        if cursor == nil {
            cursor = anchor
        }

        guard let anchorID = anchor, let cursorID = cursor,
              let cursorIndex = blocks.firstIndex(where: { $0.id == cursorID }) else { return }

        let nextIndex = max(0, min(blocks.count - 1, cursorIndex + delta))
        cursor = blocks[nextIndex].id

        guard let anchorIndex = blocks.firstIndex(where: { $0.id == anchorID }) else { return }
        let lo = min(anchorIndex, nextIndex)
        let hi = max(anchorIndex, nextIndex)
        selection = Set(blocks[lo...hi].map { $0.id })
    }

    /// Indices of selected blocks in document order. Empty if no selection.
    private func selectedIndices() -> [Int] {
        document.blocks.enumerated()
            .compactMap { (i, block) in selection.contains(block.id) ? i : nil }
    }

    // MARK: - Edit-mode transitions

    private func enterEditMode(on id: BlockID) {
        guard let block = document.blocks.first(where: { $0.id == id }) else { return }
        switch block {
        case .code, .divider, .subpage:
            setCursor(id)
            return
        default:
            break
        }
        setCursor(id)
        editingBlock = id
        editorFocused = id
    }

    private func exitEditMode() {
        let was = editingBlock
        editingBlock = nil
        editorFocused = nil
        if let was {
            setCursor(was)
        }
        // Force-rebind: if pageFocused was already nominally true, the setter is a no-op
        // and SwiftUI won't re-install the page as first responder after the editor's
        // NSTextView is gone.
        pageFocused = false
        DispatchQueue.main.async {
            pageFocused = true
        }
        onBlur()
    }

    // MARK: - Selection-wide operations

    /// Move the contiguous selection up or down by `delta` rows. No-op if doing so would
    /// push the head past 0 or the tail past the last index.
    private func moveSelectionInDocument(by delta: Int) {
        let indices = selectedIndices()
        guard !indices.isEmpty, let first = indices.first, let last = indices.last else { return }
        let target = first + delta
        let lastTarget = last + delta
        guard target >= 0, lastTarget < document.blocks.count else { return }

        mutate("Move Block") {
            // Pull the slice, splice back at the target index.
            var blocks = document.blocks
            let slice = Array(blocks[first...last])
            blocks.removeSubrange(first...last)
            blocks.insert(contentsOf: slice, at: target)
            document.blocks = blocks
        }
    }

    /// Delete every block in the current selection. Selection collapses to the block just
    /// before the deleted range (or the first remaining if we removed the head). No-op if
    /// the selection covers every block in the document.
    private func deleteSelection() {
        let indices = selectedIndices()
        guard !indices.isEmpty else { return }
        guard indices.count < document.blocks.count else { return }

        let firstIndex = indices.first!
        mutate("Delete") {
            // Snapshot, mutate locally, write once. Removing through the @Binding
            // in a loop dropped all but the first removal — match the pattern
            // used by `moveSelectionInDocument`.
            var blocks = document.blocks
            for i in indices.reversed() {
                blocks.remove(at: i)
            }
            document.blocks = blocks
        }

        let nextIndex = max(0, min(firstIndex - 1, document.blocks.count - 1))
        if !document.blocks.isEmpty {
            setCursor(document.blocks[nextIndex].id)
        }
    }

    private func deleteBlocks(ids: [BlockID], actionName: String) {
        let idSet = Set(ids)
        let indices = document.blocks.enumerated()
            .compactMap { (i, block) in idSet.contains(block.id) ? i : nil }
        guard !indices.isEmpty, indices.count < document.blocks.count else { return }

        let firstIndex = indices.first!
        mutate(actionName) {
            var blocks = document.blocks
            for i in indices.reversed() {
                blocks.remove(at: i)
            }
            document.blocks = blocks
        }

        let nextIndex = max(0, min(firstIndex - 1, document.blocks.count - 1))
        if !document.blocks.isEmpty {
            setCursor(document.blocks[nextIndex].id)
        }
    }

    private func cycleIndent(blockID: BlockID) {
        guard let i = document.index(of: blockID) else { return }
        let block = document.blocks[i]
        switch block {
        case .bullet, .numbered, .todo:
            let nextIndent = block.indent >= 3 ? 0 : block.indent + 1
            guard nextIndent != block.indent else { return }
            mutate("Indent") {
                document.blocks[i] = block.withIndent(nextIndent)
            }
        default:
            break
        }
    }

    /// Apply Tab / Shift-Tab indent change to every list-item block in the selection. Non-
    /// list blocks are skipped silently.
    private func indentSelection(by delta: Int) {
        let indices = selectedIndices()
        guard !indices.isEmpty else { return }
        // Detect whether anything will actually change before opening an undo entry.
        let willChange = indices.contains { i in
            switch document.blocks[i] {
            case .bullet, .numbered, .todo: return true
            default: return false
            }
        }
        guard willChange else { return }
        mutate(delta > 0 ? "Indent" : "Outdent") {
            var blocks = document.blocks
            for i in indices {
                let block = blocks[i]
                switch block {
                case .bullet, .numbered, .todo:
                    blocks[i] = block.withIndent(block.indent + delta)
                default:
                    break
                }
            }
            document.blocks = blocks
        }
    }

    // MARK: - Editor-side keyboard handling (delegated from the active BlockTextEditor)

    private func handleEditorKey(_ key: BlockKey, blockID: BlockID) -> KeyPress.Result {
        switch key {
        case .enter(let cursorOffset):
            return splitBlock(blockID, at: cursorOffset)
        case .backspaceAtStart:
            return deleteEmptyBlock(blockID)
        case .tab:
            return changeIndent(blockID, by: +1)
        case .shiftTab:
            return changeIndent(blockID, by: -1)
        case .escape:
            exitEditMode()
            return .handled
        case .cmdK:
            return .handled
        case .exitEditUp:
            exitEditMode()
            DispatchQueue.main.async { moveCursor(by: -1) }
            return .handled
        case .exitEditDown:
            exitEditMode()
            DispatchQueue.main.async { moveCursor(by: +1) }
            return .handled
        }
    }

    private func splitBlock(_ blockID: BlockID, at cursorOffset: Int) -> KeyPress.Result {
        guard let i = document.index(of: blockID) else { return .ignored }
        let block = document.blocks[i]
        let plain = String(block.text.characters)
        let safeOffset = max(0, min(cursorOffset, plain.count))
        let splitIndex = plain.index(plain.startIndex, offsetBy: safeOffset)
        let head = String(plain[..<splitIndex])
        let tail = String(plain[splitIndex...])

        // Enter-triggered autotransforms (`---`, ` ``` `) only fire when the cursor is at
        // the end of the row (tail empty) and the head matches a whole-row trigger.
        if tail.isEmpty,
           let result = detectEnterAutotransform(text: AttributedString(head)) {
            applyAutotransform(result.transform, remainingText: result.remainingText, blockID: blockID)
            return .handled
        }

        let updatedCurrent = block.withText(AttributedString(head))
        let newBlock = followUpBlock(after: block, withText: tail)

        mutate("Split Block") {
            var blocks = document.blocks
            blocks[i] = updatedCurrent
            blocks.insert(newBlock, at: i + 1)
            document.blocks = blocks
        }
        DispatchQueue.main.async {
            setCursor(newBlock.id)
            editingBlock = newBlock.id
            editorFocused = newBlock.id
        }
        return .handled
    }

    /// Replace the block whose row's editor just fired an autotransform. The transform's
    /// `apply(to:)` returns the new block(s); we splice via `document.replace` and refocus
    /// on the block at `transform.focusReplacementIndex` (which is the fresh paragraph for
    /// divider/codeFence and the transformed block otherwise).
    private func applyAutotransform(_ transform: BlockTransform, remainingText: AttributedString, blockID: BlockID) {
        let replacements = transform.apply(to: remainingText)
        guard !replacements.isEmpty else { return }
        mutate("Format Block") {
            document.replace(blockID: blockID, with: replacements)
        }
        let focusTarget = replacements[transform.focusReplacementIndex]
        DispatchQueue.main.async {
            setCursor(focusTarget.id)
            // Code/divider rows aren't editable in M3 (`enterEditMode` skips them); for
            // those transforms the focus target is the empty paragraph, which is editable.
            switch focusTarget {
            case .code, .divider, .subpage:
                editingBlock = nil
                editorFocused = nil
            default:
                editingBlock = focusTarget.id
                editorFocused = focusTarget.id
            }
        }
    }

    private func followUpBlock(after block: Block, withText text: String) -> Block {
        let attr = AttributedString(text)
        switch block {
        case .bullet(_, _, let indent):
            return .bullet(text: attr, indent: indent)
        case .numbered(_, _, let indent):
            return .numbered(text: attr, indent: indent)
        case .todo(_, _, _, let indent):
            return .todo(text: attr, done: false, indent: indent)
        case .quote:
            return .quote(text: attr)
        case .heading, .paragraph, .toggle, .code, .divider, .subpage:
            return .paragraph(text: attr)
        }
    }

    private func deleteEmptyBlock(_ blockID: BlockID) -> KeyPress.Result {
        guard let i = document.index(of: blockID) else { return .ignored }
        guard document.blocks.count > 1 else { return .ignored }
        let previous = i > 0 ? document.blocks[i - 1].id : document.blocks.first?.id
        mutate("Delete Block") {
            document.blocks.remove(at: i)
        }
        if let previous {
            setCursor(previous)
            editingBlock = previous
            editorFocused = previous
        }
        return .handled
    }

    private func changeIndent(_ blockID: BlockID, by delta: Int) -> KeyPress.Result {
        guard let i = document.index(of: blockID) else { return .ignored }
        let block = document.blocks[i]
        switch block {
        case .bullet, .numbered, .todo:
            mutate(delta > 0 ? "Indent" : "Outdent") {
                document.blocks[i] = block.withIndent(block.indent + delta)
            }
            return .handled
        default:
            return .ignored
        }
    }
}

private extension View {
    @ViewBuilder
    func macNearestRowHover(rowFrames: [BlockID: CGRect], hoveredBlockID: Binding<BlockID?>) -> some View {
        #if os(macOS)
        self.onContinuousHover { phase in
            switch phase {
            case .active(let location):
                hoveredBlockID.wrappedValue = nearestRowID(to: location, in: rowFrames)
            case .ended:
                hoveredBlockID.wrappedValue = nil
            }
        }
        #else
        self
        #endif
    }

    @ViewBuilder
    func macBlockDragSource(payload: BlockDragPayload, isEnabled: Bool) -> some View {
        #if os(macOS)
        if isEnabled {
            self.draggable(payload) {
                DragPreviewChip(count: payload.ids.count)
            }
        } else {
            self
        }
        #else
        self
        #endif
    }

    @ViewBuilder
    func iosBlockTouchActions(
        payload: BlockDragPayload,
        isEnabled: Bool,
        onDelete: @escaping () -> Void,
        onCycleIndent: @escaping () -> Void
    ) -> some View {
        #if os(iOS)
        if isEnabled {
            self
                .draggable(payload) {
                    DragPreviewChip(count: payload.ids.count)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        onCycleIndent()
                    } label: {
                        Label("Indent", systemImage: "indent")
                    }
                    .tint(.blue)
                }
        } else {
            self
        }
        #else
        self
        #endif
    }

    @ViewBuilder
    func iosPinchOpenToInsert(_ action: @escaping () -> Void) -> some View {
        #if os(iOS)
        self.gesture(
            MagnifyGesture(minimumScaleDelta: 0.08)
                .onEnded { value in
                    if value.magnification > 1.18 {
                        action()
                    }
                }
        )
        #else
        self
        #endif
    }

    @ViewBuilder
    func iosPinchCloseToPageList(_ action: @escaping () -> Void) -> some View {
        #if os(iOS)
        self.simultaneousGesture(
            MagnifyGesture(minimumScaleDelta: 0.08)
                .onEnded { value in
                    if value.magnification < 0.82 {
                        action()
                    }
                }
        )
        #else
        self
        #endif
    }
}

private enum PageHoverCoordinateSpace {
    static let name = "PageView.hover"
}

private struct RowFramePreferenceKey: PreferenceKey {
    static let defaultValue: [BlockID: CGRect] = [:]

    static func reduce(value: inout [BlockID: CGRect], nextValue: () -> [BlockID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private func nearestRowID(to point: CGPoint, in frames: [BlockID: CGRect]) -> BlockID? {
    frames.min { lhs, rhs in
        abs(lhs.value.midY - point.y) < abs(rhs.value.midY - point.y)
    }?.key
}
