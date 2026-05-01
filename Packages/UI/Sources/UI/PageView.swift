import SwiftUI
import Core
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

private struct PagePinchValue {
    var startLocation: CGPoint
    var location: CGPoint
    var magnification: CGFloat
    var spread: CGFloat
    var spreadDelta: CGFloat
}

private struct PageScrollMetrics: Equatable {
    var viewportHeight: CGFloat = 0
    var contentHeight: CGFloat = 0
    var contentOffsetY: CGFloat = 0
}

private enum BlockTurnInto: CaseIterable {
    // Declaration order drives the on-screen order in the 3-col Turn Into grid.
    // Grouped so each row reads as a category: headings, list types,
    // everything else (Template alone trails because most blocks can't become
    // one and `turnIntoTargets` filters it out for multi-selection).
    case heading1
    case heading2
    case heading3
    case bullet
    case numbered
    case todo
    case paragraph
    case toggle
    case page
    case divider
    case template

    var title: String {
        switch self {
        case .paragraph: return "Text"
        case .bullet: return "Bullet"
        case .numbered: return "Number"
        case .todo: return "To-do"
        case .toggle: return "Toggle"
        case .template: return "Template"
        case .heading1: return "H1"
        case .heading2: return "H2"
        case .heading3: return "H3"
        case .page: return "Page"
        case .divider: return "Divider"
        }
    }

    var systemImage: String {
        switch self {
        case .paragraph: return "text.alignleft"
        case .bullet: return "list.bullet"
        case .numbered: return "list.number"
        case .todo: return "checkmark.square"
        case .toggle: return "chevron.right"
        case .template: return "plus.square.on.square"
        case .heading1: return "h.square"
        case .heading2: return "h.square"
        case .heading3: return "h.square"
        case .page: return "doc"
        case .divider: return "minus"
        }
    }

    var keyboardShortcut: KeyEquivalent {
        switch self {
        case .paragraph: return "p"
        case .bullet: return "b"
        case .numbered: return "n"
        case .todo: return "t"
        case .toggle: return ">"
        case .template: return "m"
        case .heading1: return "1"
        case .heading2: return "2"
        case .heading3: return "3"
        case .page: return "s"
        case .divider: return "-"
        }
    }
}

private struct BlockIndentAction: Hashable {
    let delta: Int
    let title: String
    let systemImage: String
    let keyboardShortcut: KeyEquivalent
}

public extension Notification.Name {
    static let hunchEscapeKeyDown = Notification.Name("hunch.escapeKeyDown")
}

public struct PageView: View {
    @Binding public var document: Document
    /// All `.md` files in the workspace — drives the `@`-mention popover's filterable
    /// list. Empty by default so callers that don't pass it (tests, previews) just see
    /// no results in the popover.
    public let entries: [WorkspaceEntry]
    public let onSubpageTap: (String) -> Void
    public let pageTitle: (_ relativePath: String) -> String?
    public let onCreateSubpage: (_ title: String, _ requestedPath: String?, _ initialContent: String?) -> String?
    /// Inverse of subpage creation: read the .md at the given relative path and return its blocks.
    /// `nil` means the file couldn't be read or parsed; the popover action becomes a no-op.
    public let onLoadSubpage: (_ relativePath: String) -> [Block]?
    public let onMoveSubpageToTrash: (_ relativePath: String) -> Bool
    /// Append blocks to the end of the subpage at `relativePath`. Returns `true`
    /// on success. Used by drop-on-subpage to move dragged blocks into a child page.
    public let onAppendToSubpage: (_ relativePath: String, _ blocks: [Block]) -> Bool
    public let onNavigateBack: () -> Void
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
    /// When the drop pointer is squarely on a closed toggle/templateButton row's body,
    /// this records that block's id and the drop will append the dragged content as
    /// the parent's last child (with indent shifted to parent.indent + 1). Mutually
    /// exclusive with `dropHoverIndex`.
    @State private var dropOntoBlockID: BlockID?
    @State private var currentDropTarget: DropTarget?
    @State private var rowFrames: [BlockID: CGRect] = [:]
    @State private var actionToast: String?
    @State private var lastDropHapticIndex: Int?
    /// Unified reorder lift state. Set on iOS at long-press completion (with a
    /// placeholder centered touchOffset, re-anchored on the first real drag
    /// event) and on macOS on the first DragGesture event past the 4pt
    /// threshold. The fields are platform-agnostic; only the gesture that
    /// triggers it differs.
    @State private var reorderLift: ReorderLift?
    /// Active pinch-open-to-insert preview state. Drives an inline gap that grows
    /// between two rows as the user spreads their fingers; nil when no pinch is
    /// in progress (or when the pinch's startLocation didn't pin to a row pair).
    /// Committed on release past threshold; spring-closed below threshold.
    @State private var pinchPreview: PinchPreviewState?
    @State private var pinchGestureActive = false
    @State private var pinchCrossedInsertThreshold = false
    @State private var pinchCrossedFocusThreshold = false
    @State private var scrollMetrics = PageScrollMetrics()
    @State private var pinchAutoScrollTask: Task<Void, Never>?
    @State private var pinchAutoScrollVelocity: CGFloat = 0
    @State private var speechRecorder = PageSpeechRecorder()
    @State private var speechError: String?
    @State private var interactionMode: PageInteractionMode = .nav(focused: nil)
    @Environment(\.scenePhase) private var scenePhase

    private enum PageInteractionMode: Equatable {
        case nav(focused: BlockID?)
        case editing(BlockID)
    }

    struct PinchPreviewState: Equatable {
        var insertIndex: Int
        var gapHeight: CGFloat
    }

    /// Drives the compact block action popover. On iOS this is opened by a
    /// leading row swipe; on macOS by clicking the drag handle or Cmd-/ in nav mode.
    /// Wraps `BlockID` because the latter is Hashable but not Identifiable.
    fileprivate struct BlockActionSheet: Identifiable {
        let id: BlockID
    }
    @State private var actionSheet: BlockActionSheet?
    /// Toggle expansion is page-local view state — defaults to all closed every time the
    /// page opens. Toggle expansion isn't persisted to markdown (matches the previous
    /// behavior, where the model carried `expanded` but the serializer dropped it).
    @State private var expandedToggles: Set<BlockID> = []
    @State private var expandedTemplateButtons: Set<BlockID> = []

    /// Active mention menu state. When non-nil, the editor diverts ↑/↓/Return/Esc to
    /// menu navigation instead of the usual edit-mode handling.
    @State private var mentionMenu: MentionMenuState?

    fileprivate struct MentionMenuState: Equatable {
        let blockID: BlockID
        var trigger: MentionTrigger
        var selectedIndex: Int
    }

