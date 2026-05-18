import SwiftUI

/// One block in the page editor — content + the full interactive modifier
/// chain (gestures, popovers, drag handle, accessibility). Equatable so
/// `.equatable()` in `EditorView.body` gates the *whole* row, not just the
/// content's body — that's what stops the modifier chain from re-walking on
/// every parent re-render.
///
/// Closures (gestures, popover content) are captured fresh each render but
/// ignored in `==`. Safe because each callback either reads observable state
/// through reference types (`state`, `host`, the underlying Document) at
/// fire time, or captures only `block.id`/`block.kind` — which by definition
/// match if the equality check passed.
///
/// Used only here for the page editor. The reorder lift overlay uses a slim
/// read-only sibling, `BlockRowPreview`, which strips every editor closure.
public struct BlockRow: View, Equatable {
    /// Block content as a value. Mutations route through `onBlockChange` —
    /// keeping the row free of `@Binding` lets `.equatable()` actually gate
    /// `body` (DynamicProperty wrappers like `@Binding` reset per parent
    /// re-render and force body to run regardless of `==`).
    public let block: Block
    /// Editor session state. Held as a plain `let` (NOT `@Bindable`) so it
    /// doesn't defeat `BlockRow`'s `.equatable()` gating. Read inside `body`
    /// for fields that should drive a *row-local* invalidation rather than
    /// invalidating `EditorView.body` — currently `hoveredBlock` and
    /// `hoveredHandle`, which drive the drag-handle reveal. Hover writes thus
    /// re-evaluate only the rows that observed the change, leaving the
    /// `LazyVStack` layout untouched — a structural guard against the
    /// hover→write→invalidate→layout→hover-redispatch feedback loop.
    public let state: EditorState
    public let onBlockChange: (Block) -> Void
    /// Toggles the `done` state of a `.todo` block. Routed through the host's
    /// mutate path (which computes a `BlockTreeDiff` and emits ops) instead of
    /// the row's binding so the recovery journal sees the hash flip — a bare
    /// `onBlockChange` would skip the diff and leave the prior hash `.alive`.
    public let onToggleTodo: (BlockID) -> Void
    /// Depth of this block in the document tree. Replaces the old per-case
    /// `indent` field — passed in by the visible-layout walk so the row
    /// renders the right leading inset without consulting the model directly.
    public let depth: Int
    public let isPageTitle: Bool
    public let numberingIndex: Int?
    public let isSelected: Bool
    /// nil → render this row read-only. Non-nil → swap in `BlockTextEditor`
    /// for the text area and route key/autotransform/mention events through
    /// these callbacks. At most one row per `EditorView` carries this non-nil
    /// at a time (the row currently being edited).
    public let editor: TextEditing?
    /// Toggle expansion is owned by the parent (EditorView) so the body blocks render as
    /// regular siblings in the page's block loop. Ignored for non-toggle blocks.
    public let isExpanded: Bool
    /// Drag-and-drop hovering this row as the "drop on parent" target — paints a
    /// child-slot preview indicating the dragged content will be appended inside.
    public let isDropTarget: Bool
    /// True when the block action popover (Cmd-/ menu) is targeting this row —
    /// paints a ring around it so the popover's anchor block is unambiguous.
    public let isActionMenuTarget: Bool

    /// Action-menu popover is currently presenting against this row.
    public let isActionMenuPresented: Bool
    /// A page pinch gesture is in flight — disable iOS swipe affordances on
    /// this row so the two gestures don't fight.
    public let isPinching: Bool
    /// Opacity to apply to the row — used to dim the source row of an
    /// in-flight reorder lift.
    public let reorderSourceOpacity: Double
    /// True when this row is part of the in-flight reorder lift — surfaces
    /// in accessibility as `reorder-source`.
    public let isReorderingThisBlock: Bool
    /// True when this row is the multi-select drag-handle anchor (topmost
    /// row in a multi-block selection). The hover-driven side of handle
    /// visibility is read from `state` inside `body` so hover writes don't
    /// invalidate `EditorView.body`.
    public let isSelectionHandleRow: Bool
    /// Whether this row is the source of an in-flight macOS drag — keeps the
    /// handle hit-testable / gesture mounted even if the cursor drifts off.
    public let isMacDragSource: Bool
    public let accessibilityID: String
    public let accessibilityLabelText: String

    /// Render-relevant subset of `BlockRow`'s stored properties. Auto-derived
    /// `Equatable` so the row's `==` is a one-liner instead of a 20-line
    /// hand-written field-by-field check. Adding a new render-relevant
    /// property to `BlockRow` requires adding it here too — but the compiler
    /// catches the omission (the snapshot init fails to type-check), where
    /// a hand-written `==` would silently keep returning `true`.
    ///
    /// Closures (`onClickAtPoint`, gesture/popover callbacks) deliberately
    /// stay out of the snapshot. They're regenerated each render but read
    /// live state at fire time, so excluding them from `==` is exactly what
    /// lets `.equatable()` gating actually short-circuit. See the doc
    /// comment on `BlockRow` for the full reasoning.
    fileprivate struct EqualitySnapshot: Equatable {
        let block: Block
        let depth: Int
        let isPageTitle: Bool
        let numberingIndex: Int?
        let isSelected: Bool
        let isEditing: Bool                // (editor != nil)
        let isActiveEditor: Bool           // editor?.isActive ?? false
        let mentionActive: Bool            // editor?.mentionActive ?? false
        let isExpanded: Bool
        let isDropTarget: Bool
        let isActionMenuTarget: Bool
        let isActionMenuPresented: Bool
        let isPinching: Bool
        let reorderSourceOpacity: Double
        let isReorderingThisBlock: Bool
        let isSelectionHandleRow: Bool
        let isMacDragSource: Bool
        let accessibilityID: String
        let accessibilityLabelText: String
        let pageLookups: [String: PageLookup]
        let linkPreviews: [URL: LinkPreview]
        // `state` is intentionally NOT in the snapshot — the reference is
        // stable for the editor session, and the per-row reads of
        // `state.hoveredBlock` / `state.hoveredHandle` inside `body` set up
        // their own @Observable invalidation channel.
    }

