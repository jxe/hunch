import SwiftUI

/// Pure render state for one block row. This is the only value `BlockRow`
/// compares for `.equatable()` gating; callbacks, host references, and focus
/// bindings live in `BlockRowActions`.
struct BlockRowModel: Equatable {
    let block: Block
    let depth: Int
    let isPageTitle: Bool
    let numberingIndex: Int?
    let isSelected: Bool
    let isEditing: Bool
    let isActiveEditor: Bool
    let completionActive: Bool
    let isIconPickerPresented: Bool
    let isExpanded: Bool
    let isDropTarget: Bool
    let isActionMenuTarget: Bool
    let isActionMenuPresented: Bool
    let isPinching: Bool
    let reorderSourceOpacity: Double
    let isReorderingThisBlock: Bool
    let isSelectionHandleRow: Bool
    let accessibilityID: String
    let accessibilityLabelText: String
    let pageLookups: [String: PageLookup]
    let linkPreviews: [URL: LinkPreview]
}

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
struct BlockRow: View, Equatable {
    /// Editor session state. Held as a plain `let` (NOT `@Bindable`) so it
    /// doesn't defeat `BlockRow`'s `.equatable()` gating. Read inside `body`
    /// for fields that should drive a *row-local* invalidation rather than
    /// invalidating `EditorView.body` — currently `hoveredBlock` and
    /// `hoveredHandle`, which drive the drag-handle reveal. Hover writes thus
    /// re-evaluate only the rows that observed the change, leaving the
    /// `LazyVStack` layout untouched — a structural guard against the
    /// hover→write→invalidate→layout→hover-redispatch feedback loop.
    let state: EditorState
    let model: BlockRowModel
    let actions: BlockRowActions

    nonisolated static func == (lhs: BlockRow, rhs: BlockRow) -> Bool {
        MainActor.assumeIsolated {
            lhs.model == rhs.model
        }
    }

    /// Editor-only bindings/closures, present only on the row currently being
    /// edited. Bundled together so `BlockRow` doesn't carry text-editor
    /// plumbing for read-only rows (and so the lift's `BlockRowPreview`
    /// sibling doesn't even exist as a temptation to add it back).
    struct TextEditing {
        /// Plain-typed focus binding (NOT `@FocusState.Binding`). Held by value
        /// so it doesn't defeat `BlockRow`'s `.equatable()` gating; only read
        /// inside `BlockTextEditor`.
        let editorFocused: FocusState<BlockID?>.Binding
        /// True when this row is the actively-edited block (i.e. the one that
        /// should hold first responder). False during the iOS one-tick overlap
        /// where the just-vacated row stays mounted so the new row's UITextView
        /// can grab first responder while the old one is still in the window —
        /// see `iosTransitioningEditorID` in EditorView. The transitioning row's
        /// `BlockTextEditor` reads this to set `wantsFocus = false` and avoid
        /// fighting the new editor for first responder.
        let isActive: Bool
        /// True when an inline-completion popover is interacting with this row —
        /// the only `TextEditing` field whose change has to invalidate body,
        /// hence the only one compared in `BlockRow`'s `==`.
        let completionActive: Bool
        let onKey: (BlockKey) -> KeyPress.Result
        let onAutotransform: (BlockTransform, AttributedString) -> Void
        let onOpenLink: (URL) -> Bool
        /// Fires whenever the cursor sits after an in-progress `@query` (or
        /// transitions out of one). EditorView holds the popover state.
        let onCompletionTriggerChange: (InlineCompletionTrigger?) -> Void
        /// Called once on first mount to fetch the cursor target captured at
        /// tap/split/merge time. EditorView's closure atomically reads and
        /// clears `EditorState.pendingInitialCursor`.
        let consumeInitialCursor: () -> InitialCursorTarget?

        init(
            editorFocused: FocusState<BlockID?>.Binding,
            isActive: Bool = true,
            completionActive: Bool,
            onKey: @escaping (BlockKey) -> KeyPress.Result,
            onAutotransform: @escaping (BlockTransform, AttributedString) -> Void,
            onOpenLink: @escaping (URL) -> Bool,
            onCompletionTriggerChange: @escaping (InlineCompletionTrigger?) -> Void,
            consumeInitialCursor: @escaping () -> InitialCursorTarget?
        ) {
            self.editorFocused = editorFocused
            self.isActive = isActive
            self.completionActive = completionActive
            self.onKey = onKey
            self.onAutotransform = onAutotransform
            self.onOpenLink = onOpenLink
            self.onCompletionTriggerChange = onCompletionTriggerChange
            self.consumeInitialCursor = consumeInitialCursor
        }
    }

