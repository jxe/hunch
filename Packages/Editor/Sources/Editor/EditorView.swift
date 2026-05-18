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
    public let document: Document
    /// Editor session state — selection, edit mode, gestures, hover, expanded
    /// toggles, drop targets. Owned by the host (typically `@State` in a parent
    /// view) so sibling UI can observe what the user is doing. Mutation flows
    /// through named methods inside the package; the host can read but not write.
    public var state: EditorState
    /// Host integration — file I/O, navigation, paste/copy serialization, etc.
    /// Held by reference (the protocol is class-bound) so this `EditorView`
    /// struct's identity stays stable across host re-renders, which is what
    /// lets `.equatable()` gating actually work for the row wrapper. See
    /// `EditorHost`.
    public let host: any EditorHost

    // View-shaped @State that doesn't move into EditorState because it's tied to
    // SwiftUI/UIKit lifecycle (FocusState must live on a View; row-frame cache
    // is a layout output; gesture-internal flags are bookkeeping for UIKit
    // bridges; Environment must be read inside View.body).

    /// Drives the active editor's `.focused()` on iOS (UITextView). On macOS this is
    /// written but never read as a focus source — the NSTextView grabs first responder
    /// directly via `MacBlockTextViewRegistry.makeFirstResponder`. Both writes are
    /// driven from `.onChange(of: state.sessionState)` rather than scattered call sites.
    @FocusState var editorFocused: BlockID?
    /// Drives the page container's focusability for nav-mode key handling. Written only
    /// from `.onChange(of: state.sessionState)` (and once on first appear).
    @FocusState var pageFocused: Bool
    /// Bumped by `forcePageFocusGrab()` to request a re-grab of page focus.
    /// A `.onChange(of: pageFocusToken)` in body runs the false→true flip on
    /// the next runloop tick. Using a token (rather than writing `pageFocused`
    /// directly from each call site) means a same-value re-grab — needed when
    /// `pageFocused` is already `true` but SwiftUI dropped first-responder
    /// during a layout reset — fires reliably on every bump.
    @State var pageFocusToken: Int = 0
    #if os(macOS)
    /// Single-slot weak handle to the currently-mounted NSTextView. Only one editor
    /// mounts at a time (gated by `isEditing`), so `transferFocus(to: .editor(id))`
    /// can ask "is the active editor for this block?" and call `makeFirstResponder`
    /// synchronously instead of waiting for the NSTextView's own async self-grab.
    @State var macActiveTextView = MacActiveTextView()
    #endif
    #if os(iOS)
    /// One-tick overlap during inter-block focus transfer: when `state.sessionState` flips
    /// from `.editing(oldID, _)` to `.editing(newID, _)`, we keep `oldID` here for
    /// one runloop. The old row's `BlockTextEditor` stays mounted during that tick,
    /// so when SwiftUI mounts the new row's UITextView and `didMoveToWindow` calls
    /// `becomeFirstResponder`, the old UITextView is still in the window hierarchy.
    /// UIKit transfers first responder synchronously and the soft keyboard stays
    /// up — without this, splitting on Return makes the keyboard hide+show.
    ///
    /// Written by `transferFocus(to:)` synchronously, BEFORE the `state.sessionState`
    /// mutation, so the first body re-render that sees the new mode also sees
    /// this transitioning ID — `.onChange(of: state.sessionState)` fires after the
    /// render completes, which would be one tick too late.
    @State var iosTransitioningEditorID: BlockID?
    #endif
    /// Document-level undo coordinator. Owns the shared `UndoManager` that NSTextView
    /// typing-undo and structural ops (split/merge/indent/slide/delete/autotransform/
    /// drag-drop) all register against. Recreated implicitly when EditorView's identity
    /// resets; explicitly cleared on document switch via `.onChange(of: document.id)`.
    @State var undoController = DocumentUndoController()
    @State var editorCommands = EditorCommands()
    @State var rowFrames = RowFramesStore()
    /// Hoisted from per-row `@State` so `BlockRow` can stay free of any
    /// DynamicProperty wrapper (which would defeat `.equatable()`). Keyed by
    /// the absolute URL; rows receive only the subset relevant to their text.
    @State var linkPreviews: [URL: LinkPreview] = [:]
    @State var lastDropHapticTarget: DropTarget?
    @State var lastDropHapticFireAt: Date?
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
    #if os(macOS)
    /// NSEvent local+global monitors installed for the duration of an active
    /// reorder lift on macOS. Backstop for the SwiftUI `DragGesture.onEnded`
    /// callback, which is destroyed without firing if the gesture's host row
    /// (a `BlockRow` inside the `LazyVStack`) is recycled mid-drag — typical
    /// when the autoscroll edge band scrolls the source row out of view.
    /// Without this, `state.reorderLift` would survive the release, and the
    /// autoscroll task it left armed would peg the main thread re-targeting
    /// `.animation(value: dropHoverPath)` every frame.
    @State var macReorderMouseUpLocalMonitor: Any?
    @State var macReorderMouseUpGlobalMonitor: Any?
    #endif

    /// Drives the compact block action popover. On iOS this is opened by a
    /// leading row swipe; on macOS by clicking the drag handle or Cmd-/ in nav mode.
    /// Wraps `BlockID` because the latter is Hashable but not Identifiable.
    struct BlockActionSheet: Identifiable {
        let id: BlockID
    }
    @State var actionSheet: BlockActionSheet?

    public init(
        document: Document,
        state: EditorState,
        host: any EditorHost
    ) {
        self.document = document
        self.state = state
        self.host = host
    }

    public var body: some View {
        GeometryReader { geometry in
            let numbering = NumberingContext.compute(document.children)
            let snapshot = document.children
            let hidden = hiddenBlockIDs(in: snapshot)
            // Tree-aware visible-row layout walk — yields one VisibleRow per
            // displayed block, each carrying its slot, depth, and prev-sibling
            // reference so the ForEach below can iterate over the rows array
            // directly (no `Array(...enumerated())` allocation per body eval —
            // a fresh enumerated wrapper would defeat LazyVStack's identity
            // diff and force the whole visible list through `placeSubviews`
            // on every transaction).
            let visibleRows = computeVisibleLayout(snapshot: snapshot, hidden: hidden)
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
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleRows, id: \.block.id) { row in
                        let k = row.slot
                        let block = row.block
                        let gap = BlockSpacing.gap(before: block, depth: row.depth, after: row.prev, prevDepth: row.prevDepth)
                        let pinchExtraTopGap = pinchExtraGap(forIndex: k)
                        let reorderExtraTopGap = reorderDriftGap(at: k, hoverSlot: dropHoverSlot, liftFootprint: liftFootprint)
                        rowView(for: bindingForBlock(id: block.id), depth: row.depth, snapshot: snapshot, numberingIndex: numbering[block.id], selectedIDs: selectedIDs)
                            .padding(.top, gap + pinchExtraTopGap)
                            // Per-row geometry observation. Replaces a previous
                            // GeometryReader+PreferenceKey per row; that pattern's
                            // O(N) reduce step across siblings dominated layout when
                            // the document was big enough to fall behind a held
                            // arrow key, sending SwiftUI into a layout-pass spin
                            // that wouldn't terminate. `onGeometryChange` writes
                            // each row's frame directly into `rowFrames` (a non-
                            // observable reference type) and skips the reduce.
                            //
                            // The reorder drift gap is applied *after* this
                            // observer so the cached frame excludes the gap —
                            // including the gap put the row's midY inside the
                            // visual gap region, so dragging the finger into the
                            // open gap crossed midY and flipped the slot to the
                            // wrong neighbor.
                            .onGeometryChange(for: CGRect.self) { proxy in
                                proxy.frame(in: .named(PageHoverCoordinateSpace.name))
                            } action: { newValue in
                                rowFrames.frames[block.id] = newValue
                            }
                            .padding(.top, reorderExtraTopGap)
                            .animation(.spring(response: 0.26, dampingFraction: 0.76), value: state.dropHoverPath)
                            // LazyVStack unmounts rows that scroll outside its
                            // materialization window. `onGeometryChange` only
                            // fires while the view is mounted, so without this
                            // the dict keeps the row's last-known frame forever
                            // — `ensureCursorVisible` then reads a stale frame
                            // (the row's old viewport-relative Y from when it
                            // was last visible) and scrolls a few points
                            // instead of jumping to where the row actually is.
                            // Clearing on disappear means the next
                            // `ensureCursorVisible` falls through to the
                            // `scrollPosition.scrollTo(id:)` path, which lets
                            // SwiftUI walk the content forward.
                            .onDisappear {
                                rowFrames.frames.removeValue(forKey: block.id)
                            }
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
                .iosPageReorder(
                    isEnabled: !pinchGestureActive,
                    rowFrames: rowFrames
                ) { blockID, location in
                    // Read `document.children` at gesture-fire time rather than
                    // capturing the body-eval-time `snapshot` constant. The row
                    // wrapper that hosts these closures gets EquatableView gating
                    // (see `EquatableEditorRow` below); when the row is "equal"
                    // and SwiftUI keeps the cached view, the closures retained
                    // alongside it must still see fresh document state.
                    preliftReorder(blockID: blockID, snapshot: document.children)
                    // Re-anchor immediately to the touch point so the lift sits under
                    // the finger from frame one (no center-then-snap).
                    tickReorderLift(blockID: blockID, at: location, anchorAt: location, snapshot: document.children)
                    Haptics.light()
                } onChanged: { location in
                    guard let id = state.reorderLift?.ids.first else { return }
                    tickReorderLift(blockID: id, at: location, anchorAt: location, snapshot: document.children)
                } onEnded: { location in
                    endReorderLift(atY: location.y, snapshot: document.children)
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
                .iosScrollMetrics(scrollMetrics)
            }
            .coordinateSpace(name: PageHoverCoordinateSpace.name)
            .iosPageBlockDropTarget(
                onUpdate: { y in
                    applyDropTarget(at: y, snapshot: document.children)
                },
                onDrop: { payload, y in
                    performPayloadDrop(payload, atY: y, snapshot: document.children)
                },
                onCancel: {
                    if state.currentDropTarget != nil {
                        state.currentDropTarget = nil
                    }
                }
            )
            .macScrollMetrics(scrollMetrics)
            .macScrollPosition($scrollPosition)
            // `setHoveredBlock` guards same-value writes (see EditorState).
            // The read is intentionally NOT in `EditorView.body` — it lives on
            // `BlockRow` so a hover write only invalidates the rows that read
            // it, not the whole `LazyVStack`.
            .macNearestRowHover(rowFrames: rowFrames) { id in
                state.setHoveredBlock(id)
            }
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
            // Hand the controller down through the environment. BlockTextEditor reads it
            // to register a typing-session snapshot when an editor loses focus.
            .environment(\.documentUndoController, undoController)
            .environment(\.editorHost, host)
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
            #if os(macOS)
            // macOS uses page-level focus for nav-mode hardware keyboard handling.
            // iOS has no such nav mode and no hardware keyboard nav, AND attaching
            // .focusable()/.focused() at the EditorView root registers the editor
            // tree in SwiftUI's focus engine, which then eagerly calls
            // resignFirstResponder on any nested UITextView whenever the view
            // tree updates (insert a row, change state.sessionState). That race hides
            // the soft keyboard mid-split. Skip both on iOS.
            .focusable()
            .focused($pageFocused)
            #endif
            .onAppear {
                // Open with no nav-mode selection. The first ↓ press lands on the
                // top block via `moveCursor(by:)`'s nil-cursor branch.
                forcePageFocusGrab()
                installUndoApply()
                wireEditorCommands()
            }
            // Intercept inline `[text](path.md)` / `[text](https://…)` clicks
            // inside read-only `Text` rows and route through `host.didActivateLink`.
            // The host classifies workspace-relative `.md` paths internally and
            // returns false for external URLs to fall through to the system
            // browser. Live-NSTextView link taps are still owned by the
            // underlying view's click handling — this only catches read-only
            // body text.
            .environment(\.openURL, OpenURLAction { [host] url in
                host.didActivateLink(.url(url)) ? .handled : .systemAction
            })
            .onChange(of: state.currentDropTarget) { _, newValue in
                handleDropTargetChange(newValue)
            }
            #if os(macOS)
            .onChange(of: state.reorderLift != nil) { _, isActive in
                if isActive {
                    installMacReorderMouseUpBackstop()
                } else {
                    removeMacReorderMouseUpBackstop()
                }
            }
            #endif
            .onChange(of: state.sessionState) { oldState, newState in
                if actionSheet != nil { actionSheet = nil }
                handleModeChange(from: oldState, to: newState)
            }
            // Single home for the focus-pump dance. `forcePageFocusGrab()`
            // bumps `pageFocusToken`, which lands here and flips
            // `pageFocused` `false → true` across two runloop ticks (a
            // same-value `@FocusState` write is a no-op, so the flip is
            // load-bearing). Replaces five sites that each ran the same
            // double-`DispatchQueue.main.async` directly.
            .onChange(of: pageFocusToken) { _, _ in
                pageFocused = false
                DispatchQueue.main.async { pageFocused = true }
            }
            #if os(iOS)
            // On iOS the user can lose editor focus without touching `state.sessionState`
            // (tap outside the editor, keyboard dismiss). `editorFocused` going nil is
            // the only real-time signal — flush so the host saves. macOS doesn't
            // need this: every focus loss there flows through `transferFocus(to: .nav)`,
            // which `handleModeChange` already wires to flush.
            .onChange(of: editorFocused) { old, new in
                if new == nil && old != nil {
                    Task { @MainActor [host, document] in await host.flush(document) }
                }
            }
            #endif
            .onChange(of: state.pendingAppendTicket) { _, _ in
                if let payload = state.takePendingAppend() {
                    appendBlocksFromHost(payload.blocks, actionName: payload.actionName)
                }
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
            .iosEdgeGateNavigateBack()
        }
    }

    func handleEscapeKey() {
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
        #if os(iOS)
        // Treat the just-transitioned-away block as still editing for one runloop
        // tick — see `iosTransitioningEditorID`. The row stays mounted but is no
        // longer focused (`editorFocused` already points at the new block), so its
        // `BlockTextEditor` won't fight for first responder.
        let isEditing = state.editingBlock == block.id || iosTransitioningEditorID == block.id
        #else
        let isEditing = state.editingBlock == block.id
        #endif
        // The macOS action menu opens in nav mode, where the block is already painted with
        // the blue nav-selection tint — a second ring would just duplicate it. iOS has no
        // nav-mode multi-select (always one anchor block), so the ring is the only marker.
        #if os(iOS)
        let isActionMenuTarget = (actionSheet?.id == block.id)
        #else
        let isActionMenuTarget = false
        #endif

        let blockExternalURLs = collectExternalURLs(in: block.text)
        let relevantLinkPreviews: [URL: LinkPreview] = blockExternalURLs.reduce(into: [:]) { dict, url in
            if let preview = linkPreviews[url] { dict[url] = preview }
        }

        // Reorder gestures and "show action menu" fire from two anchors per row
        // (the row body itself for whole-row drag / iOS swipe, and the drag
        // handle overlay) — bind one closure each rather than allocating two
        // identical closures per render.
        let onReorderChanged: (DragGesture.Value) -> Void = { value in
            tickReorderLift(
                blockID: block.id,
                at: value.location,
                anchorAt: value.startLocation,
                snapshot: document.children
            )
        }
        let onReorderEnded: (DragGesture.Value) -> Void = { value in
            endReorderLift(atY: value.location.y, snapshot: document.children)
        }
        let onShowActionSheet: () -> Void = {
            actionSheet = BlockActionSheet(id: block.id)
        }
        // Drag-handle click on macOS: collapse selection to this row before opening
        // the menu, so dismissing the sheet leaves the clicked row selected.
        // `transferFocus` mutates `state.sessionState`, and `.onChange(of: state.sessionState)`
        // would clear a synchronously-set `actionSheet`; deferring to the next
        // runloop tick lets the change-handler run first.
        let onHandleTap: () -> Void = {
            transferFocus(to: .nav(cursor: block.id))
            DispatchQueue.main.async {
                actionSheet = BlockActionSheet(id: block.id)
            }
        }

        // Bundle of editor-only bindings/closures, present only on the row
        // currently being edited. Read-only rows pass `editor: nil` and avoid
        // allocating any of this. (`onBlockChange` / `onToggleTodo` stay at
        // the top level — they're also fired by non-editor mutations like the
        // todo-row checkbox toggle.)
        let editing: BlockRow.TextEditing? = isEditing
            ? BlockRow.TextEditing(
                editorFocused: $editorFocused,
                isActive: state.editingBlock == block.id,
                mentionActive: state.mentionMenu?.blockID == block.id,
                onKey: { key in handleEditorKey(key, blockID: block.id) },
                onAutotransform: { transform, remainingText in
                    applyAutotransform(transform, remainingText: remainingText, blockID: block.id)
                },
                onMentionTriggerChange: { trigger in
                    handleMentionTriggerChange(trigger, blockID: block.id)
                },
                consumeInitialCursor: { state.takePendingInitialCursor() }
            )
            : nil

        BlockRow(
            block: block,
            state: state,
            onBlockChange: { newBlock in binding.wrappedValue = newBlock },
            onToggleTodo: { id in
                mutate("Toggle Todo") {
                    guard let current = document.find(id),
                          case .todo(let text, let done) = current.kind else { return }
                    document.mutate(id) { $0.kind = .todo(text: text, done: !done) }
                }
            },
            depth: depth,
            editor: editing,
            isPageTitle: isPageTitleBlock(block, snapshot: snapshot),
            numberingIndex: numberingIndex,
            isSelected: isSelected,
            isExpanded: state.expandedToggles.contains(block.id) || state.expandedTemplates.contains(block.id),
            isDropTarget: state.dropOntoBlockID == block.id,
            isActionMenuTarget: isActionMenuTarget,
            isActionMenuPresented: actionSheet?.id == block.id,
            isPinching: pinchGestureActive,
            reorderSourceOpacity: reorderSourceOpacity(for: block.id),
            isReorderingThisBlock: state.reorderLift?.ids.contains(block.id) == true,
            isSelectionHandleRow: isSelectionHandleRow(for: block.id),
            isMacDragSource: isMacDraggingFromRow(block.id),
            accessibilityID: accessibilityIdentifier(for: block),
            accessibilityLabelText: accessibilityLabel(for: block),
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
            pageLookups: resolvePageLookups(for: block, host: host),
            linkPreviews: relevantLinkPreviews,
            onLinkPreviewLoaded: { url, preview in linkPreviews[url] = preview },
            host: host,
            onTapOutsideText: {
                if case .subpage = block.kind {
                    _ = navigateIntoSubpage(block.id)
                    return
                }
                // Clicks outside the editable text region (markers, paddings) — no
                // position info, cursor lands at end via the editor's default behavior.
                transferFocus(to: .editor(block.id, initialCursor: nil))
            },
            onMacReorderChanged: onReorderChanged,
            onMacReorderEnded: onReorderEnded,
            onActionMenuDismiss: {
                if actionSheet != nil { actionSheet = nil }
            },
            onMentionMenuDismiss: {
                if state.mentionMenu != nil { state.closeMentionMenu() }
            },
            onIOSDelete: {
                let isMultiSelect = state.selection.contains(block.id) && state.selection.count > 1
                if !isMultiSelect, let blk = document.find(block.id), blk.isHeading {
                    deleteHeadingKeepingChildren(blk.id)
                } else {
                    deleteBlocks(ids: dragIDs(for: block.id), actionName: "Delete")
                }
                showActionToast("Deleted")
            },
            onIOSShowMenu: onShowActionSheet,
            onHandleHover: { hovering in
                if hovering {
                    state.setHoveredHandle(block.id)
                } else if state.hoveredHandle == block.id {
                    state.setHoveredHandle(nil)
                }
            },
            onHandleTap: onHandleTap,
            onHandleReorderChanged: onReorderChanged,
            onHandleReorderEnded: onReorderEnded,
            actionMenuContent: { AnyView(blockActionMenuContent(for: block.id)) },
            mentionMenuContent: { AnyView(mentionMenuContent()) }
        )
        .equatable()
    }

    func topSelectedBlockID() -> BlockID? {
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

    /// Multi-select drag-handle anchor: in a multi-block selection, the handle
    /// appears on the topmost-in-document row only. Single-select / no-select
    /// rows return false here; the hover-driven handle reveal is computed
    /// inside `BlockRow` so hover writes don't invalidate `EditorView.body`.
    private func isSelectionHandleRow(for id: BlockID) -> Bool {
        guard state.selection.count > 1 else { return false }
        return id == topSelectedBlockID()
    }

    /// In-document destinations for the Move-to picker: every heading/toggle
    /// in the current page that is a legal drop target for `moving`. Excludes
    /// the moving subtrees themselves (no self-drops, no cycles) and anything
    /// `Document.canDrop` rejects (heading-containment violations). Result is
    /// in document order with each target's tree depth attached so the picker
    /// can indent rows to surface the page outline.
    func inDocMoveCandidates(excluding moving: [BlockID]) -> [InDocMoveTarget] {
        var excluded: Set<BlockID> = []
        for id in moving { excluded.formUnion(document.subtreeIDs(of: id)) }
        var out: [InDocMoveTarget] = []
        document.walk { block, depth, _ in
            guard !excluded.contains(block.id) else { return }
            let kind: InDocMoveTarget.Kind
            let fallback: String
            switch block.kind {
            case .heading(let level, _):
                kind = .heading(level: level)
                fallback = "Untitled heading"
            case .toggle:
                kind = .toggle
                fallback = "Untitled toggle"
            default:
                return
            }
            let dropTarget = DropPath(parent: block.id, position: block.children.count)
            guard document.canDrop(ids: moving, to: dropTarget) else { return }
            let raw = String(block.text.characters)
            let title = raw.isEmpty ? fallback : raw
            out.append(InDocMoveTarget(id: block.id, title: title, kind: kind, depth: depth))
        }
        return out
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

    /// Top-level nav-mode key handler routed from `.onKeyPress` in the body.
    /// Looks the press up in `Self.navBindings` (declarative table mapping
    /// (key, modifiers) → `EditorAction`) and dispatches via `editorCommands`.
    /// Returns `.ignored` if no binding matches so SwiftUI can pass the press
    /// through to other handlers.
    func handleNavKeyPress(_ press: KeyPress) -> KeyPress.Result {
        Diag.navkey.debug("press key=\(String(describing: press.key), privacy: .public) modifiers=\(press.modifiers.rawValue, privacy: .public) cursor=\(String(describing: state.cursor), privacy: .public) selection=\(state.selection.count, privacy: .public) editing=\(String(describing: state.editingBlock), privacy: .public)")
        guard state.editingBlock == nil else { return .ignored }
        guard let action = Self.navAction(for: press.key, modifiers: press.modifiers) else {
            Diag.navkey.debug("no action matched")
            return .ignored
        }
        Diag.navkey.debug("dispatching action=\(String(describing: action), privacy: .public)")
        editorCommands.perform(action)
        Diag.navkey.debug("after dispatch cursor=\(String(describing: state.cursor), privacy: .public) selection=\(state.selection.count, privacy: .public)")
        return .handled
    }

    /// Pure-function lookup against `Self.navBindings`. Tests dispatch to
    /// this directly — `KeyPress` has no public init, so the per-press
    /// matcher takes the (key, modifiers) pair instead.
    ///
    /// Only Shift/Control/Option/Command are matched. `.numericPad` and
    /// `.function` come pre-set on macOS arrow / function keys (rawValue
    /// 96 = .function | .numericPad on every arrow press), and `.capsLock`
    /// reflects keyboard state, not user intent — leaving any of those in
    /// the comparison breaks every arrow binding because they're declared
    /// with `modifiers: []`.
    static func navAction(for key: KeyEquivalent, modifiers: EventModifiers) -> EditorAction? {
        let userModifiers: EventModifiers = [.shift, .control, .option, .command]
        let pressModifiers = modifiers.intersection(userModifiers)
        for binding in navBindings where binding.key == key && binding.modifiers == pressModifiers {
            return binding.action
        }
        return nil
    }

    /// `(KeyEquivalent, EventModifiers) → EditorAction` row.
    /// `modifiers` is matched exactly (not via `contains`), so Cmd-B does NOT
    /// fire a binding declared for Cmd-Shift-B.
    struct NavKeyBinding {
        let key: KeyEquivalent
        let modifiers: EventModifiers
        let action: EditorAction
    }

    /// All keyboard chords handled in nav mode. Order doesn't matter — each
    /// key+modifier combo is unique. To wire a new shortcut: add a row here,
    /// an `EditorAction` case, and a switch arm in `wireEditorCommands`.
    static let navBindings: [NavKeyBinding] = [
        // Cmd shortcuts
        .init(key: "[", modifiers: .command, action: .navigateBack),
        .init(key: "c", modifiers: .command, action: .copySelection),
        .init(key: "v", modifiers: .command, action: .pasteFromPasteboard),
        .init(key: "x", modifiers: .command, action: .cutSelection),
        .init(key: "b", modifiers: .command, action: .toggleInlineMark(.bold)),
        .init(key: "i", modifiers: .command, action: .toggleInlineMark(.italic)),
        .init(key: "s", modifiers: [.command, .shift], action: .toggleInlineMark(.strikethrough)),
        .init(key: "/", modifiers: .command, action: .openBlockActionMenu),
        .init(key: "k", modifiers: .command, action: .toggleLinkOrSubpage),
        .init(key: .return, modifiers: .command, action: .newBlockBelow),

        // Delete (forward-delete + macOS backspace + iOS DEL)
        .init(key: .delete, modifiers: [], action: .deleteSelection),
        .init(key: KeyEquivalent("\u{8}"), modifiers: [], action: .deleteSelection),
        .init(key: KeyEquivalent("\u{7F}"), modifiers: [], action: .deleteSelection),

        // Tab — indent / outdent. Shift+Tab arrives as a distinct character
        // (BackTab, U+0019), not as .tab + .shift, so it gets its own row.
        .init(key: .tab, modifiers: [], action: .indent),
        .init(key: KeyEquivalent("\u{19}"), modifiers: [], action: .outdent),

        // Arrows — modifier-aware action.
        .init(key: .upArrow, modifiers: [], action: .moveCursor(delta: -1)),
        .init(key: .upArrow, modifiers: .shift, action: .extendSelection(delta: -1)),
        .init(key: .upArrow, modifiers: .option, action: .moveBlockUp),
        .init(key: .downArrow, modifiers: [], action: .moveCursor(delta: +1)),
        .init(key: .downArrow, modifiers: .shift, action: .extendSelection(delta: +1)),
        .init(key: .downArrow, modifiers: .option, action: .moveBlockDown),
        .init(key: .leftArrow, modifiers: [], action: .navLeftArrow),
        .init(key: .rightArrow, modifiers: [], action: .navRightArrow),

        // Single keys
        .init(key: .return, modifiers: [], action: .enterEditOrOpenSubpage),
        .init(key: .escape, modifiers: [], action: .escape),
    ]

    /// Wrap a structural mutation so its inverse is registered with the
    /// document's `undoManager`. Callers must only call `mutate` when actually
    /// changing something — the helper doesn't equality-check.
    ///
    /// Thin wrapper over `undoController.transaction(...)`: that handles
    /// flushing in-flight text via `preMutation`, snapshotting `[Block]`
    /// for undo, enforcing heading containment, computing the pre→post
    /// diff, and firing `Document.didCommitTransaction` (wired in
    /// `installUndoApply` to forward the ops to `host.persistCommit`).
    /// Typing goes through the same transaction path from `commitLiveText`,
    /// so this is just the structural-mutation entry point — the document
    /// is the single emission point for both flavours.
    ///
    /// The transaction's `before` snapshot is captured pre-`preMutation`,
    /// so any typing flush triggered by the live editor on commit gets
    /// folded into the same diff as the structural change — one emission,
    /// one atomic undo step covering "the in-flight typing plus the
    /// structural op the user just invoked."
    func mutate(_ name: String, _ change: () -> Void) {
        undoController.transaction(name: name) { change() }
    }

    /// Consume a host-supplied append payload (via `EditorState.appendBlocks`).
    /// Mutates with undo, then puts the nav-mode cursor on the last appended
    /// block so the user lands on what was just inserted.
    func appendBlocksFromHost(_ blocks: [Block], actionName: String) {
        guard !blocks.isEmpty else { return }
        mutate(actionName) {
            document.children.append(contentsOf: blocks)
        }
        if let lastID = blocks.last?.id {
            transferFocus(to: .nav(cursor: lastID))
        }
    }

    // Command and undo wiring (`wireEditorCommands`, `installUndoApply`,
    // `activeContainedTextView`, `runDualMode`) lives in EditorView+Wiring.swift.

    // MARK: - Selection state helpers

    /// Collapse selection to a single block. The next Shift-extend will pivot off this block.
    func setCursor(_ id: BlockID) {
        state.setCursor(id)
    }

    private func clearCursor() {
        state.clearCursor()
    }

    /// Where focus should land. Both cases are model-shaped — they describe what the
    /// next `state.sessionState` should be. The actual SwiftUI focus state (`pageFocused`,
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
    /// editor's live text, mutates `state.sessionState`, and lets `.onChange(of: state.sessionState)`
    /// (→ `handleModeChange`) derive the SwiftUI/AppKit focus update.
    func transferFocus(to target: FocusTarget) {
        // Commit in-flight editor text into the model before mutating mode. The state
        // change unmounts the active BlockTextEditor; a binding write during teardown
        // doesn't reliably reach the freshly-rendered read-only Text — see
        // `flushActiveText`.
        undoController.flushActiveText?()

        switch target {
        case .editor(let id, let initialCursor):
            // Soft lookup: only redirect to nav on POSITIVE confirmation that the
            // block is non-editable. On absence we assume editable and proceed.
            // SwiftUI snapshots `document.children` at last view-render time and
            // doesn't re-read it within the same event handler, so a block that
            // was just inserted via `mutate(...)` won't appear in
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
            #if os(iOS)
            // Set BEFORE the sessionState mutation so the next body render sees
            // both new values together. Driving this from .onChange(of: state.sessionState)
            // fires too late — the old row unmounts in the first render that
            // sees the new mode, before .onChange runs. See `iosTransitioningEditorID`.
            if case .editing(let oldID, _) = state.sessionState, oldID != id {
                iosTransitioningEditorID = oldID
                DispatchQueue.main.async { iosTransitioningEditorID = nil }
            }
            #endif
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
    /// the host's `flush()` callback in sync with `state.sessionState`. Driven from
    /// `.onChange(of: state.sessionState)` so any path that mutates state (clicks,
    /// key handlers, undo/redo, …) gets focus right automatically — no caller has
    /// to remember to flip `pageFocused`.
    func handleModeChange(from oldState: SessionState, to newState: SessionState) {
        let wasEditing: Bool = { if case .editing = oldState { return true } else { return false } }()
        Diag.mode.debug("from=\(String(describing: oldState), privacy: .public) to=\(String(describing: newState), privacy: .public)")

        switch newState {
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
            // iOS inter-block overlap (`iosTransitioningEditorID`) is set inside
            // `transferFocus` BEFORE the sessionState mutation, not here — .onChange
            // fires after the render that picks up the new state, which is too late.
        case .navigating:
            editorFocused = nil
            // Only re-grab page focus on real edit→nav transitions. .onChange fires on
            // intra-nav selection changes (cursor moves, extends) and gesture ticks
            // too; re-grabbing every time would steal focus from menus and sheets.
            if wasEditing {
                forcePageFocusGrab()
                Task { @MainActor [host, document] in await host.flush(document) }
            }
        }

        #if os(macOS)
        ensureCursorVisible()
        #endif
    }

    #if os(macOS)
    /// Scroll the page so the nav-mode cursor's row is in view — but only if
    /// it isn't already. Arrow nav within the visible region produces no page
    /// motion; nav that walks the cursor off-screen scrolls just enough to
    /// bring it back. Called from `handleModeChange` so every mode-changing
    /// path (arrow, Shift+arrow, paste, undo, …) keeps cursor and viewport
    /// in lockstep.
    ///
    /// `rowFrames` are in `PageHoverCoordinateSpace`, which is the ScrollView's
    /// local coords — `frame.minY` is already the row's offset from the
    /// viewport top, so we can compare directly against `[topInset,
    /// viewportH-bottomInset]`. When the cursor's row isn't yet in
    /// `rowFrames` (LazyVStack hasn't materialized it), we fall back to
    /// `scrollPosition.scrollTo(id:)`, which SwiftUI resolves by walking the
    /// content forward until the id is reached.
    func ensureCursorVisible() {
        guard case .navigating(let sel, _) = state.sessionState, let cursor = sel.cursor else { return }
        let viewportH = scrollMetrics.viewportHeight
        guard viewportH > 0 else { return }
        let visibleTop = scrollMetrics.topInset
        let visibleBottom = viewportH - scrollMetrics.bottomInset
        guard let frame = rowFrames.frames[cursor] else {
            scrollPosition.scrollTo(id: cursor, anchor: nil)
            return
        }
        if frame.minY >= visibleTop && frame.maxY <= visibleBottom {
            return
        }
        let currentOffset = scrollMetrics.contentOffsetY
        let targetOffset: CGFloat
        if frame.minY < visibleTop {
            targetOffset = currentOffset + (frame.minY - visibleTop)
        } else {
            targetOffset = currentOffset + (frame.maxY - visibleBottom)
        }
        let maxOffset = max(0, scrollMetrics.contentHeight - viewportH)
        let clamped = max(0, min(maxOffset, targetOffset))
        scrollPosition.scrollTo(point: CGPoint(x: 0, y: clamped))
    }
    #endif

    /// Request a re-grab of page focus. Bumps a token that the body's
    /// `.onChange(of: pageFocusToken)` observes; the actual `false → true`
    /// flip on the next runloop tick happens there. Using a token instead
    /// of writing `pageFocused` directly means a same-value re-grab still
    /// fires (a same-value `@FocusState` write is a no-op).
    private func forcePageFocusGrab() {
        pageFocusToken &+= 1
    }

    /// Nav-mode →: check todos in the selection, otherwise enter a selected subpage
    /// or open the collapsible section under the cursor.
    @discardableResult
    func handleNavRightArrow() -> Bool {
        if setTodoDoneOnSelection(true) { return true }
        guard let id = state.cursor, state.selection.count == 1 else { return false }
        if navigateIntoSubpage(id) { return true }
        guard let block = document.find(id),
              isCollapsibleSection(block) else { return false }
        withAnimation(.easeInOut(duration: 0.15)) {
            expandSection(block)
        }
        // Re-attach AppKit first responder: the `expandedToggles` mutation rebuilds
        // the VStack inside an animation transaction and drops it. `pageFocused`
        // stays `true`, so a same-value setter is a no-op.
        forcePageFocusGrab()
        return true
    }

    /// Nav-mode ←: uncheck todos in the selection, otherwise close the current section if
    /// expanded, otherwise close the innermost enclosing collapsible section and move the
    /// selection there.
    @discardableResult
    func handleNavLeftArrow() -> Bool {
        if setTodoDoneOnSelection(false) { return true }
        guard let id = state.cursor, state.selection.count == 1 else { return false }
        guard let cursorBlock = document.find(id) else { return false }

        if isSectionExpanded(cursorBlock) {
            withAnimation(.easeInOut(duration: 0.15)) {
                collapseSection(cursorBlock)
            }
            forcePageFocusGrab()
            return true
        }

        guard let parentID = enclosingCollapsibleSectionID(forBlockID: id),
              let parent = document.find(parentID) else { return false }
        withAnimation(.easeInOut(duration: 0.15)) {
            collapseSection(parent)
        }
        setCursor(parentID)
        forcePageFocusGrab()
        return true
    }

    /// Toggle strikethrough across every text-bearing block the user has explicitly
    /// selected — parent rows only, never the implicit section children. If all of them
    /// are already fully struck, remove strikethrough; otherwise add it uniformly. Skips
    /// blocks without an `AttributedString` body (code/divider/subpage) and template
    /// buttons (whose `withText` flattens formatting). Returns `true` if it acted.
    func toggleStrikethroughOnSelection() -> Bool {
        toggleInlineMarkOnSelection(
            attribute: InlineAttributes.StrikethroughAttribute.self,
            setLabel: "Strikethrough",
            clearLabel: "Remove Strikethrough"
        )
    }

    /// Toggle bold across every text-bearing block the user has explicitly selected.
    /// Parent-only — does not expand to section children. See
    /// `toggleStrikethroughOnSelection` for the shared semantics.
    func toggleBoldOnSelection() -> Bool {
        toggleInlineMarkOnSelection(
            attribute: InlineAttributes.BoldAttribute.self,
            setLabel: "Bold",
            clearLabel: "Remove Bold"
        )
    }

    /// Toggle italic across every text-bearing block the user has explicitly selected.
    /// Parent-only — does not expand to section children.
    func toggleItalicOnSelection() -> Bool {
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
        let slot: Int
        let prev: Block?
        let prevDepth: Int
    }

    func computeVisibleLayout(snapshot: [Block], hidden: Set<BlockID>) -> [VisibleRow] {
        var rows: [VisibleRow] = []
        rows.reserveCapacity(snapshot.count)
        var lastVisible: Block? = nil
        var lastDepth: Int = 0
        appendVisible(in: snapshot, depth: 0, parentID: nil, hidden: hidden,
                      rows: &rows,
                      lastVisible: &lastVisible, lastDepth: &lastDepth)
        return rows
    }

    private func appendVisible(
        in blocks: [Block],
        depth: Int,
        parentID: BlockID?,
        hidden: Set<BlockID>,
        rows: inout [VisibleRow],
        lastVisible: inout Block?,
        lastDepth: inout Int
    ) {
        for block in blocks {
            // Block visibility: hidden if any ancestor is collapsed. The
            // `hidden` set is populated by `hiddenBlockIDs` which marks every
            // descendant of a closed container.
            if !hidden.contains(block.id) {
                rows.append(VisibleRow(
                    block: block, depth: depth, parentID: parentID,
                    slot: rows.count, prev: lastVisible, prevDepth: lastDepth
                ))
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
                              rows: &rows,
                              lastVisible: &lastVisible, lastDepth: &lastDepth)
            }
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

    /// Hop into the previous (delta < 0) or next (delta > 0) editable block in
    /// preorder, skipping non-text-bearing kinds. Lands the cursor at end of the
    /// previous block when going left, offset 0 when going right.
    private func exitEditHorizontal(_ blockID: BlockID, by delta: Int) -> KeyPress.Result {
        let blocks = preorderFlat()
        let hidden = hiddenBlockIDs(in: document.children)
        let visible = blocks.filter { !hidden.contains($0.id) }
        guard let start = visible.firstIndex(where: { $0.id == blockID }) else { return .ignored }
        var i = start + delta
        while i >= 0, i < visible.count {
            let candidate = visible[i]
            switch candidate.kind {
            case .paragraph, .heading, .bullet, .numbered, .todo, .quote, .toggle:
                let cursor: InitialCursorTarget = (delta < 0)
                    ? .offset(candidate.text.characters.count)
                    : .offset(0)
                transferFocus(to: .editor(candidate.id, initialCursor: cursor))
                return .handled
            case .code, .divider, .subpage, .templateButton, .image:
                i += delta
            }
        }
        return .ignored
    }

    /// Move the cursor by `delta` rows; collapse to a single-block selection at the new cursor.
    /// Skips blocks hidden inside collapsed toggles.
    func moveCursor(by delta: Int) {
        let blocks = preorderFlat()
        guard !blocks.isEmpty else { return }
        let hidden = hiddenBlockIDs(in: document.children)
        let visible = blocks.filter { !hidden.contains($0.id) }
        guard !visible.isEmpty else { return }
        if state.cursor == nil {
            // Fresh document or post-Esc: first ↓ lands on the top row,
            // first ↑ on the bottom row.
            setCursor(visible[delta > 0 ? 0 : visible.count - 1].id)
            return
        }
        let currentIndex = state.cursor.flatMap { id in visible.firstIndex(where: { $0.id == id }) } ?? 0
        let nextIndex = max(0, min(visible.count - 1, currentIndex + delta))
        setCursor(visible[nextIndex].id)
    }

    /// Extend the selection in the direction of `delta`. The anchor stays put; the cursor
    /// moves by outline sections so extending over a parent consumes its descendants as
    /// real selection.
    func extendSelection(by delta: Int) {
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
        if out.isEmpty, !state.selection.isEmpty {
            Diag.mode.error("effectiveSelectedIDs: state.selection has \(state.selection.count, privacy: .public) IDs but none present in document")
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
    func moveSelectionInDocument(by delta: Int) {
        moveBlocksInDocument(state.selection, by: delta)
    }

    /// Same as `moveSelectionInDocument` but slides an explicit set of block IDs.
    /// The menu's Move Block Up/Down items use this with `{state.editingBlock}`
    /// when the active editor is in edit mode, since `state.selection` may not
    /// reflect the editing block.
    func moveBlocksInDocument(_ ids: Set<BlockID>, by delta: Int) {
        let roots = document.selectionSubtreeRoots(ids)
        guard !roots.isEmpty else { return }
        // `slideSiblings` is internally atomic: it returns false and leaves the
        // doc untouched if the slab isn't a valid contiguous same-parent set.
        // On the invalid path the wrapping transaction still registers a
        // before==after undo entry, which Cmd-Z silently no-ops — acceptable.
        mutate("Move Block") {
            _ = document.slideSiblings(Set(roots), by: delta)
        }
        revealHiddenBlocks(ids)
    }

    /// Delete every block in the current selection. No-op if the selection
    /// covers every top-level block.
    func deleteSelection() {
        deleteBlocks(ids: Array(state.selection), actionName: "Delete")
    }

    /// Swipe-delete on a heading is an exception to the usual rule: it removes
    /// only the heading row, lifting its body content to siblings. The post-
    /// mutation `enforceHeadingContainment()` re-folds those siblings into a
    /// preceding heading at the same scope if one exists.
    private func deleteHeadingKeepingChildren(_ id: BlockID) {
        guard let heading = document.find(id), heading.isHeading else { return }
        // Don't strand the document with no top-level blocks.
        if document.parent(of: id) == nil,
           document.children.count == 1,
           heading.children.isEmpty {
            return
        }

        let cursorTarget = nearestCursorAfterRemoval(of: [id])
        mutate("Delete") {
            document.removeBlockLiftingChildren(id)
        }
        if let target = cursorTarget { setCursor(target) }
    }

    private func deleteBlocks(ids: [BlockID], actionName: String) {
        let roots = document.selectionSubtreeRoots(Set(ids))
        guard !roots.isEmpty else { return }
        // Don't allow deleting the entire top-level tree.
        let coveredRoots = roots.filter { document.parent(of: $0) == nil }
        if coveredRoots.count >= document.children.count, document.children.count > 0 {
            return
        }

        // Sanity check: selection IDs all missing from the doc — would silently
        // no-op. Should be unreachable now that `Document.didReplaceChildren`
        // revalidates state on bulk-replace; log loudly if it ever fires again.
        if !roots.contains(where: { document.documentOrder(of: $0) != nil }) {
            Diag.mode.error("deleteBlocks: selection has no doc-present IDs roots=\(roots.count, privacy: .public)")
            return
        }

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

    /// Pick a cursor target after removing the given subtree-roots. Prefer
    /// the block that visually slides up to take the deleted area's place —
    /// the first non-deleted block AFTER the deleted range in preorder.
    /// Falls back to the last non-deleted block BEFORE the deleted range
    /// (when the deletion includes the document's tail).
    func nearestCursorAfterRemoval(of roots: [BlockID]) -> BlockID? {
        guard !roots.isEmpty else { return nil }
        var deleted: Set<BlockID> = []
        for id in roots {
            deleted.formUnion(document.subtreeIDs(of: id))
        }
        let orders = roots.compactMap { document.documentOrder(of: $0) }
        guard let minOrder = orders.min(), let maxOrder = orders.max() else { return nil }

        var lastBefore: BlockID?
        var firstAfter: BlockID?
        var index = 0
        document.walk { block, _, _ in
            let i = index
            index += 1
            if deleted.contains(block.id) { return }
            if i < minOrder {
                lastBefore = block.id
            } else if i > maxOrder, firstAfter == nil {
                firstAfter = block.id
            }
        }
        return firstAfter ?? lastBefore
    }

    /// Apply Tab / Shift-Tab indent change to the effective selection. Each
    /// subtree-root indents/outdents independently — selection across parents
    /// is allowed; ops that aren't valid for some roots no-op for those.
    func indentSelection(by delta: Int) {
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

    func copySelectionToPasteboard() -> Bool {
        copyBlocksToPasteboard(ids: state.selection)
    }

    /// Cut: copy the selection to the pasteboard, then delete it as a single undo entry.
    /// Mirrors the `deleteSelection` guard against deleting the entire document.
    func cutSelectionToPasteboard() -> Bool {
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
    func pasteFromPasteboard() -> Bool {
        // Image-on-pasteboard takes precedence over text — same rule as the
        // editor's `paste(_:)` override.
        #if os(macOS)
        let images = readPasteboardImages(NSPasteboard.general)
        #else
        let images = readPasteboardImages(UIPasteboard.general)
        #endif
        if !images.isEmpty {
            let paths = host.saveImages(images)
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
        guard let parsed = host.parseBlocksFromPasteboard(pasted), !parsed.isEmpty else { return false }
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
        let serialized = host.serializeBlocksForPasteboard(blocks)
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
        // Sync live text into the binding before dispatching. Structural ops
        // (splitBlock, deleteEmptyBlock, changeIndent, convertBlockToSubpage,
        // …) all read `block.text` from the model *before* invoking
        // `mutate(...)` and `mutate`'s own `flushActiveText` would fire
        // too late — the read would have already used the stale binding.
        // Idempotent (`textStorageDirty == false` short-circuits), so the
        // mention/escape cases that don't actually need a commit pay nothing.
        undoController.flushActiveText?()
        switch key {
        case .enter(let selectionStart, let selectionEnd):
            return splitBlock(blockID, selectionStart: selectionStart, selectionEnd: selectionEnd)
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
            host.navigateBack()
            return .handled
        case .exitEditUp:
            transferFocus(to: .nav(cursor: state.editingBlock))
            DispatchQueue.main.async { moveCursor(by: -1) }
            return .handled
        case .exitEditDown:
            transferFocus(to: .nav(cursor: state.editingBlock))
            DispatchQueue.main.async { moveCursor(by: +1) }
            return .handled
        case .exitEditLeft:
            return exitEditHorizontal(blockID, by: -1)
        case .exitEditRight:
            return exitEditHorizontal(blockID, by: +1)
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
        let paths = host.saveImages(images)
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
        guard let parsed = host.parseBlocksFromPasteboard(str), !parsed.isEmpty else {
            return .ignored
        }
        if parsed.count == 1, case .paragraph = parsed[0].kind {
            return .ignored
        }
        spliceParsedBlocksAfter(blockID, parsed: parsed, focusLast: true)
        return .handled
    }


    private func splitBlock(_ blockID: BlockID, selectionStart: Int, selectionEnd: Int) -> KeyPress.Result {
        guard let block = document.find(blockID) else { return .ignored }
        let attr = block.text
        let total = attr.characters.count
        // Return over a selection deletes the selected range as part of the split:
        // head ends at the selection's start, tail begins after its end. Empty
        // selection collapses to the standard cursor split. Slice on the
        // AttributedString directly so bold/italic/code/strike/link survive — a
        // round-trip through `String(attr.characters)` would strip every mark.
        let safeStart = max(0, min(selectionStart, total))
        let safeEnd = max(safeStart, min(selectionEnd, total))
        let startIdx = attr.index(attr.startIndex, offsetByCharacters: safeStart)
        let endIdx = attr.index(attr.startIndex, offsetByCharacters: safeEnd)
        let headAttr = AttributedString(attr[attr.startIndex..<startIdx])
        let tailAttr = AttributedString(attr[endIdx..<attr.endIndex])
        let headEmpty = headAttr.characters.isEmpty
        let tailEmpty = tailAttr.characters.isEmpty

        // Enter-triggered autotransforms (`---`, ` ``` `) only fire when the cursor is at
        // the end of the row (tail empty) and the head matches a whole-row trigger.
        if tailEmpty,
           let result = detectEnterAutotransform(text: headAttr) {
            applyAutotransform(result.transform, remainingText: result.remainingText, blockID: blockID)
            return .handled
        }

        // Empty + indented row: Return tries to outdent. If the outdent is
        // refused (e.g. parent is a heading — heading-containment forbids
        // outdent there), fall through to the convert-to-paragraph or split
        // path so the user gets SOMETHING useful instead of a no-op.
        if headEmpty, tailEmpty, document.parent(of: blockID) != nil {
            let result = changeIndent(blockID, by: -1)
            if result == .handled { return result }
        }

        // Return at the START of a parent block with children: keep the head
        // row (and its sub-bullets) intact and insert a fresh empty sibling
        // of the same kind ABOVE it. Without this, the default split below
        // would wipe the head text and reattach it as a sibling AFTER the
        // children, orphaning the sub-bullets under an empty row.
        if headEmpty, !tailEmpty, !block.children.isEmpty {
            let newBlock = followUpBlock(after: block, withText: AttributedString())
            let parentID = document.parent(of: blockID)
            let siblings: [Block] = parentID.flatMap(document.find)?.children ?? document.children
            let i = siblings.firstIndex(where: { $0.id == blockID }) ?? siblings.count
            mutate("Split Block") {
                document.insertSubtree(newBlock, at: DropPath(parent: parentID, position: i))
            }
            transferFocus(to: .editor(newBlock.id, initialCursor: .offset(0)))
            return .handled
        }

        // Enter at end of a block that has children: add a child instead of a
        // sibling between the parent and its first child. Two flavors:
        //   * Closed toggle/template — children are hidden, so insert a
        //     sibling AFTER the whole collapsed section instead.
        //   * Anything else with children — insert a new FIRST child of the
        //     same kind as the existing first child.
        if tailEmpty, !block.children.isEmpty {
            if isCollapsedSection(block) {
                let parentID = document.parent(of: blockID)
                let siblings: [Block] = parentID.flatMap(document.find)?.children ?? document.children
                let i = siblings.firstIndex(where: { $0.id == blockID }) ?? siblings.count - 1
                let newBlock = followUpBlock(after: block, withText: AttributedString())
                mutate("Split Block") {
                    document.insertSubtree(newBlock, at: DropPath(parent: parentID, position: i + 1))
                }
                transferFocus(to: .editor(newBlock.id, initialCursor: .offset(0)))
                return .handled
            } else {
                let firstChild = block.children[0]
                let newBlock = followUpBlock(after: firstChild, withText: AttributedString())
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
        if headEmpty && tailEmpty {
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

        let newBlock = followUpBlock(after: block, withText: tailAttr)
        let parentID = document.parent(of: blockID)
        let siblings: [Block] = parentID.flatMap(document.find)?.children ?? document.children
        let i = siblings.firstIndex(where: { $0.id == blockID }) ?? siblings.count - 1

        mutate("Split Block") {
            document.setText(blockID, headAttr)
            document.insertSubtree(newBlock, at: DropPath(parent: parentID, position: i + 1))
        }
        transferFocus(to: .editor(newBlock.id, initialCursor: .offset(0)))
        return .handled
    }

    func navigateIntoSubpage(_ blockID: BlockID) -> Bool {
        guard let block = document.find(blockID),
              case .subpage(_, let path) = block.kind else {
            return false
        }
        // Silently swallow the action if the target file is gone. The row
        // already renders in its broken state; navigating would wedge the
        // nav stack on a load that's going to fail.
        guard !host.lookupPage(path).isMissing else { return true }
        transferFocus(to: .nav(cursor: blockID))
        host.didActivateLink(.page(pageID: path))
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
    /// after the selected block and enter edit mode on it.
    func createEmptySiblingAndEdit() -> Bool {
        guard let id = state.cursor, state.selection.count == 1 else { return false }
        return insertEmptySiblingAfter(id)
    }

    func insertEmptySiblingAfter(_ id: BlockID) -> Bool {
        guard let source = document.find(id) else { return false }
        let newBlock = followUpBlock(after: source, withText: AttributedString())
        // Always insert as the next sibling under the source's parent — even
        // containers with children (toggles, lists) get a peer below, not a
        // nested first-child. Headings auto-refold their body via
        // enforceHeadingContainment(), so a sibling inserted after a heading
        // lands at the end of its section as expected.
        let parentID = document.parent(of: id)
        let siblings: [Block] = parentID.flatMap(document.find)?.children ?? document.children
        let i = siblings.firstIndex(where: { $0.id == id }) ?? siblings.count - 1
        let dropPath = DropPath(parent: parentID, position: i + 1)

        mutate("New Block") {
            document.insertSubtree(newBlock, at: dropPath)
        }
        transferFocus(to: .editor(newBlock.id, initialCursor: .offset(0)))
        return true
    }

    private func followUpBlock(after block: Block, withText text: AttributedString) -> Block {
        switch block.kind {
        case .bullet:
            return .bullet(text: text)
        case .numbered:
            return .numbered(text: text)
        case .todo:
            return .todo(text: text, done: false)
        case .quote:
            return .quote(text: text)
        case .heading, .paragraph, .toggle, .templateButton, .code, .divider, .subpage, .image:
            return .paragraph(text: text)
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
