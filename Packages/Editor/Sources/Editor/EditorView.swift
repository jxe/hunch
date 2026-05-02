import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif


public extension Notification.Name {
    static let hunchEscapeKeyDown = Notification.Name("hunch.escapeKeyDown")
}

/// Single-page block editor.
///
/// **One EditorView per document.** Each `(document, state)` pair is one editing
/// session. Don't reuse the same EditorView with a different `Document` or
/// `EditorState` — the editor caches focus, undo, and gesture state internally
/// and assumes both are stable. To switch documents, create a fresh
/// `EditorView` with a fresh `EditorState` (typically by giving each navigation
/// destination its own wrapper view that owns the state).
public struct EditorView: View {
    @Binding public var document: Document
    /// Editor session state — selection, edit mode, gestures, hover, expanded
    /// toggles, drop targets. Owned by the host (typically `@State` in a parent
    /// view) so sibling UI can observe what the user is doing. Mutation flows
    /// through named methods inside the package; the host can read but not write.
    public var state: EditorState
    /// Host callback that provides `@`-mention candidates for the given query string.
    /// The editor renders up to the first 8 results; the host owns filtering/ranking.
    public let suggestPages: (_ query: String) -> [MentionItem]
    public let onSubpageTap: (_ pageID: String) -> Void
    public let pageTitle: (_ pageID: String) -> String?
    /// Persist a new subpage. `initialContent` is the body the editor wants the new
    /// page to start with (descendants of the source block); the host serializes it
    /// and prepends a title heading. Returns the host-assigned page id.
    public let onCreateSubpage: (_ title: String, _ requestedID: String?, _ initialContent: [Block]?) -> String?
    /// Read the page at `pageID` and return its blocks. `nil` means the page couldn't
    /// be loaded; the calling action becomes a no-op. Used by Expand Subpage — the
    /// source page stays put.
    public let onLoadSubpage: (_ pageID: String) -> [Block]?
    /// Absorb a subpage's content into the parent (Turn Into a non-page block):
    /// the editor inlines the loaded blocks at the subpage row's position and the
    /// host trashes the original file. Returns `true` if the host trashed it.
    public let onAbsorbSubpage: (_ pageID: String) -> Bool
    /// Append blocks to the end of the page at `pageID`. Returns `true` on success.
    /// Used by drop-on-subpage to move dragged blocks into a child page.
    public let onAppendToSubpage: (_ pageID: String, _ blocks: [Block]) -> Bool
    public let onNavigateBack: () -> Void
    public let onEdited: () -> Void
    public let onBlur: () -> Void
    /// Capture a block-level deletion before mutation so it can be restored from the
    /// recently-deleted view. The host model knows the document's relative path —
    /// the editor just supplies the indices, blocks, and a friendly action name.
    public let onRecordBlockDeletion: (_ indices: [Int], _ blocks: [Block], _ actionName: String) -> Void
    /// Serialize blocks into a string the editor will write to the system pasteboard
    /// on copy/cut. The host chooses the format (markdown, plain text, etc.). Default
    /// is empty — copy is a no-op until the host wires this up.
    public let serializeBlocksForPasteboard: (_ blocks: [Block]) -> String
    /// Parse a string from the system pasteboard back into blocks the editor will
    /// insert on paste. Returning nil cancels the paste. Default returns nil.
    public let parseBlocksFromPasteboard: (_ string: String) -> [Block]?

    // View-shaped @State that doesn't move into EditorState because it's tied to
    // SwiftUI/UIKit lifecycle (FocusState must live on a View; row-frame cache
    // is a layout output; gesture-internal flags are bookkeeping for UIKit
    // bridges; Environment must be read inside View.body).

    /// Drives the active editor's `.focused()` (iOS path; macOS uses NSResponder directly).
    @FocusState var editorFocused: BlockID?
    /// Drives the page container's focusability for nav-mode key handling.
    @FocusState var pageFocused: Bool
    /// Click point captured the moment a non-editing row was tapped. Forwarded to the
    /// editor on its first mount so the cursor lands where the user clicked. Stale values
    /// are harmless — the editor only consumes the point once on `makeNSView`.
    @State private var pendingCursorPoint: (id: BlockID, point: CGPoint)?
    /// Document-level undo coordinator. Owns the shared `UndoManager` that NSTextView
    /// typing-undo and structural ops (split/merge/indent/slide/delete/autotransform/
    /// drag-drop) all register against. Recreated implicitly when EditorView's identity
    /// resets; explicitly cleared on document switch via `.onChange(of: document.id)`.
    @State private var undoController = DocumentUndoController()
    @State var rowFrames: [BlockID: CGRect] = [:]
    @State var lastDropHapticIndex: Int?
    @State var pinchGestureActive = false
    @State var pinchCrossedInsertThreshold = false
    @State var pinchCrossedFocusThreshold = false
    /// Index of the slot the gap will open at, captured once at gesture start.
    /// Recomputing each update is wrong: as the gap grows it shifts the rows
    /// below it, mutating their `midY`, which can flip the calculation to an
    /// adjacent slot mid-gesture.
    @State var pinchPendingInsertIndex: Int?
    @State var scrollMetrics = PageScrollMetrics()
    @State var scrollPosition = ScrollPosition()
    @State var pinchAutoScrollTask: Task<Void, Never>?
    @State var pinchAutoScrollVelocity: CGFloat = 0
    @State var reorderAutoScrollTask: Task<Void, Never>?
    @State var reorderAutoScrollVelocity: CGFloat = 0
    @State var speechError: String?

    /// Drives the compact block action popover. On iOS this is opened by a
    /// leading row swipe; on macOS by clicking the drag handle or Cmd-/ in nav mode.
    /// Wraps `BlockID` because the latter is Hashable but not Identifiable.
    struct BlockActionSheet: Identifiable {
        let id: BlockID
    }
    @State var actionSheet: BlockActionSheet?