    public init(
        document: Binding<Document>,
        entries: [WorkspaceEntry] = [],
        onSubpageTap: @escaping (String) -> Void = { _ in },
        pageTitle: @escaping (_ relativePath: String) -> String? = { _ in nil },
        onCreateSubpage: @escaping (_ title: String, _ requestedPath: String?, _ initialContent: String?) -> String? = { _, requestedPath, _ in requestedPath },
        onLoadSubpage: @escaping (_ relativePath: String) -> [Block]? = { _ in nil },
        onMoveSubpageToTrash: @escaping (_ relativePath: String) -> Bool = { _ in true },
        onAppendToSubpage: @escaping (_ relativePath: String, _ blocks: [Block]) -> Bool = { _, _ in false },
        onNavigateBack: @escaping () -> Void = {},
        onEdited: @escaping () -> Void = {},
        onBlur: @escaping () -> Void = {}
    ) {
        self._document = document
        self.entries = entries
        self.onSubpageTap = onSubpageTap
        self.pageTitle = pageTitle
        self.onCreateSubpage = onCreateSubpage
        self.onLoadSubpage = onLoadSubpage
        self.onMoveSubpageToTrash = onMoveSubpageToTrash
        self.onAppendToSubpage = onAppendToSubpage
        self.onNavigateBack = onNavigateBack
        self.onEdited = onEdited
        self.onBlur = onBlur
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
                        let pinchExtraTopGap: CGFloat = (pinchPreview?.insertIndex == i) ? (pinchPreview?.gapHeight ?? 0) : 0
                        let reorderExtraTopGap = reorderDriftGap(for: i)
                        rowView(for: $document.blocks[i], snapshot: snapshot, numberingIndex: numbering[block.id])
                            .padding(.top, gap + pinchExtraTopGap + reorderExtraTopGap)
                            .animation(.spring(response: 0.26, dampingFraction: 0.76), value: dropHoverIndex)
                            .background(rowFrameReporter(id: block.id))
                    }
                    // Trailing slot for "insert at end" — claims the existing bottom 32pt
                    // page padding. Total visual spacing unchanged: the outer
                    // `.padding(.vertical, 32)` becomes `.padding(.top, 32)` only.
                    let trailingPinchGap: CGFloat = (pinchPreview?.insertIndex == snapshot.count) ? (pinchPreview?.gapHeight ?? 0) : 0
                    gapDropTarget(at: snapshot.count, height: 32 + trailingPinchGap + reorderDriftGap(for: snapshot.count))
                        .animation(.spring(response: 0.26, dampingFraction: 0.76), value: dropHoverIndex)
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
                    guard let id = reorderLift?.ids.first else { return }
                    tickReorderLift(blockID: id, at: location, anchorAt: location, snapshot: snapshot)
                } onEnded: { location in
                    endReorderLift(atY: location.y, snapshot: snapshot)
                } onCancelled: {
                    cancelReorderLift()
                }
                .iosPagePinch(
                    isEnabled: editingBlock == nil,
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
                    dropHoverIndex = nil
                    dropOntoBlockID = nil
                    currentDropTarget = nil
                }
            )
            .iosScrollMetrics($scrollMetrics)
            .macNearestRowHover(rowFrames: rowFrames, hoveredBlockID: $hoveredBlockID)
            .background(NotionStyle.background)
            .iosTapBelowRows {
                handleTapBelowRows(at: $0)
            }
            .overlay(alignment: .topLeading) {
                reorderLiftView()
            }
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
                if cursor == nil, case .nav(nil) = interactionMode {
                    interactionMode = .nav(focused: document.blocks.first?.id)
                }
                switch interactionMode {
                case .nav:
                    applyInteractionMode(.nav(focused: cursor ?? document.blocks.first?.id))
                case .editing:
                    applyInteractionMode(interactionMode)
                }
                installUndoApply()
                consumePendingVoiceRecordingStart()
            }
            .onChange(of: editorFocused) { old, new in
                if new == nil && old != nil {
                    onBlur()
                }
            }
            .onChange(of: document.id) { _, _ in
                actionSheet = nil
                if let first = document.blocks.first {
                    setInteractionMode(.nav(focused: first.id))
                } else {
                    setInteractionMode(.nav(focused: nil))
                }
                expandedToggles = []
                expandedTemplateButtons = []
                // Captured undo entries reference the previous document's blocks — drop them.
                undoController.reset()
            }
            .onChange(of: dropHoverIndex) { _, newValue in
                handleDropHoverChange(newValue)
            }
            .onChange(of: selection) { _, _ in
                actionSheet = nil
            }
            .onChange(of: cursor) { _, _ in
                actionSheet = nil
            }
            .onChange(of: anchor) { _, _ in
                actionSheet = nil
            }
            .onChange(of: scenePhase) { _, newValue in
                if newValue == .active {
                    consumePendingVoiceRecordingStart()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .hunchEscapeKeyDown)) { _ in
                handleEscapeKey()
            }
            .onReceive(NotificationCenter.default.publisher(for: VoiceRecordingLaunchRequest.notificationName)) { _ in
                consumePendingVoiceRecordingStart()
            }
            .onKeyPress(keys: [
                .upArrow, .downArrow, .leftArrow, .rightArrow, .return, .escape, .tab,
                KeyEquivalent("\u{19}"),  // NSBackTabCharacter — Shift+Tab on macOS
                .delete,
                KeyEquivalent("\u{8}"),
                KeyEquivalent("\u{7F}"),
                KeyEquivalent("c"),
                KeyEquivalent("k"),
                KeyEquivalent("s"),
                KeyEquivalent("/"),
                KeyEquivalent("[")
            ]) { press in
                guard editingBlock == nil else { return .ignored }
                let modifiers = press.modifiers

                if press.key == KeyEquivalent("["), modifiers.contains(.command) {
                    onNavigateBack()
                    return .handled
                }

                if press.key == KeyEquivalent("c"), modifiers.contains(.command) {
                    return copySelectionToPasteboard() ? .handled : .ignored
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
                    if let id = cursor, selection.count == 1 {
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
                        guard let id = cursor, selection.count == 1 else { return .ignored }
                        return convertBlockToSubpage(blockID: id, preferredTitle: nil)
                    }
                    return .ignored
                }
            }
            .toolbar {
                ToolbarItem(placement: speechToolbarPlacement) {
                    speechRecordButton
                }
            }
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
        if editingBlock != nil {
            exitEditMode()
            return
        }
        clearCursor()
    }

    private func consumePendingVoiceRecordingStart() {
        guard VoiceRecordingLaunchRequest.consumePendingStart() else { return }
        Task { await handleSpeechRecordButton() }
    }

    private var speechErrorBinding: Binding<Bool> {
        Binding(
            get: { speechError != nil },
            set: { newValue in if !newValue { speechError = nil } }
        )
    }

    private var speechToolbarPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }

    private var speechRecordButton: some View {
        Button {
            Task { await handleSpeechRecordButton() }
        } label: {
            switch speechRecorder.state {
            case .idle:
                Image(systemName: "mic")
            case .recording:
                Image(systemName: "stop.circle.fill")
                    .foregroundStyle(.red)
            case .transcribing:
                ProgressView()
                    .controlSize(.small)
            }
        }
        .disabled(speechRecorder.state == .transcribing)
        .help(speechRecordButtonHelp)
        .accessibilityLabel(speechRecordButtonHelp)
    }

    private var speechRecordButtonHelp: String {
        switch speechRecorder.state {
        case .idle:
            return "Record Audio"
        case .recording:
            return "Stop Recording"
        case .transcribing:
            return "Transcribing"
        }
    }

    private func handleSpeechRecordButton() async {
        do {
            switch speechRecorder.state {
            case .idle:
                try await speechRecorder.start()
            case .recording:
                let transcript = try await speechRecorder.stopAndTranscribe()
                appendTranscript(transcript)
            case .transcribing:
                break
            }
        } catch {
            speechRecorder.cancel()
            speechError = error.localizedDescription
        }
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
        let isEditing = editingBlock == block.id

        BlockRow(
            block: binding,
            editorFocused: $editorFocused,
            isPageTitle: isPageTitleBlock(block, snapshot: snapshot),
            numberingIndex: numberingIndex,
            isSelected: isSelected,
            isEditing: isEditing,
            isExpanded: expandedToggles.contains(block.id) || expandedTemplateButtons.contains(block.id),
            isDropTarget: dropOntoBlockID == block.id,
            onKey: { key in handleEditorKey(key, blockID: block.id) },
            onEdited: onEdited,
            onAutotransform: { transform, remainingText in
                applyAutotransform(transform, remainingText: remainingText, blockID: block.id)
            },
            onMentionTriggerChange: { trigger in
                handleMentionTriggerChange(trigger, blockID: block.id)
            },
            mentionActive: mentionMenu?.blockID == block.id,
            onClickAtPoint: { point in
                pendingCursorPoint = (block.id, point)
                enterEditMode(on: block.id)
            },
            onToggleExpansion: {
                if case .templateButton = block {
                    if expandedTemplateButtons.contains(block.id) {
                        expandedTemplateButtons.remove(block.id)
                    } else {
                        expandedTemplateButtons.insert(block.id)
                    }
                } else if expandedToggles.contains(block.id) {
                    expandedToggles.remove(block.id)
                } else {
                    expandedToggles.insert(block.id)
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
                    get: { mentionMenu?.blockID == block.id },
                    set: { if !$0 { mentionMenu = nil } }
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
            .accessibilityValue(reorderLift?.ids.contains(block.id) == true ? "reorder-source" : "")
            .onTapGesture {
                if case .subpage(_, _, let path, _) = block {
                    setInteractionMode(.nav(focused: block.id))
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
                            hoveredHandleBlockID = block.id
                        } else if hoveredHandleBlockID == block.id {
                            hoveredHandleBlockID = nil
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

    private func orderedDropFrames(snapshot: [Block]) -> [ReorderDropFrame] {
        snapshot.compactMap { block in
            rowFrames[block.id].map { ReorderDropFrame(id: block.id, frame: $0) }
        }
    }

    private func reorderDriftGap(for index: Int) -> CGFloat {
        guard dropHoverIndex == index else { return 0 }
        // Dropping the source row at its own slot is a no-op — don't open a
        // gap there. (Also avoids layout churn that would destabilise the
        // lift's frozen sourceFrame.)
        if let lift = reorderLift,
           index >= lift.sourceIndex && index <= lift.sourceEndIndex + 1 {
            return 0
        }
        return 42
    }

    private func reorderSourceOpacity(for id: BlockID) -> Double {
        return reorderLift?.ids.contains(id) == true ? 0.12 : 1
    }

    private func isMacDraggingFromRow(_ id: BlockID) -> Bool {
        #if os(macOS)
        return reorderLift?.ids.contains(id) == true
        #else
        return false
        #endif
    }

    @ViewBuilder
    private func reorderLiftView() -> some View {
        if let lift = reorderLift {
            BlockRow(
                block: .constant(lift.block),
                editorFocused: $editorFocused,
                isPageTitle: false,
                numberingIndex: nil,
                isSelected: false,
                isEditing: false,
                pageTitle: pageTitle
            )
            .frame(width: lift.sourceFrame.width, height: lift.sourceFrame.height, alignment: .leading)
            .scaleEffect(1.035)
            .position(
                x: lift.location.x - lift.touchOffset.width + (lift.sourceFrame.width / 2),
                y: lift.location.y - lift.touchOffset.height + (lift.sourceFrame.height / 2)
            )
            .allowsHitTesting(false)
            .zIndex(100)
        }
    }

    /// Pre-mounts the lift in a `pendingAnchor` state at the source row's
    /// center. iOS calls this on long-press completion (where the gesture
    /// value carries no cursor location) so the user gets immediate visual
    /// feedback — source row dims and lift overlay appears — instead of
    /// waiting for the first drag event. The next `tickReorderLift(at:)` call
    /// re-anchors `touchOffset` to the actual cursor location.
    private func preliftReorder(blockID: BlockID, snapshot: [Block]) {
        guard let block = snapshot.first(where: { $0.id == blockID }),
              let sourceFrame = rowFrames[blockID],
              let sourceIndex = snapshot.firstIndex(where: { $0.id == blockID })
        else { return }
        let ids = dragIDs(for: blockID)
        let idSet = Set(ids)
        let sourceIndices = snapshot.enumerated()
            .compactMap { idSet.contains($0.element.id) ? $0.offset : nil }
        reorderLift = ReorderLift(
            block: block,
            ids: ids,
            sourceFrame: sourceFrame,
            sourceIndex: sourceIndex,
            sourceEndIndex: sourceIndices.last ?? sourceIndex,
            touchOffset: CGSize(width: sourceFrame.width / 2, height: sourceFrame.height / 2),
            location: CGPoint(x: sourceFrame.midX, y: sourceFrame.midY),
            pendingAnchor: true
        )
    }

    /// Per-event update: creates the lift if missing (macOS click-and-drag
    /// path), re-anchors `touchOffset` if a previous `preliftReorder` left it
    /// pending, then updates `location` and recomputes `dropHoverIndex`.
    ///
    /// `at location` is the current cursor position — drives lift placement
    /// and drop-slot resolution. `anchorAt` is the point that should sit
    /// under the cursor inside the lift; iOS passes the same value as
    /// `location` (the finger may drift up to 36pt during long-press, and we
    /// want the lift to lock to where the finger IS now), macOS passes
    /// `value.startLocation` (the click point — typically in the gutter,
    /// 4pt away from where the gesture-cleared `value.location` is).
    ///
    /// `sourceFrame`, `sourceIndex`, and `touchOffset` are frozen once the
    /// lift exists with a real anchor — `rowFrames[id]` keeps shifting as the
    /// drift gap animates open and recomputing against a moving frame would
    /// drift the lift away from the cursor.
    private func tickReorderLift(blockID: BlockID, at location: CGPoint, anchorAt anchor: CGPoint, snapshot: [Block]) {
        if reorderLift == nil {
            guard let block = snapshot.first(where: { $0.id == blockID }),
                  let sourceFrame = rowFrames[blockID],
                  let sourceIndex = snapshot.firstIndex(where: { $0.id == blockID })
            else { return }
            let ids = dragIDs(for: blockID)
            let idSet = Set(ids)
            let sourceIndices = snapshot.enumerated()
                .compactMap { idSet.contains($0.element.id) ? $0.offset : nil }
            reorderLift = ReorderLift(
                block: block,
                ids: ids,
                sourceFrame: sourceFrame,
                sourceIndex: sourceIndex,
                sourceEndIndex: sourceIndices.last ?? sourceIndex,
                touchOffset: CGSize(
                    width: anchor.x - sourceFrame.minX,
                    height: anchor.y - sourceFrame.minY
                ),
                location: location,
                pendingAnchor: false
            )
        } else if var lift = reorderLift {
            if lift.pendingAnchor {
                lift.touchOffset = CGSize(
                    width: anchor.x - lift.sourceFrame.minX,
                    height: anchor.y - lift.sourceFrame.minY
                )
                lift.pendingAnchor = false
            }
            lift.location = location
            reorderLift = lift
        }
        applyDropTarget(at: location.y, snapshot: snapshot)
    }

    /// Resolves the drop slot from `y`, then clears the lift and applies the
    /// move inside one no-animation transaction so neither the gap close, the
    /// lift unmount, nor the row reflow springs.
    private func endReorderLift(atY y: CGFloat, snapshot: [Block]) {
        guard let lift = reorderLift else { return }
        SoundFX.play(.drop)
        let hidden = hiddenBlockIDs(in: snapshot)
        let target = currentDropTarget ?? resolveDropTarget(atY: y, snapshot: snapshot, hidden: hidden)
        let ids = lift.ids
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            dropHoverIndex = nil
            dropOntoBlockID = nil
            currentDropTarget = nil
            reorderLift = nil
            switch target {
            case .insertBefore(let index):
                moveBlocks(ids: ids, toIndexBefore: index)
            case .asLastChildOf(let parentID):
                moveBlocks(ids: ids, asChildrenOf: parentID, snapshot: snapshot, hidden: hidden)
            case .intoSubpage(_, let path):
                moveBlocks(ids: ids, intoSubpagePath: path)
            }
        }
    }

    private func cancelReorderLift() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            dropHoverIndex = nil
            dropOntoBlockID = nil
            currentDropTarget = nil
            reorderLift = nil
        }
    }

    /// Resolved drop target: either a between-rows insertion (snapshot index in
    /// `document.blocks`) or an "append as child" of a closed parent.
    private enum DropTarget {
        case insertBefore(Int)
        case asLastChildOf(BlockID)
        case intoSubpage(BlockID, String)
    }

    /// Update `dropHoverIndex` / `dropOntoBlockID` based on the live drop point.
    /// Source rows (the lift itself) are excluded from the drop-on hit-test so
    /// you can't drop onto your own collapsed parent.
    private func applyDropTarget(at y: CGFloat, snapshot: [Block]) {
        let hidden = hiddenBlockIDs(in: snapshot)
        let target = resolveDropTarget(atY: y, snapshot: snapshot, hidden: hidden)
        currentDropTarget = target
        switch target {
        case .insertBefore(let index):
            dropOntoBlockID = nil
            dropHoverIndex = index
        case .asLastChildOf(let id):
            dropHoverIndex = nil
            dropOntoBlockID = id
        case .intoSubpage(let id, _):
            dropHoverIndex = nil
            dropOntoBlockID = id
        }
    }

    private func resolveDropTarget(atY y: CGFloat, snapshot: [Block], hidden: Set<BlockID>) -> DropTarget {
        let liftIDs = reorderLift?.ids ?? []
        // Hit-test for "drop on closed parent". Use a small edge band so the
        // gap above/below the row still feels reachable.
        let edgeBand: CGFloat = 6
        for block in snapshot where !hidden.contains(block.id) && !liftIDs.contains(block.id) {
            guard let frame = rowFrames[block.id] else { continue }
            if case .subpage(_, _, let path, _) = block,
               y >= frame.minY && y <= frame.maxY {
                return .intoSubpage(block.id, path)
            }
            guard y > frame.minY + edgeBand && y < frame.maxY - edgeBand else { continue }
            if isCollapsedSection(block) {
                return .asLastChildOf(block.id)
            }
        }
        let visibleCount = ReorderDropResolver.insertionIndex(
            forY: y,
            rowFrames: orderedDropFrames(snapshot: snapshot),
            previousIndex: dropHoverIndex
        )
        return .insertBefore(snapshotIndex(forVisibleCount: visibleCount, snapshot: snapshot, hidden: hidden))
    }

    private func performPayloadDrop(_ payload: BlockDragPayload, atY y: CGFloat, snapshot: [Block]) {
        let hidden = hiddenBlockIDs(in: snapshot)
        let target = currentDropTarget ?? resolveDropTarget(atY: y, snapshot: snapshot, hidden: hidden)
        switch target {
        case .insertBefore(let index):
            moveBlocks(ids: payload.ids, toIndexBefore: index)
        case .asLastChildOf(let parentID):
            moveBlocks(ids: payload.ids, asChildrenOf: parentID, snapshot: snapshot, hidden: hidden)
        case .intoSubpage(_, let path):
            moveBlocks(ids: payload.ids, intoSubpagePath: path)
        }
    }

    /// Convert "kth visible row above the drop" into a snapshot index that lies
    /// outside any collapsed subtree. Without this, dropping in the gap below a
    /// closed toggle/templateButton lands as a hidden child.
    private func snapshotIndex(forVisibleCount k: Int, snapshot: [Block], hidden: Set<BlockID>) -> Int {
        if k <= 0 { return 0 }
        var seen = 0
        for i in snapshot.indices where !hidden.contains(snapshot[i].id) {
            seen += 1
            if seen == k {
                var j = i + 1
                while j < snapshot.count && hidden.contains(snapshot[j].id) { j += 1 }
                return j
            }
        }
        return snapshot.count
    }

    private func handleDropHoverChange(_ index: Int?) {
        #if os(iOS)
        guard let index else {
            lastDropHapticIndex = nil
            return
        }
        guard lastDropHapticIndex != index else { return }
        lastDropHapticIndex = index
        Haptics.light()
        #else
        _ = index
        #endif
    }

    /// Drop target rendered inside a row's existing top-gap area (or the trailing
    /// page-bottom area). Adds no layout space — the hit area is provided by an
    /// in-flow `Color.clear` whose vertical extent exactly matches the existing gap.
    @ViewBuilder
    private func gapDropTarget(at index: Int, height: CGFloat) -> some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .contentShape(Rectangle())
            .accessibilityIdentifier("block-drop-slot-\(index)")
            .accessibilityLabel("Drop before block \(index + 1)")
    }

    /// Compute the BlockIDs to include in a drag started from `blockID`. If the row
    /// is part of a multi-block selection, drag the whole selection (in document
    /// order); otherwise just the single row.
    private func dragIDs(for blockID: BlockID) -> [BlockID] {
        if selection.contains(blockID) && selection.count > 1 {
            return effectiveSelectedIDsInDocumentOrder()
        }
        return document.indicesIncludingSections(of: [blockID]).map { document.blocks[$0].id }
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

    /// Drop-on-parent: append `ids` after the parent's hidden subtree (snapshot
    /// position = parent index + 1 + count of contiguous hidden blocks following)
    /// AND shift each dragged block's indent so the topmost dragged block lands
    /// at `parent.indent + 1`. Internal nesting within the dragged range is
    /// preserved by applying the same indent delta to every dragged block.
    private func moveBlocks(ids: [BlockID], asChildrenOf parentID: BlockID, snapshot: [Block], hidden: Set<BlockID>) {
        guard let parentIndex = snapshot.firstIndex(where: { $0.id == parentID }),
              !ids.contains(parentID)
        else { return }

        let parent = snapshot[parentIndex]
        var insertAt = parentIndex + 1
        while insertAt < snapshot.count && hidden.contains(snapshot[insertAt].id) {
            insertAt += 1
        }

        let idSet = Set(ids)
        let sourceIndices = document.blocks.enumerated()
            .compactMap { (i, block) in idSet.contains(block.id) ? i : nil }
        guard !sourceIndices.isEmpty else { return }

        // The drag-source must not include the parent (already guarded), and the
        // insertion point must not be inside the dragged range.
        if let first = sourceIndices.first, let last = sourceIndices.last,
           insertAt >= first && insertAt <= last + 1 {
            return
        }

        let movingBlocks = sourceIndices.map { document.blocks[$0] }
        let oldRootIndent = movingBlocks.map(\.indent).min() ?? 0
        let newRootIndent = parent.indent + 1
        let indentDelta = newRootIndent - oldRootIndent

        let removalsBeforeTarget = sourceIndices.filter { $0 < insertAt }.count
        let adjustedTarget = insertAt - removalsBeforeTarget

        mutate("Move Block") {
            var blocks = document.blocks
            for i in sourceIndices.reversed() {
                blocks.remove(at: i)
            }
            let shifted = movingBlocks.map { $0.withIndent(max(0, $0.indent + indentDelta)) }
            blocks.insert(contentsOf: shifted, at: adjustedTarget)
            document.blocks = blocks
        }

        // Auto-expand the parent so the user can see the result.
        switch parent {
        case .toggle(let id, _, _): expandedToggles.insert(id)
        case .templateButton(let id, _, _): expandedTemplateButtons.insert(id)
        default: break
        }
    }

    /// Drop-on-subpage: append `ids` to the end of the child page's `.md` file
    /// (cross-document write via `onAppendToSubpage`) and remove them from this
    /// document. Indents are normalized so the topmost dragged block lands at 0
    /// in the destination; relative nesting within the dragged set is preserved.
    /// If the destination write fails, the source document is left untouched.
    private func moveBlocks(ids: [BlockID], intoSubpagePath path: String) {
        let idSet = Set(ids)
        let sourceIndices = document.blocks.enumerated()
            .compactMap { (i, block) in idSet.contains(block.id) ? i : nil }
        guard !sourceIndices.isEmpty else { return }

        let movingBlocks = sourceIndices.map { document.blocks[$0] }
        let oldRootIndent = movingBlocks.map(\.indent).min() ?? 0
        let indentDelta = -oldRootIndent
        let shifted = movingBlocks.map { $0.withIndent(max(0, $0.indent + indentDelta)) }

        guard onAppendToSubpage(path, shifted) else { return }

        mutate("Move to Subpage") {
            var blocks = document.blocks
            for i in sourceIndices.reversed() {
                blocks.remove(at: i)
            }
            document.blocks = blocks
        }
    }

    private func insertParagraph(at index: Int, focus: Bool = true) {
        let newBlock = Block.paragraph(text: AttributedString())
        let insertionIndex = max(0, min(index, document.blocks.count))
        mutate("Insert Block") {
            document.blocks.insert(newBlock, at: insertionIndex)
        }
        if focus {
            setInteractionMode(.editing(newBlock.id))
        }
    }

    private func appendTranscript(_ transcript: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let newBlock = Block.paragraph(text: AttributedString(trimmed))
        mutate("Insert Transcript") {
            document.blocks.append(newBlock)
        }
        setInteractionMode(.nav(focused: newBlock.id))
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
            setInteractionMode(.nav(focused: first.id))
        }
    }

    // MARK: - Pinch-open-to-insert (iOS)

    private let pinchInsertCommitGap: CGFloat = 40
    private let pinchInsertFocusGap: CGFloat = 110

    /// Soft asymptote past `soft` — gap continues to track fingers but tightens
    /// toward `max`. Replaces a hard clamp, which feels dead at the limit.
    private func pinchRubberBand(_ x: CGFloat, soft: CGFloat = 140, max: CGFloat = 240) -> CGFloat {
        guard x > soft else { return x }
        let over = x - soft
        let range = max - soft
        return soft + range * (1 - 1 / (1 + over / range))
    }

    /// Track the live finger spread: above the starting distance, open an inline
    /// gap at the row pair under the current midpoint; below the starting
    /// distance, no insert preview (pinch-close commits on release).
    private func handlePinchUpdate(_ value: PagePinchValue) {
        pinchGestureActive = true
        guard editingBlock == nil else {
            if pinchPreview != nil { pinchPreview = nil }
            stopPinchAutoScroll()
            return
        }
        updatePinchAutoScroll(for: value.location)
        if value.spreadDelta > 0 {
            let gapHeight = pinchRubberBand(value.spreadDelta)
            let insertIndex = pinchInsertIndex(for: value.startLocation)
            pinchPreview = PinchPreviewState(insertIndex: insertIndex, gapHeight: gapHeight)
            if gapHeight >= pinchInsertCommitGap, !pinchCrossedInsertThreshold {
                pinchCrossedInsertThreshold = true
                Haptics.medium()
                SoundFX.play(.pinchOpen)
            } else if gapHeight < pinchInsertCommitGap {
                pinchCrossedInsertThreshold = false
            }
            if gapHeight >= pinchInsertFocusGap, !pinchCrossedFocusThreshold {
                pinchCrossedFocusThreshold = true
                Haptics.medium()
                SoundFX.play(.pinchOpen)
            } else if gapHeight < pinchInsertFocusGap {
                pinchCrossedFocusThreshold = false
            }
        } else if pinchPreview != nil {
            pinchPreview = nil
            pinchCrossedInsertThreshold = false
            pinchCrossedFocusThreshold = false
        }
    }

    private func handlePinchCommit(_ value: PagePinchValue) {
        let preview = pinchPreview
        let gap = preview?.gapHeight ?? pinchRubberBand(max(0, value.spreadDelta))

        if gap >= pinchInsertCommitGap, editingBlock == nil {
            let insertIndex = preview?.insertIndex ?? pinchInsertIndex(for: value.startLocation)
            let shouldFocus = gap >= pinchInsertFocusGap
            // Bundle the structural insert and the gap collapse into the same
            // spring transaction so the new row appears inside the opened gap
            // and the surrounding rows close in around it. Without the shared
            // animation transaction the gap snap-closes first and the new row
            // pops in afterwards — visually disjoint.
            Haptics.heavy()
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                insertParagraph(at: insertIndex, focus: shouldFocus)
                pinchPreview = nil
            }
        } else {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) {
                pinchPreview = nil
            }
        }
        pinchCrossedInsertThreshold = false
        pinchCrossedFocusThreshold = false
        pinchGestureActive = false
        stopPinchAutoScroll()
    }

    private func updatePinchAutoScroll(for location: CGPoint) {
        let threshold: CGFloat = 88
        let maxVelocity: CGFloat = 520
        let viewportHeight = scrollMetrics.viewportHeight
        guard viewportHeight > threshold * 2 else {
            stopPinchAutoScroll()
            return
        }

        let topDistance = location.y
        let bottomDistance = viewportHeight - location.y
        let velocity: CGFloat
        if topDistance < threshold {
            let progress = min(1, max(0, (threshold - topDistance) / threshold))
            velocity = -maxVelocity * progress * progress
        } else if bottomDistance < threshold {
            let progress = min(1, max(0, (threshold - bottomDistance) / threshold))
            velocity = maxVelocity * progress * progress
        } else {
            velocity = 0
        }

        pinchAutoScrollVelocity = velocity
        if abs(velocity) > 1 {
            startPinchAutoScrollIfNeeded()
        } else {
            stopPinchAutoScroll()
        }
    }

    private func startPinchAutoScrollIfNeeded() {
        guard pinchAutoScrollTask == nil else { return }
        pinchAutoScrollTask = Task { @MainActor in
            let frameDuration: TimeInterval = 1.0 / 60.0
            while !Task.isCancelled {
                let velocity = pinchAutoScrollVelocity
                if abs(velocity) <= 1 { break }
                scrollBy(velocity * frameDuration)
                try? await Task.sleep(for: .milliseconds(16))
            }
            pinchAutoScrollTask = nil
        }
    }

    private func stopPinchAutoScroll() {
        pinchAutoScrollVelocity = 0
        pinchAutoScrollTask?.cancel()
        pinchAutoScrollTask = nil
    }

    private func scrollBy(_ deltaY: CGFloat) {
        let maxOffset = max(0, scrollMetrics.contentHeight - scrollMetrics.viewportHeight)
        let nextOffset = min(maxOffset, max(0, scrollMetrics.contentOffsetY + deltaY))
        guard abs(nextOffset - scrollMetrics.contentOffsetY) > 0.5 else { return }
        #if os(iOS)
        PageScrollController.shared.scroll(toY: nextOffset)
        #endif
    }

    /// The insert index for a pinch whose start midpoint is at `point` (in the
    /// page's hover-named coordinate space — same space rowFrames live in).
    /// Returns the index of the first row whose mid-Y is below the point; if
    /// every row sits above the point, returns `blocks.count` (insert at end).
    private func pinchInsertIndex(for point: CGPoint) -> Int {
        let blocks = document.blocks
        guard !blocks.isEmpty else { return 0 }
        for (i, block) in blocks.enumerated() {
            if let frame = rowFrames[block.id], point.y < frame.midY {
                return i
            }
        }
        return blocks.count
    }

    private func handleTapBelowRows(at point: CGPoint) {
        guard editingBlock == nil else { return }
        guard let lastBlock = document.blocks.last, let frame = rowFrames[lastBlock.id] else {
            insertParagraph(at: document.blocks.count)
            return
        }
        guard point.y > frame.maxY + 12 else { return }
        insertParagraph(at: document.blocks.count)
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
        guard case .heading(_, 1, _, _) = block else { return false }
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
                setInteractionMode(.nav(focused: cursor))
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
        if case .nav = interactionMode {
            interactionMode = .nav(focused: id)
        }
    }

    private func clearCursor() {
        selection = []
        anchor = nil
        cursor = nil
        if case .nav = interactionMode {
            interactionMode = .nav(focused: nil)
        }
    }

    private func setInteractionMode(_ mode: PageInteractionMode) {
        interactionMode = mode
        applyInteractionMode(mode)
    }

    private func applyInteractionMode(_ mode: PageInteractionMode) {
        switch mode {
        case .nav(let focused):
            editingBlock = nil
            editorFocused = nil
            if let focused, document.blocks.contains(where: { $0.id == focused }) {
                setCursor(focused)
            } else if let cursor, document.blocks.contains(where: { $0.id == cursor }) {
                setCursor(cursor)
            } else if let first = document.blocks.first {
                setCursor(first.id)
            } else {
                clearCursor()
            }
            requestPageNavigationFocus()
        case .editing(let id):
            guard document.blocks.contains(where: { $0.id == id }) else {
                setInteractionMode(.nav(focused: document.blocks.first?.id))
                return
            }
            setCursor(id)
            editingBlock = id
            editorFocused = id
            pageFocused = false
        }
    }

    private func requestPageNavigationFocus() {
        pageFocused = false
        DispatchQueue.main.async {
            pageFocused = true
        }
    }

    /// Nav-mode →: check todos in the selection, otherwise enter a selected subpage
    /// or open the collapsible section under the cursor.
    @discardableResult
    private func handleNavRightArrow() -> Bool {
        if setTodoDoneOnSelection(true) { return true }
        guard let id = cursor, selection.count == 1 else { return false }
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
        guard let id = cursor, selection.count == 1 else { return false }
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
    private func hiddenBlockIDs(in blocks: [Block]) -> Set<BlockID> {
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

    private func isCollapsedSection(_ block: Block) -> Bool {
        switch block {
        case .toggle(let id, _, _):
            return !expandedToggles.contains(id)
        case .templateButton(let id, _, _):
            return !expandedTemplateButtons.contains(id)
        default:
            return false
        }
    }

    private func isSectionExpanded(_ block: Block) -> Bool {
        switch block {
        case .toggle(let id, _, _):
            return expandedToggles.contains(id)
        case .templateButton(let id, _, _):
            return expandedTemplateButtons.contains(id)
        default:
            return false
        }
    }

    private func expandSection(_ block: Block) {
        switch block {
        case .toggle(let id, _, _):
            expandedToggles.insert(id)
        case .templateButton(let id, _, _):
            expandedTemplateButtons.insert(id)
        default:
            break
        }
    }

    private func collapseSection(_ block: Block) {
        switch block {
        case .toggle(let id, _, _):
            expandedToggles.remove(id)
        case .templateButton(let id, _, _):
            expandedTemplateButtons.remove(id)
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
        let currentIndex = cursor.flatMap { id in visible.firstIndex(where: { $0.id == id }) } ?? 0
        let nextIndex = max(0, min(visible.count - 1, currentIndex + delta))
        setCursor(visible[nextIndex].id)
    }

    /// Extend the selection in the direction of `delta`. The anchor stays put; the cursor
    /// moves by outline sections so extending over a parent consumes its descendants as
    /// real selection, not only via the effective-selection expansion used by operations.
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
              let anchorIndex = blocks.firstIndex(where: { $0.id == anchorID }),
              let cursorIndex = blocks.firstIndex(where: { $0.id == cursorID }) else { return }

        let nextIndex = outlineSelectionStep(from: cursorIndex, anchoredAt: anchorIndex, by: delta)
        cursor = blocks[nextIndex].id

        let lo = min(anchorIndex, nextIndex)
        let hi = max(anchorIndex, nextIndex)
        selection = Set(blocks[lo...hi].map { $0.id })
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
            .compactMap { (i, block) in selection.contains(block.id) ? i : nil }
    }

    private func effectiveSelectedIndices() -> [Int] {
        document.indicesIncludingSections(of: selection)
    }

    private func effectiveSelectedIDs() -> Set<BlockID> {
        Set(effectiveSelectedIDsInDocumentOrder())
    }

    private func effectiveSelectedIDsInDocumentOrder() -> [BlockID] {
        effectiveSelectedIndices().map { document.blocks[$0].id }
    }

    // MARK: - Edit-mode transitions

    private func enterEditMode(on id: BlockID) {
        // Switching active editor — drop any stale mention popover that may have been
        // left attached to a different row.
        if mentionMenu?.blockID != id {
            mentionMenu = nil
        }

        guard let block = document.blocks.first(where: { $0.id == id }) else { return }
        switch block {
        case .code, .divider, .subpage:
            setInteractionMode(.nav(focused: id))
            return
        default:
            break
        }
        setInteractionMode(.editing(id))
    }

    private func exitEditMode() {
        let was = editingBlock
        // Drop the @-menu state with the editor — the popover is anchored to the
        // editing row, and a stale mentionMenu after exit would attach to a
        // read-only Text that can no longer drive the input.
        mentionMenu = nil
        setInteractionMode(.nav(focused: was))
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
        copyBlocksToPasteboard(ids: selection)
    }

    private func copyBlocksToPasteboard(ids: some Sequence<BlockID>) -> Bool {
        let indices = document.indicesIncludingSections(of: ids)
        guard !indices.isEmpty else { return false }

        let selectedBlocks = indices.map { document.blocks[$0] }
        let minIndent = selectedBlocks.map(\.indent).min() ?? 0
        let normalizedBlocks = selectedBlocks.map { block in
            block.withIndent(block.indent - minIndent)
        }
        let markdown = BlockSerializer.serialize(normalizedBlocks)

        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
        #else
        UIPasteboard.general.string = markdown
        #endif
        return true
    }

    private func canChangeIndent(at indices: [Int], by delta: Int) -> Bool {
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
            mentionMenu = nil
            return .handled
        }
    }

    // MARK: - Mention popover

    /// `entries` filtered + ranked against the active query. Page titles are matched
    /// case-insensitively as substrings; an empty query lists everything (recent first).
    fileprivate var mentionMatches: [WorkspaceEntry] {
        guard let menu = mentionMenu else { return [] }
        let q = menu.trigger.query.lowercased()
        let pool = entries.sorted { $0.modificationDate > $1.modificationDate }
        if q.isEmpty {
            return Array(pool.prefix(8))
        }
        let ranked = pool.compactMap { entry -> (WorkspaceEntry, Int)? in
            let title = entry.title.lowercased()
            if title.hasPrefix(q) { return (entry, 0) }
            if title.contains(q) { return (entry, 1) }
            // Allow matching against the relative path too — useful for nested pages
            // whose titles collide.
            if entry.relativePath.lowercased().contains(q) { return (entry, 2) }
            return nil
        }
        return ranked.sorted { $0.1 < $1.1 }.map(\.0).prefix(8).map { $0 }
    }

    private func handleMentionTriggerChange(_ trigger: MentionTrigger?, blockID: BlockID) {
        guard let trigger else {
            // The editor lost the @-region (cursor moved past whitespace, range cleared,
            // etc.). Drop the menu — even if its blockID still matches, we shouldn't
            // hold stale state.
            if mentionMenu?.blockID == blockID {
                mentionMenu = nil
            }
            return
        }
        if var existing = mentionMenu, existing.blockID == blockID {
            // Query / range changed — keep the menu open, refresh state. Reset the
            // selection if the new filter would put it out of bounds.
            existing.trigger = trigger
            mentionMenu = existing
            let count = mentionMatches.count
            if count == 0 {
                existing.selectedIndex = 0
            } else if existing.selectedIndex >= count {
                existing.selectedIndex = count - 1
            }
            mentionMenu = existing
        } else {
            mentionMenu = MentionMenuState(blockID: blockID, trigger: trigger, selectedIndex: 0)
        }
    }

    private func moveMentionSelection(by delta: Int) -> KeyPress.Result {
        guard var menu = mentionMenu else { return .ignored }
        let matches = mentionMatches
        guard !matches.isEmpty else { return .handled }
        let count = matches.count
        // Wrap around — feels right for a short list and makes ↑ on the first row a
        // shortcut to the last entry.
        menu.selectedIndex = ((menu.selectedIndex + delta) % count + count) % count
        mentionMenu = menu
        return .handled
    }

    private func commitMentionSelection() -> KeyPress.Result {
        guard let menu = mentionMenu else { return .ignored }
        let matches = mentionMatches
        guard !matches.isEmpty else {
            // No matches — Return on an empty filter just dismisses the menu without
            // splitting the block.
            mentionMenu = nil
            return .handled
        }
        let safeIndex = max(0, min(menu.selectedIndex, matches.count - 1))
        commitMention(matches[safeIndex], state: menu)
        return .handled
    }

    /// Replace the active block with a `.subpage` row pointing at `entry`, then drop
    /// out of edit mode. The user typed `@` to *make a page link*, not to insert
    /// `[title]` mid-sentence — so we mirror Cmd-K's `convertBlockToSubpage` shape
    /// (whole block becomes the link). Any text before/after the `@query` span is
    /// preserved as adjacent paragraphs.
    private func commitMention(_ entry: WorkspaceEntry, state: MentionMenuState) {
        defer { mentionMenu = nil }
        guard let blockIndex = document.index(of: state.blockID) else { return }
        let block = document.blocks[blockIndex]
        let plain = String(block.text.characters) as NSString

        let triggerStart = state.trigger.nsRange.location
        let triggerEnd = triggerStart + state.trigger.nsRange.length
        guard triggerEnd <= plain.length else { return }
        let beforeText = plain.substring(with: NSRange(location: 0, length: triggerStart))
        let afterText = plain.substring(with: NSRange(location: triggerEnd, length: plain.length - triggerEnd))

        // Reuse the original block's id when the @ consumed the whole row — keeps any
        // upstream references (selection, hover, undo) targeted at the same block.
        // When there's surrounding text, the leading paragraph keeps the id and the
        // subpage row gets a fresh one.
        let beforeIsEmpty = beforeText.isEmpty
        let subpageID = beforeIsEmpty ? block.id : BlockID()

        var replacements: [Block] = []
        if !beforeIsEmpty {
            replacements.append(block.withText(AttributedString(beforeText)))
        }
        replacements.append(.subpage(
            id: subpageID,
            title: entry.title,
            path: entry.relativePath,
            indent: block.indent
        ))
        if !afterText.isEmpty {
            replacements.append(.paragraph(text: AttributedString(afterText), indent: block.indent))
        }

        mutate("Insert Page Link") {
            document.blocks.replaceSubrange(blockIndex..<blockIndex + 1, with: replacements)
        }

        DispatchQueue.main.async {
            setInteractionMode(.nav(focused: subpageID))
        }
    }

    @ViewBuilder
    private func mentionMenuContent() -> some View {
        let matches = mentionMatches
        VStack(alignment: .leading, spacing: 0) {
            // Hidden hotkey buttons — make the menu's keyboard shortcuts work even if
            // the popover happens to take focus; the editor's keyDown intercept is the
            // primary path, but this provides a fallback when the popover content is
            // first responder (iOS / certain macOS edge cases).
            Group {
                Button("") { _ = commitMentionSelection() }
                    .keyboardShortcut(.return, modifiers: [])
                Button("") { mentionMenu = nil }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)

            if matches.isEmpty {
                Text("No matching pages")
                    .font(NotionStyle.body(size: 12))
                    .foregroundStyle(NotionStyle.mutedForeground)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                ForEach(Array(matches.enumerated()), id: \.element.id) { index, entry in
                    mentionRow(entry: entry, isSelected: mentionMenu?.selectedIndex == index)
                        .onTapGesture {
                            guard let menu = mentionMenu else { return }
                            commitMention(entry, state: menu)
                        }
                        .onHover { hovering in
                            #if os(macOS)
                            if hovering, var menu = mentionMenu {
                                menu.selectedIndex = index
                                mentionMenu = menu
                            }
                            #endif
                        }
                }
            }
        }
        .padding(.vertical, 4)
        .frame(width: 240, alignment: .leading)
    }

    @ViewBuilder
    private func mentionRow(entry: WorkspaceEntry, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc")
                .font(.system(size: 13))
                .foregroundStyle(NotionStyle.mutedForeground)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(NotionStyle.body(size: 13))
                    .foregroundStyle(NotionStyle.foreground)
                    .lineLimit(1)
                if entry.relativePath != entry.title + ".md" {
                    Text(entry.relativePath)
                        .font(NotionStyle.body(size: 10))
                        .foregroundStyle(NotionStyle.mutedForeground)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? NotionStyle.linkForeground.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
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
                    setInteractionMode(.editing(newBlock.id))
                }
                return .handled
            } else {
                let firstChild = document.blocks[firstChildIdx]
                let newBlock = followUpBlock(after: firstChild, withText: "")
                mutate("Split Block") {
                    document.blocks.insert(newBlock, at: firstChildIdx)
                }
                DispatchQueue.main.async {
                    setInteractionMode(.editing(newBlock.id))
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
            setInteractionMode(.editing(newBlock.id))
        }
        return .handled
    }

    private func navigateIntoSubpage(_ blockID: BlockID) -> Bool {
        guard let block = document.blocks.first(where: { $0.id == blockID }),
              case .subpage(_, _, let path, _) = block else {
            return false
        }
        setInteractionMode(.nav(focused: blockID))
        onSubpageTap(path)
        return true
    }

    private func convertBlockToSubpage(blockID: BlockID, preferredTitle: String?) -> KeyPress.Result {
        guard let i = document.index(of: blockID) else { return .ignored }
        let block = document.blocks[i]
        guard !isStructuralBlock(block) else { return .ignored }

        let existingLink = wholeBlockMarkdownLink(in: block.text)
        let title = cleanedTitle(preferredTitle)
            ?? existingLink?.title
            ?? cleanedTitle(String(block.text.characters))
            ?? "Untitled"
        let requestedPath = existingLink?.path

        // The block's indent-descendants (canonical via Document.sectionRange) become the
        // body of the new subpage. When present, the new file gets a `# title` header plus
        // the serialized descendants; otherwise we leave it nil so the app layer writes
        // today's stub.
        let range = document.sectionRange(of: blockID) ?? (i..<i+1)
        let baseIndent = block.indent
        let descendants = document.blocks[(i + 1)..<range.upperBound].map {
            $0.withIndent($0.indent - (baseIndent + 1))
        }
        let initialContent: String? = descendants.isEmpty
            ? nil
            : "# \(title)\n\n" + BlockSerializer.serialize(descendants)

        let path = onCreateSubpage(title, requestedPath, initialContent)
            ?? requestedPath
            ?? defaultSubpagePath(for: title)

        mutate("Create Subpage") {
            document.blocks.replaceSubrange(range, with: [
                .subpage(id: blockID, title: title, path: path, indent: baseIndent)
            ])
        }
        DispatchQueue.main.async {
            setInteractionMode(.nav(focused: blockID))
        }
        return .handled
    }

    @discardableResult
    private func expandSubpage(blockID: BlockID) -> KeyPress.Result {
        guard let i = document.index(of: blockID) else { return .ignored }
        guard case .subpage(_, _, let path, let indent) = document.blocks[i] else { return .ignored }
        guard let loaded = onLoadSubpage(path), !loaded.isEmpty else { return .ignored }

        // Shift all loaded blocks by the subpage row's indent so the inlined
        // content sits at the same depth as the link it's replacing.
        let shifted = loaded.map { $0.withIndent($0.indent + indent) }
        mutate("Expand Subpage") {
            document.blocks.replaceSubrange(i..<(i + 1), with: shifted)
        }
        DispatchQueue.main.async {
            if let first = shifted.first {
                setCursor(first.id)
            }
        }
        return .handled
    }

    @discardableResult
    private func convert(blockID: BlockID, to target: BlockTurnInto) -> KeyPress.Result {
        convert(blockIDs: menuTargetIDs(anchorID: blockID), to: target)
    }

    @discardableResult
    private func convert(blockIDs: [BlockID], to target: BlockTurnInto) -> KeyPress.Result {
        let ids = blockIDs.filter { document.index(of: $0) != nil }
        guard !ids.isEmpty else { return .ignored }
        if ids.count == 1, let id = ids.first {
            return convertSingle(blockID: id, to: target)
        }

        var handled = false
        for id in ids.reversed() {
            if convertSingle(blockID: id, to: target) == .handled {
                handled = true
            }
        }
        if let first = ids.first {
            DispatchQueue.main.async {
                setCursor(first)
            }
        }
        return handled ? .handled : .ignored
    }

    @discardableResult
    private func convertSingle(blockID: BlockID, to target: BlockTurnInto) -> KeyPress.Result {
        if target == .page {
            return convertBlockToSubpage(blockID: blockID, preferredTitle: nil)
        }
        if target == .template {
            return convertBlockToTemplate(blockID: blockID)
        }
        guard let i = document.index(of: blockID) else { return .ignored }
        let block = document.blocks[i]
        if target == .divider {
            guard canReplaceEmptyBlockWithDivider(block) else { return .ignored }
            mutate("Turn Into") {
                document.blocks[i] = .divider(id: blockID, indent: block.indent)
            }
            expandedToggles.remove(blockID)
            expandedTemplateButtons.remove(blockID)
            return .handled
        }
        if case .subpage = block {
            return convertSubpage(blockID: blockID, to: target)
        }
        guard let text = textForBlockTypeChange(block) else { return .ignored }

        mutate("Turn Into") {
            document.blocks[i] = blockForTurnInto(target, id: blockID, text: text, indent: block.indent)
        }
        if target == .toggle {
            expandedToggles.insert(blockID)
        } else {
            expandedToggles.remove(blockID)
        }
        return .handled
    }

    @discardableResult
    private func convertBlockToTemplate(blockID: BlockID) -> KeyPress.Result {
        guard let i = document.index(of: blockID) else { return .ignored }
        let block = document.blocks[i]
        guard let text = textForBlockTypeChange(block) else { return .ignored }
        let label = cleanedTitle(String(text.characters)) ?? "Template"
        let range = document.sectionRange(of: blockID) ?? (i..<i + 1)
        let hasBody = range.upperBound > i + 1
        let replacement = Block.templateButton(id: blockID, label: label, indent: block.indent)
        let defaultBody = Block.paragraph(text: AttributedString(), indent: block.indent + 1)

        mutate("Turn Into") {
            document.blocks[i] = replacement
            if !hasBody {
                document.blocks.insert(defaultBody, at: i + 1)
            }
        }
        expandedToggles.remove(blockID)
        expandedTemplateButtons.insert(blockID)
        return .handled
    }

    @discardableResult
    private func convertSubpage(blockID: BlockID, to target: BlockTurnInto) -> KeyPress.Result {
        guard target != .page else { return .ignored }
        guard let i = document.index(of: blockID) else { return .ignored }
        guard case .subpage(_, let title, let path, let indent) = document.blocks[i] else { return .ignored }
        guard var loaded = onLoadSubpage(path) else { return .ignored }
        if case .heading(_, 1, let leadingText, _) = loaded.first,
           String(leadingText.characters).trimmingCharacters(in: .whitespacesAndNewlines) == title {
            loaded.removeFirst()
        }
        guard onMoveSubpageToTrash(path) else { return .ignored }

        let body = loaded.map { $0.withIndent($0.indent + indent + 1) }
        let replacement = blockForTurnInto(target, id: blockID, text: AttributedString(title), indent: indent)
        mutate("Turn Into") {
            document.blocks.replaceSubrange(i..<(i + 1), with: [replacement] + body)
        }
        if target == .toggle {
            expandedToggles.insert(blockID)
        } else if target == .template {
            expandedTemplateButtons.insert(blockID)
        } else {
            expandedToggles.remove(blockID)
            expandedTemplateButtons.remove(blockID)
        }
        return .handled
    }

    private func blockForTurnInto(_ target: BlockTurnInto, id: BlockID, text: AttributedString, indent: Int) -> Block {
        switch target {
        case .paragraph:
            return .paragraph(id: id, text: text, indent: indent)
        case .bullet:
            return .bullet(id: id, text: text, indent: indent)
        case .numbered:
            return .numbered(id: id, text: text, indent: indent)
        case .todo:
            return .todo(id: id, text: text, done: false, indent: indent)
        case .toggle:
            return .toggle(id: id, title: text, indent: indent)
        case .template:
            return .templateButton(id: id, label: String(text.characters), indent: indent)
        case .heading1:
            return .heading(id: id, level: 1, text: text, indent: indent)
        case .heading2:
            return .heading(id: id, level: 2, text: text, indent: indent)
        case .heading3:
            return .heading(id: id, level: 3, text: text, indent: indent)
        case .divider:
            return .divider(id: id, indent: indent)
        case .page:
            preconditionFailure("Page conversion creates a subpage file before replacing the block")
        }
    }

    /// Extracts the text/title from a block whose type can be swapped for another
    /// text-bearing type without losing content. Returns nil for blocks that don't
    /// carry user text (code/divider/subpage).
    private func textForBlockTypeChange(_ block: Block) -> AttributedString? {
        switch block {
        case .paragraph(_, let t, _),
             .heading(_, _, let t, _),
             .bullet(_, let t, _),
             .numbered(_, let t, _),
             .quote(_, let t, _),
             .toggle(_, let t, _):
            return t
        case .templateButton(_, let label, _):
            return AttributedString(label)
        case .todo(_, let t, _, _):
            return t
        case .code, .divider, .subpage:
            return nil
        }
    }

    private func canReplaceEmptyBlockWithDivider(_ block: Block) -> Bool {
        switch block {
        case .paragraph(_, let text, _),
             .heading(_, _, let text, _),
             .bullet(_, let text, _),
             .numbered(_, let text, _),
             .todo(_, let text, _, _),
             .quote(_, let text, _),
             .toggle(_, let text, _):
            return String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .templateButton(_, let label, _):
            return label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .code(_, let source, _, _):
            return source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .divider, .subpage:
            return false
        }
    }

    @ViewBuilder
    fileprivate func blockActionMenuContent(for blockID: BlockID) -> some View {
        let targetIDs = menuTargetIDs(anchorID: blockID)
        let targetIndices = targetIDs.compactMap { document.index(of: $0) }
        let targetBlocks = targetIndices.map { document.blocks[$0] }
        if !targetBlocks.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Button("Close") {
                    actionSheet = nil
                }
                .keyboardShortcut(.escape, modifiers: [])
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    blockMenuSectionHeader("Turn Into")
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.fixed(68), spacing: 8), count: 3),
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ForEach(turnIntoTargets(for: targetBlocks), id: \.self) { target in
                            compactMenuButton(
                                title: target.title,
                                systemImage: target.systemImage,
                                keyboardShortcut: target.keyboardShortcut
                            ) {
                                _ = convert(blockIDs: targetIDs, to: target)
                            }
                        }
                    }
                }
                let indentTargets = indentActions(for: targetIndices)
                VStack(alignment: .leading, spacing: 8) {
                    blockMenuSectionHeader("Actions")
                    HStack(spacing: 8) {
                        compactMenuButton(
                            title: "Copy",
                            systemImage: "doc.on.doc",
                            keyboardShortcut: "c",
                            keyboardShortcutModifiers: .command,
                            keyboardShortcutLabel: "⌘C"
                        ) {
                            _ = copyBlocksToPasteboard(ids: targetIDs)
                        }
                        .frame(maxWidth: .infinity)
                        ForEach(indentTargets, id: \.self) { action in
                            compactMenuButton(
                                title: action.title,
                                systemImage: action.systemImage,
                                keyboardShortcut: action.keyboardShortcut
                            ) {
                                indentMenuTargets(targetIDs, by: action.delta)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .padding(12)
            .frame(width: 248, alignment: .leading)
        }
    }

    @ViewBuilder
    private func blockMenuSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(NotionStyle.mutedForeground)
            .padding(.horizontal, 2)
    }

    @ViewBuilder
    private func compactMenuButton(
        title: String,
        systemImage: String,
        keyboardShortcut: KeyEquivalent,
        keyboardShortcutModifiers: EventModifiers = [],
        keyboardShortcutLabel: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            actionSheet = nil
            action()
        } label: {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .semibold))
                        .frame(height: 20)
                    Text(title)
                        .font(NotionStyle.body(size: 11).weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                BlockMenuShortcutChip(label: keyboardShortcutLabel ?? String(keyboardShortcut.character))
                    .padding(.top, 4)
                    .padding(.trailing, 5)
            }
            .frame(height: 60)
        }
        .buttonStyle(BlockMenuTileStyle())
        .keyboardShortcut(keyboardShortcut, modifiers: keyboardShortcutModifiers)
    }

    private func menuTargetIDs(anchorID: BlockID) -> [BlockID] {
        #if os(macOS)
        if selection.contains(anchorID), selection.count > 1 {
            let selectedBlocks = document.blocks.filter { selection.contains($0.id) }
            guard let baseIndent = selectedBlocks.map(\.indent).min() else { return [anchorID] }
            let baseIDs = selectedBlocks
                .filter { $0.indent == baseIndent }
                .map(\.id)
            return baseIDs.isEmpty ? [anchorID] : baseIDs
        }
        #endif
        return [anchorID]
    }

    private func indentMenuTargets(_ ids: [BlockID], by delta: Int) {
        for id in ids {
            _ = changeIndent(id, by: delta)
        }
    }

    private func turnIntoTargets(for blocks: [Block]) -> [BlockTurnInto] {
        BlockTurnInto.allCases.filter { target in
            if target == .template, blocks.count > 1 {
                return false
            }
            if blocks.allSatisfy({ currentTurnIntoTarget(for: $0) == target }) {
                return false
            }
            return blocks.allSatisfy { canTurn($0, into: target) }
        }
    }

    private func currentTurnIntoTarget(for block: Block) -> BlockTurnInto? {
        switch block {
        case .paragraph:
            return .paragraph
        case .heading(_, let level, _, _):
            switch level {
            case 1:
                return .heading1
            case 2:
                return .heading2
            case 3:
                return .heading3
            default:
                return nil
            }
        case .bullet:
            return .bullet
        case .numbered:
            return .numbered
        case .todo:
            return .todo
        case .toggle:
            return .toggle
        case .templateButton:
            return .template
        case .subpage:
            return .page
        case .quote, .code, .divider:
            return nil
        }
    }

    private func canTurn(_ block: Block, into target: BlockTurnInto) -> Bool {
        switch target {
        case .page:
            return !isStructuralBlock(block)
        case .template:
            return textForBlockTypeChange(block) != nil
        case .divider:
            return canReplaceEmptyBlockWithDivider(block)
        default:
            switch block {
            case .paragraph, .bullet, .numbered, .todo, .quote, .heading, .toggle, .templateButton, .subpage:
                return true
            case .code, .divider:
                return false
            }
        }
    }

    private func turnIntoTargets(for block: Block) -> [BlockTurnInto] {
        turnIntoTargets(for: [block])
    }

    private func indentActions(for indices: [Int]) -> [BlockIndentAction] {
        var actions: [BlockIndentAction] = []
        if canChangeIndent(at: indices, by: -1) {
            actions.append(BlockIndentAction(delta: -1, title: "Outdent", systemImage: "decrease.indent", keyboardShortcut: "["))
        }
        if canChangeIndent(at: indices, by: +1) {
            actions.append(BlockIndentAction(delta: +1, title: "Indent", systemImage: "increase.indent", keyboardShortcut: "]"))
        }
        return actions
    }

    private func isStructuralBlock(_ block: Block) -> Bool {
        switch block {
        case .code, .divider, .subpage:
            return true
        default:
            return false
        }
    }

    private func cleanedTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private func wholeBlockMarkdownLink(in text: AttributedString) -> (title: String, path: String)? {
        var linkTitle = ""
        var linkPath: String?
        var hasNonLinkText = false

        for run in text.runs {
            let segment = String(text[run.range].characters)
            if let link = run.link {
                let destination = link.absoluteString
                guard destination.hasSuffix(".md") else { return nil }
                if let existingPath = linkPath, existingPath != destination {
                    return nil
                }
                linkPath = destination
                linkTitle += segment
            } else if !segment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                hasNonLinkText = true
            }
        }

        guard !hasNonLinkText, let linkPath, let title = cleanedTitle(linkTitle) else {
            return nil
        }
        return (title, linkPath)
    }

    private func defaultSubpagePath(for title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let chars = title.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(chars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        let stem = collapsed.isEmpty ? "Untitled" : collapsed
        return stem + ".md"
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
                expandedToggles.insert(id)
            }
        }
        let focusTarget = replacements[transform.focusReplacementIndex]
        DispatchQueue.main.async {
            // Code/divider rows aren't editable in M3 (`enterEditMode` skips them); for
            // those transforms the focus target is the empty paragraph, which is editable.
            switch focusTarget {
            case .code, .divider, .subpage:
                setInteractionMode(.nav(focused: focusTarget.id))
            default:
                setInteractionMode(.editing(focusTarget.id))
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
            setInteractionMode(.editing(previous))
        }
        return .handled
    }

    private func changeIndent(_ blockID: BlockID, by delta: Int) -> KeyPress.Result {
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

private extension View {
    @ViewBuilder
    func iosPageBlockDropTarget(
        onUpdate: @escaping (CGFloat) -> Void,
        onDrop: @escaping (BlockDragPayload, CGFloat) -> Void,
        onCancel: @escaping () -> Void
    ) -> some View {
        #if os(iOS)
        self.onDrop(
            of: [UTType.plainText],
            delegate: PageBlockDropDelegate(
                onUpdate: onUpdate,
                onDrop: onDrop,
                onCancel: onCancel
            )
        )
        #else
        self
        #endif
    }

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
    func macRowReorder(
        isEnabled: Bool,
        block: Block,
        snapshot: [Block],
        onChanged: @escaping (DragGesture.Value) -> Void,
        onEnded: @escaping (DragGesture.Value) -> Void
    ) -> some View {
        #if os(macOS)
        if isEnabled {
            self.simultaneousGesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named(PageHoverCoordinateSpace.name))
                    .onChanged(onChanged)
                    .onEnded(onEnded)
            )
        } else {
            self
        }
        #else
        self
        #endif
    }

    @ViewBuilder
    func iosBlockTouchActions(
        isEnabled: Bool,
        onDelete: @escaping () -> Void,
        onShowMenu: @escaping () -> Void
    ) -> some View {
        #if os(iOS)
        if isEnabled {
            self.modifier(IOSRowSwipeActions(onDelete: onDelete, onShowMenu: onShowMenu))
        } else {
            self
        }
        #else
        self
        #endif
    }

    @ViewBuilder
    func blockActionPopover<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        self.popover(isPresented: isPresented) {
            content()
                #if os(iOS)
                .presentationCompactAdaptation(.popover)
                #endif
        }
    }

    @ViewBuilder
    func iosPageReorder(
        isEnabled: Bool,
        rowFrames: [BlockID: CGRect],
        snapshot: [Block],
        onBegin: @escaping (BlockID, CGPoint) -> Void,
        onChanged: @escaping (CGPoint) -> Void,
        onEnded: @escaping (CGPoint) -> Void,
        onCancelled: @escaping () -> Void
    ) -> some View {
        #if os(iOS)
        if isEnabled {
            self.background(
                IOSPageReorderGestureBridge(
                    rowFrames: rowFrames,
                    onBegin: onBegin,
                    onChanged: onChanged,
                    onEnded: onEnded,
                    onCancelled: onCancelled
                )
            )
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Unified page-level pinch: forwards every magnification update so the page
    /// can drive a live insert-gap preview, and forwards `.onEnded` so it can
    /// commit insert (open) or close-to-page-list. Replaces the prior
    /// open-on-row + close-on-page split — both directions now arbitrate
    /// through a single gesture.
    @ViewBuilder
    func iosPagePinch(
        isEnabled: Bool,
        onUpdate: @escaping (PagePinchValue) -> Void,
        onCommit: @escaping (PagePinchValue) -> Void
    ) -> some View {
        #if os(iOS)
        self.background(
            IOSPagePinchGestureBridge(
                isEnabled: isEnabled,
                onUpdate: onUpdate,
                onCommit: onCommit
            )
        )
        #else
        self
        #endif
    }

    @ViewBuilder
    func iosScrollMetrics(_ metrics: Binding<PageScrollMetrics>) -> some View {
        #if os(iOS)
        self.background(IOSScrollMetricsReader(metrics: metrics))
        #else
        self
        #endif
    }

    @ViewBuilder
    func iosTapBelowRows(_ onTap: @escaping (CGPoint) -> Void) -> some View {
        #if os(iOS)
        self.simultaneousGesture(
            SpatialTapGesture()
                .onEnded { value in
                    onTap(value.location)
                }
        )
        #else
        self
        #endif
    }

    @ViewBuilder
    func iosEdgeGateNavigateBack() -> some View {
        #if os(iOS)
        self.background(IOSNavigationBackGestureGate())
        #else
        self
        #endif
    }
}

#if os(iOS)
private struct IOSNavigationBackGestureGate: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.installWhenReady()
    }

    final class Controller: UIViewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            installWhenReady()
        }

        func installWhenReady() {
            guard let navigationController else { return }
            navigationController.interactiveContentPopGestureRecognizer?.isEnabled = false
            navigationController.interactivePopGestureRecognizer?.isEnabled = true
        }
    }
}
#endif

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