    fileprivate var equalitySnapshot: EqualitySnapshot {
        EqualitySnapshot(
            block: block,
            depth: depth,
            isPageTitle: isPageTitle,
            numberingIndex: numberingIndex,
            isSelected: isSelected,
            isEditing: editor != nil,
            isActiveEditor: editor?.isActive ?? false,
            mentionActive: editor?.mentionActive ?? false,
            isExpanded: isExpanded,
            isDropTarget: isDropTarget,
            isActionMenuTarget: isActionMenuTarget,
            isActionMenuPresented: isActionMenuPresented,
            isPinching: isPinching,
            reorderSourceOpacity: reorderSourceOpacity,
            isReorderingThisBlock: isReorderingThisBlock,
            isSelectionHandleRow: isSelectionHandleRow,
            isMacDragSource: isMacDragSource,
            accessibilityID: accessibilityID,
            accessibilityLabelText: accessibilityLabelText,
            pageLookups: pageLookups,
            linkPreviews: linkPreviews
        )
    }

    nonisolated public static func == (lhs: BlockRow, rhs: BlockRow) -> Bool {
        MainActor.assumeIsolated {
            lhs.equalitySnapshot == rhs.equalitySnapshot
        }
    }

    /// Editor-only bindings/closures, present only on the row currently being
    /// edited. Bundled together so `BlockRow` doesn't carry text-editor
    /// plumbing for read-only rows (and so the lift's `BlockRowPreview`
    /// sibling doesn't even exist as a temptation to add it back).
    public struct TextEditing {
        /// Plain-typed focus binding (NOT `@FocusState.Binding`). Held by value
        /// so it doesn't defeat `BlockRow`'s `.equatable()` gating; only read
        /// inside `BlockTextEditor`.
        public let editorFocused: FocusState<BlockID?>.Binding
        /// True when this row is the actively-edited block (i.e. the one that
        /// should hold first responder). False during the iOS one-tick overlap
        /// where the just-vacated row stays mounted so the new row's UITextView
        /// can grab first responder while the old one is still in the window —
        /// see `iosTransitioningEditorID` in EditorView. The transitioning row's
        /// `BlockTextEditor` reads this to set `wantsFocus = false` and avoid
        /// fighting the new editor for first responder.
        public let isActive: Bool
        /// True when the `@`-mention popover is interacting with this row —
        /// the only `TextEditing` field whose change has to invalidate body,
        /// hence the only one compared in `BlockRow`'s `==`.
        public let mentionActive: Bool
        public let onKey: (BlockKey) -> KeyPress.Result
        public let onAutotransform: (BlockTransform, AttributedString) -> Void
        /// Fires whenever the cursor sits after an in-progress `@query` (or
        /// transitions out of one). EditorView holds the popover state.
        public let onMentionTriggerChange: (MentionTrigger?) -> Void
        /// Called once on first mount to fetch the cursor target captured at
        /// tap/split/merge time. EditorView's closure atomically reads and
        /// clears `EditorState.pendingInitialCursor`.
        public let consumeInitialCursor: () -> InitialCursorTarget?

        public init(
            editorFocused: FocusState<BlockID?>.Binding,
            isActive: Bool = true,
            mentionActive: Bool,
            onKey: @escaping (BlockKey) -> KeyPress.Result,
            onAutotransform: @escaping (BlockTransform, AttributedString) -> Void,
            onMentionTriggerChange: @escaping (MentionTrigger?) -> Void,
            consumeInitialCursor: @escaping () -> InitialCursorTarget?
        ) {
            self.editorFocused = editorFocused
            self.isActive = isActive
            self.mentionActive = mentionActive
            self.onKey = onKey
            self.onAutotransform = onAutotransform
            self.onMentionTriggerChange = onMentionTriggerChange
            self.consumeInitialCursor = consumeInitialCursor
        }
    }

    /// Called when the user clicks the read-only text area to enter edit
    /// mode at a specific point (in editor-local coordinates).
    let onClickAtPoint: (CGPoint) -> Void
    /// Called when the toggle's chevron is tapped. No-op for non-toggle blocks.
    let onToggleExpansion: () -> Void
    let onTemplateButtonPress: () -> Void
    /// Resolved existence + titles for every `.md` page reference this row
    /// needs to render — the subpage path for `.subpage` blocks, plus inline
    /// page links inside `block.text`. Pre-resolved at the call site so page
    /// renames / deletes invalidate the row's `Equatable` `==` (the parent
    /// `lookupPage` closure isn't itself comparable). Map from the link's
    /// `path.md` (matching what `block.kind` stores for subpages and what
    /// `.link` URLs' `absoluteString` carries for inline page links) to the
    /// page's lookup result.
    let pageLookups: [String: PageLookup]

    /// Subset of the host's link-preview cache relevant to this row. Filtered
    /// at the call site to just the URLs in `block.text`, so the dict stays
    /// small and Equatable comparisons are cheap. Async fetches still run
    /// inside this row's `.task` and call `onLinkPreviewLoaded` to write back
    /// to the host's cache.
    let linkPreviews: [URL: LinkPreview]
    let onLinkPreviewLoaded: (URL, LinkPreview) -> Void
    let linkPreviewProvider: LinkPreviewProvider?