    init(model: BlockRowModel, state: EditorState, actions: BlockRowActions) {
        self.model = model
        self.state = state
        self.actions = actions
    }

    var block: Block { model.block }
    var depth: Int { model.depth }
    var isPageTitle: Bool { model.isPageTitle }
    var numberingIndex: Int? { model.numberingIndex }
    var isSelected: Bool { model.isSelected }
    var editor: TextEditing? { actions.editor }
    var isExpanded: Bool { model.isExpanded }
    var isDropTarget: Bool { model.isDropTarget }
    var isActionMenuTarget: Bool { model.isActionMenuTarget }
    var isActionMenuPresented: Bool { model.isActionMenuPresented }
    var isPinching: Bool { model.isPinching }
    var reorderSourceOpacity: Double { model.reorderSourceOpacity }
    var isReorderingThisBlock: Bool { model.isReorderingThisBlock }
    var isSelectionHandleRow: Bool { model.isSelectionHandleRow }
    var accessibilityID: String { model.accessibilityID }
    var accessibilityLabelText: String { model.accessibilityLabelText }
    var pageLookups: [String: PageLookup] { model.pageLookups }
    var linkPreviews: [URL: LinkPreview] { model.linkPreviews }
    var onBlockChange: (Block) -> Void { actions.onBlockChange }
    var onToggleTodo: (BlockID) -> Void { actions.onToggleTodo }
    var onClickAtPoint: (CGPoint) -> Void { actions.onClickAtPoint }
    var onToggleExpansion: () -> Void { actions.onToggleExpansion }
    var onTemplateButtonPress: () -> Void { actions.onTemplateButtonPress }
    var onLinkPreviewLoaded: (URL, LinkPreview) -> Void { actions.onLinkPreviewLoaded }
    var host: EditorHost { actions.host }
    var onTapOutsideText: () -> Void { actions.onTapOutsideText }
    var onSubpageIconTap: () -> Void { actions.onSubpageIconTap }
    var onActionMenuDismiss: () -> Void { actions.onActionMenuDismiss }
    var onCompletionMenuDismiss: () -> Void { actions.onCompletionMenuDismiss }
    var onIconPickerDismiss: () -> Void { actions.onIconPickerDismiss }
    var onIOSDelete: () -> Void { actions.onIOSDelete }
    var onIOSShowMenu: () -> Void { actions.onIOSShowMenu }
    var actionMenuContent: () -> AnyView { actions.actionMenuContent }
    var completionMenuContent: () -> AnyView { actions.completionMenuContent }
    var emojiPickerContent: () -> AnyView { actions.emojiPickerContent }

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