struct ReorderLift {
    /// Lead block — this is what `reorderLiftView()` renders inside the lift.
    var block: Block
    /// All blocks being reordered. Single-row drags carry one ID; drags
    /// initiated from a multi-block selection carry the whole selection.
    var ids: [BlockID]
    var sourceFrame: CGRect
    var sourceIndex: Int
    var sourceEndIndex: Int
    var touchOffset: CGSize
    var location: CGPoint
    /// True while the lift is mounted but `touchOffset` is a placeholder
    /// (centered on the source row) waiting for a real cursor location to
    /// re-anchor against. Used on iOS when prelift state is mounted before
    /// the first concrete touch point is applied.
    var pendingAnchor: Bool
}

struct IOSPageReorderGeometry {
    static func pageLocation(
        forScrollViewLocation location: CGPoint,
        contentOffset: CGPoint,
        adjustedTopInset: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: location.x - contentOffset.x,
            y: location.y - effectiveScrollOffsetY(
                contentOffsetY: contentOffset.y,
                adjustedTopInset: adjustedTopInset
            )
        )
    }

    private static func effectiveScrollOffsetY(contentOffsetY: CGFloat, adjustedTopInset: CGFloat) -> CGFloat {
        max(0, contentOffsetY + adjustedTopInset)
    }
}