    let onTapOutsideText: () -> Void
    let onMacReorderChanged: (DragGesture.Value) -> Void
    let onMacReorderEnded: (DragGesture.Value) -> Void
    let onActionMenuDismiss: () -> Void
    let onMentionMenuDismiss: () -> Void
    let onIOSDelete: () -> Void
    let onIOSShowMenu: () -> Void
    let onHandleHover: (Bool) -> Void
    let onHandleTap: () -> Void
    let onHandleReorderChanged: (DragGesture.Value) -> Void
    let onHandleReorderEnded: (DragGesture.Value) -> Void
    let actionMenuContent: () -> AnyView
    let mentionMenuContent: () -> AnyView

    public init(
        block: Block,
        state: EditorState,
        onBlockChange: @escaping (Block) -> Void,
        onToggleTodo: @escaping (BlockID) -> Void,
        depth: Int,
        editor: TextEditing?,
        isPageTitle: Bool,
        numberingIndex: Int?,
        isSelected: Bool,
        isExpanded: Bool,
        isDropTarget: Bool,
        isActionMenuTarget: Bool,
        isActionMenuPresented: Bool,
        isPinching: Bool,
        reorderSourceOpacity: Double,
        isReorderingThisBlock: Bool,
        isSelectionHandleRow: Bool,
        isMacDragSource: Bool,
        accessibilityID: String,
        accessibilityLabelText: String,
        onClickAtPoint: @escaping (CGPoint) -> Void,
        onToggleExpansion: @escaping () -> Void,
        onTemplateButtonPress: @escaping () -> Void,
        pageLookups: [String: PageLookup],
        linkPreviews: [URL: LinkPreview],
        onLinkPreviewLoaded: @escaping (URL, LinkPreview) -> Void,
        linkPreviewProvider: LinkPreviewProvider?,
        onTapOutsideText: @escaping () -> Void,
        onMacReorderChanged: @escaping (DragGesture.Value) -> Void,
        onMacReorderEnded: @escaping (DragGesture.Value) -> Void,
        onActionMenuDismiss: @escaping () -> Void,
        onMentionMenuDismiss: @escaping () -> Void,
        onIOSDelete: @escaping () -> Void,
        onIOSShowMenu: @escaping () -> Void,
        onHandleHover: @escaping (Bool) -> Void,
        onHandleTap: @escaping () -> Void,
        onHandleReorderChanged: @escaping (DragGesture.Value) -> Void,
        onHandleReorderEnded: @escaping (DragGesture.Value) -> Void,
        actionMenuContent: @escaping () -> AnyView,
        mentionMenuContent: @escaping () -> AnyView
    ) {
        self.block = block
        self.state = state
        self.onBlockChange = onBlockChange
        self.onToggleTodo = onToggleTodo
        self.depth = depth
        self.editor = editor
        self.isPageTitle = isPageTitle
        self.numberingIndex = numberingIndex
        self.isSelected = isSelected
        self.isExpanded = isExpanded
        self.isDropTarget = isDropTarget
        self.isActionMenuTarget = isActionMenuTarget
        self.isActionMenuPresented = isActionMenuPresented
        self.isPinching = isPinching
        self.reorderSourceOpacity = reorderSourceOpacity
        self.isReorderingThisBlock = isReorderingThisBlock
        self.isSelectionHandleRow = isSelectionHandleRow
        self.isMacDragSource = isMacDragSource
        self.accessibilityID = accessibilityID
        self.accessibilityLabelText = accessibilityLabelText
        self.onClickAtPoint = onClickAtPoint
        self.onToggleExpansion = onToggleExpansion
        self.onTemplateButtonPress = onTemplateButtonPress
        self.pageLookups = pageLookups
        self.linkPreviews = linkPreviews
        self.onLinkPreviewLoaded = onLinkPreviewLoaded
        self.linkPreviewProvider = linkPreviewProvider
        self.onTapOutsideText = onTapOutsideText
        self.onMacReorderChanged = onMacReorderChanged
        self.onMacReorderEnded = onMacReorderEnded
        self.onActionMenuDismiss = onActionMenuDismiss
        self.onMentionMenuDismiss = onMentionMenuDismiss
        self.onIOSDelete = onIOSDelete
        self.onIOSShowMenu = onIOSShowMenu
        self.onHandleHover = onHandleHover
        self.onHandleTap = onHandleTap
        self.onHandleReorderChanged = onHandleReorderChanged
        self.onHandleReorderEnded = onHandleReorderEnded
        self.actionMenuContent = actionMenuContent
        self.mentionMenuContent = mentionMenuContent
    }

    /// Convenience: this row is in edit mode (its text area is hosting a
    /// `BlockTextEditor` rather than a read-only renderer).
    var isEditing: Bool { editor != nil }

    /// Combined drag-handle visibility: the multi-select-anchor case (passed
    /// in from `EditorView`) plus the hover-driven case (read from `state`
    /// here, so a hover write invalidates this row's body and *only* this
    /// row's — not `EditorView.body` and therefore not the `LazyVStack`'s
    /// layout pass).
    var isHandleVisible: Bool {
        isSelectionHandleRow
            || state.hoveredBlock == block.id
            || state.hoveredHandle == block.id
    }