    public init(
        document: Binding<Document>,
        state: EditorState,
        suggestPages: @escaping (_ query: String) -> [MentionItem] = { _ in [] },
        onSubpageTap: @escaping (_ pageID: String) -> Void = { _ in },
        pageTitle: @escaping (_ pageID: String) -> String? = { _ in nil },
        onCreateSubpage: @escaping (_ title: String, _ requestedID: String?, _ initialContent: [Block]?) -> String? = { _, requestedID, _ in requestedID },
        onLoadSubpage: @escaping (_ pageID: String) -> [Block]? = { _ in nil },
        onAbsorbSubpage: @escaping (_ pageID: String) -> Bool = { _ in true },
        onAppendToSubpage: @escaping (_ pageID: String, _ blocks: [Block]) -> Bool = { _, _ in false },
        onNavigateBack: @escaping () -> Void = {},
        onEdited: @escaping () -> Void = {},
        onBlur: @escaping () -> Void = {},
        onRecordBlockDeletion: @escaping (_ indices: [Int], _ blocks: [Block], _ actionName: String) -> Void = { _, _, _ in },
        serializeBlocksForPasteboard: @escaping (_ blocks: [Block]) -> String = { _ in "" },
        parseBlocksFromPasteboard: @escaping (_ string: String) -> [Block]? = { _ in nil }
    ) {
        self._document = document
        self.state = state
        self.suggestPages = suggestPages
        self.onSubpageTap = onSubpageTap
        self.pageTitle = pageTitle
        self.onCreateSubpage = onCreateSubpage
        self.onLoadSubpage = onLoadSubpage
        self.onAbsorbSubpage = onAbsorbSubpage
        self.onAppendToSubpage = onAppendToSubpage
        self.onNavigateBack = onNavigateBack
        self.onEdited = onEdited
        self.onBlur = onBlur
        self.onRecordBlockDeletion = onRecordBlockDeletion
        self.serializeBlocksForPasteboard = serializeBlocksForPasteboard
        self.parseBlocksFromPasteboard = parseBlocksFromPasteboard
    }