    var body: some View {
        let externalURLs = collectExternalURLs(in: block.text)
        return content
            .padding(.top, BlockSpacing.intrinsicTopPadding(block))
            .padding(.bottom, BlockSpacing.intrinsicBottomPadding(block))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected && !isEditing ? NotionStyle.selectionBackground : Color.clear)
            .task(id: externalURLs) {
                for url in externalURLs where linkPreviews[url] == nil {
                    if let preview = await host.linkPreview(for: url) {
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
                    get: { editor?.completionActive == true },
                    set: { if !$0 { onCompletionMenuDismiss() } }
                )
            ) {
                completionMenuContent()
            }
            .opacity(reorderSourceOpacity)
            .contentShape(Rectangle())
            #if os(iOS)
            .iosBlockTouchActions(
                isEnabled: !isEditing && !isPinching,
                onDelete: onIOSDelete,
                onShowMenu: onIOSShowMenu
            )
            // Row-level tap on iOS enters edit mode (no macOS analog — macOS
            // taps come through `MacPageGestureHost.onClickRow` instead).
            .gesture(
                SpatialTapGesture().onEnded { value in
                    if case .subpage = block.kind,
                       hitsSubpageIconColumn(localX: value.location.x, depth: depth) {
                        onSubpageIconTap()
                    } else {
                        onTapOutsideText()
                    }
                }
            )
            #endif
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier(accessibilityID)
            .accessibilityLabel(accessibilityLabelText)
            .accessibilityValue(isReorderingThisBlock ? "reorder-source" : "")
            .overlay(alignment: .topLeading) {
                // Drag handle: visual-only on macOS — pan + click both come
                // from `MacPageGestureHost`. No `.onHover`, no
                // `.onTapGesture`, no `.macRowReorder` here; those used to
                // anchor recyclable per-row gestures inside the LazyVStack
                // and were the source of the "destroyed mid-drag" failure
                // mode that needed the NSEvent mouse-up backstop.
                DragHandle()
                    .opacity(isHandleVisible && !isEditing ? 1 : 0)
                    .offset(x: -DragHandle.gutterWidth, y: BlockSpacing.dragHandleYOffset(block))
                    .allowsHitTesting(false)
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
                    // `controller.transaction(name:"Type")`;
                    // the resulting diff flows through
                    // `Document.didCommitTransaction` to the host.
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
            Image(systemName: "arrowtriangle.right.fill")
                .font(.system(size: NotionStyle.chevronSize, weight: .medium))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .foregroundStyle(NotionStyle.foreground)
                .frame(width: NotionStyle.bulletMarkerColumnWidth, height: NotionStyle.listMarkerFrameHeight, alignment: .trailing)
                .offset(x: NotionStyle.markerCenteringOffset(markerWidth: NotionStyle.chevronSize))
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
                    InlineRenderer.swiftUIText(block.text, baseFont: NotionStyle.body(), resolvingPageTitle: { pageLookups[$0]?.title })
                        .font(NotionStyle.body())
                        .lineSpacing(NotionStyle.bodyLineSpacing)
                        .textRenderer(InlineCodeChipRenderer())
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
        subpageRowBody(title: title, missing: missing, depth: depth)
            .overlay(alignment: .leading) {
                Color.clear
                    .frame(width: NotionStyle.bulletMarkerColumnWidth)
                    .offset(x: CGFloat(depth) * NotionStyle.indentStep)
                    .allowsHitTesting(false)
                    .popover(
                        isPresented: Binding(
                            get: { model.isIconPickerPresented },
                            set: { if !$0 { onIconPickerDismiss() } }
                        )
                    ) {
                        emojiPickerContent()
                    }
            }
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
                onOpenLink: editor.onOpenLink,
                onCompletionTriggerChange: editor.onCompletionTriggerChange,
                completionActive: editor.completionActive,
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
                    pageLookups: pageLookups,
                    previews: linkPreviews
                )
                    .font(font)
                    .foregroundStyle(muted ? NotionStyle.mutedForeground : NotionStyle.foreground)
                    .lineSpacing(lineSpacing)
                    .textRenderer(InlineCodeChipRenderer())
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

/// Non-equatable row dependencies and callbacks. These are regenerated from
/// `EditorView` on each parent render and deliberately stay out of
/// `BlockRowModel` so equality reflects only visible row state.
struct BlockRowActions {
    let editor: BlockRow.TextEditing?
    let onBlockChange: (Block) -> Void
    let onToggleTodo: (BlockID) -> Void
    let onClickAtPoint: (CGPoint) -> Void
    let onToggleExpansion: () -> Void
    let onTemplateButtonPress: () -> Void
    let onLinkPreviewLoaded: (URL, LinkPreview) -> Void
    let host: EditorHost
    let onTapOutsideText: () -> Void
    let onSubpageIconTap: () -> Void
    let onActionMenuDismiss: () -> Void
    let onCompletionMenuDismiss: () -> Void
    let onIconPickerDismiss: () -> Void
    let onIOSDelete: () -> Void
    let onIOSShowMenu: () -> Void
    let actionMenuContent: () -> AnyView
    let completionMenuContent: () -> AnyView
    let emojiPickerContent: () -> AnyView
}

/// A page title that begins with an emoji ("👍 Emoji Page") lends that
/// emoji to its subpage-row icon; the rest becomes the label. Returns nil
/// when there's no leading emoji, or when stripping it would leave an empty
/// label (an emoji-only title renders normally instead of as a blank row).
func leadingEmojiIcon(in title: String) -> (emoji: String, rest: String)? {
    let trimmed = title.trimmingCharacters(in: .whitespaces)
    guard let first = trimmed.first else { return nil }
    guard isEmojiCharacter(first) else { return nil }
    let rest = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
    guard !rest.isEmpty else { return nil }
    return (String(first), rest)
}

/// Shared subpage-row body (used by both the editing and preview render
/// paths). A leading emoji in the title becomes the row icon in place of
/// the generic `doc.text`; a missing target keeps its warning icon.
@ViewBuilder
func subpageRowBody(title: String, missing: Bool, depth: Int) -> some View {
    let icon = missing ? nil : leadingEmojiIcon(in: title)
    let displayTitle = leadingEmojiIcon(in: title)?.rest ?? title
    HStack(alignment: .firstTextBaseline, spacing: NotionStyle.listMarkerGap) {
        Group {
            if let icon {
                // Slightly larger than the SF Symbol so the emoji reads at a
                // comparable weight; the fixed frame height below keeps the
                // row from growing.
                Text(icon.emoji)
                    .font(.system(size: NotionStyle.subpageEmojiIconSize))
            } else {
                Image(systemName: missing ? "doc.badge.exclamationmark" : "doc.text")
                    .font(.system(size: NotionStyle.pageIconSize))
                    .foregroundStyle(NotionStyle.mutedForeground)
            }
        }
        .frame(width: NotionStyle.bulletMarkerColumnWidth, height: NotionStyle.listMarkerFrameHeight, alignment: .trailing)
        .offset(x: NotionStyle.markerCenteringOffset(
            markerWidth: icon != nil ? NotionStyle.subpageEmojiIconAdvance : NotionStyle.pageIconSize
        ))
        .alignmentGuide(.firstTextBaseline) { dimensions in
            dimensions[VerticalAlignment.center] + NotionStyle.bulletMarkerBaselineOffset
        }
        HStack(spacing: 6) {
            Text(displayTitle)
                .font(NotionStyle.body(weight: .semibold))
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

/// Pre-resolve every workspace-page reference this row needs to render: the
/// subpage pageID for `.subpage` blocks plus every inline workspace-page link
/// URL inside the block's text. Inline-link URLs are classified by the host
/// (`resolvePageID`); the editor doesn't bake in a storage
/// convention. The result is the value `BlockRow` stores as `pageLookups`
/// and compares in `==`, so a rename or delete of any referenced page
/// changes the map for the rows that mention it (and only those rows) —
/// letting `.equatable()` short-circuit the rest while keeping link titles
/// correct and broken-subpage indicators in sync.
///
/// Inline-link entries are keyed by `URL.absoluteString` (what the renderer
/// matches against `run.link.absoluteString`); subpage entries are keyed by
/// the block's stored pageID.
@MainActor
func resolvePageLookups(for block: Block, host: EditorHost, in document: Document) -> [String: PageLookup] {
    var result: [String: PageLookup] = [:]
    if case .subpage(_, let pageID) = block.kind {
        result[pageID] = host.lookupPage(pageID)
    }
    for run in block.text.runs {
        guard let url = run.link, !isExternalLinkURL(url) else { continue }
        guard let pageID = host.resolvePageID(from: url, in: document) else { continue }
        let key = url.absoluteString
        if result[key] == nil {
            result[key] = host.lookupPage(pageID)
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
    pageLookups: [String: PageLookup],
    previews: [URL: LinkPreview]
) -> Text {
    var output = Text("")
    let inlineCodePaddingText = "\u{2005}"
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
            if let resolved = pageLookups[url.absoluteString]?.title {
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

        let renderedDisplay = code ? inlineCodePaddingText + displayText + inlineCodePaddingText : displayText
        var attributed = AttributedString(renderedDisplay)
        if code {
            attributed.font = NotionStyle.mono(size: NotionStyle.inlineCodeSize)
            attributed.foregroundColor = NotionStyle.codeForeground
        } else {
            var f = (bold || link != nil) ? boldFont : baseFont
            if italic { f = f.italic() }
            attributed.font = f
        }
        if strike {
            attributed.strikethroughStyle = .single
        }
        if let url = link {
            attributed.link = url
            attributed.foregroundColor = NotionStyle.foreground
        }

        if let preview = externalWithPreview,
           let iconData = preview.iconPNG,
           let iconImage = decodeFavicon(iconData) {
            output = output + Text(iconImage)
                .baselineOffset(-2)
                + Text(" ")
        }

        var text = Text(attributed)
        if code {
            text = text.customAttribute(InlineCodeChipAttribute())
        }
        output = output + text
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
/// editor closures (`onKey`, `onAutotransform`, `onCompletionTriggerChange`,
/// `editorFocused`, …) or hover/drop state. Equatable so the lift overlay can
/// re-render cheaply if the dragged block's text or page-title resolution
/// changes mid-drag.
struct BlockRowPreview: View, Equatable {
    let block: Block
    let depth: Int
    let isPageTitle: Bool
    let numberingIndex: Int?
    let isExpanded: Bool
    let pageLookups: [String: PageLookup]
    let linkPreviews: [URL: LinkPreview]

    init(
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

    var body: some View {
        content
            .padding(.top, BlockSpacing.intrinsicTopPadding(block))
            .padding(.bottom, BlockSpacing.intrinsicBottomPadding(block))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        switch block.kind {
        case .paragraph:
            text(font: NotionStyle.body(), fontSize: 16, lineSpacing: NotionStyle.bodyLineSpacing)
                .padding(.leading, NotionStyle.nonListLeading(depth: depth))

        case .heading(let level, _):
            let size: CGFloat = (isPageTitle && level == .h1) ? NotionStyle.pageTitleSize
                              : level == .h1 ? NotionStyle.h1Size
                              : level == .h2 ? NotionStyle.h2Size
                                             : NotionStyle.h3Size
            let font = NotionStyle.body(size: size, weight: NotionStyle.headingWeight)
            text(font: font, fontSize: size, lineSpacing: NotionStyle.headingLineSpacing)
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
                text(font: NotionStyle.body(), fontSize: 16, lineSpacing: NotionStyle.bodyLineSpacing)
            }
            .padding(.leading, CGFloat(depth) * NotionStyle.indentStep)

        case .numbered:
            HStack(alignment: .firstTextBaseline, spacing: NotionStyle.listMarkerGap) {
                Text("\(numberingIndex ?? 1).")
                    .font(NotionStyle.body())
                    .foregroundStyle(NotionStyle.foreground)
                    .frame(width: NotionStyle.numberedMarkerColumnWidth, alignment: .trailing)
                text(font: NotionStyle.body(), fontSize: 16, lineSpacing: NotionStyle.bodyLineSpacing)
            }
            .padding(.leading, CGFloat(depth) * NotionStyle.indentStep)

        case .todo(_, let done):
            HStack(alignment: .firstTextBaseline, spacing: NotionStyle.listMarkerGap) {
                Image(systemName: done ? "checkmark.square.fill" : "square")
                    .font(.system(size: NotionStyle.todoCheckboxSize))
                    .foregroundStyle(done ? NotionStyle.mutedForeground : NotionStyle.foreground)
                    .frame(width: NotionStyle.todoMarkerColumnWidth, alignment: .trailing)
                text(font: NotionStyle.body(), fontSize: 16, lineSpacing: NotionStyle.bodyLineSpacing, strikethrough: done, muted: done)
            }
            .padding(.leading, CGFloat(depth) * NotionStyle.indentStep)

        case .quote:
            let quoteFontSize: CGFloat = 16 * 1.2
            HStack(spacing: 14) {
                Rectangle()
                    .fill(NotionStyle.foreground)
                    .frame(width: 3)
                text(font: NotionStyle.body(size: quoteFontSize), fontSize: quoteFontSize, lineSpacing: NotionStyle.bodyLineSpacing)
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
                Image(systemName: "arrowtriangle.right.fill")
                    .font(.system(size: NotionStyle.chevronSize, weight: .medium))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(NotionStyle.foreground)
                    .frame(width: NotionStyle.bulletMarkerColumnWidth, height: NotionStyle.listMarkerFrameHeight, alignment: .trailing)
                    .alignmentGuide(.firstTextBaseline) { dimensions in
                        dimensions[VerticalAlignment.center] + NotionStyle.bulletMarkerBaselineOffset
                    }
                text(font: NotionStyle.body(), fontSize: 16, lineSpacing: NotionStyle.bodyLineSpacing)
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
                    InlineRenderer.swiftUIText(block.text, baseFont: NotionStyle.body(), resolvingPageTitle: { pageLookups[$0]?.title })
                        .font(NotionStyle.body())
                        .lineSpacing(NotionStyle.bodyLineSpacing)
                        .textRenderer(InlineCodeChipRenderer())
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
            subpageRowBody(title: displayTitle, missing: missing, depth: depth)

        case .image(let source, let alt):
            ImageBlockView(source: source, alt: alt)
                .padding(.leading, NotionStyle.nonListLeading(depth: depth))
        }
    }

    @ViewBuilder
    private func text(font: Font, fontSize: CGFloat, lineSpacing: CGFloat, strikethrough: Bool = false, muted: Bool = false) -> some View {
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
                pageLookups: pageLookups,
                previews: linkPreviews
            )
                .font(font)
                .foregroundStyle(muted ? NotionStyle.mutedForeground : NotionStyle.foreground)
                .lineSpacing(lineSpacing)
                .textRenderer(InlineCodeChipRenderer())
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