    public var body: some View {
        let externalURLs = collectExternalURLs(in: block.text)
        return content
            .padding(.top, BlockSpacing.intrinsicTopPadding(block))
            .padding(.bottom, BlockSpacing.intrinsicBottomPadding(block))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected && !isEditing ? NotionStyle.selectionBackground : Color.clear)
            .task(id: externalURLs) {
                guard let provider = linkPreviewProvider else { return }
                for url in externalURLs where linkPreviews[url] == nil {
                    if let preview = await provider(url) {
                        if Task.isCancelled { return }
                        onLinkPreviewLoaded(url, preview)
                    }
                }
            }
            .background(alignment: .leading) {
                if isDropTarget {
                    let leadingInset = CGFloat(depth) * NotionStyle.indentStep
                    RoundedRectangle(cornerRadius: 5)
                        .fill(NotionStyle.linkForeground.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(NotionStyle.linkForeground.opacity(0.55), lineWidth: 1.5)
                        )
                        .padding(.leading, leadingInset)
                        .padding(.trailing, 4)
                        .allowsHitTesting(false)
                } else if isActionMenuTarget {
                    let leadingInset = CGFloat(depth) * NotionStyle.indentStep
                    let gold = Color(red: 0.83, green: 0.66, blue: 0.18)
                    RoundedRectangle(cornerRadius: 5)
                        .fill(gold.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(gold.opacity(0.42), lineWidth: 1)
                        )
                        .padding(.leading, leadingInset)
                        .padding(.trailing, 4)
                        .allowsHitTesting(false)
                }
            }
            .macRowReorder(
                isEnabled: !isEditing,
                onChanged: onMacReorderChanged,
                onEnded: onMacReorderEnded
            )
            .blockActionPopover(
                isPresented: Binding(
                    get: { isActionMenuPresented },
                    set: { if !$0 { onActionMenuDismiss() } }
                )
            ) {
                actionMenuContent()
            }
            .blockActionPopover(
                isPresented: Binding(
                    get: { editor?.mentionActive == true },
                    set: { if !$0 { onMentionMenuDismiss() } }
                )
            ) {
                mentionMenuContent()
            }
            .opacity(reorderSourceOpacity)
            .contentShape(Rectangle())
            .iosBlockTouchActions(
                isEnabled: !isEditing && !isPinching,
                onDelete: onIOSDelete,
                onShowMenu: onIOSShowMenu
            )
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier(accessibilityID)
            .accessibilityLabel(accessibilityLabelText)
            .accessibilityValue(isReorderingThisBlock ? "reorder-source" : "")
            .onTapGesture {
                onTapOutsideText()
            }
            .overlay(alignment: .topLeading) {
                DragHandle()
                    .opacity(isHandleVisible && !isEditing ? 1 : 0)
                    .offset(x: -DragHandle.gutterWidth, y: BlockSpacing.dragHandleYOffset(block))
                    .onHover(perform: onHandleHover)
                    .onTapGesture(perform: onHandleTap)
                    // Keep the handle hit-testable AND the gesture mounted for
                    // the duration of an in-flight drag. As the cursor leaves
                    // the source row, hoveredBlock shifts and `isHandleVisible`
                    // flips false; without `allowsHitTesting` mirroring the
                    // `isMacDragSource` condition, SwiftUI silently cancels the
                    // gesture mid-drag and `.onEnded` never fires.
                    .macRowReorder(
                        isEnabled: (isHandleVisible || isMacDragSource) && !isEditing,
                        onChanged: onHandleReorderChanged,
                        onEnded: onHandleReorderEnded
                    )
                    .allowsHitTesting(isHandleVisible || isMacDragSource)
            }
    }

    /// AttributedString projection of the block's text for editing. Marks (bold/italic/
    /// code/strike/link) survive editing now — no more lossy String round-trip.
    private var textBinding: Binding<AttributedString> {
        Binding(
            get: { block.text },
            set: { newValue in
                if String(newValue.characters) != String(block.text.characters) ||
                   !attributedStringMarksEqual(newValue, block.text) {
                    // Update the model. Persistence is driven by the live
                    // editor's `commitLiveText`, which opens a
                    // `controller.transaction(name:"Type", coalesceKey:)`;
                    // the resulting diff flows through
                    // `DocumentUndoController.onCommit` to the host.
                    onBlockChange(block.withText(newValue))
                }
            }
        )
    }

    @ViewBuilder
    private var content: some View {
        switch block.kind {
        case .paragraph:
            paragraphRow()

        case .heading(let level, _):
            headingRow(level: level)

        case .bullet:
            bulletRow()

        case .numbered:
            numberedRow()

        case .todo(_, let done):
            todoRow(done: done)

        case .quote:
            quoteRow()

        case .code(let source, let language):
            codeRow(source: source, language: language)

        case .divider:
            dividerRow()

        case .toggle:
            toggleRow()

        case .templateButton:
            templateButtonRow()

        case .subpage(let title, let path):
            let lookup = pageLookups[path]
            subpageRow(title: lookup?.title ?? title, missing: lookup?.isMissing == true)

        case .image(let source, let alt):
            imageRow(source: source, alt: alt)
        }
    }

    private func paragraphRow() -> some View {
        editableText(font: NotionStyle.body(), fontSize: 16, bold: false, lineSpacing: NotionStyle.bodyLineSpacing)
            .padding(.leading, NotionStyle.nonListLeading(depth: depth))
    }

    private func headingRow(level: HeadingLevel) -> some View {
        let size: CGFloat = (isPageTitle && level == .h1) ? NotionStyle.pageTitleSize
                          : level == .h1 ? NotionStyle.h1Size
                          : level == .h2 ? NotionStyle.h2Size
                                         : NotionStyle.h3Size
        let font = NotionStyle.body(size: size, weight: NotionStyle.headingWeight)
        return editableText(font: font, fontSize: size, bold: true, lineSpacing: NotionStyle.headingLineSpacing)
            .padding(.leading, NotionStyle.nonListLeading(depth: depth))
    }

    private func bulletRow() -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NotionStyle.listMarkerGap) {
            Circle()
                .foregroundStyle(NotionStyle.foreground)
                .frame(width: NotionStyle.bulletMarkerDiameter, height: NotionStyle.bulletMarkerDiameter)
                .frame(width: NotionStyle.bulletMarkerColumnWidth, height: NotionStyle.listMarkerFrameHeight, alignment: .trailing)
                .alignmentGuide(.firstTextBaseline) { dimensions in
                    dimensions[VerticalAlignment.center] + NotionStyle.bulletMarkerBaselineOffset
                }
            editableText(font: NotionStyle.body(), fontSize: 16, bold: false, lineSpacing: NotionStyle.bodyLineSpacing)
        }
        .padding(.leading, CGFloat(depth) * NotionStyle.indentStep)
    }

    private func numberedRow() -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NotionStyle.listMarkerGap) {
            Text("\(numberingIndex ?? 1).")
                .font(NotionStyle.body())
                .foregroundStyle(NotionStyle.foreground)
                .frame(width: NotionStyle.numberedMarkerColumnWidth, alignment: .trailing)
            editableText(font: NotionStyle.body(), fontSize: 16, bold: false, lineSpacing: NotionStyle.bodyLineSpacing)
        }
        .padding(.leading, CGFloat(depth) * NotionStyle.indentStep)
    }

    private func todoRow(done: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NotionStyle.listMarkerGap) {
            Button {
                if case .todo = block.kind {
                    onToggleTodo(block.id)
                }
            } label: {
                Image(systemName: done ? "checkmark.square.fill" : "square")
                    .font(.system(size: NotionStyle.todoCheckboxSize))
                    .foregroundStyle(done ? NotionStyle.mutedForeground : NotionStyle.foreground)
                    .frame(width: NotionStyle.todoMarkerColumnWidth, alignment: .trailing)
            }
            .buttonStyle(.plain)
            editableText(
                font: NotionStyle.body(),
                fontSize: 16,
                bold: false,
                lineSpacing: NotionStyle.bodyLineSpacing,
                strikethrough: done,
                muted: done
            )
        }
        .padding(.leading, CGFloat(depth) * NotionStyle.indentStep)
    }

    private func quoteRow() -> some View {
        let quoteFontSize: CGFloat = 16 * 1.2
        return HStack(spacing: 14) {
            Rectangle()
                .fill(NotionStyle.foreground)
                .frame(width: 3)
            editableText(font: NotionStyle.body(size: quoteFontSize), fontSize: quoteFontSize, bold: false, lineSpacing: NotionStyle.bodyLineSpacing)
        }
        .padding(.leading, NotionStyle.nonListLeading(depth: depth))
    }

    private func codeRow(source: String, language: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(NotionStyle.mono(size: 11))
                    .foregroundStyle(NotionStyle.mutedForeground)
                    .padding(.bottom, 8)
            }
            Text(source)
                .font(NotionStyle.mono())
                .foregroundStyle(NotionStyle.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .background(NotionStyle.codeBackground.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.leading, NotionStyle.nonListLeading(depth: depth))
    }

    private func dividerRow() -> some View {
        Rectangle()
            .fill(NotionStyle.dividerColor)
            .frame(height: 1)
            .padding(.leading, NotionStyle.nonListLeading(depth: depth))
    }

    private func toggleRow() -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NotionStyle.listMarkerGap) {
            Image(systemName: "chevron.right")
                .font(.system(size: NotionStyle.chevronSize, weight: .medium))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .foregroundStyle(NotionStyle.foreground)
                .frame(width: NotionStyle.bulletMarkerColumnWidth, height: NotionStyle.listMarkerFrameHeight, alignment: .trailing)
                .alignmentGuide(.firstTextBaseline) { dimensions in
                    dimensions[VerticalAlignment.center] + NotionStyle.bulletMarkerBaselineOffset
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        onToggleExpansion()
                    }
                }

            editableText(font: NotionStyle.body(), fontSize: 16, bold: false, lineSpacing: NotionStyle.bodyLineSpacing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, CGFloat(depth) * NotionStyle.indentStep)
    }

    private func templateButtonRow() -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NotionStyle.listMarkerGap) {
            Image(systemName: "chevron.right")
                .font(.system(size: NotionStyle.chevronSize, weight: .medium))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .foregroundStyle(NotionStyle.foreground)
                .frame(width: NotionStyle.bulletMarkerColumnWidth, height: NotionStyle.listMarkerFrameHeight, alignment: .trailing)
                .alignmentGuide(.firstTextBaseline) { dimensions in
                    dimensions[VerticalAlignment.center] + NotionStyle.bulletMarkerBaselineOffset
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        onToggleExpansion()
                    }
                }

            if isEditing {
                HStack(spacing: 7) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                    editableText(font: NotionStyle.body(), fontSize: 16, bold: false, lineSpacing: NotionStyle.bodyLineSpacing)
                }
                .foregroundStyle(NotionStyle.foreground)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(NotionStyle.selectionBackground.opacity(0.75))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                HStack(spacing: 7) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                    Text(InlineRenderer.swiftUIAttributed(block.text, baseFont: NotionStyle.body(), resolvingPageTitle: { pageLookups[$0]?.title }))
                        .font(NotionStyle.body())
                        .lineSpacing(NotionStyle.bodyLineSpacing)
                }
                .foregroundStyle(NotionStyle.foreground)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(NotionStyle.selectionBackground.opacity(0.75))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .contentShape(RoundedRectangle(cornerRadius: 5))
                .onTapGesture {
                    onTemplateButtonPress()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, CGFloat(depth) * NotionStyle.indentStep)
    }

    private func subpageRow(title: String, missing: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NotionStyle.listMarkerGap) {
            Image(systemName: missing ? "doc.badge.exclamationmark" : "doc.text")
                .font(.system(size: NotionStyle.pageIconSize))
                .foregroundStyle(NotionStyle.mutedForeground)
                .frame(width: NotionStyle.bulletMarkerColumnWidth, height: NotionStyle.listMarkerFrameHeight, alignment: .trailing)
                .offset(x: NotionStyle.markerCenteringOffset(markerWidth: NotionStyle.pageIconSize))
                .alignmentGuide(.firstTextBaseline) { dimensions in
                    dimensions[VerticalAlignment.center] + NotionStyle.bulletMarkerBaselineOffset
                }
            HStack(spacing: 6) {
                Text(title)
                    .font(NotionStyle.body(weight: .medium))
                    .foregroundStyle(missing ? NotionStyle.mutedForeground : NotionStyle.foreground)
                    .lineSpacing(NotionStyle.bodyLineSpacing)
                if missing {
                    Text("(missing)")
                        .font(NotionStyle.body())
                        .foregroundStyle(NotionStyle.mutedForeground)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, CGFloat(depth) * NotionStyle.indentStep)
    }

    private func imageRow(source: String, alt: String) -> some View {
        ImageBlockView(source: source, alt: alt)
            .padding(.leading, NotionStyle.nonListLeading(depth: depth))
    }

    @ViewBuilder
    private func editableText(font: Font, fontSize: CGFloat, bold: Bool, lineSpacing: CGFloat, strikethrough: Bool = false, muted: Bool = false) -> some View {
        if let editor {
            BlockTextEditor(
                text: textBinding,
                font: font,
                fontSize: fontSize,
                bold: bold,
                lineSpacing: lineSpacing,
                focused: editor.editorFocused,
                isActive: editor.isActive,
                blockID: block.id,
                onKey: editor.onKey,
                onAutotransform: editor.onAutotransform,
                onMentionTriggerChange: editor.onMentionTriggerChange,
                mentionActive: editor.mentionActive,
                consumeInitialCursor: editor.consumeInitialCursor
            )
            .foregroundStyle(muted ? NotionStyle.mutedForeground : NotionStyle.foreground)
            .strikethrough(strikethrough)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            if String(block.text.characters).isEmpty {
                Text(" ")
                    .font(font)
                    .lineSpacing(lineSpacing)
                    .opacity(0)
                    .accessibilityHidden(true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { value in
                        onClickAtPoint(value.location)
                    })
            } else {
                decoratedText(
                    block.text,
                    baseFont: font,
                    boldFont: NotionStyle.body(size: fontSize, weight: .semibold),
                    fontSize: fontSize,
                    pageLookups: pageLookups,
                    previews: linkPreviews
                )
                    .font(font)
                    .foregroundStyle(muted ? NotionStyle.mutedForeground : NotionStyle.foreground)
                    .lineSpacing(lineSpacing)
                    .strikethrough(strikethrough)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { value in
                        onClickAtPoint(value.location)
                    })
            }
        }
    }
}

