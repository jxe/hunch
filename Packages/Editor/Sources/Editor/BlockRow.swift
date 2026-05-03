import SwiftUI

public struct BlockRow: View {
    @Binding var block: Block
    public let isPageTitle: Bool
    public let numberingIndex: Int?
    public let isSelected: Bool
    public let isEditing: Bool
    /// Toggle expansion is owned by the parent (EditorView) so the body blocks render as
    /// regular siblings in the page's block loop. Ignored for non-toggle blocks.
    public let isExpanded: Bool
    /// Drag-and-drop hovering this row as the "drop on parent" target — paints a
    /// child-slot preview indicating the dragged content will be appended inside.
    public let isDropTarget: Bool
    /// True when the block action popover (Cmd-/ menu) is targeting this row —
    /// paints a ring around it so the popover's anchor block is unambiguous.
    public let isActionMenuTarget: Bool
    @FocusState.Binding var editorFocused: BlockID?
    let onKey: (BlockKey) -> KeyPress.Result
    let onEdited: () -> Void
    let onAutotransform: (BlockTransform, AttributedString) -> Void
    /// Forwarded to the editor — fires whenever the cursor sits after an in-progress
    /// `@query` (or transitions out of one). EditorView holds the popover state.
    let onMentionTriggerChange: (MentionTrigger?) -> Void
    /// Forwarded to the editor — when true, ↑/↓/Return/Esc are diverted to menu-nav
    /// events instead of intra-block / exit-edit.
    let mentionActive: Bool
    /// Called when the user clicks the editable text area while not editing — point is
    /// in the editor area's local coordinate space (matches what `NSTextView`'s
    /// `characterIndexForInsertion(at:)` expects).
    let onClickAtPoint: (CGPoint) -> Void
    /// Called when the toggle's chevron is tapped. No-op for non-toggle blocks.
    let onToggleExpansion: () -> Void
    let onTemplateButtonPress: () -> Void
    let pageTitle: (String) -> String?
    /// Forwarded to the BlockTextEditor — called once on its first mount to fetch
    /// the cursor target captured at tap/split/merge time. EditorView constructs
    /// this closure to atomically read-and-clear `EditorState.pendingInitialCursor`.
    let consumeInitialCursor: () -> InitialCursorTarget?

    public init(
        block: Binding<Block>,
        editorFocused: FocusState<BlockID?>.Binding,
        isPageTitle: Bool = false,
        numberingIndex: Int? = nil,
        isSelected: Bool = false,
        isEditing: Bool = false,
        isExpanded: Bool = false,
        isDropTarget: Bool = false,
        isActionMenuTarget: Bool = false,
        onKey: @escaping (BlockKey) -> KeyPress.Result = { _ in .ignored },
        onEdited: @escaping () -> Void = {},
        onAutotransform: @escaping (BlockTransform, AttributedString) -> Void = { _, _ in },
        onMentionTriggerChange: @escaping (MentionTrigger?) -> Void = { _ in },
        mentionActive: Bool = false,
        onClickAtPoint: @escaping (CGPoint) -> Void = { _ in },
        onToggleExpansion: @escaping () -> Void = {},
        onTemplateButtonPress: @escaping () -> Void = {},
        pageTitle: @escaping (String) -> String? = { _ in nil },
        consumeInitialCursor: @escaping () -> InitialCursorTarget? = { nil }
    ) {
        self._block = block
        self.isPageTitle = isPageTitle
        self.numberingIndex = numberingIndex
        self.isSelected = isSelected
        self.isEditing = isEditing
        self.isExpanded = isExpanded
        self.isDropTarget = isDropTarget
        self.isActionMenuTarget = isActionMenuTarget
        self._editorFocused = editorFocused
        self.onKey = onKey
        self.onEdited = onEdited
        self.onAutotransform = onAutotransform
        self.onMentionTriggerChange = onMentionTriggerChange
        self.mentionActive = mentionActive
        self.onClickAtPoint = onClickAtPoint
        self.onToggleExpansion = onToggleExpansion
        self.onTemplateButtonPress = onTemplateButtonPress
        self.pageTitle = pageTitle
        self.consumeInitialCursor = consumeInitialCursor
    }