#if os(iOS)
/// Page-level reorder gesture. Walks up to the enclosing `UIScrollView`,
/// attaches a `UILongPressGestureRecognizer` to it, and tells the scroll
/// view's pan recognizer to `require(toFail:)` it. UIKit-level coordination
/// is what lets the page scroll on a fast vertical drag (motion exceeds
/// `allowableMovement` before the timer fires → long-press fails → pan
/// proceeds) while still entering reorder on a deliberate hold (timer
/// fires within tolerance → long-press wins → pan never starts).
///
/// Prior SwiftUI implementation used `LongPressGesture.sequenced(before:
/// DragGesture(0))` per row. That triggered SwiftUI's "system gesture gate"
/// after `.first(true)` and stranded touches — no further events to either
/// the row gesture or the scroll view, leaving rows dimmed and scroll
/// blocked. Removing the SwiftUI long-press but keeping `DragGesture(0)`
/// didn't help either: `DragGesture(minimumDistance: 0)` claims the touch
/// at the SwiftUI layer and blocks the scroll view's pan even when our
/// handler ignores the events.
struct IOSPageReorderGestureBridge: UIViewRepresentable {
    var rowFrames: [BlockID: CGRect]
    var onBegin: (BlockID, CGPoint) -> Void
    var onChanged: (CGPoint) -> Void
    var onEnded: (CGPoint) -> Void
    var onCancelled: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = HostView()
        view.coordinator = context.coordinator
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class HostView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                coordinator?.attach(from: self)
            } else {
                coordinator?.detach()
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: IOSPageReorderGestureBridge
        weak var recognizer: UILongPressGestureRecognizer?
        weak var scrollView: UIScrollView?
        private var activeBlockID: BlockID?

        init(parent: IOSPageReorderGestureBridge) {
            self.parent = parent
        }

        func attach(from view: UIView) {
            guard recognizer == nil else { return }
            var current: UIView? = view.superview
            while let v = current {
                if let scroll = v as? UIScrollView {
                    let lp = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
                    lp.minimumPressDuration = 0.5
                    lp.allowableMovement = 8
                    lp.cancelsTouchesInView = false
                    lp.delegate = self
                    scroll.addGestureRecognizer(lp)
                    scroll.panGestureRecognizer.require(toFail: lp)
                    self.recognizer = lp
                    self.scrollView = scroll
                    return
                }
                current = v.superview
            }
        }

        func detach() {
            if let recognizer, let scrollView {
                scrollView.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
            scrollView = nil
            activeBlockID = nil
        }

        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard let scrollView else { return }
            let location = pageCoordinateLocation(for: recognizer, scrollView: scrollView)
            switch recognizer.state {
            case .began:
                guard let blockID = nearestRowID(to: location, frames: parent.rowFrames) else {
                    activeBlockID = nil
                    return
                }
                activeBlockID = blockID
                parent.onBegin(blockID, location)
            case .changed:
                guard activeBlockID != nil else { return }
                parent.onChanged(location)
            case .ended:
                if activeBlockID != nil {
                    parent.onEnded(location)
                }
                activeBlockID = nil
            case .cancelled, .failed:
                if activeBlockID != nil {
                    parent.onCancelled()
                }
                activeBlockID = nil
            default:
                break
            }
        }

        private func pageCoordinateLocation(
            for recognizer: UIGestureRecognizer,
            scrollView: UIScrollView
        ) -> CGPoint {
            IOSPageReorderGeometry.pageLocation(
                forScrollViewLocation: recognizer.location(in: scrollView),
                contentOffset: scrollView.contentOffset,
                adjustedTopInset: scrollView.adjustedContentInset.top
            )
        }

        private func nearestRowID(to point: CGPoint, frames: [BlockID: CGRect]) -> BlockID? {
            frames
                .filter { $0.value.contains(point) }
                .min(by: { abs($0.value.midY - point.y) < abs($1.value.midY - point.y) })?
                .key
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === recognizer,
                  let scrollView else {
                return true
            }
            let location = pageCoordinateLocation(for: gestureRecognizer, scrollView: scrollView)
            return nearestRowID(to: location, frames: parent.rowFrames) != nil
        }
    }
}