/// Pre-resolve every `.md` page reference this row needs to render: the
/// subpage path for `.subpage` blocks plus every inline page-link URL inside
/// the block's text. The result is the value `BlockRow` stores as
/// `pageLookups` and compares in `==`, so a rename or delete of any
/// referenced page changes the map for the rows that mention it (and only
/// those rows) — letting `.equatable()` short-circuit the rest while keeping
/// link titles correct and broken-subpage indicators in sync.
func resolvePageLookups(for block: Block, resolver: (String) -> PageLookup) -> [String: PageLookup] {
    var result: [String: PageLookup] = [:]
    if case .subpage(_, let path) = block.kind {
        result[path] = resolver(path)
    }
    for run in block.text.runs {
        guard let url = run.link, !isExternalLinkURL(url), url.absoluteString.hasSuffix(".md") else { continue }
        let key = url.absoluteString
        if result[key] == nil {
            result[key] = resolver(key)
        }
    }
    return result
}

/// Walk an `AttributedString` and gather every `http`/`https` URL referenced
/// by an inline `.link` run. Internal `.md` page links don't go through link
/// previews — they have their own subpage-resolution path (`pageLookups`).
func collectExternalURLs(in text: AttributedString) -> Set<URL> {
    var set: Set<URL> = []
    for run in text.runs {
        if let url = run.link, isExternalLinkURL(url) {
            set.insert(url)
        }
    }
    return set
}

func isExternalLinkURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return scheme == "http" || scheme == "https"
}

@MainActor
private func decoratedText(
    _ source: AttributedString,
    baseFont: Font,
    boldFont: Font,
    fontSize: CGFloat,
    pageLookups: [String: PageLookup],
    previews: [URL: LinkPreview]
) -> Text {
    var output = Text("")
    for run in source.runs {
        let segment = source[run.range]
        let runText = String(segment.characters)
        let bold = run[InlineAttributes.BoldAttribute.self] == true
        let italic = run[InlineAttributes.ItalicAttribute.self] == true
        let code = run[InlineAttributes.CodeAttribute.self] == true
        let strike = run[InlineAttributes.StrikethroughAttribute.self] == true
        let link = run.link

        var displayText = runText
        if let url = link {
            if !isExternalLinkURL(url), url.absoluteString.hasSuffix(".md"),
               let resolved = pageLookups[url.absoluteString]?.title {
                displayText = resolved
            } else if isExternalLinkURL(url),
                      let preview = previews[url],
                      let title = preview.title,
                      runMatchesURL(runText, url: url) {
                displayText = abbreviateTitle(title)
            }
        }

        let externalWithPreview = link.flatMap { url -> LinkPreview? in
            guard isExternalLinkURL(url), let preview = previews[url] else { return nil }
            return preview
        }

        var attributed = AttributedString(displayText)
        if code {
            attributed.font = NotionStyle.mono(size: NotionStyle.inlineCodeSize)
            attributed.foregroundColor = NotionStyle.codeForeground
            attributed.backgroundColor = NotionStyle.codeBackground
        } else if externalWithPreview != nil {
            var f = NotionStyle.body(size: fontSize, weight: .medium)
            if italic { f = f.italic() }
            attributed.font = f
        } else {
            var f = bold ? boldFont : baseFont
            if italic { f = f.italic() }
            attributed.font = f
        }
        if strike {
            attributed.strikethroughStyle = .single
        }
        if let url = link {
            attributed.link = url
            if externalWithPreview == nil {
                attributed.underlineStyle = .single
                attributed.foregroundColor = NotionStyle.linkForeground
            }
        }

        if let preview = externalWithPreview,
           let iconData = preview.iconPNG,
           let iconImage = decodeFavicon(iconData) {
            output = output + Text(iconImage)
                .baselineOffset(-2)
                + Text(" ")
        }

        output = output + Text(attributed)
    }
    return output
}