    public var body: some View {
        content
            .padding(.vertical, BlockSpacing.intrinsicVerticalPadding(block))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected && !isEditing ? NotionStyle.selectionBackground : Color.clear)
            .background(alignment: .leading) {
                // Toggle / templateButton / subpage are the only blocks that
                // become drop targets — for those we want a "drop on folder"
                // affordance: tint + ring around the parent row itself, no
                // child-slot preview.
                if isDropTarget {
                    let leadingInset = CGFloat(block.indent) * NotionStyle.indentStep
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
                    let leadingInset = CGFloat(block.indent) * NotionStyle.indentStep
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
    }

    /// AttributedString projection of the block's text for editing. Marks (bold/italic/
    /// code/strike/link) survive editing now — no more lossy String round-trip.
    private var textBinding: Binding<AttributedString> {
        Binding(
            get: { block.text },
            set: { newValue in
                if String(newValue.characters) != String(block.text.characters) ||
                   !attributedStringMarksEqual(newValue, block.text) {
                    block = block.withText(newValue)
                    onEdited()
                }
            }
        )
    }

    @ViewBuilder
    private var content: some View {
        switch block {
        case .paragraph(_, _, let indent):
            paragraphRow(indent: indent)

        case .heading(_, let level, _, let indent):
            headingRow(level: level, indent: indent)

        case .bullet(_, _, let indent):
            bulletRow(indent: indent)

        case .numbered(_, _, let indent):
            numberedRow(indent: indent)

        case .todo(_, _, let done, let indent):
            todoRow(done: done, indent: indent)

        case .quote(_, _, let indent):
            quoteRow(indent: indent)

        case .code(_, let source, let language, let indent):
            codeRow(source: source, language: language, indent: indent)

        case .divider(_, let indent):
            dividerRow(indent: indent)

        case .toggle(_, _, let indent):
            toggleRow(indent: indent)

        case .templateButton(_, _, let indent):
            templateButtonRow(indent: indent)

        case .subpage(_, let title, let path, let indent):
            subpageRow(title: pageTitle(path) ?? title, indent: indent)
        }
    }

    private func paragraphRow(indent: Int) -> some View {
        editableText(font: NotionStyle.body(), fontSize: 16, bold: false, lineSpacing: NotionStyle.bodyLineSpacing)
            .padding(.leading, NotionStyle.nonListLeading(indent: indent))
    }

    private func headingRow(level: Int, indent: Int) -> some View {
        let size: CGFloat = (isPageTitle && level == 1) ? NotionStyle.pageTitleSize
                          : level == 1 ? NotionStyle.h1Size
                          : level == 2 ? NotionStyle.h2Size
                                       : NotionStyle.h3Size
        let font = NotionStyle.body(size: size, weight: NotionStyle.headingWeight)
        return editableText(font: font, fontSize: size, bold: true, lineSpacing: NotionStyle.headingLineSpacing)
            .padding(.leading, NotionStyle.nonListLeading(indent: indent))
    }

    private func bulletRow(indent: Int) -> some View {
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
        .padding(.leading, CGFloat(indent) * NotionStyle.indentStep)
    }

    private func numberedRow(indent: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NotionStyle.listMarkerGap) {
            Text("\(numberingIndex ?? 1).")
                .font(NotionStyle.body())
                .foregroundStyle(NotionStyle.foreground)
                .frame(width: NotionStyle.numberedMarkerColumnWidth, alignment: .trailing)
            editableText(font: NotionStyle.body(), fontSize: 16, bold: false, lineSpacing: NotionStyle.bodyLineSpacing)
        }
        .padding(.leading, CGFloat(indent) * NotionStyle.indentStep)
    }