/// Page-level pinch gesture. Walks up to the enclosing `UIScrollView`, attaches
/// a `UIPinchGestureRecognizer` and reads the live finger positions via
/// `location(ofTouch:in:)` so we can emit the *actual* pixel distance the
/// fingers have spread. SwiftUI's `MagnifyGesture` only exposes a magnification
/// ratio, which forces a magic-number assumption about start finger distance —
/// pinch felt amplified at narrow grips and undersized at wide grips.
private struct IOSPagePinchGestureBridge: UIViewRepresentable {
    var isEnabled: Bool
    var onUpdate: (PagePinchValue) -> Void
    var onCommit: (PagePinchValue) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = HostView()
        view.coordinator = context.coordinator
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.recognizer?.isEnabled = isEnabled
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class HostView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                coordinator?.attach(from: self)
            } else {
                coordinator?.detach()
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: IOSPagePinchGestureBridge
        weak var recognizer: UIPinchGestureRecognizer?
        weak var scrollView: UIScrollView?
        private var startDistance: CGFloat = 0
        private var startMidpoint: CGPoint = .zero

        init(parent: IOSPagePinchGestureBridge) {
            self.parent = parent
        }

        func attach(from view: UIView) {
            guard recognizer == nil else { return }
            var current: UIView? = view.superview
            while let v = current {
                if let scroll = v as? UIScrollView {
                    let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
                    pinch.cancelsTouchesInView = false
                    pinch.delegate = self
                    pinch.isEnabled = parent.isEnabled
                    scroll.addGestureRecognizer(pinch)
                    self.recognizer = pinch
                    self.scrollView = scroll
                    return
                }
                current = v.superview
            }
        }

        func detach() {
            if let recognizer, let scrollView {
                scrollView.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
            scrollView = nil
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let scrollView else { return }
            switch recognizer.state {
            case .began:
                guard recognizer.numberOfTouches >= 2 else { return }
                let p0 = recognizer.location(ofTouch: 0, in: scrollView)
                let p1 = recognizer.location(ofTouch: 1, in: scrollView)
                startDistance = hypot(p0.x - p1.x, p0.y - p1.y)
                let midScroll = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
                startMidpoint = pageCoordinateLocation(for: midScroll, scrollView: scrollView)
                parent.onUpdate(makeValue(recognizer: recognizer, scrollView: scrollView, currentDistance: startDistance))
            case .changed:
                let distance = currentDistance(recognizer: recognizer, scrollView: scrollView)
                parent.onUpdate(makeValue(recognizer: recognizer, scrollView: scrollView, currentDistance: distance))
            case .ended, .cancelled, .failed:
                let distance = currentDistance(recognizer: recognizer, scrollView: scrollView)
                parent.onCommit(makeValue(recognizer: recognizer, scrollView: scrollView, currentDistance: distance))
            default:
                break
            }
        }

        private func currentDistance(recognizer: UIPinchGestureRecognizer, scrollView: UIScrollView) -> CGFloat {
            guard recognizer.numberOfTouches >= 2 else {
                // One finger lifted before .ended — fall back to scale × startDistance.
                return startDistance * recognizer.scale
            }
            let p0 = recognizer.location(ofTouch: 0, in: scrollView)
            let p1 = recognizer.location(ofTouch: 1, in: scrollView)
            return hypot(p0.x - p1.x, p0.y - p1.y)
        }

        private func makeValue(
            recognizer: UIPinchGestureRecognizer,
            scrollView: UIScrollView,
            currentDistance: CGFloat
        ) -> PagePinchValue {
            let midScroll: CGPoint
            if recognizer.numberOfTouches >= 2 {
                let p0 = recognizer.location(ofTouch: 0, in: scrollView)
                let p1 = recognizer.location(ofTouch: 1, in: scrollView)
                midScroll = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
            } else {
                midScroll = recognizer.location(in: scrollView)
            }
            let midPage = pageCoordinateLocation(for: midScroll, scrollView: scrollView)
            return PagePinchValue(
                startLocation: startMidpoint,
                location: midPage,
                magnification: recognizer.scale,
                spread: currentDistance,
                spreadDelta: currentDistance - startDistance
            )
        }

        private func pageCoordinateLocation(
            for scrollLocation: CGPoint,
            scrollView: UIScrollView
        ) -> CGPoint {
            IOSPageReorderGeometry.pageLocation(
                forScrollViewLocation: scrollLocation,
                contentOffset: scrollView.contentOffset,
                adjustedTopInset: scrollView.adjustedContentInset.top
            )
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

private struct PageBlockDropDelegate: DropDelegate {
    let onUpdate: (CGFloat) -> Void
    let onDrop: (BlockDragPayload, CGFloat) -> Void
    let onCancel: () -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? {
        onUpdate(info.location.y)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        onCancel()
    }

    func performDrop(info: DropInfo) -> Bool {
        let y = info.location.y
        let dropSpring = Animation.spring(response: 0.26, dampingFraction: 0.76)

        guard let provider = info.itemProviders(for: [UTType.plainText]).first else {
            withAnimation(dropSpring) { onCancel() }
            return false
        }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? NSString,
                  let payload = BlockDragPayload(jsonString: string as String) else {
                Task { @MainActor in
                    withAnimation(dropSpring) { onCancel() }
                }
                return
            }
            Task { @MainActor in
                withAnimation(dropSpring) {
                    onDrop(payload, y)
                    onCancel()
                }
            }
        }
        return true
    }
}

@MainActor
private final class PageScrollController {
    static let shared = PageScrollController()

    weak var scrollView: UIScrollView?

    func scroll(toY y: CGFloat) {
        guard let scrollView else { return }
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: y), animated: false)
    }
}