    public var body: some View {
        GeometryReader { geometry in
            let numbering = NumberingContext.compute(document.blocks)
            let snapshot = document.blocks
            let hidden = hiddenBlockIDs(in: snapshot)
            let visiblePairs = Array(snapshot.enumerated()).filter { !hidden.contains($0.element.id) }
            let horizontalPadding = NotionStyle.pageHorizontalPadding(for: geometry.size.width)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(visiblePairs, id: \.element.id) { (i, block) in
                        let prev = previousVisibleBlock(before: block.id, in: snapshot, hidden: hidden)
                        let gap = BlockSpacing.gap(before: block, after: prev)
                        let pinchExtraTopGap = pinchExtraGap(forIndex: i)
                        let reorderExtraTopGap = reorderDriftGap(for: i)
                        rowView(for: $document.blocks[i], snapshot: snapshot, numberingIndex: numbering[block.id])
                            .padding(.top, gap + pinchExtraTopGap + reorderExtraTopGap)
                            .animation(.spring(response: 0.26, dampingFraction: 0.76), value: state.dropHoverIndex)
                            .background(rowFrameReporter(id: block.id))
                    }
                    // Trailing slot for "insert at end" — claims the existing bottom 32pt
                    // page padding. Total visual spacing unchanged: the outer
                    // `.padding(.vertical, 32)` becomes `.padding(.top, 32)` only.
                    let trailingPinchGap = pinchExtraGap(forIndex: snapshot.count)
                    gapDropTarget(at: snapshot.count, height: 32 + trailingPinchGap + reorderDriftGap(for: snapshot.count))
                        .animation(.spring(response: 0.26, dampingFraction: 0.76), value: state.dropHoverIndex)
                }
                .frame(maxWidth: NotionStyle.maxContentWidth, alignment: .leading)
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 32)
                .frame(maxWidth: .infinity, alignment: .center)
                .onPreferenceChange(RowFramePreferenceKey.self) { frames in
                    rowFrames = frames
                }
                .iosPageReorder(
                    isEnabled: !pinchGestureActive,
                    rowFrames: rowFrames,
                    snapshot: snapshot
                ) { blockID, location in
                    preliftReorder(blockID: blockID, snapshot: snapshot)
                    // Re-anchor immediately to the touch point so the lift sits under
                    // the finger from frame one (no center-then-snap).
                    tickReorderLift(blockID: blockID, at: location, anchorAt: location, snapshot: snapshot)
                    Haptics.light()
                } onChanged: { location in
                    guard let id = state.reorderLift?.ids.first else { return }
                    tickReorderLift(blockID: id, at: location, anchorAt: location, snapshot: snapshot)
                } onEnded: { location in
                    endReorderLift(atY: location.y, snapshot: snapshot)
                } onCancelled: {
                    cancelReorderLift()
                }
                .iosPagePinch(
                    isEnabled: state.editingBlock == nil,
                    onUpdate: { value in handlePinchUpdate(value) },
                    onCommit: { value in handlePinchCommit(value) }
                )
            }
            .coordinateSpace(name: PageHoverCoordinateSpace.name)
            .iosPageBlockDropTarget(
                onUpdate: { y in
                    applyDropTarget(at: y, snapshot: snapshot)
                },
                onDrop: { payload, y in
                    performPayloadDrop(payload, atY: y, snapshot: snapshot)
                },
                onCancel: {
                    state.dropHoverIndex = nil
                    state.dropOntoBlockID = nil
                    state.currentDropTarget = nil
                }
            )
            .iosScrollMetrics($scrollMetrics)
            .macScrollMetrics($scrollMetrics)
            .scrollPosition($scrollPosition)
            .macNearestRowHover(rowFrames: rowFrames) { id in state.hoveredBlock = id }
            .background(NotionStyle.background)
            .iosTapBelowRows {
                handleTapBelowRows(at: $0)
            }
            .overlay(alignment: .topLeading) {
                reorderLiftView()
            }
            .overlay(alignment: .bottom) {
                if let toast = state.actionToast {
                    HStack(spacing: 12) {
                        Text(toast)
                        Button("Undo") {
                            undoController.undoManager.undo()
                            state.actionToast = nil
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
            // Publish for App-level CommandGroup so Cmd-Z routes through this EditorView's
            // undo manager regardless of where focus actually lives. Uses scene-level
            // exposure (rather than `.focusedValue`) because in edit mode the NSTextView
            // holds AppKit-level focus, which SwiftUI's per-view focus tracking misses —
            // scene-level remains visible to the menu commands.
            .focusedSceneValue(\.documentUndoController, undoController)
            .focusable()
            .focused($pageFocused)
            .onAppear {
                if state.cursor == nil, let first = document.blocks.first {
                    state.setCursor(first.id)
                }
                requestPageNavigationFocus()
                installUndoApply()
            }
            .onChange(of: editorFocused) { old, new in
                if new == nil && old != nil {
                    onBlur()
                }
            }
            .onChange(of: state.dropHoverIndex) { _, newValue in
                handleDropHoverChange(newValue)
            }
            .onChange(of: state.selection) { _, _ in
                actionSheet = nil
            }
            .onChange(of: state.cursor) { _, _ in
                actionSheet = nil
            }
            .onChange(of: state.anchor) { _, _ in
                actionSheet = nil
            }
            .onChange(of: state.voiceRecordingToggleTicket) { _, _ in
                Task { await handleVoiceRecordingToggle() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .hunchEscapeKeyDown)) { _ in
                handleEscapeKey()
            }
            .onKeyPress(keys: [
                .upArrow, .downArrow, .leftArrow, .rightArrow, .return, .escape, .tab,
                KeyEquivalent("\u{19}"),  // NSBackTabCharacter — Shift+Tab on macOS
                .delete,
                KeyEquivalent("\u{8}"),
                KeyEquivalent("\u{7F}"),
                KeyEquivalent("c"),
                KeyEquivalent("v"),
                KeyEquivalent("x"),
                KeyEquivalent("k"),
                KeyEquivalent("s"),
                KeyEquivalent("/"),
                KeyEquivalent("[")
            ], action: handleNavKeyPress)
            .alert("Recording", isPresented: speechErrorBinding) {
                Button("OK") { speechError = nil }
            } message: {
                Text(speechError ?? "")
            }
            .iosEdgeGateNavigateBack()
        }
    }

    private func handleEscapeKey() {
        if actionSheet != nil {
            actionSheet = nil
            return
        }
        if state.editingBlock != nil {
            exitEditMode()
            return
        }
        clearCursor()
    }


    // MARK: - Row builder

    @ViewBuilder
    private func rowView(for binding: Binding<Block>, snapshot: [Block], numberingIndex: Int?) -> some View {
        let block = binding.wrappedValue
        // iOS has no nav-mode multi-select — there's no hardware keyboard arrow nav and the
        // blue tint after dismissing the keyboard is just visual noise. Hardcode false to
        // suppress it (the underlying nav state still updates; nothing reads it on iOS).
        #if os(iOS)
        let isSelected = false
        #else
        let isSelected = effectiveSelectedIDs().contains(block.id)
        #endif
        let isEditing = state.editingBlock == block.id

        BlockRow(
            block: binding,
            editorFocused: $editorFocused,
            isPageTitle: isPageTitleBlock(block, snapshot: snapshot),
            numberingIndex: numberingIndex,
            isSelected: isSelected,
            isEditing: isEditing,
            isExpanded: state.expandedToggles.contains(block.id) || state.expandedTemplates.contains(block.id),
            isDropTarget: state.dropOntoBlockID == block.id,
            onKey: { key in handleEditorKey(key, blockID: block.id) },
            onEdited: onEdited,
            onAutotransform: { transform, remainingText in
                applyAutotransform(transform, remainingText: remainingText, blockID: block.id)
            },
            onMentionTriggerChange: { trigger in
                handleMentionTriggerChange(trigger, blockID: block.id)
            },
            mentionActive: state.mentionMenu?.blockID == block.id,
            onClickAtPoint: { point in
                pendingCursorPoint = (block.id, point)
                enterEditMode(on: block.id)
            },
            onToggleExpansion: {
                if case .templateButton = block {
                    if state.expandedTemplates.contains(block.id) {
                        state.expandedTemplates.remove(block.id)
                    } else {
                        state.expandedTemplates.insert(block.id)
                    }
                } else if state.expandedToggles.contains(block.id) {
                    state.expandedToggles.remove(block.id)
                } else {
                    state.expandedToggles.insert(block.id)
                }
            },
            onTemplateButtonPress: {
                instantiateTemplateButton(blockID: block.id)
            },
            pageTitle: pageTitle,
            initialCursorPoint: (pendingCursorPoint?.id == block.id) ? pendingCursorPoint?.point : nil
        )
            // Whole-row reorder on macOS. Coexists with click-to-edit
            // (.onTapGesture below) because of the 4pt minimumDistance: a
            // click without movement enters edit mode; movement past 4pt
            // starts a drag instead. isEditing gates the drag off so the
            // editor's own selection gestures aren't shadowed.
            .macRowReorder(
                isEnabled: !isEditing,
                block: block,
                snapshot: snapshot,
                onChanged: { value in
                    tickReorderLift(
                        blockID: block.id,
                        at: value.location,
                        anchorAt: value.startLocation,
                        snapshot: snapshot
                    )
                },
                onEnded: { value in endReorderLift(atY: value.location.y, snapshot: snapshot) }
            )
            .blockActionPopover(
                isPresented: Binding(
                    get: { actionSheet?.id == block.id },
                    set: { if !$0 { actionSheet = nil } }
                )
            ) {
                blockActionMenuContent(for: block.id)
            }
            .blockActionPopover(
                isPresented: Binding(
                    get: { state.mentionMenu?.blockID == block.id },
                    set: { if !$0 { state.closeMentionMenu() } }
                )
            ) {
                mentionMenuContent()
            }
            .opacity(reorderSourceOpacity(for: block.id))
            .contentShape(Rectangle())
            .iosBlockTouchActions(
                isEnabled: !isEditing && !pinchGestureActive,
                onDelete: {
                    deleteBlocks(ids: dragIDs(for: block.id), actionName: "Delete")
                    showActionToast("Deleted")
                },
                onShowMenu: {
                    actionSheet = BlockActionSheet(id: block.id)
                }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier(accessibilityIdentifier(for: block))
            .accessibilityLabel(accessibilityLabel(for: block))
            .accessibilityValue(state.reorderLift?.ids.contains(block.id) == true ? "reorder-source" : "")
            .onTapGesture {
                if case .subpage(_, _, let path, _) = block {
                    focusPageNavigation(on: block.id)
                    onSubpageTap(path)
                    return
                }
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
                            state.hoveredHandle = block.id
                        } else if state.hoveredHandle == block.id {
                            state.hoveredHandle = nil
                        }
                    }
                    .onTapGesture {
                        actionSheet = BlockActionSheet(id: block.id)
                    }
                    // Keep the handle hit-testable AND the gesture mounted for
                    // the duration of an in-flight drag. As the cursor leaves
                    // the source row, hoveredBlockID shifts to a different row
                    // and showHandleOverlay(source) flips false; without this
                    // override, allowsHitTesting(false) gets applied to the
                    // still-tracking view and SwiftUI cancels the gesture
                    // silently — no .onEnded fires, lift gets stuck.
                    .macRowReorder(
                        isEnabled: (showHandleOverlay(for: block.id) || isMacDraggingFromRow(block.id)) && !isEditing,
                        block: block,
                        snapshot: snapshot,
                        onChanged: { value in
                            tickReorderLift(
                                blockID: block.id,
                                at: value.location,
                                anchorAt: value.startLocation,
                                snapshot: snapshot
                            )
                        },
                        onEnded: { value in endReorderLift(atY: value.location.y, snapshot: snapshot) }
                    )
                    .allowsHitTesting(showHandleOverlay(for: block.id) || isMacDraggingFromRow(block.id))
            }
    }

    private func topSelectedBlockID() -> BlockID? {
        for block in document.blocks where state.selection.contains(block.id) {
            return block.id
        }
        return nil
    }

    private func showHandleOverlay(for id: BlockID) -> Bool {
        if state.selection.count > 1 {
            return id == topSelectedBlockID()
        }
        return state.hoveredBlock == id || state.hoveredHandle == id
    }

    private func rowFrameReporter(id: BlockID) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: RowFramePreferenceKey.self,
                value: [id: proxy.frame(in: .named(PageHoverCoordinateSpace.name))]
            )
        }
    }


    private func accessibilityLabel(for block: Block) -> String {
        let text = accessibilityText(for: block)
        let kind = blockKindLabel(for: block)
        return text.isEmpty ? kind : "\(kind): \(text)"
    }

    private func accessibilityIdentifier(for block: Block) -> String {
        let text = accessibilityText(for: block)
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: "-")
        if text.isEmpty {
            return "block-row-\(block.id.value.uuidString)"
        }
        return "block-row-\(text)"
    }

    private func accessibilityText(for block: Block) -> String {
        switch block {
        case .code(_, let source, _, _):
            return source
        case .divider:
            return ""
        case .subpage(_, let title, _, _):
            return title
        default:
            return String(block.text.characters)
        }
    }

    private func blockKindLabel(for block: Block) -> String {
        switch block {
        case .paragraph:
            return "Paragraph"
        case .heading(_, let level, _, _):
            return "Heading \(level)"
        case .bullet:
            return "Bullet"
        case .numbered:
            return "Numbered item"
        case .todo:
            return "To-do"
        case .quote:
            return "Quote"
        case .code:
            return "Code block"
        case .divider:
            return "Divider"
        case .toggle:
            return "Toggle"
        case .templateButton:
            return "Template button"
        case .subpage:
            return "Subpage"
        }
    }

    /// Move the contiguous-or-not set of blocks identified by `ids` so they're
    /// inserted starting at `target` (an index in the *current* document blocks). The
    /// dragged blocks come out of the old positions and go in at `target`, with `target`
    /// adjusted for the count of dragged blocks that came from before it. No-op if the
    /// drop is into the dragged range itself.
    func insertParagraph(at index: Int, focus: Bool = true) {
        insertBlock(.paragraph(text: AttributedString()), at: index, focus: focus)
    }

    func insertBlock(_ newBlock: Block, at index: Int, focus: Bool = true) {
        let insertionIndex = max(0, min(index, document.blocks.count))
        mutate("Insert Block") {
            document.blocks.insert(newBlock, at: insertionIndex)
        }
        if focus {
            enterEditMode(on: newBlock.id)
        }
    }

    /// Pick a sensible block kind for a pinch-open insert at `index`. Continues
    /// list/quote runs by mirroring the neighbour's kind & indent — above wins,
    /// otherwise below, otherwise paragraph. Captures cases like inserting
    /// between two bullets, after the last bullet of a list, or between a
    /// heading and the first item of a list (all should yield a list item).
    func smartInsertBlock(at index: Int) -> Block {
        let blocks = document.blocks
        let above = (index - 1 >= 0 && index - 1 < blocks.count) ? blocks[index - 1] : nil
        let below = (index >= 0 && index < blocks.count) ? blocks[index] : nil
        if let kind = listLikeTemplate(from: above) { return kind }
        if let kind = listLikeTemplate(from: below) { return kind }
        return .paragraph(text: AttributedString())
    }

    /// If `block` is a list-like row (bullet/numbered/todo/quote), return a
    /// fresh empty block of the same kind & indent. Otherwise nil.
    private func listLikeTemplate(from block: Block?) -> Block? {
        guard let block else { return nil }
        switch block {
        case .bullet(_, _, let indent):
            return .bullet(text: AttributedString(), indent: indent)
        case .numbered(_, _, let indent):
            return .numbered(text: AttributedString(), indent: indent)
        case .todo(_, _, _, let indent):
            return .todo(text: AttributedString(), done: false, indent: indent)
        case .quote(_, _, let indent):
            return .quote(text: AttributedString(), indent: indent)
        default:
            return nil
        }
    }


    private func instantiateTemplateButton(blockID: BlockID) {
        guard let i = document.index(of: blockID),
              case .templateButton = document.blocks[i],
              let range = document.sectionRange(of: blockID) else { return }
        let body = document.blocks[(i + 1)..<range.upperBound]
        guard !body.isEmpty else { return }

        let copies = body.map { block in
            block
                .withIndent(max(0, block.indent - 1))
                .withFreshID()
        }
        mutate("Insert Template") {
            document.blocks.insert(contentsOf: copies, at: range.upperBound)
        }
        if let first = copies.first {
            focusPageNavigation(on: first.id)
        }
    }


    private func handleTapBelowRows(at point: CGPoint) {
        guard state.editingBlock == nil else { return }
        guard let lastBlock = document.blocks.last, let frame = rowFrames[lastBlock.id] else {
            insertParagraph(at: document.blocks.count)
            return
        }
        guard point.y > frame.maxY + 12 else { return }
        insertParagraph(at: document.blocks.count)
    }

    private func showActionToast(_ message: String) {
        state.actionToast = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if state.actionToast == message {
                state.actionToast = nil
            }
        }
    }

    private func isPageTitleBlock(_ block: Block, snapshot: [Block]) -> Bool {
        guard case .heading(_, 1, _, _) = block else { return false }
        guard let first = snapshot.first else { return false }
        return first.id == block.id
    }

    // MARK: - Undo

    /// Top-level key handler routed from `.onKeyPress` in the body. Extracted
    /// from the body so SwiftUI's body type-checker doesn't have to swallow
    /// the whole switch in one go.
    func handleNavKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard state.editingBlock == nil else { return .ignored }
        let modifiers = press.modifiers

        if press.key == KeyEquivalent("["), modifiers.contains(.command) {
            onNavigateBack()
            return .handled
        }

        if press.key == KeyEquivalent("c"), modifiers.contains(.command) {
            return copySelectionToPasteboard() ? .handled : .ignored
        }

        if press.key == KeyEquivalent("v"), modifiers.contains(.command) {
            return pasteFromPasteboard() ? .handled : .ignored
        }

        if press.key == KeyEquivalent("x"), modifiers.contains(.command) {
            return cutSelectionToPasteboard() ? .handled : .ignored
        }

        if press.key == KeyEquivalent("s"), modifiers.contains([.command, .shift]) {
            return toggleStrikethroughOnSelection() ? .handled : .ignored
        }

        if press.key == KeyEquivalent("/"), modifiers.contains(.command) {
            guard let id = topSelectedBlockID() else { return .ignored }
            actionSheet = BlockActionSheet(id: id)
            return .handled
        }

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
        case .rightArrow:
            return handleNavRightArrow() ? .handled : .ignored
        case .leftArrow:
            return handleNavLeftArrow() ? .handled : .ignored
        case .tab:
            indentSelection(by: modifiers.contains(.shift) ? -1 : +1)
            return .handled
        case .return:
            if let id = state.cursor, state.selection.count == 1 {
                if navigateIntoSubpage(id) {
                    return .handled
                }
                enterEditMode(on: id)
            }
            return .handled
        case .escape:
            handleEscapeKey()
            return .handled
        default:
            if press.key == KeyEquivalent("k"), modifiers.contains(.command) {
                guard let id = state.cursor, state.selection.count == 1 else { return .ignored }
                return convertBlockToSubpage(blockID: id, preferredTitle: nil)
            }
            return .ignored
        }
    }

    /// Wrap a structural mutation so its inverse is registered with `undoController`.
    /// Callers must only call `mutate` when actually changing something — the helper
    /// doesn't equality-check. Snapshots `document.blocks` before the change, runs
    /// the change, then registers the previous snapshot as the undo. Redo is
    /// re-registered by the apply closure during `isUndoing`.
    func mutate(_ name: String, _ change: () -> Void) {
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

            // Validate cursor/selection/edit-mode against the new block set in one
            // sweep — drops invalid IDs from the navigating selection, falls back
            // to nav mode if the editing block disappeared.
            let validIDs = Set(newBlocks.map { $0.id })
            state.revalidate(against: validIDs, fallbackCursor: newBlocks.first?.id)
            if state.editingBlock == nil {
                editorFocused = nil
            }

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
    func setCursor(_ id: BlockID) {
        state.setCursor(id)
    }

    private func clearCursor() {
        state.clearCursor()
    }

    func focusPageNavigation(on id: BlockID? = nil) {
        state.exitEditModeWithoutCursor()
        editorFocused = nil
        if let id, document.blocks.contains(where: { $0.id == id }) {
            state.setCursor(id)
        }
        requestPageNavigationFocus()
    }

    private func requestPageNavigationFocus() {
        DispatchQueue.main.async {
            pageFocused = false
            DispatchQueue.main.async {
                pageFocused = true
            }
        }
    }

    /// Nav-mode →: check todos in the selection, otherwise enter a selected subpage
    /// or open the collapsible section under the cursor.
    @discardableResult
    private func handleNavRightArrow() -> Bool {
        if setTodoDoneOnSelection(true) { return true }
        guard let id = state.cursor, state.selection.count == 1 else { return false }
        if navigateIntoSubpage(id) { return true }
        guard let block = document.blocks.first(where: { $0.id == id }),
              isCollapsibleSection(block) else { return false }
        withAnimation(.easeInOut(duration: 0.15)) {
            expandSection(block)
        }
        return true
    }

    /// Nav-mode ←: uncheck todos in the selection, otherwise close the current section if
    /// expanded, otherwise close the innermost enclosing collapsible section and move the
    /// selection there.
    @discardableResult
    private func handleNavLeftArrow() -> Bool {
        if setTodoDoneOnSelection(false) { return true }
        guard let id = state.cursor, state.selection.count == 1 else { return false }
        guard let cursorIdx = document.blocks.firstIndex(where: { $0.id == id }) else { return false }

        if isSectionExpanded(document.blocks[cursorIdx]) {
            withAnimation(.easeInOut(duration: 0.15)) {
                collapseSection(document.blocks[cursorIdx])
            }
            return true
        }

        guard let parentID = enclosingCollapsibleSectionID(at: cursorIdx),
              let parent = document.blocks.first(where: { $0.id == parentID }) else { return false }
        withAnimation(.easeInOut(duration: 0.15)) {
            collapseSection(parent)
        }
        setCursor(parentID)
        return true
    }

    /// Toggle strikethrough across every text-bearing block in the current selection.
    /// If all of them are already fully struck, remove strikethrough; otherwise add it
    /// uniformly. Skips blocks without an `AttributedString` body (code/divider/subpage)
    /// and template buttons (whose `withText` flattens formatting). Returns `true` if it
    /// acted.
    private func toggleStrikethroughOnSelection() -> Bool {
        let indices = effectiveSelectedIndices()
        let targets = indices.filter { i in
            switch document.blocks[i] {
            case .paragraph, .heading, .bullet, .numbered, .todo, .quote, .toggle:
                return true
            case .templateButton, .code, .divider, .subpage:
                return false
            }
        }
        guard !targets.isEmpty else { return false }

        var sawAnyText = false
        var allStruck = true
        for i in targets {
            let text = document.blocks[i].text
            if text.runs.isEmpty { continue }
            sawAnyText = true
            for run in text.runs {
                if run[InlineAttributes.StrikethroughAttribute.self] != true {
                    allStruck = false
                    break
                }
            }
            if !allStruck { break }
        }
        guard sawAnyText else { return false }
        let newValue = !allStruck

        mutate(newValue ? "Strikethrough" : "Remove Strikethrough") {
            var blocks = document.blocks
            for i in targets {
                var text = blocks[i].text
                let range = text.startIndex..<text.endIndex
                if range.lowerBound < range.upperBound {
                    text[range][InlineAttributes.StrikethroughAttribute.self] = newValue
                    blocks[i] = blocks[i].withText(text)
                }
            }
            document.blocks = blocks
        }
        return true
    }

    /// If every block in the current selection is a `.todo`, set their `done` state to
    /// `done` (skipping any that already match). Returns `true` if it acted.
    private func setTodoDoneOnSelection(_ done: Bool) -> Bool {
        let indices = selectedIndices()
        guard !indices.isEmpty else { return false }
        let targets: [(Int, BlockID, AttributedString, Int)] = indices.compactMap { i in
            if case let .todo(id, text, _, indent) = document.blocks[i] {
                return (i, id, text, indent)
            }
            return nil
        }
        guard targets.count == indices.count else { return false }
        let needsChange = targets.contains { i, _, _, _ in
            if case let .todo(_, _, currentDone, _) = document.blocks[i] {
                return currentDone != done
            }
            return false
        }
        guard needsChange else { return true }
        mutate(done ? "Check" : "Uncheck") {
            var blocks = document.blocks
            for (i, id, text, indent) in targets {
                blocks[i] = .todo(id: id, text: text, done: done, indent: indent)
            }
            document.blocks = blocks
        }
        return true
    }

    /// Innermost ancestor collapsible section whose section contains `cursorIdx`.
    private func enclosingCollapsibleSectionID(at cursorIdx: Int) -> BlockID? {
        var best: (id: BlockID, indent: Int)?
        for i in 0..<cursorIdx {
            let b = document.blocks[i]
            guard isCollapsibleSection(b) else { continue }
            if let range = document.sectionRange(of: b.id), range.contains(cursorIdx) {
                if best == nil || b.indent > best!.indent {
                    best = (b.id, b.indent)
                }
            }
        }
        return best?.id
    }

    /// IDs of blocks that should be hidden from rendering and from arrow-nav because they
    /// live inside a collapsed section. The section row itself is always visible; only its
    /// body (subsequent blocks at greater indent) is hidden when collapsed.
    func hiddenBlockIDs(in blocks: [Block]) -> Set<BlockID> {
        var hidden: Set<BlockID> = []
        var i = 0
        while i < blocks.count {
            let block = blocks[i]
            if isCollapsedSection(block) {
                let indent = block.indent
                var end = i + 1
                while end < blocks.count, blocks[end].indent > indent {
                    hidden.insert(blocks[end].id)
                    end += 1
                }
                i = end
                continue
            }
            i += 1
        }
        return hidden
    }

    private func isCollapsibleSection(_ block: Block) -> Bool {
        switch block {
        case .toggle, .templateButton:
            return true
        default:
            return false
        }
    }

    func isCollapsedSection(_ block: Block) -> Bool {
        switch block {
        case .toggle(let id, _, _):
            return !state.expandedToggles.contains(id)
        case .templateButton(let id, _, _):
            return !state.expandedTemplates.contains(id)
        default:
            return false
        }
    }

    private func isSectionExpanded(_ block: Block) -> Bool {
        switch block {
        case .toggle(let id, _, _):
            return state.expandedToggles.contains(id)
        case .templateButton(let id, _, _):
            return state.expandedTemplates.contains(id)
        default:
            return false
        }
    }

    private func expandSection(_ block: Block) {
        switch block {
        case .toggle(let id, _, _):
            state.expandedToggles.insert(id)
        case .templateButton(let id, _, _):
            state.expandedTemplates.insert(id)
        default:
            break
        }
    }

    private func collapseSection(_ block: Block) {
        switch block {
        case .toggle(let id, _, _):
            state.expandedToggles.remove(id)
        case .templateButton(let id, _, _):
            state.expandedTemplates.remove(id)
        default:
            break
        }
    }

    private func previousVisibleBlock(before id: BlockID, in blocks: [Block], hidden: Set<BlockID>) -> Block? {
        guard let idx = blocks.firstIndex(where: { $0.id == id }) else { return nil }
        var j = idx - 1
        while j >= 0 {
            if !hidden.contains(blocks[j].id) { return blocks[j] }
            j -= 1
        }
        return nil
    }

    /// Move the cursor by `delta` rows; collapse to a single-block selection at the new cursor.
    /// Skips blocks hidden inside collapsed toggles.
    private func moveCursor(by delta: Int) {
        let blocks = document.blocks
        guard !blocks.isEmpty else { return }
        let hidden = hiddenBlockIDs(in: blocks)
        let visible = blocks.filter { !hidden.contains($0.id) }
        guard !visible.isEmpty else { return }
        let currentIndex = state.cursor.flatMap { id in visible.firstIndex(where: { $0.id == id }) } ?? 0
        let nextIndex = max(0, min(visible.count - 1, currentIndex + delta))
        setCursor(visible[nextIndex].id)
    }

    /// Extend the selection in the direction of `delta`. The anchor stays put; the cursor
    /// moves by outline sections so extending over a parent consumes its descendants as
    /// real selection, not only via the effective-selection expansion used by operations.
    private func extendSelection(by delta: Int) {
        let blocks = document.blocks
        guard !blocks.isEmpty else { return }

        let initialAnchor = state.anchor ?? state.cursor ?? blocks.first?.id
        let initialCursor = state.cursor ?? initialAnchor

        guard let anchorID = initialAnchor, let cursorID = initialCursor,
              let anchorIndex = blocks.firstIndex(where: { $0.id == anchorID }),
              let cursorIndex = blocks.firstIndex(where: { $0.id == cursorID }) else { return }

        let nextIndex = outlineSelectionStep(from: cursorIndex, anchoredAt: anchorIndex, by: delta)
        let newCursor = blocks[nextIndex].id

        let lo = min(anchorIndex, nextIndex)
        let hi = max(anchorIndex, nextIndex)
        let newSelection = Set(blocks[lo...hi].map { $0.id })
        state.setNavSelection(blocks: newSelection, anchor: anchorID, cursor: newCursor)
    }

    private func outlineSelectionStep(from cursorIndex: Int, anchoredAt anchorIndex: Int, by delta: Int) -> Int {
        let blocks = document.blocks
        guard !blocks.isEmpty else { return cursorIndex }

        if delta > 0 {
            if cursorIndex < anchorIndex {
                if let range = document.sectionRange(of: blocks[cursorIndex].id),
                   range.upperBound <= anchorIndex {
                    return range.upperBound
                }
                return min(anchorIndex, cursorIndex + 1)
            }

            if let range = document.sectionRange(of: blocks[cursorIndex].id),
               range.upperBound > cursorIndex + 1 {
                guard range.upperBound < blocks.count else { return cursorIndex }
                return range.upperBound
            }
            return min(blocks.count - 1, cursorIndex + 1)
        }

        if delta < 0 {
            if cursorIndex > anchorIndex {
                if let anchorRange = document.sectionRange(of: blocks[anchorIndex].id),
                   anchorRange.contains(cursorIndex) {
                    return anchorIndex
                }
                return max(anchorIndex, cursorIndex - 1)
            }

            let indent = blocks[cursorIndex].indent
            var previousStart = cursorIndex - 1
            while previousStart >= 0, blocks[previousStart].indent > indent {
                previousStart -= 1
            }
            if previousStart >= 0, blocks[previousStart].indent == indent {
                return previousStart
            }
            return max(0, cursorIndex - 1)
        }

        return cursorIndex
    }

    /// Indices of selected blocks in document order. Empty if no selection.
    private func selectedIndices() -> [Int] {
        document.blocks.enumerated()
            .compactMap { (i, block) in state.selection.contains(block.id) ? i : nil }
    }

    private func effectiveSelectedIndices() -> [Int] {
        document.indicesIncludingSections(of: state.selection)
    }

    private func effectiveSelectedIDs() -> Set<BlockID> {
        Set(effectiveSelectedIDsInDocumentOrder())
    }

    func effectiveSelectedIDsInDocumentOrder() -> [BlockID] {
        effectiveSelectedIndices().map { document.blocks[$0].id }
    }

    // MARK: - Edit-mode transitions

    private func enterEditMode(on id: BlockID) {
        guard let block = document.blocks.first(where: { $0.id == id }) else { return }
        switch block {
        case .code, .divider, .subpage:
            focusPageNavigation(on: id)
            return
        default:
            break
        }
        // .editing(id, overlay: nil) — also drops any stale mention overlay attached
        // to a different row, since the new mode replaces the old one wholesale.
        state.enterEditMode(on: id)
        editorFocused = id
    }

    func exitEditMode() {
        let was = state.editingBlock
        // Mode → .navigating(...) drops any active mention overlay along with it,
        // since the popover is anchored to the editing row and would otherwise
        // attach to a read-only Text that can no longer drive the input.
        focusPageNavigation(on: was)
        onBlur()
    }

    // MARK: - Selection-wide operations

    /// Move the contiguous selection up or down across outline siblings. Selected
    /// parents carry their descendants, so top-level blocks hop over whole sections.
    private func moveSelectionInDocument(by delta: Int) {
        let ids = effectiveSelectedIDsInDocumentOrder()
        guard !ids.isEmpty else { return }

        var moved = document
        guard moved.moveSections(containing: ids, by: delta) else { return }

        mutate("Move Block") {
            document.blocks = moved.blocks
        }
    }

    /// Delete every block in the current selection. Selection collapses to the block just
    /// before the deleted range (or the first remaining if we removed the head). No-op if
    /// the selection covers every block in the document.
    private func deleteSelection() {
        let indices = effectiveSelectedIndices()
        guard !indices.isEmpty else { return }
        guard indices.count < document.blocks.count else { return }

        let removed = indices.map { document.blocks[$0] }
        onRecordBlockDeletion(indices, removed, "Delete")

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
        let indices = document.indicesIncludingSections(of: ids)
        guard !indices.isEmpty, indices.count < document.blocks.count else { return }

        let removed = indices.map { document.blocks[$0] }
        onRecordBlockDeletion(indices, removed, actionName)

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

    private func indentByOne(blockID: BlockID) {
        let indices = document.indicesIncludingSections(of: [blockID])
        guard canChangeIndent(at: indices, by: 1) else { return }
        mutate("Indent") {
            var blocks = document.blocks
            for i in indices {
                blocks[i] = blocks[i].withIndent(blocks[i].indent + 1)
            }
            document.blocks = blocks
        }
    }

    /// Apply Tab / Shift-Tab indent change to the effective selection.
    private func indentSelection(by delta: Int) {
        let indices = effectiveSelectedIndices()
        guard !indices.isEmpty else { return }
        guard canChangeIndent(at: indices, by: delta) else { return }
        mutate(delta > 0 ? "Indent" : "Outdent") {
            var blocks = document.blocks
            for i in indices {
                blocks[i] = blocks[i].withIndent(blocks[i].indent + delta)
            }
            document.blocks = blocks
        }
    }

    private func copySelectionToPasteboard() -> Bool {
        copyBlocksToPasteboard(ids: state.selection)
    }

    /// Cut: copy the selection to the pasteboard, then delete it as a single undo entry.
    /// Mirrors the `deleteSelection` guard against deleting every block in the document.
    private func cutSelectionToPasteboard() -> Bool {
        let indices = effectiveSelectedIndices()
        guard !indices.isEmpty else { return false }
        guard indices.count < document.blocks.count else { return false }
        guard copyBlocksToPasteboard(ids: state.selection) else { return false }

        let firstIndex = indices.first!
        mutate("Cut") {
            var blocks = document.blocks
            for i in indices.reversed() { blocks.remove(at: i) }
            document.blocks = blocks
        }

        let nextIndex = max(0, min(firstIndex - 1, document.blocks.count - 1))
        if !document.blocks.isEmpty {
            setCursor(document.blocks[nextIndex].id)
        } else {
            clearCursor()
        }
        return true
    }

    /// Paste: read a string from the pasteboard, hand it to the host to parse into blocks,
    /// and insert them after the cursor block. If the cursor block already has children
    /// (i.e. its `sectionRange` extends past itself), pasted blocks land at the end of
    /// those children as siblings (indent + 1); otherwise they land immediately below the
    /// cursor at the cursor's own indent. With no cursor, append at end of doc, indent 0.
    /// The host is expected to return blocks normalized to indent 0; we shift each by the
    /// chosen base.
    private func pasteFromPasteboard() -> Bool {
        let pasted: String
        #if os(macOS)
        guard let str = NSPasteboard.general.string(forType: .string) else { return false }
        pasted = str
        #else
        guard let str = UIPasteboard.general.string else { return false }
        pasted = str
        #endif
        guard let parsed = parseBlocksFromPasteboard(pasted), !parsed.isEmpty else { return false }

        let baseIndent: Int
        let insertIndex: Int
        if let cursorID = state.cursor,
           let anchorIdx = document.index(of: cursorID),
           let section = document.sectionRange(of: cursorID) {
            let anchorIndent = document.blocks[anchorIdx].indent
            let hasChildren = section.count > 1
            baseIndent = hasChildren ? anchorIndent + 1 : anchorIndent
            insertIndex = section.upperBound
        } else {
            baseIndent = 0
            insertIndex = document.blocks.count
        }
        let reindented = baseIndent == 0
            ? parsed
            : parsed.map { $0.withIndent($0.indent + baseIndent) }

        mutate("Paste") {
            var blocks = document.blocks
            blocks.insert(contentsOf: reindented, at: insertIndex)
            document.blocks = blocks
        }

        if let last = reindented.last {
            setCursor(last.id)
        }
        return true
    }

    func copyBlocksToPasteboard(ids: some Sequence<BlockID>) -> Bool {
        let indices = document.indicesIncludingSections(of: ids)
        guard !indices.isEmpty else { return false }

        let selectedBlocks = indices.map { document.blocks[$0] }
        let minIndent = selectedBlocks.map(\.indent).min() ?? 0
        let normalizedBlocks = selectedBlocks.map { block in
            block.withIndent(block.indent - minIndent)
        }
        let serialized = serializeBlocksForPasteboard(normalizedBlocks)
        guard !serialized.isEmpty else { return false }

        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(serialized, forType: .string)
        #else
        UIPasteboard.general.string = serialized
        #endif
        return true
    }

    func canChangeIndent(at indices: [Int], by delta: Int) -> Bool {
        guard !indices.isEmpty else { return false }
        return indices.allSatisfy { i in
            let next = document.blocks[i].indent + delta
            return next >= 0 && next <= 5
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
        case .cmdK(let selectedText):
            return convertBlockToSubpage(blockID: blockID, preferredTitle: selectedText)
        case .navigateBack:
            onNavigateBack()
            return .handled
        case .exitEditUp:
            exitEditMode()
            DispatchQueue.main.async { moveCursor(by: -1) }
            return .handled
        case .exitEditDown:
            exitEditMode()
            DispatchQueue.main.async { moveCursor(by: +1) }
            return .handled
        case .mentionUp:
            return moveMentionSelection(by: -1)
        case .mentionDown:
            return moveMentionSelection(by: +1)
        case .mentionCommit:
            return commitMentionSelection()
        case .mentionDismiss:
            state.closeMentionMenu()
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

        // Enter at end of a block that has indent-children: the natural intent is
        // to add a child, not a sibling that would slot between the parent and
        // its first child. Two flavors:
        //   * Closed toggle/template — the children are hidden, so a "child" would
        //     vanish; insert a sibling AFTER the whole collapsed section instead.
        //   * Anything else with children — insert a new FIRST child of the same
        //     type as the existing first child.
        if tail.isEmpty,
           i + 1 < document.blocks.count,
           document.blocks[i + 1].indent > block.indent {
            let firstChildIdx = i + 1
            if isCollapsedSection(block) {
                let endOfSection = document.sectionRange(of: blockID)?.upperBound ?? firstChildIdx
                let newBlock = followUpBlock(after: block, withText: "")
                mutate("Split Block") {
                    document.blocks.insert(newBlock, at: endOfSection)
                }
                DispatchQueue.main.async {
                    enterEditMode(on: newBlock.id)
                }
                return .handled
            } else {
                let firstChild = document.blocks[firstChildIdx]
                let newBlock = followUpBlock(after: firstChild, withText: "")
                mutate("Split Block") {
                    document.blocks.insert(newBlock, at: firstChildIdx)
                }
                DispatchQueue.main.async {
                    enterEditMode(on: newBlock.id)
                }
                return .handled
            }
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
            enterEditMode(on: newBlock.id)
        }
        return .handled
    }

    private func navigateIntoSubpage(_ blockID: BlockID) -> Bool {
        guard let block = document.blocks.first(where: { $0.id == blockID }),
              case .subpage(_, _, let path, _) = block else {
            return false
        }
        focusPageNavigation(on: blockID)
        onSubpageTap(path)
        return true
    }


    /// Replace the block whose row's editor just fired an autotransform. The transform's
    /// `apply(to:)` returns the new block(s); we splice via `document.replace` and refocus
    /// on the block at `transform.focusReplacementIndex` (which is the fresh paragraph for
    /// divider/codeFence and the transformed block otherwise).
    private func applyAutotransform(_ transform: BlockTransform, remainingText: AttributedString, blockID: BlockID) {
        guard let source = document.blocks.first(where: { $0.id == blockID }) else { return }
        let replacements = transform.apply(to: remainingText).map { $0.withIndent(source.indent) }
        guard !replacements.isEmpty else { return }
        mutate("Format Block") {
            document.replace(blockID: blockID, with: replacements)
        }
        // `> ` on a row with indent-descendants converts it to a toggle whose body is those
        // descendants — start expanded so they don't immediately vanish from the page.
        if transform == .toggle {
            for case .toggle(let id, _, _) in replacements {
                state.expandedToggles.insert(id)
            }
        }
        let focusTarget = replacements[transform.focusReplacementIndex]
        DispatchQueue.main.async {
            // Code/divider rows aren't editable in M3 (`enterEditMode` skips them); for
            // those transforms the focus target is the empty paragraph, which is editable.
            switch focusTarget {
            case .code, .divider, .subpage:
                focusPageNavigation(on: focusTarget.id)
            default:
                enterEditMode(on: focusTarget.id)
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
        case .quote(_, _, let indent):
            return .quote(text: attr, indent: indent)
        case .heading(_, _, _, let indent),
             .paragraph(_, _, let indent),
             .toggle(_, _, let indent),
             .templateButton(_, _, let indent),
             .code(_, _, _, let indent),
             .divider(_, let indent),
             .subpage(_, _, _, let indent):
            return .paragraph(text: attr, indent: indent)
        }
    }

    /// Backspace fired at offset 0 of a *blank* row (only entry path: macOS
    /// `keyDown` and the iOS hardware-keyboard `.onKeyPress(.delete)` gate on
    /// the block being empty). Two-step:
    ///
    ///   1. If the row is anything other than `.paragraph` (heading, bullet,
    ///      numbered, todo, quote, toggle), collapse it to an empty paragraph
    ///      in place — same id, same editor focus, just the marker / sizing
    ///      goes away.
    ///   2. If the row is already an empty paragraph, remove it and move the
    ///      cursor to the previous block.
    private func deleteEmptyBlock(_ blockID: BlockID) -> KeyPress.Result {
        guard let i = document.index(of: blockID) else { return .ignored }
        let block = document.blocks[i]

        let isParagraph: Bool = {
            if case .paragraph = block { return true }
            return false
        }()

        if !isParagraph {
            mutate("Convert to Paragraph") {
                document.blocks[i] = .paragraph(id: block.id, text: AttributedString(), indent: block.indent)
            }
            return .handled
        }

        guard document.blocks.count > 1 else { return .ignored }
        let previous = i > 0 ? document.blocks[i - 1].id : document.blocks.first?.id
        mutate("Delete Block") {
            document.blocks.remove(at: i)
        }
        if let previous {
            enterEditMode(on: previous)
        }
        return .handled
    }

    func changeIndent(_ blockID: BlockID, by delta: Int) -> KeyPress.Result {
        let indices = document.indicesIncludingSections(of: [blockID])
        guard canChangeIndent(at: indices, by: delta) else { return .ignored }
        mutate(delta > 0 ? "Indent" : "Outdent") {
            var blocks = document.blocks
            for i in indices {
                blocks[i] = blocks[i].withIndent(blocks[i].indent + delta)
            }
            document.blocks = blocks
        }
        return .handled
    }
}