private func runMatchesURL(_ runText: String, url: URL) -> Bool {
    let trimmed = runText.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == url.absoluteString { return true }
    if let host = url.host, trimmed == host { return true }
    return false
}

#if os(macOS)
import AppKit
private func decodeFavicon(_ data: Data) -> Image? {
    guard let nsImage = NSImage(data: data) else { return nil }
    nsImage.size = NSSize(width: NotionStyle.pageIconSize, height: NotionStyle.pageIconSize)
    return Image(nsImage: nsImage)
}
#else
import UIKit
private func decodeFavicon(_ data: Data) -> Image? {
    guard let uiImage = UIImage(data: data, scale: 2) else { return nil }
    return Image(uiImage: uiImage)
}
#endif

/// Read-only block renderer used by the reorder lift overlay. The lift just
/// shows what's being dragged — no editing, no gestures, no popovers, no
/// link-preview fetching. So this view doesn't carry any of `BlockRowContent`'s
/// editor closures (`onKey`, `onAutotransform`, `onMentionTriggerChange`,
/// `editorFocused`, …) or hover/drop state. Equatable so the lift overlay can
/// re-render cheaply if the dragged block's text or page-title resolution
/// changes mid-drag.
public struct BlockRowPreview: View, Equatable {
    public let block: Block
    public let depth: Int
    public let isPageTitle: Bool
    public let numberingIndex: Int?
    public let isExpanded: Bool
    public let pageLookups: [String: PageLookup]
    public let linkPreviews: [URL: LinkPreview]

    public init(
        block: Block,
        depth: Int,
        isPageTitle: Bool = false,
        numberingIndex: Int? = nil,
        isExpanded: Bool = false,
        pageLookups: [String: PageLookup] = [:],
        linkPreviews: [URL: LinkPreview] = [:]
    ) {
        self.block = block
        self.depth = depth
        self.isPageTitle = isPageTitle
        self.numberingIndex = numberingIndex
        self.isExpanded = isExpanded
        self.pageLookups = pageLookups
        self.linkPreviews = linkPreviews
    }

    public var body: some View {
        content
            .padding(.top, BlockSpacing.intrinsicTopPadding(block))
            .padding(.bottom, BlockSpacing.intrinsicBottomPadding(block))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        switch block.kind {
        case .paragraph:
            text(font: NotionStyle.body(), fontSize: 16, bold: false, lineSpacing: NotionStyle.bodyLineSpacing)
                .padding(.leading, NotionStyle.nonListLeading(depth: depth))

        case .heading(let level, _):
            let size: CGFloat = (isPageTitle && level == .h1) ? NotionStyle.pageTitleSize
                              : level == .h1 ? NotionStyle.h1Size
                              : level == .h2 ? NotionStyle.h2Size
                                             : NotionStyle.h3Size
            let font = NotionStyle.body(size: size, weight: NotionStyle.headingWeight)
            text(font: font, fontSize: size, bold: true, lineSpacing: NotionStyle.headingLineSpacing)
                .padding(.leading, NotionStyle.nonListLeading(depth: depth))

        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: NotionStyle.listMarkerGap) {
                Circle()
                    .foregroundStyle(NotionStyle.foreground)
                    .frame(width: NotionStyle.bulletMarkerDiameter, height: NotionStyle.bulletMarkerDiameter)
                    .frame(width: NotionStyle.bulletMarkerColumnWidth, height: NotionStyle.listMarkerFrameHeight, alignment: .trailing)
                    .alignmentGuide(.firstTextBaseline) { dimensions in
                        dimensions[VerticalAlignment.center] + NotionStyle.bulletMarkerBaselineOffset
                    }
                text(font: NotionStyle.body(), fontSize: 16, bold: false, lineSpacing: NotionStyle.bodyLineSpacing)
            }
            .padding(.leading, CGFloat(depth) * NotionStyle.indentStep)

        case .numbered:
            HStack(alignment: .firstTextBaseline, spacing: NotionStyle.listMarkerGap) {
                Text("\(numberingIndex ?? 1).")
                    .font(NotionStyle.body())
                    .foregroundStyle(NotionStyle.foreground)
                    .frame(width: NotionStyle.numberedMarkerColumnWidth, alignment: .trailing)
                text(font: NotionStyle.body(), fontSize: 16, bold: false, lineSpacing: NotionStyle.bodyLineSpacing)
            }
            .padding(.leading, CGFloat(depth) * NotionStyle.indentStep)

        case .todo(_, let done):
            HStack(alignment: .firstTextBaseline, spacing: NotionStyle.listMarkerGap) {
                Image(systemName: done ? "checkmark.square.fill" : "square")
                    .font(.system(size: NotionStyle.todoCheckboxSize))
                    .foregroundStyle(done ? NotionStyle.mutedForeground : NotionStyle.foreground)
                    .frame(width: NotionStyle.todoMarkerColumnWidth, alignment: .trailing)
                text(font: NotionStyle.body(), fontSize: 16, bold: false, lineSpacing: NotionStyle.bodyLineSpacing, strikethrough: done, muted: done)
            }
            .padding(.leading, CGFloat(depth) * NotionStyle.indentStep)

        case .quote:
            let quoteFontSize: CGFloat = 16 * 1.2
            HStack(spacing: 14) {
                Rectangle()
                    .fill(NotionStyle.foreground)
                    .frame(width: 3)
                text(font: NotionStyle.body(size: quoteFontSize), fontSize: quoteFontSize, bold: false, lineSpacing: NotionStyle.bodyLineSpacing)
            }
            .padding(.leading, NotionStyle.nonListLeading(depth: depth))

        case .code(let source, let language):
            VStack(alignment: .leading, spacing: 0) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(NotionStyle.mono(size: 11))
                        .foregroundStyle(NotionStyle.mutedForeground)
                        .padding(.bottom, 8)
                }
                Text(source)
                    .font(NotionStyle.mono())
                    .foregroundStyle(NotionStyle.foreground)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .background(NotionStyle.codeBackground.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.leading, NotionStyle.nonListLeading(depth: depth))