private struct IOSScrollMetricsReader: UIViewRepresentable {
    @Binding var metrics: PageScrollMetrics

    func makeCoordinator() -> Coordinator {
        Coordinator(metrics: $metrics)
    }

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: ReaderView, context: Context) {
        context.coordinator.metrics = $metrics
        uiView.coordinator = context.coordinator
        uiView.installIfNeeded()
    }

    @MainActor
    final class ReaderView: UIView {
        weak var coordinator: Coordinator?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            isUserInteractionEnabled = false
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            installIfNeeded()
            DispatchQueue.main.async { [weak self] in
                self?.installIfNeeded()
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            installIfNeeded()
            DispatchQueue.main.async { [weak self] in
                self?.installIfNeeded()
            }
        }

        func installIfNeeded() {
            guard let scrollView = nearestScrollView() else { return }
            PageScrollController.shared.scrollView = scrollView
            coordinator?.update(from: scrollView)
        }

        private func nearestScrollView() -> UIScrollView? {
            var current = superview
            while let view = current {
                if let scrollView = view as? UIScrollView {
                    return scrollView
                }
                current = view.superview
            }
            return nil
        }
    }

    @MainActor
    final class Coordinator {
        var metrics: Binding<PageScrollMetrics>
        private weak var observedScrollView: UIScrollView?
        private var observation: NSKeyValueObservation?
        private var boundsObservation: NSKeyValueObservation?
        private var contentSizeObservation: NSKeyValueObservation?

        init(metrics: Binding<PageScrollMetrics>) {
            self.metrics = metrics
        }

        func update(from scrollView: UIScrollView) {
            if observedScrollView !== scrollView {
                observedScrollView = scrollView
                observation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self, weak scrollView] _, _ in
                    Task { @MainActor in
                        guard let self, let scrollView else { return }
                        self.publish(scrollView)
                    }
                }
                boundsObservation = scrollView.observe(\.bounds, options: [.new]) { [weak self, weak scrollView] _, _ in
                    Task { @MainActor in
                        guard let self, let scrollView else { return }
                        self.publish(scrollView)
                    }
                }
                contentSizeObservation = scrollView.observe(\.contentSize, options: [.new]) { [weak self, weak scrollView] _, _ in
                    Task { @MainActor in
                        guard let self, let scrollView else { return }
                        self.publish(scrollView)
                    }
                }
            }
            publish(scrollView)
        }

        private func publish(_ scrollView: UIScrollView) {
            let next = PageScrollMetrics(
                viewportHeight: scrollView.bounds.height,
                contentHeight: scrollView.contentSize.height,
                contentOffsetY: scrollView.contentOffset.y
            )
            if metrics.wrappedValue != next {
                metrics.wrappedValue = next
            }
        }
    }
}

