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
    /// Ask the host to present its page picker for a "Move to" action. The host
    /// shows whatever picker UI it owns (sheet, popover, etc.) and calls back
    /// with the chosen `pageID` (relative path) — or nil if the user cancelled.
    /// The editor then performs the move.
    public let onRequestMoveDestination: (_ blockIDs: [BlockID], _ pick: @escaping (String?) -> Void) -> Void
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
    /// Host-provided async fetcher for external-URL preview metadata (favicon +
    /// page title). The editor calls this for every external `http`/`https`
    /// link in a rendered (read-only) row and decorates the inline link with
    /// the result. Default is `nil` — no fetching happens, links render as today.
    public let linkPreviewProvider: LinkPreviewProvider?
    /// Persist pasted image bytes. Returns relative paths suitable for
    /// `Block.image.source` (one per input, in order). Returning an empty
    /// array, or fewer paths than inputs, cancels the paste.
    public let onSaveImages: (_ items: [PastedImage]) -> [String]
    /// Resolve an image block's `source` to a file URL the renderer can load.
    /// Nil → renderer shows a missing-image placeholder. Same callback is
    /// also published into the Environment for `ImageBlockView`.
    public let imageURLResolver: ImageURLResolver?

    // View-shaped @State that doesn't move into EditorState because it's tied to
    // SwiftUI/UIKit lifecycle (FocusState must live on a View; row-frame cache
    // is a layout output; gesture-internal flags are bookkeeping for UIKit
    // bridges; Environment must be read inside View.body).

    /// Drives the active editor's `.focused()` on iOS (UITextView). On macOS this is
    /// written but never read as a focus source — the NSTextView grabs first responder
    /// directly via `MacBlockTextViewRegistry.makeFirstResponder`. Both writes are
    /// driven from `.onChange(of: state.mode)` rather than scattered call sites.
    @FocusState var editorFocused: BlockID?
    /// Drives the page container's focusability for nav-mode key handling. Written only
    /// from `.onChange(of: state.mode)` (and once on first appear).
    @FocusState var pageFocused: Bool
    #if os(macOS)
    /// Single-slot weak handle to the currently-mounted NSTextView. Only one editor
    /// mounts at a time (gated by `isEditing`), so `transferFocus(to: .editor(id))`
    /// can ask "is the active editor for this block?" and call `makeFirstResponder`
    /// synchronously instead of waiting for the NSTextView's own async self-grab.
    @State var macActiveTextView = MacActiveTextView()
    #endif
    /// Document-level undo coordinator. Owns the shared `UndoManager` that NSTextView
    /// typing-undo and structural ops (split/merge/indent/slide/delete/autotransform/
    /// drag-drop) all register against. Recreated implicitly when EditorView's identity
    /// resets; explicitly cleared on document switch via `.onChange(of: document.id)`.
    @State var undoController = DocumentUndoController()
    @State var editorCommands = EditorCommands()
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
        onRequestMoveDestination: @escaping (_ blockIDs: [BlockID], _ pick: @escaping (String?) -> Void) -> Void = { _, pick in pick(nil) },
        onNavigateBack: @escaping () -> Void = {},
        onEdited: @escaping () -> Void = {},
        onBlur: @escaping () -> Void = {},
        onRecordBlockDeletion: @escaping (_ indices: [Int], _ blocks: [Block], _ actionName: String) -> Void = { _, _, _ in },
        serializeBlocksForPasteboard: @escaping (_ blocks: [Block]) -> String = { _ in "" },
        parseBlocksFromPasteboard: @escaping (_ string: String) -> [Block]? = { _ in nil },
        linkPreviewProvider: LinkPreviewProvider? = nil,
        onSaveImages: @escaping (_ items: [PastedImage]) -> [String] = { _ in [] },
        imageURLResolver: ImageURLResolver? = nil
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
        self.onRequestMoveDestination = onRequestMoveDestination
        self.onNavigateBack = onNavigateBack
        self.onEdited = onEdited
        self.onBlur = onBlur
        self.onRecordBlockDeletion = onRecordBlockDeletion
        self.serializeBlocksForPasteboard = serializeBlocksForPasteboard
        self.parseBlocksFromPasteboard = parseBlocksFromPasteboard
        self.linkPreviewProvider = linkPreviewProvider
        self.onSaveImages = onSaveImages
        self.imageURLResolver = imageURLResolver
    }

    public var body: some View {
        GeometryReader { geometry in
            let numbering = NumberingContext.compute(document.children)
            let snapshot = document.children
            let hidden = hiddenBlockIDs(in: snapshot)
            // Tree-aware visible-row layout walk — yields one VisibleRow per
            // displayed block with its depth and prev-sibling reference.
            let layout = computeVisibleLayout(snapshot: snapshot, hidden: hidden)
            let visibleRows = layout.rows
            let prevVisibleBlocks = layout.prevVisible
            let prevDepths = layout.prevDepths
            // Translate the (tree-aware) drop hover and lift footprint into the
            // visible-row slot space the gap renderers operate in. Both gestures
            // render gaps against the body's `ForEach` enumeration index `k`, so
            // anything they need to compare against has to live in slot space.
            let dropHoverSlot = visibleSlotForCurrentDropPath(in: visibleRows)
            let liftFootprint = currentLiftFootprint(in: visibleRows)
            let trailingSlot = visibleRows.count
            #if os(iOS)
            let selectedIDs: Set<BlockID> = []
            #else
            let selectedIDs = effectiveSelectedIDs()
            #endif
            let horizontalPadding = NotionStyle.pageHorizontalPadding(for: geometry.size.width)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(visibleRows.enumerated()), id: \.element.block.id) { (k, row) in
                        let block = row.block
                        let prev = prevVisibleBlocks[k]
                        let prevDepth = prevDepths[k]
                        let gap = BlockSpacing.gap(before: block, depth: row.depth, after: prev, prevDepth: prevDepth)
                        let pinchExtraTopGap = pinchExtraGap(forIndex: k)
                        let reorderExtraTopGap = reorderDriftGap(at: k, hoverSlot: dropHoverSlot, liftFootprint: liftFootprint)
                        rowView(for: bindingForBlock(id: block.id), depth: row.depth, snapshot: snapshot, numberingIndex: numbering[block.id], selectedIDs: selectedIDs)
                            .padding(.top, gap + pinchExtraTopGap + reorderExtraTopGap)
                            .animation(.spring(response: 0.26, dampingFraction: 0.76), value: state.dropHoverPath)
                            .background(rowFrameReporter(id: block.id))
                    }
                    let trailingPinchGap = pinchExtraGap(forIndex: trailingSlot)
                    let trailingReorderGap = reorderDriftGap(at: trailingSlot, hoverSlot: dropHoverSlot, liftFootprint: liftFootprint)
                    gapDropTarget(at: trailingSlot, height: 32 + trailingPinchGap + trailingReorderGap)
                        .animation(.spring(response: 0.26, dampingFraction: 0.76), value: state.dropHoverPath)
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
                    rowFrames: rowFrames
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
                // Mount the iOS metrics reader INSIDE the ScrollView so its UIView's
                // superview chain walks up through the UIScrollView. Attached as a
                // background of the outer ScrollView, the background sits as a
                // sibling and superview never reaches the scroll view → metrics stay
                // at zero, autoscroll bails. macScrollMetrics uses
                // `.onScrollGeometryChange` so it doesn't need to be inside.
                .iosScrollMetrics($scrollMetrics)
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
                    state.currentDropTarget = nil
                }
            )
            .macScrollMetrics($scrollMetrics)
            .macScrollPosition($scrollPosition)
            .macNearestRowHover(rowFrames: rowFrames) { id in state.hoveredBlock = id }
            .background(NotionStyle.background)
            .tapBelowRows {
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
            .environment(\.linkPreviewProvider, linkPreviewProvider)
            .environment(\.imageURLResolver, imageURLResolver)
            #if os(macOS)
            .environment(\.macActiveTextView, macActiveTextView)
            #endif
            // Publish for App-level CommandGroup so Cmd-Z routes through this EditorView's
            // undo manager regardless of where focus actually lives. Uses scene-level
            // exposure (rather than `.focusedValue`) because in edit mode the NSTextView
            // holds AppKit-level focus, which SwiftUI's per-view focus tracking misses —
            // scene-level remains visible to the menu commands.
            .focusedSceneValue(\.documentUndoController, undoController)
            .focusedSceneValue(\.editorCommands, editorCommands)
            .focusable()
            .focused($pageFocused)
            .onAppear {
                if state.cursor == nil, let first = document.children.first {
                    state.setCursor(first.id)
                }
                forcePageFocusGrab()
                installUndoApply()
                wireEditorCommands()
            }
            .onChange(of: state.dropHoverPath) { _, newValue in
                handleDropHoverChange(newValue?.position)
            }
            .onChange(of: state.mode) { oldMode, newMode in
                actionSheet = nil
                handleModeChange(from: oldMode, to: newMode)
            }
            #if os(iOS)
            // On iOS the user can lose editor focus without touching `state.mode`
            // (tap outside the editor, keyboard dismiss). `editorFocused` going nil is
            // the only real-time signal — fire onBlur so the host saves. macOS doesn't
            // need this: every focus loss there flows through `transferFocus(to: .nav)`,
            // which `handleModeChange` already wires to onBlur.
            .onChange(of: editorFocused) { old, new in
                if new == nil && old != nil {
                    onBlur()
                }
            }
            #endif
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
                KeyEquivalent("b"),
                KeyEquivalent("i"),
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
            transferFocus(to: .nav(cursor: state.editingBlock))
            return
        }
        clearCursor()
    }


    // MARK: - Row builder

    /// Returns a `Binding<Block>` that reads the block by id from the live
    /// document and writes it back via `Document.mutate`. Used by the body
    /// in place of the old `$document.blocks[i]` index-based binding.
    private func bindingForBlock(id: BlockID) -> Binding<Block> {
        Binding(
            get: { document.find(id) ?? Block.paragraph(text: AttributedString()) },
            set: { newValue in
                document.mutate(id) { existing in
                    existing.kind = newValue.kind
                    existing.children = newValue.children
                }
            }
        )
    }

    @ViewBuilder
    private func rowView(for binding: Binding<Block>, depth: Int, snapshot: [Block], numberingIndex: Int?, selectedIDs: Set<BlockID>) -> some View {
        let block = binding.wrappedValue
        // iOS has no nav-mode multi-select — there's no hardware keyboard arrow nav and the
        // blue tint after dismissing the keyboard is just visual noise. Hardcode false to
        // suppress it (the underlying nav state still updates; nothing reads it on iOS).
        #if os(iOS)
        let isSelected = false
        #else
        let isSelected = selectedIDs.contains(block.id)
        #endif
        let isEditing = state.editingBlock == block.id
        // The macOS action menu opens in nav mode, where the block is already painted with
        // the blue nav-selection tint — a second ring would just duplicate it. iOS has no
        // nav-mode multi-select (always one anchor block), so the ring is the only marker.
        #if os(iOS)
        let isActionMenuTarget = (actionSheet?.id == block.id)
        #else
        let isActionMenuTarget = false
        #endif

        BlockRow(
            block: binding,
            depth: depth,
            editorFocused: $editorFocused,
            isPageTitle: isPageTitleBlock(block, snapshot: snapshot),
            numberingIndex: numberingIndex,
            isSelected: isSelected,
            isEditing: isEditing,
            isExpanded: state.expandedToggles.contains(block.id) || state.expandedTemplates.contains(block.id),
            isDropTarget: state.dropOntoBlockID == block.id,
            isActionMenuTarget: isActionMenuTarget,
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
                transferFocus(to: .editor(block.id, initialCursor: .point(point)))
            },
            onToggleExpansion: {
                if case .templateButton = block.kind {
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
            consumeInitialCursor: { state.takePendingInitialCursor() }
        )
            // Whole-row reorder on macOS. Coexists with click-to-edit
            // (.onTapGesture below) because of the 4pt minimumDistance: a
            // click without movement enters edit mode; movement past 4pt
            // starts a drag instead. isEditing gates the drag off so the
            // editor's own selection gestures aren't shadowed.
            .macRowReorder(
                isEnabled: !isEditing,
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
                if case .subpage(_, let path) = block.kind {
                    transferFocus(to: .nav(cursor: block.id))
                    onSubpageTap(path)
                    return
                }
                // Clicks outside the editable text region (markers, paddings) — no
                // position info, cursor lands at end via the editor's default behavior.
                transferFocus(to: .editor(block.id, initialCursor: nil))
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
        // First-in-document-order id within the selection.
        var best: (id: BlockID, order: Int)?
        for id in state.selection {
            guard let order = document.documentOrder(of: id) else { continue }
            if best == nil || order < best!.order {
                best = (id, order)
            }
        }
        return best?.id
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
        switch block.kind {
        case .code(let source, _):
            return source
        case .divider:
            return ""
        case .subpage(let title, _):
            return title
        case .image(let source, let alt):
            return alt.isEmpty ? source : alt
        default:
            return String(block.text.characters)
        }
    }

    private func blockKindLabel(for block: Block) -> String {
        switch block.kind {
        case .paragraph:
            return "Paragraph"
        case .heading(let level, _):
            return "Heading \(level.rawValue)"
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
        case .image:
            return "Image"
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

    /// Insert a top-level block at the given index (paragraph creation,
    /// end-of-page tap). Used where the insertion always targets the
    /// document root.
    func insertBlock(_ newBlock: Block, at index: Int, focus: Bool = true) {
        let position = max(0, min(index, document.children.count))
        insertBlock(newBlock, at: DropPath(parent: nil, position: position), focus: focus)
    }

    /// Tree-aware insert (pinch-open, anywhere in the visible-row stack).
    func insertBlock(_ newBlock: Block, at path: DropPath, focus: Bool = true) {
        mutate("Insert Block") {
            document.insertSubtree(newBlock, at: path)
        }
        if focus {
            transferFocus(to: .editor(newBlock.id, initialCursor: nil))
        }
    }

    /// Pick a sensible block kind for a pinch-open insert. Continues
    /// list/quote runs by mirroring the neighbour's kind — above wins, otherwise
    /// below, otherwise paragraph.
    func smartInsertBlock(above: Block?, below: Block?) -> Block {
        if let kind = listLikeTemplate(from: above) { return kind }
        if let kind = listLikeTemplate(from: below) { return kind }
        return .paragraph(text: AttributedString())
    }

    /// If `block` is a list-like row (bullet/numbered/todo/quote), return a
    /// fresh empty block of the same kind. Tree-depth follows from where the
    /// caller inserts; no per-block indent to copy.
    private func listLikeTemplate(from block: Block?) -> Block? {
        guard let block else { return nil }
        switch block.kind {
        case .bullet:
            return .bullet(text: AttributedString())
        case .numbered:
            return .numbered(text: AttributedString())
        case .todo:
            return .todo(text: AttributedString(), done: false)
        case .quote:
            return .quote(text: AttributedString())
        default:
            return nil
        }
    }


    private func instantiateTemplateButton(blockID: BlockID) {
        guard let block = document.find(blockID),
              case .templateButton = block.kind else { return }
        let body = block.children
        guard !body.isEmpty else { return }

        // Instantiate by appending fresh-id copies of the template's body as
        // siblings AFTER the template-button itself, at the same depth.
        let copies = body.map { $0.withFreshIDs() }
        let parentID = document.parent(of: blockID)
        let siblings: [Block] = parentID.flatMap(document.find)?.children ?? document.children
        guard let myIndex = siblings.firstIndex(where: { $0.id == blockID }) else { return }
        mutate("Insert Template") {
            document.insertSubtrees(copies, at: DropPath(parent: parentID, position: myIndex + 1))
        }
        if let first = copies.first {
            transferFocus(to: .nav(cursor: first.id))
        }
    }


    private func handleTapBelowRows(at point: CGPoint) {
        guard state.editingBlock == nil else { return }
        // Visible-flat last block: walk visible-flat in reverse to find a row
        // with a known frame. Tap-below-rows always appends at the document
        // root, so we use top-level children's count.
        let visibleLast = lastVisibleBlock()
        guard let lastBlock = visibleLast, let frame = rowFrames[lastBlock.id] else {
            insertParagraph(at: document.children.count)
            return
        }
        guard point.y > frame.maxY + 12 else { return }
        insertParagraph(at: document.children.count)
    }

    private func lastVisibleBlock() -> Block? {
        let hidden = hiddenBlockIDs(in: document.children)
        var lastVisible: Block?
        document.walk { block, _, _ in
            if !hidden.contains(block.id) { lastVisible = block }
        }
        return lastVisible
    }

    func showActionToast(_ message: String) {
        state.actionToast = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if state.actionToast == message {
                state.actionToast = nil
            }
        }
    }

    private func isPageTitleBlock(_ block: Block, snapshot: [Block]) -> Bool {
        guard case .heading(.h1, _) = block.kind else { return false }
        guard let first = document.children.first else { return false }
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

        if press.key == KeyEquivalent("b"), modifiers.contains(.command), !modifiers.contains(.shift) {
            return toggleBoldOnSelection() ? .handled : .ignored
        }

        if press.key == KeyEquivalent("i"), modifiers.contains(.command), !modifiers.contains(.shift) {
            return toggleItalicOnSelection() ? .handled : .ignored
        }

        if press.key == KeyEquivalent("/"), modifiers.contains(.command) {
            guard let id = topSelectedBlockID() else { return .ignored }
            actionSheet = BlockActionSheet(id: id)
            return .handled
        }

        if press.key == .return, modifiers.contains(.command) {
            return createEmptySiblingAndEdit() ? .handled : .ignored
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
                transferFocus(to: .editor(id, initialCursor: nil))
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
    /// doesn't equality-check. Snapshots the document tree before the change, runs
    /// the change, then registers the previous snapshot as the undo. Redo is
    /// re-registered by the apply closure during `isUndoing`.
    func mutate(_ name: String, _ change: () -> Void) {
        let before = document.snapshot()
        change()
        // Re-apply heading containment after every structural mutation. This
        // is what makes "Enter at end of heading creates a paragraph INSIDE
        // the heading" work — the split inserts a sibling, and refold moves
        // it under the heading. Idempotent on already-valid trees.
        document.enforceHeadingContainment()
        undoController.register(before, name: name)
        onEdited()
    }

    private func wireEditorCommands() {
        editorCommands.openBlockActionMenu = {
            guard let id = topSelectedBlockID() else { return }
            actionSheet = BlockActionSheet(id: id)
        }
        editorCommands.openMoveTo = {
            guard let id = topSelectedBlockID() else { return }
            let targetIDs = menuTargetIDs(anchorID: id)
            onRequestMoveDestination(targetIDs) { picked in
                guard let picked else { return }
                moveBlocks(ids: targetIDs, intoSubpagePath: picked)
            }
        }
        editorCommands.indent = {
            #if os(macOS)
            // In edit mode, the active text view's keyDown commits live text before
            // calling the same `changeIndent` helper; the menu path skips keyDown,
            // so do the commit ourselves before changing the model.
            if let view = NSApp.keyWindow?.firstResponder as? ContainedTextView,
               let bid = state.editingBlock {
                view.coordinator?.commitLiveText(view)
                _ = changeIndent(bid, by: +1)
                return
            }
            #endif
            indentSelection(by: 1)
        }
        editorCommands.outdent = {
            #if os(macOS)
            if let view = NSApp.keyWindow?.firstResponder as? ContainedTextView,
               let bid = state.editingBlock {
                view.coordinator?.commitLiveText(view)
                _ = changeIndent(bid, by: -1)
                return
            }
            #endif
            indentSelection(by: -1)
        }
        editorCommands.toggleLinkOrSubpage = {
            guard let id = state.cursor, state.selection.count == 1 else { return }
            _ = convertBlockToSubpage(blockID: id, preferredTitle: nil)
        }
        editorCommands.toggleInlineMark = { mark in
            #if os(macOS)
            if let view = NSApp.keyWindow?.firstResponder as? ContainedTextView {
                view.toggleInlineMark(mark)
                return
            }
            #endif
            switch mark {
            case .bold: _ = toggleBoldOnSelection()
            case .italic: _ = toggleItalicOnSelection()
            case .strikethrough: _ = toggleStrikethroughOnSelection()
            case .code: break
            }
        }
        editorCommands.canIndent = {
            // Use the editing block when one's mounted; otherwise use the
            // current selection's subtree-roots.
            if let bid = state.editingBlock {
                return document.canIndent(bid)
            }
            let roots = document.selectionSubtreeRoots(state.selection)
            return !roots.isEmpty && roots.allSatisfy { document.canIndent($0) }
        }
        editorCommands.canOutdent = {
            if let bid = state.editingBlock {
                return document.canOutdent(bid)
            }
            let roots = document.selectionSubtreeRoots(state.selection)
            return !roots.isEmpty && roots.allSatisfy { document.canOutdent($0) }
        }
    }

    /// Install the closure that the undo controller calls on Cmd-Z (and on redo).
    /// Restores the document tree and fixes up cursor/selection against the new
    /// block set. Re-registers the inverse so redo works.
    private func installUndoApply() {
        undoController.apply = { newBlocks in
            let beforeRedo = document.snapshot()
            document.restore(newBlocks)

            // Validate cursor/selection/edit-mode against the new tree — drops
            // invalid IDs from the navigating selection, falls back to nav mode
            // if the editing block disappeared.
            var validIDs: Set<BlockID> = []
            document.walk { block, _, _ in validIDs.insert(block.id) }
            state.revalidate(against: validIDs, fallbackCursor: document.children.first?.id)

            // Re-register inverse — when this runs during isUndoing, UndoManager pushes
            // it to the redo stack; during isRedoing, it goes back on the undo stack.
            undoController.register(beforeRedo, name: undoController.undoManager.undoActionName)
            onEdited()
        }
        undoController.applyTextChange = { blockID, oldText in
            guard let block = document.find(blockID) else { return }
            let beforeRedoText = block.text
            document.setText(blockID, oldText)
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

    /// Where focus should land. Both cases are model-shaped — they describe what the
    /// next `state.mode` should be. The actual SwiftUI focus state (`pageFocused`,
    /// `editorFocused`) and AppKit first-responder updates are derived from the
    /// resulting mode change in `handleModeChange`, so callers never write focus
    /// state directly.
    enum FocusTarget {
        case editor(BlockID, initialCursor: InitialCursorTarget?)
        case nav(cursor: BlockID?)
    }

    /// Single named operation for any focus hand-off between nav mode and an editor
    /// (or vice versa). The canonical primitive — call sites name a target and let
    /// the helper handle the order of operations. Synchronously commits any active
    /// editor's live text, mutates `state.mode`, and lets `.onChange(of: state.mode)`
    /// (→ `handleModeChange`) derive the SwiftUI/AppKit focus update.
    func transferFocus(to target: FocusTarget) {
        // Commit in-flight editor text into the model before mutating mode. The state
        // change unmounts the active BlockTextEditor; a binding write during teardown
        // doesn't reliably reach the freshly-rendered read-only Text — see
        // `commitActiveEditor`.
        undoController.commitActiveEditor?()

        switch target {
        case .editor(let id, let initialCursor):
            // Soft lookup: only redirect to nav on POSITIVE confirmation that the
            // block is non-editable. On absence we assume editable and proceed.
            // SwiftUI snapshots `@Binding<Document>` at last view-render time and
            // doesn't re-call the host's `get` within the same event handler, so
            // a block that was just inserted via `mutate(...)` won't appear in
            // `document.blocks` until SwiftUI re-renders. A hard guard here would
            // silently bail for that exact (common) case — Cmd+Return creating a
            // new row was the canonical bug.
            if let block = document.find(id) {
                switch block.kind {
                case .code, .divider, .subpage:
                    transferFocus(to: .nav(cursor: id))
                    return
                default:
                    break
                }
            }
            state.enterEditMode(on: id, initialCursor: initialCursor)

        case .nav(let cursor):
            state.exitEditModeWithoutCursor()
            // Same soft-lookup tolerance: trust the caller. `state.revalidate` cleans
            // up dangling cursor IDs against the current block set on undo/redo.
            if let cursor {
                state.setCursor(cursor)
            }
        }
    }

    /// Single source of truth for keeping SwiftUI focus, AppKit first responder, and
    /// the host's `onBlur` callback in sync with `state.mode`. Driven from
    /// `.onChange(of: state.mode)` so any path that mutates mode (clicks, key
    /// handlers, undo/redo, …) gets focus right automatically — no caller has to
    /// remember to flip `pageFocused`.
    func handleModeChange(from oldMode: Mode, to newMode: Mode) {
        let wasEditing: Bool = { if case .editing = oldMode { return true } else { return false } }()

        switch newMode {
        case .editing(let id, _):
            editorFocused = id
            pageFocused = false
            #if os(macOS)
            // Synchronous AppKit grab if the NSTextView is already mounted (e.g. when
            // re-focusing via Esc → click; or transferring between editors). When the
            // row hasn't mounted yet (new-block insertion), this is a no-op and the
            // NSTextView's `viewDidMoveToWindow` `wantsFocus` async path takes over.
            macActiveTextView.makeFirstResponder(for: id)
            #endif
        case .navigating:
            editorFocused = nil
            // Only re-grab page focus on real edit→nav transitions. .onChange fires on
            // intra-nav selection changes too (cursor moves, selection extends);
            // re-grabbing every time would steal focus from menus and sheets.
            if wasEditing {
                forcePageFocusGrab()
                onBlur()
            }
        }
    }

    /// Force SwiftUI to re-assert focus on the page VStack via a `false → true` flip
    /// on the next runloop. A same-value setter is a no-op in SwiftUI focus state, so
    /// this is the only way to reliably re-grab page focus after edit mode releases it
    /// (or on first appear).
    private func forcePageFocusGrab() {
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
        guard let block = document.find(id),
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
        guard let cursorBlock = document.find(id) else { return false }

        if isSectionExpanded(cursorBlock) {
            withAnimation(.easeInOut(duration: 0.15)) {
                collapseSection(cursorBlock)
            }
            return true
        }

        guard let parentID = enclosingCollapsibleSectionID(forBlockID: id),
              let parent = document.find(parentID) else { return false }
        withAnimation(.easeInOut(duration: 0.15)) {
            collapseSection(parent)
        }
        setCursor(parentID)
        return true
    }

    /// Toggle strikethrough across every text-bearing block the user has explicitly
    /// selected — parent rows only, never the implicit section children. If all of them
    /// are already fully struck, remove strikethrough; otherwise add it uniformly. Skips
    /// blocks without an `AttributedString` body (code/divider/subpage) and template
    /// buttons (whose `withText` flattens formatting). Returns `true` if it acted.
    private func toggleStrikethroughOnSelection() -> Bool {
        toggleInlineMarkOnSelection(
            attribute: InlineAttributes.StrikethroughAttribute.self,
            setLabel: "Strikethrough",
            clearLabel: "Remove Strikethrough"
        )
    }

    /// Toggle bold across every text-bearing block the user has explicitly selected.
    /// Parent-only — does not expand to section children. See
    /// `toggleStrikethroughOnSelection` for the shared semantics.
    private func toggleBoldOnSelection() -> Bool {
        toggleInlineMarkOnSelection(
            attribute: InlineAttributes.BoldAttribute.self,
            setLabel: "Bold",
            clearLabel: "Remove Bold"
        )
    }

    /// Toggle italic across every text-bearing block the user has explicitly selected.
    /// Parent-only — does not expand to section children.
    private func toggleItalicOnSelection() -> Bool {
        toggleInlineMarkOnSelection(
            attribute: InlineAttributes.ItalicAttribute.self,
            setLabel: "Italic",
            clearLabel: "Remove Italic"
        )
    }

    private func toggleInlineMarkOnSelection<K: AttributedStringKey>(
        attribute: K.Type,
        setLabel: String,
        clearLabel: String
    ) -> Bool where K.Value == Bool {
        let targetIDs = state.selection.compactMap { id -> BlockID? in
            guard let block = document.find(id) else { return nil }
            switch block.kind {
            case .paragraph, .heading, .bullet, .numbered, .todo, .quote, .toggle:
                return id
            case .templateButton, .code, .divider, .subpage, .image:
                return nil
            }
        }
        guard !targetIDs.isEmpty else { return false }

        var sawAnyText = false
        var allMarked = true
        for id in targetIDs {
            guard let block = document.find(id) else { continue }
            let text = block.text
            if text.runs.isEmpty { continue }
            sawAnyText = true
            for run in text.runs {
                if run[K.self] != true {
                    allMarked = false
                    break
                }
            }
            if !allMarked { break }
        }
        guard sawAnyText else { return false }
        let newValue = !allMarked

        mutate(newValue ? setLabel : clearLabel) {
            for id in targetIDs {
                document.mutate(id) { block in
                    var text = block.text
                    let range = text.startIndex..<text.endIndex
                    if range.lowerBound < range.upperBound {
                        text[range][K.self] = newValue
                        block = block.withText(text)
                    }
                }
            }
        }
        return true
    }

    /// If every block in the current selection is a `.todo`, set their `done` state to
    /// `done` (skipping any that already match). Returns `true` if it acted.
    private func setTodoDoneOnSelection(_ done: Bool) -> Bool {
        let targetIDs = Array(state.selection)
        guard !targetIDs.isEmpty else { return false }
        let allTodos = targetIDs.allSatisfy { id in
            if let block = document.find(id), case .todo = block.kind { return true }
            return false
        }
        guard allTodos else { return false }
        let needsChange = targetIDs.contains { id in
            if let block = document.find(id), case .todo(_, let currentDone) = block.kind {
                return currentDone != done
            }
            return false
        }
        guard needsChange else { return true }
        mutate(done ? "Check" : "Uncheck") {
            for id in targetIDs {
                document.mutate(id) { block in
                    if case .todo(let text, _) = block.kind {
                        block.kind = .todo(text: text, done: done)
                    }
                }
            }
        }
        return true
    }

    /// Innermost collapsible-section ancestor of `blockID`. Walks the parent
    /// chain and returns the first toggle/templateButton encountered.
    private func enclosingCollapsibleSectionID(forBlockID blockID: BlockID) -> BlockID? {
        var current: BlockID? = document.parent(of: blockID)
        while let id = current {
            if let block = document.find(id), isCollapsibleSection(block) {
                return id
            }
            current = document.parent(of: id)
        }
        return nil
    }

    /// IDs of blocks that should be hidden from rendering and from arrow-nav because they
    /// live inside a collapsed section. The section row itself is always visible; only its
    /// body (subsequent blocks at greater indent) is hidden when collapsed.
    func hiddenBlockIDs(in blocks: [Block]) -> Set<BlockID> {
        var hidden: Set<BlockID> = []
        collectHidden(in: blocks, into: &hidden)
        return hidden
    }

    private func collectHidden(in blocks: [Block], into hidden: inout Set<BlockID>) {
        for block in blocks {
            if isCollapsedSection(block) {
                // The container itself stays visible — only its descendants
                // hide. Nested expanded toggles inside a closed parent stay
                // hidden because we never recurse past the closed boundary.
                for child in block.children {
                    insertSubtree(child, into: &hidden)
                }
            } else {
                collectHidden(in: block.children, into: &hidden)
            }
        }
    }

    private func insertSubtree(_ block: Block, into hidden: inout Set<BlockID>) {
        hidden.insert(block.id)
        for child in block.children {
            insertSubtree(child, into: &hidden)
        }
    }

    private func isCollapsibleSection(_ block: Block) -> Bool {
        switch block.kind {
        case .toggle, .templateButton:
            return true
        default:
            return false
        }
    }

    func isCollapsedSection(_ block: Block) -> Bool {
        switch block.kind {
        case .toggle:
            return !state.expandedToggles.contains(block.id)
        case .templateButton:
            return !state.expandedTemplates.contains(block.id)
        default:
            return false
        }
    }

    private func isSectionExpanded(_ block: Block) -> Bool {
        switch block.kind {
        case .toggle:
            return state.expandedToggles.contains(block.id)
        case .templateButton:
            return state.expandedTemplates.contains(block.id)
        default:
            return false
        }
    }

    private func expandSection(_ block: Block) {
        switch block.kind {
        case .toggle:
            state.expandedToggles.insert(block.id)
        case .templateButton:
            state.expandedTemplates.insert(block.id)
        default:
            break
        }
    }

    private func collapseSection(_ block: Block) {
        switch block.kind {
        case .toggle:
            state.expandedToggles.remove(block.id)
        case .templateButton:
            state.expandedTemplates.remove(block.id)
        default:
            break
        }
    }

    /// Expand any closed toggle/templateButton ancestors so every id in `ids` is
    /// visible. Called after nav-mode structural mutations (Tab, Option-arrows,
    /// Cmd-/ Indent) that can land a selected block inside a collapsed container —
    /// without this, the selection is preserved by id but invisible to the user.
    /// Mirrors the auto-expand the drag-drop `asChildrenOf` paths already do.
    /// Iterates: each pass expands one closed ancestor per still-hidden id; nested
    /// containers converge in O(depth).
    func revealHiddenBlocks(_ ids: Set<BlockID>) {
        guard !ids.isEmpty else { return }
        var safety = 16
        while safety > 0 {
            safety -= 1
            let hidden = hiddenBlockIDs(in: document.children)
            var didExpand = false
            for id in ids where hidden.contains(id) {
                // Walk up the parent chain looking for the closest collapsed
                // collapsible ancestor.
                var ancestorID = document.parent(of: id)
                while let aid = ancestorID {
                    if let block = document.find(aid),
                       isCollapsibleSection(block),
                       !isSectionExpanded(block) {
                        expandSection(block)
                        didExpand = true
                        break
                    }
                    ancestorID = document.parent(of: aid)
                }
            }
            if !didExpand { break }
        }
    }

    /// One-pass visible-row layout precompute used by `body`. Walks the tree
    /// in preorder, skipping any subtree under a closed toggle/templateButton,
    /// and emits one `VisibleRow` per visible block. Replaces the old flat-
    /// snapshot indexing scheme.
    struct VisibleRow {
        let block: Block
        let depth: Int
        let parentID: BlockID?
        let preorderIndex: Int
    }

    func computeVisibleLayout(snapshot: [Block], hidden: Set<BlockID>)
        -> (rows: [VisibleRow], prevVisible: [Block?], prevDepths: [Int])
    {
        var rows: [VisibleRow] = []
        var prevVisible: [Block?] = []
        var prevDepths: [Int] = []
        rows.reserveCapacity(snapshot.count)
        prevVisible.reserveCapacity(snapshot.count)
        prevDepths.reserveCapacity(snapshot.count)
        var lastVisible: Block? = nil
        var lastDepth: Int = 0
        var preorderCounter = 0
        appendVisible(in: document.children, depth: 0, parentID: nil, hidden: hidden,
                      rows: &rows, prevVisible: &prevVisible, prevDepths: &prevDepths,
                      lastVisible: &lastVisible, lastDepth: &lastDepth, preorderCounter: &preorderCounter)
        return (rows, prevVisible, prevDepths)
    }

    private func appendVisible(
        in blocks: [Block],
        depth: Int,
        parentID: BlockID?,
        hidden: Set<BlockID>,
        rows: inout [VisibleRow],
        prevVisible: inout [Block?],
        prevDepths: inout [Int],
        lastVisible: inout Block?,
        lastDepth: inout Int,
        preorderCounter: inout Int
    ) {
        for block in blocks {
            let myIndex = preorderCounter
            preorderCounter += 1
            // Block visibility: hidden if any ancestor is collapsed. The
            // `hidden` set is populated by `hiddenBlockIDs` which marks every
            // descendant of a closed container.
            if !hidden.contains(block.id) {
                rows.append(VisibleRow(block: block, depth: depth, parentID: parentID, preorderIndex: myIndex))
                prevVisible.append(lastVisible)
                prevDepths.append(lastDepth)
                lastVisible = block
                lastDepth = depth
            }
            // Recurse into children only if this block is not a collapsed
            // container — descendants under a closed toggle don't render.
            // Heading containers don't bump depth: their children render
            // flush with the heading itself (Notion-style), so a paragraph
            // under an H1 sits at the same horizontal position as the H1.
            if !isCollapsedSection(block) {
                let childDepth = block.isHeading ? depth : depth + 1
                appendVisible(in: block.children, depth: childDepth, parentID: block.id, hidden: hidden,
                              rows: &rows, prevVisible: &prevVisible, prevDepths: &prevDepths,
                              lastVisible: &lastVisible, lastDepth: &lastDepth, preorderCounter: &preorderCounter)
            } else {
                // Still bump the preorder counter for the hidden subtree so
                // ids and indices align with the legacy flat representation.
                bumpPreorder(in: block.children, counter: &preorderCounter)
            }
        }
    }

    private func bumpPreorder(in blocks: [Block], counter: inout Int) {
        for block in blocks {
            counter += 1
            bumpPreorder(in: block.children, counter: &counter)
        }
    }

    /// Preorder flat view of every block in the tree. Cheap derived
    /// representation used by keyboard cursor nav. NOT a snapshot — caller
    /// reads it once per event.
    private func preorderFlat() -> [Block] {
        var out: [Block] = []
        document.walk { block, _, _ in out.append(block) }
        return out
    }

    /// Move the cursor by `delta` rows; collapse to a single-block selection at the new cursor.
    /// Skips blocks hidden inside collapsed toggles.
    private func moveCursor(by delta: Int) {
        let blocks = preorderFlat()
        guard !blocks.isEmpty else { return }
        let hidden = hiddenBlockIDs(in: document.children)
        let visible = blocks.filter { !hidden.contains($0.id) }
        guard !visible.isEmpty else { return }
        let currentIndex = state.cursor.flatMap { id in visible.firstIndex(where: { $0.id == id }) } ?? 0
        let nextIndex = max(0, min(visible.count - 1, currentIndex + delta))
        setCursor(visible[nextIndex].id)
    }

    /// Extend the selection in the direction of `delta`. The anchor stays put; the cursor
    /// moves by outline sections so extending over a parent consumes its descendants as
    /// real selection.
    private func extendSelection(by delta: Int) {
        let blocks = preorderFlat()
        guard !blocks.isEmpty else { return }

        let initialAnchor = state.anchor ?? state.cursor ?? blocks.first?.id
        let initialCursor = state.cursor ?? initialAnchor

        guard let anchorID = initialAnchor, let cursorID = initialCursor,
              let anchorIndex = blocks.firstIndex(where: { $0.id == anchorID }),
              let cursorIndex = blocks.firstIndex(where: { $0.id == cursorID }) else { return }

        let nextIndex = outlineSelectionStep(from: cursorIndex, anchoredAt: anchorIndex, by: delta, blocks: blocks)
        let newCursor = blocks[nextIndex].id

        let lo = min(anchorIndex, nextIndex)
        let hi = max(anchorIndex, nextIndex)
        let newSelection = Set(blocks[lo...hi].map { $0.id })
        state.setNavSelection(blocks: newSelection, anchor: anchorID, cursor: newCursor)
    }

    private func outlineSelectionStep(from cursorIndex: Int, anchoredAt anchorIndex: Int, by delta: Int, blocks: [Block]) -> Int {
        guard !blocks.isEmpty else { return cursorIndex }
        // Subtree size for a block (number of descendants in preorder).
        func subtreeEnd(of blockID: BlockID, startingAt i: Int) -> Int {
            guard let block = document.find(blockID) else { return i + 1 }
            var size = 0
            countDescendants(block, into: &size)
            return i + 1 + size
        }

        if delta > 0 {
            if cursorIndex < anchorIndex {
                let end = subtreeEnd(of: blocks[cursorIndex].id, startingAt: cursorIndex)
                if end <= anchorIndex { return end }
                return min(anchorIndex, cursorIndex + 1)
            }
            let end = subtreeEnd(of: blocks[cursorIndex].id, startingAt: cursorIndex)
            if end > cursorIndex + 1 {
                guard end < blocks.count else { return cursorIndex }
                return end
            }
            return min(blocks.count - 1, cursorIndex + 1)
        }

        if delta < 0 {
            if cursorIndex > anchorIndex {
                let anchorEnd = subtreeEnd(of: blocks[anchorIndex].id, startingAt: anchorIndex)
                if (anchorIndex..<anchorEnd).contains(cursorIndex) {
                    return anchorIndex
                }
                return max(anchorIndex, cursorIndex - 1)
            }
            // Step up to the previous SIBLING (not just a previous preorder-
            // adjacent block, which might be a parent's last descendant).
            let cursorBlockID = blocks[cursorIndex].id
            let parentID = document.parent(of: cursorBlockID)
            let siblings: [Block] = parentID.flatMap(document.find)?.children ?? document.children
            if let posInParent = siblings.firstIndex(where: { $0.id == cursorBlockID }), posInParent > 0 {
                let prevSiblingID = siblings[posInParent - 1].id
                if let prevIdx = blocks.firstIndex(where: { $0.id == prevSiblingID }) {
                    return prevIdx
                }
            }
            return max(0, cursorIndex - 1)
        }

        return cursorIndex
    }

    private func countDescendants(_ block: Block, into out: inout Int) {
        for child in block.children {
            out += 1
            countDescendants(child, into: &out)
        }
    }

    private func effectiveSelectedIDs() -> Set<BlockID> {
        Set(effectiveSelectedIDsInDocumentOrder())
    }

    /// Selected blocks plus every descendant of each, in document order.
    /// Used by drag/copy/delete to expand a sparse selection into the full
    /// covered subtree.
    func effectiveSelectedIDsInDocumentOrder() -> [BlockID] {
        var out: [BlockID] = []
        var seen: Set<BlockID> = []
        for id in state.selection {
            guard let block = document.find(id) else { continue }
            collectPreorderIDs(block, into: &out, seen: &seen)
        }
        // Sort by document order.
        out.sort { (a, b) in
            (document.documentOrder(of: a) ?? .max) < (document.documentOrder(of: b) ?? .max)
        }
        return out
    }

    func collectPreorderIDs(_ block: Block, into out: inout [BlockID], seen: inout Set<BlockID>) {
        if seen.insert(block.id).inserted {
            out.append(block.id)
        }
        for child in block.children {
            collectPreorderIDs(child, into: &out, seen: &seen)
        }
    }

    // MARK: - Selection-wide operations

    /// Move the contiguous selection up or down across outline siblings. Selected
    /// parents carry their descendants, so top-level blocks hop over whole sections.
    /// Tree analog: requires every selected subtree-root to share one parent;
    /// otherwise no-op.
    private func moveSelectionInDocument(by delta: Int) {
        let roots = document.selectionSubtreeRoots(state.selection)
        guard !roots.isEmpty else { return }
        // Snapshot pre-mutation so `mutate` registers an undo iff we actually
        // changed something.
        let canMove = document.slideSiblings(Set(roots), by: delta)
        guard canMove else { return }
        // Roll back the move so `mutate` can record it as one undo entry; then
        // re-apply inside the mutation closure.
        // (`slideSiblings` already mutated; treat the trial as the mutation.)
        // Since slideSiblings has been called above, the doc is already moved.
        // Register the inverse by snapshotting the pre-move state — but we
        // already lost that. Reconstruct via inverse direction.
        _ = document.slideSiblings(Set(roots), by: -delta)
        mutate("Move Block") {
            _ = document.slideSiblings(Set(roots), by: delta)
        }
        revealHiddenBlocks(state.selection)
    }

    /// Delete every block in the current selection. No-op if the selection
    /// covers every top-level block.
    private func deleteSelection() {
        deleteBlocks(ids: Array(state.selection), actionName: "Delete")
    }

    private func deleteBlocks(ids: [BlockID], actionName: String) {
        let roots = document.selectionSubtreeRoots(Set(ids))
        guard !roots.isEmpty else { return }
        // Don't allow deleting the entire top-level tree.
        let coveredRoots = roots.filter { document.parent(of: $0) == nil }
        if coveredRoots.count >= document.children.count, document.children.count > 0 {
            return
        }

        // Capture the removed subtrees flat-preorder (for `onRecordBlockDeletion`).
        var removedFlat: [Block] = []
        var indicesFlat: [Int] = []
        for id in roots {
            guard let order = document.documentOrder(of: id) else { continue }
            indicesFlat.append(order)
            if let block = document.find(id) {
                appendPreorder(block, into: &removedFlat)
            }
        }
        onRecordBlockDeletion(indicesFlat, removedFlat, actionName)

        let cursorTarget = nearestCursorAfterRemoval(of: roots)
        mutate(actionName) {
            // Bottom-up by depth to avoid stranding a child whose parent was
            // already removed.
            let ordered = roots.sorted { (a, b) -> Bool in
                let da = (document.path(to: a)?.count ?? 0)
                let db = (document.path(to: b)?.count ?? 0)
                return da > db
            }
            for id in ordered {
                document.removeSubtree(id)
            }
        }

        if let id = cursorTarget {
            setCursor(id)
        }
    }

    /// Walk a subtree in preorder and append every node to `out`.
    private func appendPreorder(_ block: Block, into out: inout [Block]) {
        out.append(block)
        for child in block.children {
            appendPreorder(child, into: &out)
        }
    }

    /// Pick a cursor target after removing the given subtree-roots. Tries the
    /// preorder-predecessor of the first root; falls back to the first
    /// remaining top-level block.
    private func nearestCursorAfterRemoval(of roots: [BlockID]) -> BlockID? {
        guard let first = roots.first else { return nil }
        if let predecessor = document.preorderPredecessor(of: first) {
            return predecessor
        }
        return document.children.first(where: { !roots.contains($0.id) })?.id
    }

    private func indentByOne(blockID: BlockID) {
        _ = changeIndent(blockID, by: 1)
    }

    /// Apply Tab / Shift-Tab indent change to the effective selection. Each
    /// subtree-root indents/outdents independently — selection across parents
    /// is allowed; ops that aren't valid for some roots no-op for those.
    private func indentSelection(by delta: Int) {
        let roots = document.selectionSubtreeRoots(state.selection)
        guard !roots.isEmpty else { return }
        guard canChangeIndent(ids: roots, by: delta) else { return }
        mutate(delta > 0 ? "Indent" : "Outdent") {
            for id in roots {
                if delta > 0 {
                    document.indent(id)
                } else if delta < 0 {
                    document.outdent(id)
                }
            }
        }
        revealHiddenBlocks(state.selection)
    }

    private func copySelectionToPasteboard() -> Bool {
        copyBlocksToPasteboard(ids: state.selection)
    }

    /// Cut: copy the selection to the pasteboard, then delete it as a single undo entry.
    /// Mirrors the `deleteSelection` guard against deleting the entire document.
    private func cutSelectionToPasteboard() -> Bool {
        let roots = document.selectionSubtreeRoots(state.selection)
        guard !roots.isEmpty else { return false }
        // Don't allow cutting every top-level block.
        let topLevelRoots = roots.filter { document.parent(of: $0) == nil }
        if topLevelRoots.count >= document.children.count, document.children.count > 0 {
            return false
        }
        guard copyBlocksToPasteboard(ids: state.selection) else { return false }

        let cursorTarget = nearestCursorAfterRemoval(of: roots)
        mutate("Cut") {
            let ordered = roots.sorted { (a, b) -> Bool in
                let da = (document.path(to: a)?.count ?? 0)
                let db = (document.path(to: b)?.count ?? 0)
                return da > db
            }
            for id in ordered {
                document.removeSubtree(id)
            }
        }

        if let id = cursorTarget {
            setCursor(id)
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
        // Image-on-pasteboard takes precedence over text — same rule as the
        // editor's `paste(_:)` override.
        #if os(macOS)
        let images = readPasteboardImages(NSPasteboard.general)
        #else
        let images = readPasteboardImages(UIPasteboard.general)
        #endif
        if !images.isEmpty {
            let paths = onSaveImages(images)
            guard !paths.isEmpty else { return true }
            let blocks: [Block] = paths.map { .image(source: $0, alt: "") }
            return spliceParsedBlocksAfter(state.cursor, parsed: blocks, focusLast: false)
        }

        let pasted: String
        #if os(macOS)
        guard let str = NSPasteboard.general.string(forType: .string) else { return false }
        pasted = str
        #else
        guard let str = UIPasteboard.general.string else { return false }
        pasted = str
        #endif
        guard let parsed = parseBlocksFromPasteboard(pasted), !parsed.isEmpty else { return false }
        return spliceParsedBlocksAfter(state.cursor, parsed: parsed, focusLast: false)
    }

    /// Splice host-parsed blocks into the document after `anchorID` (or at the end of
    /// the document if `anchorID == nil` / not found). Indent + insertion-point logic:
    /// if the anchor has indent-children, pasted blocks land after the last child as
    /// siblings of the children (indent + 1); otherwise they land immediately below
    /// the anchor at the anchor's own indent. The host is expected to return blocks
    /// normalized to indent 0; we shift each by the chosen base. Returns true and
    /// either selects (`focusLast == false`, nav-mode) or enters edit mode on
    /// (`focusLast == true`, edit-mode paste) the last spliced block.
    @discardableResult
    private func spliceParsedBlocksAfter(_ anchorID: BlockID?, parsed: [Block], focusLast: Bool) -> Bool {
        guard !parsed.isEmpty else { return false }

        // Tree analog of "after the anchor's section": if the anchor has
        // children, splice as the FIRST CHILDREN of the anchor; otherwise
        // splice as the next siblings of the anchor under its parent.
        let dropPath: DropPath
        if let anchorID, let anchor = document.find(anchorID) {
            if !anchor.children.isEmpty {
                dropPath = DropPath(parent: anchorID, position: 0)
            } else {
                let parentID = document.parent(of: anchorID)
                let siblings: [Block] = parentID.flatMap(document.find)?.children ?? document.children
                let i = siblings.firstIndex(where: { $0.id == anchorID }) ?? siblings.count - 1
                dropPath = DropPath(parent: parentID, position: i + 1)
            }
        } else {
            dropPath = DropPath(parent: nil, position: document.children.count)
        }

        mutate("Paste") {
            document.insertSubtrees(parsed, at: dropPath)
        }

        if let last = parsed.last {
            if focusLast {
                DispatchQueue.main.async { self.transferFocus(to: .editor(last.id, initialCursor: nil)) }
            } else {
                setCursor(last.id)
            }
        }
        return true
    }

    func copyBlocksToPasteboard(ids: some Sequence<BlockID>) -> Bool {
        let roots = document.selectionSubtreeRoots(Set(ids))
        guard !roots.isEmpty else { return false }
        let blocks = roots.compactMap { document.find($0) }
        let serialized = serializeBlocksForPasteboard(blocks)
        guard !serialized.isEmpty else { return false }

        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(serialized, forType: .string)
        #else
        UIPasteboard.general.string = serialized
        #endif
        return true
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
            transferFocus(to: .nav(cursor: state.editingBlock))
            return .handled
        case .cmdK(let preferredTitle):
            return convertBlockToSubpage(blockID: blockID, preferredTitle: preferredTitle)
        case .navigateBack:
            onNavigateBack()
            return .handled
        case .exitEditUp:
            transferFocus(to: .nav(cursor: state.editingBlock))
            DispatchQueue.main.async { moveCursor(by: -1) }
            return .handled
        case .exitEditDown:
            transferFocus(to: .nav(cursor: state.editingBlock))
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
        case .paste(let str):
            return handleEditorPaste(str, blockID: blockID)
        case .imagesPasted(let images):
            return handleEditorImagePaste(images, blockID: blockID)
        }
    }

    /// Persist pasted image bytes via the host, splice the resulting image
    /// blocks immediately below the row's section, and move focus to the last
    /// inserted image. If the host returns no paths (callback unset, or the
    /// host cancelled), we drop the paste — `.handled` either way so the
    /// platform text view doesn't ALSO try to paste a string fallback.
    private func handleEditorImagePaste(_ images: [PastedImage], blockID: BlockID) -> KeyPress.Result {
        guard !images.isEmpty else { return .handled }
        let paths = onSaveImages(images)
        guard !paths.isEmpty else { return .handled }
        let blocks: [Block] = paths.map { .image(source: $0, alt: "") }
        spliceParsedBlocksAfter(blockID, parsed: blocks, focusLast: false)
        return .handled
    }

    /// Decide what to do with a paste arriving from the active row's editor:
    /// - If parsing fails or returns empty, return `.ignored` so the platform
    ///   text view does its native paste of the raw string.
    /// - If parsing returns exactly one `.paragraph`, also return `.ignored`:
    ///   native paste preserves cursor position + typing-undo coalescing for
    ///   plain inline text. (Inline-mark interpretation of single-paragraph
    ///   markdown is a known follow-up.)
    /// - Otherwise (≥2 blocks, or a single non-paragraph block like `- foo`),
    ///   splice the parsed blocks immediately below the row's section and
    ///   move focus to the last one.
    private func handleEditorPaste(_ str: String, blockID: BlockID) -> KeyPress.Result {
        guard let parsed = parseBlocksFromPasteboard(str), !parsed.isEmpty else {
            return .ignored
        }
        if parsed.count == 1, case .paragraph = parsed[0].kind {
            return .ignored
        }
        spliceParsedBlocksAfter(blockID, parsed: parsed, focusLast: true)
        return .handled
    }


    private func splitBlock(_ blockID: BlockID, at cursorOffset: Int) -> KeyPress.Result {
        guard let block = document.find(blockID) else { return .ignored }
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

        // Empty + indented row: Return tries to outdent. If the outdent is
        // refused (e.g. parent is a heading — heading-containment forbids
        // outdent there), fall through to the convert-to-paragraph or split
        // path so the user gets SOMETHING useful instead of a no-op.
        if head.isEmpty, tail.isEmpty, document.parent(of: blockID) != nil {
            let result = changeIndent(blockID, by: -1)
            if result == .handled { return result }
        }

        // Enter at end of a block that has children: add a child instead of a
        // sibling between the parent and its first child. Two flavors:
        //   * Closed toggle/template — children are hidden, so insert a
        //     sibling AFTER the whole collapsed section instead.
        //   * Anything else with children — insert a new FIRST child of the
        //     same kind as the existing first child.
        if tail.isEmpty, !block.children.isEmpty {
            if isCollapsedSection(block) {
                let parentID = document.parent(of: blockID)
                let siblings: [Block] = parentID.flatMap(document.find)?.children ?? document.children
                let i = siblings.firstIndex(where: { $0.id == blockID }) ?? siblings.count - 1
                let newBlock = followUpBlock(after: block, withText: "")
                mutate("Split Block") {
                    document.insertSubtree(newBlock, at: DropPath(parent: parentID, position: i + 1))
                }
                transferFocus(to: .editor(newBlock.id, initialCursor: .offset(0)))
                return .handled
            } else {
                let firstChild = block.children[0]
                let newBlock = followUpBlock(after: firstChild, withText: "")
                mutate("Split Block") {
                    document.insertSubtree(newBlock, at: DropPath(parent: blockID, position: 0))
                }
                transferFocus(to: .editor(newBlock.id, initialCursor: .offset(0)))
                return .handled
            }
        }

        // Empty list item + Enter exits the list: convert to paragraph in place.
        // Reached only when the block has no children (handled above) and the
        // row is fully empty.
        if head.isEmpty && tail.isEmpty {
            switch block.kind {
            case .bullet, .numbered, .todo:
                mutate("Convert to Paragraph") {
                    document.mutate(blockID) { existing in
                        existing.kind = .paragraph(text: AttributedString())
                    }
                }
                return .handled
            default:
                break
            }
        }

        let newBlock = followUpBlock(after: block, withText: tail)
        let parentID = document.parent(of: blockID)
        let siblings: [Block] = parentID.flatMap(document.find)?.children ?? document.children
        let i = siblings.firstIndex(where: { $0.id == blockID }) ?? siblings.count - 1

        mutate("Split Block") {
            document.setText(blockID, AttributedString(head))
            document.insertSubtree(newBlock, at: DropPath(parent: parentID, position: i + 1))
        }
        transferFocus(to: .editor(newBlock.id, initialCursor: .offset(0)))
        return .handled
    }

    private func navigateIntoSubpage(_ blockID: BlockID) -> Bool {
        guard let block = document.find(blockID),
              case .subpage(_, let path) = block.kind else {
            return false
        }
        transferFocus(to: .nav(cursor: blockID))
        onSubpageTap(path)
        return true
    }


    /// Replace the block whose row's editor just fired an autotransform. The transform's
    /// `apply(to:)` returns the new block(s); we splice via `document.replace` and refocus
    /// on the block at `transform.focusReplacementIndex` (which is the fresh paragraph for
    /// divider/codeFence and the transformed block otherwise).
    private func applyAutotransform(_ transform: BlockTransform, remainingText: AttributedString, blockID: BlockID) {
        guard let source = document.find(blockID) else { return }
        let replacements = transform.apply(to: remainingText)
        guard !replacements.isEmpty else { return }
        // For `> ` (toggle) on a row with children, the new toggle inherits
        // the source's children as its body so they don't vanish.
        let firstReplacementWithChildren: [Block]
        if transform == .toggle, !source.children.isEmpty, var first = replacements.first {
            first.children = source.children
            firstReplacementWithChildren = [first] + replacements.dropFirst()
        } else {
            firstReplacementWithChildren = replacements
        }
        mutate("Format Block") {
            document.replaceSubtree(blockID, with: firstReplacementWithChildren)
        }
        if transform == .toggle {
            for replacement in firstReplacementWithChildren {
                if case .toggle = replacement.kind {
                    state.expandedToggles.insert(replacement.id)
                }
            }
        }
        let focusTarget = firstReplacementWithChildren[transform.focusReplacementIndex]
        DispatchQueue.main.async {
            switch focusTarget.kind {
            case .code, .divider, .subpage:
                transferFocus(to: .nav(cursor: focusTarget.id))
            default:
                transferFocus(to: .editor(focusTarget.id, initialCursor: nil))
            }
        }
    }

    /// Nav-mode Cmd+Return: create an empty sibling of the same kind directly
    /// after the selected block (or after its whole indent-section, so the new
    /// row doesn't get wedged between a parent and its children) and enter
    /// edit mode on it.
    private func createEmptySiblingAndEdit() -> Bool {
        guard let id = state.cursor, state.selection.count == 1 else { return false }
        guard let source = document.find(id) else { return false }
        let newBlock = followUpBlock(after: source, withText: "")
        // Tree analog of "after the source's section": if the source has
        // children, splice as the FIRST CHILD of source (so the new block is
        // visually adjacent and at one deeper level). Otherwise, splice as the
        // next sibling under the source's parent.
        let dropPath: DropPath
        if !source.children.isEmpty {
            dropPath = DropPath(parent: id, position: 0)
        } else {
            let parentID = document.parent(of: id)
            let siblings: [Block] = parentID.flatMap(document.find)?.children ?? document.children
            let i = siblings.firstIndex(where: { $0.id == id }) ?? siblings.count - 1
            dropPath = DropPath(parent: parentID, position: i + 1)
        }

        mutate("New Block") {
            document.insertSubtree(newBlock, at: dropPath)
        }
        transferFocus(to: .editor(newBlock.id, initialCursor: .offset(0)))
        return true
    }

    private func followUpBlock(after block: Block, withText text: String) -> Block {
        let attr = AttributedString(text)
        switch block.kind {
        case .bullet:
            return .bullet(text: attr)
        case .numbered:
            return .numbered(text: attr)
        case .todo:
            return .todo(text: attr, done: false)
        case .quote:
            return .quote(text: attr)
        case .heading, .paragraph, .toggle, .templateButton, .code, .divider, .subpage, .image:
            return .paragraph(text: attr)
        }
    }

    /// Handle backspace pressed with the cursor at offset 0 of a block. Three shapes:
    /// 1. Non-paragraph (bullet/numbered/todo/heading/quote/toggle) with any text →
    ///    convert to a paragraph at the same indent, preserving the text. Cursor
    ///    stays at offset 0 of the same row.
    /// 2. Empty paragraph → delete the row and focus the previous block (cursor at
    ///    end). No-op if there's nothing to focus.
    /// 3. Non-empty paragraph → merge its text into the previous text-bearing block
    ///    (paragraph/heading/bullet/numbered/todo/quote/toggle). Cursor lands at the
    ///    join point. If the previous block isn't text-bearing (code/divider/subpage/
    ///    templateButton) we ignore — the user can navigate up and delete it
    ///    explicitly.
    private func deleteEmptyBlock(_ blockID: BlockID) -> KeyPress.Result {
        guard let block = document.find(blockID) else { return .ignored }

        // Empty + nested row: backspace tries to outdent. If outdent is
        // refused (parent is a heading — heading-containment forbids it),
        // fall through to the convert-to-paragraph or merge path.
        if document.parent(of: blockID) != nil, String(block.text.characters).isEmpty {
            let result = changeIndent(blockID, by: -1)
            if result == .handled { return result }
        }

        let isParagraph: Bool = {
            if case .paragraph = block.kind { return true }
            return false
        }()

        if !isParagraph {
            // Convert to paragraph in place, preserving any text. The cursor stays at
            // offset 0 — if the editor re-mounts because the row layout changed, the
            // pending-cursor channel steers it back to 0 instead of seek-to-end.
            switch block.kind {
            case .bullet, .numbered, .todo, .heading, .quote, .toggle:
                let preservedText = block.text
                state.setPendingInitialCursor(.offset(0))
                mutate("Convert to Paragraph") {
                    document.mutate(blockID) { existing in
                        existing.kind = .paragraph(text: preservedText)
                    }
                }
                return .handled
            default:
                return .ignored
            }
        }

        let plain = String(block.text.characters)
        let previousID = document.preorderPredecessor(of: blockID)

        if plain.isEmpty {
            // Don't allow deleting the last top-level block.
            if document.children.count <= 1, document.parent(of: blockID) == nil {
                return .ignored
            }
            mutate("Delete Block") {
                document.removeSubtree(blockID)
            }
            if let previousID {
                transferFocus(to: .editor(previousID, initialCursor: nil))
            }
            return .handled
        }

        // Non-empty paragraph: merge into the previous text-bearing block.
        guard let previousID, let previous = document.find(previousID) else { return .ignored }
        switch previous.kind {
        case .paragraph, .heading, .bullet, .numbered, .todo, .quote, .toggle:
            break
        case .code, .divider, .subpage, .templateButton, .image:
            return .ignored
        }
        let previousLen = previous.text.characters.count
        var combined = previous.text
        combined.append(block.text)

        mutate("Merge Block") {
            document.setText(previousID, combined)
            document.removeSubtree(blockID)
        }
        transferFocus(to: .editor(previousID, initialCursor: .offset(previousLen)))
        return .handled
    }

    func changeIndent(_ blockID: BlockID, by delta: Int) -> KeyPress.Result {
        // Tree analog of indent/outdent: reparent to the previous sibling
        // (delta = +1) or to the next sibling of the parent (delta = -1).
        if delta > 0 {
            guard document.canIndent(blockID) else { return .ignored }
            mutate("Indent") {
                document.indent(blockID)
            }
        } else if delta < 0 {
            guard document.canOutdent(blockID) else { return .ignored }
            mutate("Outdent") {
                document.outdent(blockID)
            }
        } else {
            return .ignored
        }
        revealHiddenBlocks([blockID])
        return .handled
    }

    /// Multi-block indent/outdent validity. All-or-nothing: every subtree-root
    /// in `ids` must be permitted, otherwise the op is rejected.
    func canChangeIndent(ids: [BlockID], by delta: Int) -> Bool {
        guard !ids.isEmpty else { return false }
        let roots = document.selectionSubtreeRoots(Set(ids))
        if delta > 0 {
            return roots.allSatisfy { document.canIndent($0) }
        } else if delta < 0 {
            return roots.allSatisfy { document.canOutdent($0) }
        }
        return false
    }
}