    private func todoRow(done: Bool, indent: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NotionStyle.listMarkerGap) {
            Button {
                if case .todo(let id, let text, let isDone, let i) = block {
                    block = .todo(id: id, text: text, done: !isDone, indent: i)
                    onEdited()
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
        .padding(.leading, CGFloat(indent) * NotionStyle.indentStep)
    }

    private func quoteRow(indent: Int) -> some View {
        let quoteFontSize: CGFloat = 16 * 1.2
        return HStack(spacing: 14) {
            Rectangle()
                .fill(NotionStyle.foreground)
                .frame(width: 3)
            editableText(font: NotionStyle.body(size: quoteFontSize), fontSize: quoteFontSize, bold: false, lineSpacing: NotionStyle.bodyLineSpacing)
        }
        .padding(.leading, NotionStyle.nonListLeading(indent: indent))
    }

    private func codeRow(source: String, language: String?, indent: Int) -> some View {
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
        .padding(.leading, NotionStyle.nonListLeading(indent: indent))
    }

    private func dividerRow(indent: Int) -> some View {
        Rectangle()
            .fill(NotionStyle.dividerColor)
            .frame(height: 1)
            .padding(.leading, NotionStyle.nonListLeading(indent: indent))
    }

    private func toggleRow(indent: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NotionStyle.listMarkerGap) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    onToggleExpansion()
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: NotionStyle.chevronSize, weight: .medium))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(NotionStyle.foreground)
                    .frame(width: NotionStyle.bulletMarkerColumnWidth, height: NotionStyle.listMarkerFrameHeight, alignment: .trailing)
                    .alignmentGuide(.firstTextBaseline) { dimensions in
                        dimensions[VerticalAlignment.center] + NotionStyle.bulletMarkerBaselineOffset
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            editableText(font: NotionStyle.body(), fontSize: 16, bold: false, lineSpacing: NotionStyle.bodyLineSpacing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, CGFloat(indent) * NotionStyle.indentStep)
    }

    private func templateButtonRow(indent: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NotionStyle.listMarkerGap) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    onToggleExpansion()
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: NotionStyle.chevronSize, weight: .medium))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(NotionStyle.foreground)
                    .frame(width: NotionStyle.bulletMarkerColumnWidth, height: NotionStyle.listMarkerFrameHeight, alignment: .trailing)
                    .alignmentGuide(.firstTextBaseline) { dimensions in
                        dimensions[VerticalAlignment.center] + NotionStyle.bulletMarkerBaselineOffset
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

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
                    Text(InlineRenderer.swiftUIAttributed(block.text, baseFont: NotionStyle.body(), resolvingPageTitle: pageTitle))
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
        .padding(.leading, CGFloat(indent) * NotionStyle.indentStep)
    }

    private func subpageRow(title: String, indent: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NotionStyle.listMarkerGap) {
            Image(systemName: "doc.text")
                .font(.system(size: NotionStyle.pageIconSize))
                .foregroundStyle(NotionStyle.mutedForeground)
                .frame(width: NotionStyle.bulletMarkerColumnWidth, height: NotionStyle.listMarkerFrameHeight, alignment: .trailing)
                .alignmentGuide(.firstTextBaseline) { dimensions in
                    dimensions[VerticalAlignment.center] + NotionStyle.bulletMarkerBaselineOffset
                }
            Text(title)
                .font(NotionStyle.body(weight: .medium))
                .foregroundStyle(NotionStyle.foreground)
                .lineSpacing(NotionStyle.bodyLineSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, CGFloat(indent) * NotionStyle.indentStep)
    }

    /// Renders the block's text. When `isEditing` is true (this row is the active editor),
    /// shows a `BlockTextEditor`; otherwise a read-only formatted `Text`. Only ONE editor is
    /// ever mounted across the whole page — the rest are plain `Text`.
    @ViewBuilder
    private func editableText(font: Font, fontSize: CGFloat, bold: Bool, lineSpacing: CGFloat, strikethrough: Bool = false, muted: Bool = false) -> some View {
        if isEditing {
            BlockTextEditor(
                text: textBinding,
                font: font,
                fontSize: fontSize,
                bold: bold,
                lineSpacing: lineSpacing,
                focused: $editorFocused,
                blockID: block.id,
                onKey: onKey,
                onAutotransform: onAutotransform,
                onMentionTriggerChange: onMentionTriggerChange,
                mentionActive: mentionActive,
                consumeInitialCursor: consumeInitialCursor
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
                Text(InlineRenderer.swiftUIAttributed(
                    block.text,
                    baseFont: font,
                    boldFont: NotionStyle.body(size: fontSize, weight: .semibold),
                    resolvingPageTitle: pageTitle
                ))
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

/// Compare two AttributedStrings on the marks the editor cares about (bold/italic/code/
/// strike/link). We can't rely on `==` because the editor's NSAttributedString round-trip
/// drops scope-unaware Cocoa attrs (paragraph style, font), and we need the binding
/// setter to fire iff a *meaningful* mark changed.
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