/// Horizontal-swipe actions on a row: leading swipe (right) reveals an
/// `ellipsis.circle.fill` glyph and, past the trigger, opens the row's
/// action sheet. Trailing swipe (left) deletes. SwiftUI's `.swipeActions`
/// only fires inside a `List`, but the page is built on a `VStack` to keep
/// typography control, so this is a manual `DragGesture` that tracks the
/// row offset, reveals per-edge action labels, and commits past a threshold.
private struct IOSRowSwipeActions: ViewModifier {
    let onDelete: () -> Void
    let onShowMenu: () -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var triggered: Bool = false
    @State private var crossedDeleteThreshold: Bool = false

    private let trigger: CGFloat = 96
    private let revealCap: CGFloat = 140

    func body(content: Content) -> some View {
        let rightOffset = min(revealCap, max(0, dragOffset))
        let revealProgress = min(1, rightOffset / trigger)
        let deleteProgress = min(1, max(0, -dragOffset) / trigger)

        ZStack {
            // Right-swipe only: recessed well + ellipsis icon. Hidden behind
            // the row at rest; uncovered as the row slides right.
            ZStack {
                Color.black.opacity(0.06)
                HStack(spacing: 0) {
                    Image(systemName: "ellipsis.circle.fill")
                        .foregroundStyle(.blue)
                        .font(.system(size: 18, weight: .semibold))
                        .padding(.leading, 22)
                    Spacer(minLength: 0)
                }
            }
            .opacity(revealProgress)
            .allowsHitTesting(false)

            content
                .background(NotionStyle.background)
                .offset(x: rightOffset)

            // Left-swipe: a graphite "pencil line" emerges from the trailing
            // edge and crosses the row as the user drags left. Scaled so
            // reaching the commit threshold = a complete cross-out. At commit
            // the stroke thickens and darkens — like the pencil pressed harder.
            GeometryReader { geo in
                pencilLine(
                    rowWidth: geo.size.width,
                    lineLength: geo.size.width * deleteProgress
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .allowsHitTesting(false)
        }
        .highPriorityGesture(
            DragGesture(minimumDistance: 18, coordinateSpace: .local)
                .onChanged { value in
                    guard !triggered else { return }
                    let h = value.translation.width
                    let v = value.translation.height
                    // Commit horizontal motion only when the drag is clearly
                    // sideways — keeps vertical scroll free.
                    guard abs(h) > abs(v) * 1.4 else { return }
                    dragOffset = h
                    // The menu opens on threshold-crossed mid-gesture so the
                    // user can swipe-and-hold to peek the menu. Delete is
                    // destructive — only commits on release, but fire a haptic
                    // when the strike-through completes so the user knows
                    // releasing now will commit.
                    if h >= trigger {
                        fire(onShowMenu)
                    } else if h <= -trigger {
                        if !crossedDeleteThreshold {
                            crossedDeleteThreshold = true
                            Haptics.medium()
                        }
                    } else {
                        crossedDeleteThreshold = false
                    }
                }
                .onEnded { value in
                    let h = value.translation.width
                    if !triggered, h <= -trigger {
                        onDelete()
                        SoundFX.play(.delete)
                    }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                        dragOffset = 0
                    }
                    triggered = false
                    crossedDeleteThreshold = false
                }
        )
    }

    private func fire(_ action: () -> Void) {
        triggered = true
        Haptics.medium()
        action()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            dragOffset = 0
        }
    }