        case .divider:
            Rectangle()
                .fill(NotionStyle.dividerColor)
                .frame(height: 1)
                .padding(.leading, NotionStyle.nonListLeading(depth: depth))

        case .toggle:
            HStack(alignment: .firstTextBaseline, spacing: NotionStyle.listMarkerGap) {
                Image(systemName: "chevron.right")
                    .font(.system(size: NotionStyle.chevronSize, weight: .medium))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(NotionStyle.foreground)
                    .frame(width: NotionStyle.bulletMarkerColumnWidth, height: NotionStyle.listMarkerFrameHeight, alignment: .trailing)
                    .alignmentGuide(.firstTextBaseline) { dimensions in
                        dimensions[VerticalAlignment.center] + NotionStyle.bulletMarkerBaselineOffset
                    }
                text(font: NotionStyle.body(), fontSize: 16, bold: false, lineSpacing: NotionStyle.bodyLineSpacing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, CGFloat(depth) * NotionStyle.indentStep)

        case .templateButton:
            HStack(alignment: .firstTextBaseline, spacing: NotionStyle.listMarkerGap) {
                Image(systemName: "chevron.right")
                    .font(.system(size: NotionStyle.chevronSize, weight: .medium))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(NotionStyle.foreground)
                    .frame(width: NotionStyle.bulletMarkerColumnWidth, height: NotionStyle.listMarkerFrameHeight, alignment: .trailing)
                    .alignmentGuide(.firstTextBaseline) { dimensions in
                        dimensions[VerticalAlignment.center] + NotionStyle.bulletMarkerBaselineOffset
                    }
                HStack(spacing: 7) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                    Text(InlineRenderer.swiftUIAttributed(block.text, baseFont: NotionStyle.body(), resolvingPageTitle: { pageLookups[$0]?.title }))
                        .font(NotionStyle.body())
                        .lineSpacing(NotionStyle.bodyLineSpacing)
                }
                .foregroundStyle(NotionStyle.foreground)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(NotionStyle.selectionBackground.opacity(0.75))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, CGFloat(depth) * NotionStyle.indentStep)

        case .subpage(let title, let path):
            let lookup = pageLookups[path]
            let displayTitle = lookup?.title ?? title
            let missing = lookup?.isMissing == true
            HStack(alignment: .firstTextBaseline, spacing: NotionStyle.listMarkerGap) {
                Image(systemName: missing ? "doc.badge.exclamationmark" : "doc.text")
                    .font(.system(size: NotionStyle.pageIconSize))
                    .foregroundStyle(NotionStyle.mutedForeground)
                    .frame(width: NotionStyle.bulletMarkerColumnWidth, height: NotionStyle.listMarkerFrameHeight, alignment: .trailing)
                    .offset(x: NotionStyle.markerCenteringOffset(markerWidth: NotionStyle.pageIconSize))
                    .alignmentGuide(.firstTextBaseline) { dimensions in
                        dimensions[VerticalAlignment.center] + NotionStyle.bulletMarkerBaselineOffset
                    }
                HStack(spacing: 6) {
                    Text(displayTitle)
                        .font(NotionStyle.body(weight: .medium))
                        .foregroundStyle(missing ? NotionStyle.mutedForeground : NotionStyle.foreground)
                        .lineSpacing(NotionStyle.bodyLineSpacing)
                    if missing {
                        Text("(missing)")
                            .font(NotionStyle.body())
                            .foregroundStyle(NotionStyle.mutedForeground)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, CGFloat(depth) * NotionStyle.indentStep)

        case .image(let source, let alt):
            ImageBlockView(source: source, alt: alt)
                .padding(.leading, NotionStyle.nonListLeading(depth: depth))
        }
    }

    @ViewBuilder
    private func text(font: Font, fontSize: CGFloat, bold: Bool, lineSpacing: CGFloat, strikethrough: Bool = false, muted: Bool = false) -> some View {
        if String(block.text.characters).isEmpty {
            Text(" ")
                .font(font)
                .lineSpacing(lineSpacing)
                .opacity(0)
                .accessibilityHidden(true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            decoratedText(
                block.text,
                baseFont: font,
                boldFont: NotionStyle.body(size: fontSize, weight: .semibold),
                fontSize: fontSize,
                pageLookups: pageLookups,
                previews: linkPreviews
            )
                .font(font)
                .foregroundStyle(muted ? NotionStyle.mutedForeground : NotionStyle.foreground)
                .lineSpacing(lineSpacing)
                .strikethrough(strikethrough)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

func attributedStringMarksEqual(_ a: AttributedString, _ b: AttributedString) -> Bool {
    let aRuns = Array(a.runs)
    let bRuns = Array(b.runs)
    guard aRuns.count == bRuns.count else { return false }
    for (ra, rb) in zip(aRuns, bRuns) {
        if String(a[ra.range].characters) != String(b[rb.range].characters) { return false }
        if (ra[InlineAttributes.BoldAttribute.self] == true) != (rb[InlineAttributes.BoldAttribute.self] == true) { return false }
        if (ra[InlineAttributes.ItalicAttribute.self] == true) != (rb[InlineAttributes.ItalicAttribute.self] == true) { return false }
        if (ra[InlineAttributes.CodeAttribute.self] == true) != (rb[InlineAttributes.CodeAttribute.self] == true) { return false }
        if (ra[InlineAttributes.StrikethroughAttribute.self] == true) != (rb[InlineAttributes.StrikethroughAttribute.self] == true) { return false }
        if ra.link != rb.link { return false }
    }
    return true
}
