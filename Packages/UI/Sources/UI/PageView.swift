import SwiftUI
import Core

public struct PageView: View {
    @Binding public var document: Document
    public let onSubpageTap: (String) -> Void
    public let onEdited: () -> Void
    public let onBlur: () -> Void

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

    public init(
        document: Binding<Document>,
        onSubpageTap: @escaping (String) -> Void = { _ in },
        onEdited: @escaping () -> Void = {},
        onBlur: @escaping () -> Void = {}
    ) {
        self._document = document
        self.onSubpageTap = onSubpageTap
        self.onEdited = onEdited
        self.onBlur = onBlur
    }

    public var body: some View {
        let numbering = NumberingContext.compute(document.blocks)
        let snapshot = document.blocks
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach($document.blocks) { $block in
                    rowView(for: $block, snapshot: snapshot, numberingIndex: numbering[block.id])
                        .padding(.top, BlockSpacing.gap(
                            before: block,
                            after: previousBlock(before: block.id, in: snapshot)
                        ))
                }
            }
            .frame(maxWidth: NotionStyle.maxContentWidth, alignment: .leading)
            .padding(.horizontal, NotionStyle.pageHorizontalPadding)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(NotionStyle.background)
        .focusable()
        .focused($pageFocused)
        .onAppear {
            if cursor == nil, let first = document.blocks.first {
                setCursor(first.id)
            }
            pageFocused = true
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
                onEdited: onEdited
            )
            .contentShape(Rectangle())
            .onTapGesture {
                enterEditMode(on: block.id)
            }
        }
    }

    private func isPageTitleBlock(_ block: Block, snapshot: [Block]) -> Bool {
        guard case .heading(_, 1, _) = block else { return false }
        guard let first = snapshot.first else { return false }
        return first.id == block.id
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

        // Pull the slice, splice back at the target index.
        var blocks = document.blocks
        let slice = Array(blocks[first...last])
        blocks.removeSubrange(first...last)
        blocks.insert(contentsOf: slice, at: target)
        document.blocks = blocks
        onEdited()
    }

    /// Delete every block in the current selection. Selection collapses to the block just
    /// before the deleted range (or the first remaining if we removed the head). No-op if
    /// the selection covers every block in the document.
    private func deleteSelection() {
        let indices = selectedIndices()
        guard !indices.isEmpty else { return }
        guard indices.count < document.blocks.count else { return }

        let firstIndex = indices.first!
        // Remove highest indices first so earlier indices stay valid.
        for i in indices.reversed() {
            document.blocks.remove(at: i)
        }
        let nextIndex = max(0, min(firstIndex - 1, document.blocks.count - 1))
        if !document.blocks.isEmpty {
            setCursor(document.blocks[nextIndex].id)
        }
        onEdited()
    }

    /// Apply Tab / Shift-Tab indent change to every list-item block in the selection. Non-
    /// list blocks are skipped silently.
    private func indentSelection(by delta: Int) {
        let indices = selectedIndices()
        guard !indices.isEmpty else { return }
        var changed = false
        for i in indices {
            let block = document.blocks[i]
            switch block {
            case .bullet, .numbered, .todo:
                let newIndent = block.indent + delta
                document.blocks[i] = block.withIndent(newIndent)
                changed = true
            default:
                break
            }
        }
        if changed { onEdited() }
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

        let updatedCurrent = block.withText(AttributedString(head))
        let newBlock = followUpBlock(after: block, withText: tail)

        document.blocks[i] = updatedCurrent
        document.blocks.insert(newBlock, at: i + 1)
        onEdited()
        DispatchQueue.main.async {
            setCursor(newBlock.id)
            editingBlock = newBlock.id
            editorFocused = newBlock.id
        }
        return .handled
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
        document.blocks.remove(at: i)
        onEdited()
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
            let newIndent = block.indent + delta
            document.blocks[i] = block.withIndent(newIndent)
            onEdited()
            return .handled
        default:
            return .ignored
        }
    }
}