    /// A graphite-style cross-out line drawn in a `Canvas`. Composited from a
    /// soft halo, a crisp core, and a deterministic scatter of grain dots that
    /// simulate the graphite catching on tooth of the paper. The grain pattern
    /// is keyed off a fixed seed so it stays put as the line extends — only the
    /// trailing-aligned mask grows with `lineLength`. At commit the stroke
    /// thickens/darkens and grain density bumps, like the pencil pressed harder.
    @ViewBuilder
    private func pencilLine(rowWidth: CGFloat, lineLength: CGFloat) -> some View {
        let armed = crossedDeleteThreshold
        let coreColor = Color(white: 0.18)
        let coreHeight: CGFloat = armed ? 2.4 : 1.6
        let coreOpacity: Double = armed ? 0.92 : 0.72
        let haloHeight: CGFloat = armed ? 6 : 4
        let haloOpacity: Double = armed ? 0.22 : 0.12
        let grainSpacing: CGFloat = armed ? 0.8 : 1.3
        let grainBoost: Double = armed ? 0.18 : 0

        Canvas { context, size in
            let centerY = size.height / 2

            let halo = Path(CGRect(
                x: 0, y: centerY - haloHeight / 2,
                width: size.width, height: haloHeight
            ))
            context.fill(halo, with: .color(coreColor.opacity(haloOpacity)))

            let core = Path(CGRect(
                x: 0, y: centerY - coreHeight / 2,
                width: size.width, height: coreHeight
            ))
            context.fill(core, with: .color(coreColor.opacity(coreOpacity)))

            var rng = SeededLCG(seed: 0xF1B2C3D4)
            let grainCount = Int(size.width / grainSpacing)
            for _ in 0..<grainCount {
                let x = CGFloat(rng.next01()) * size.width
                let yJitter = (CGFloat(rng.next01()) - 0.5) * 7
                let r = 0.25 + CGFloat(rng.next01()) * 0.7
                let opacity = 0.12 + rng.next01() * 0.42 + grainBoost
                let dot = Path(ellipseIn: CGRect(
                    x: x - r, y: centerY + yJitter - r,
                    width: r * 2, height: r * 2
                ))
                context.fill(dot, with: .color(coreColor.opacity(opacity)))
            }
        }
        .frame(width: rowWidth, height: 12)
        .mask(alignment: .trailing) {
            Color.black.frame(width: lineLength)
        }
        .animation(.spring(response: 0.18, dampingFraction: 0.7), value: armed)
    }
}

/// Linear-congruential PRNG — deterministic per seed so the grain pattern
/// stays put across re-renders (and frames during animation).
private struct SeededLCG {
    private var state: UInt32
    init(seed: UInt32) { self.state = seed }
    mutating func next01() -> Double {
        state = state &* 1_664_525 &+ 1_013_904_223
        return Double(state) / Double(UInt32.max)
    }
}
#endif

private struct BlockMenuTileStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(NotionStyle.foreground)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(fillColor(isPressed: configuration.isPressed))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.08), value: isHovering)
            #if os(macOS)
            .onHover { isHovering = $0 }
            #endif
    }

    private func fillColor(isPressed: Bool) -> Color {
        if isPressed { return NotionStyle.dividerColor }
        if isHovering { return NotionStyle.dividerColor.opacity(0.5) }
        return .clear
    }
}

private struct BlockMenuShortcutChip: View {
    let label: String
    #if os(iOS)
    // On iOS the chip only makes sense when a hardware keyboard is around to
    // hit the shortcut. HardwareKeyboardObserver flips when GameController's
    // GCKeyboard reports connect/disconnect; @ObservedObject re-evaluates body
    // on change so the chip appears/disappears live.
    @ObservedObject private var keyboard = HardwareKeyboardObserver.shared
    #endif

    var body: some View {
        #if os(iOS)
        if keyboard.isConnected {
            chip
        }
        #else
        chip
        #endif
    }

    private var chip: some View {
        Text(label)
            .font(NotionStyle.mono(size: 9))
            .foregroundStyle(NotionStyle.mutedForeground)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(NotionStyle.codeBackground)
            )
    }
}

#if os(iOS)
import GameController

@MainActor
private final class HardwareKeyboardObserver: ObservableObject {
    static let shared = HardwareKeyboardObserver()

    @Published private(set) var isConnected: Bool = GCKeyboard.coalesced != nil

    private init() {
        NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidConnect, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.isConnected = true }
        }
        NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidDisconnect, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.isConnected = GCKeyboard.coalesced != nil }
        }
    }
}
#endif
