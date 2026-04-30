import SwiftUI
import Core

/// Translates a `Core.AttributedString` (with our custom inline marks) into a SwiftUI-renderable
/// `AttributedString` that uses Foundation/SwiftUI attributes (font weight, italic, link, etc.).
public enum InlineRenderer {
    public static func swiftUIAttributed(_ source: AttributedString, baseFont: Font = NotionStyle.body()) -> AttributedString {
        var result = AttributedString()
        for run in source.runs {
            let segment = source[run.range]
            var attributed = AttributedString(String(segment.characters))

            let bold = run[InlineAttributes.BoldAttribute.self] == true
            let italic = run[InlineAttributes.ItalicAttribute.self] == true
            let code = run[InlineAttributes.CodeAttribute.self] == true
            let strike = run[InlineAttributes.StrikethroughAttribute.self] == true
            let link = run.link

            if code {
                attributed.font = NotionStyle.mono(size: NotionStyle.inlineCodeSize)
                attributed.foregroundColor = NotionStyle.codeForeground
                attributed.backgroundColor = NotionStyle.codeBackground
            } else {
                var font = baseFont
                if bold && italic {
                    font = font.weight(.semibold).italic()
                } else if bold {
                    font = font.weight(.semibold)
                } else if italic {
                    font = font.italic()
                }
                attributed.font = font
            }

            if strike {
                attributed.strikethroughStyle = .single
            }
            if let link {
                attributed.link = link
                attributed.underlineStyle = .single
                attributed.foregroundColor = .blue
            }

            result.append(attributed)
        }
        return result
    }
}

// MARK: - Block row

public struct BlockRow: View {
    @Binding var block: Block
    public let isPageTitle: Bool
    public let numberingIndex: Int?
    public let isSelected: Bool
    public let isEditing: Bool
    @FocusState.Binding var editorFocused: BlockID?
    let onKey: (BlockKey) -> KeyPress.Result
    let onEdited: () -> Void
    let onAutotransform: (BlockTransform, AttributedString) -> Void
    /// Called when the user clicks the editable text area while not editing — point is
    /// in the editor area's local coordinate space (matches what `NSTextView`'s
    /// `characterIndexForInsertion(at:)` expects).
    let onClickAtPoint: (CGPoint) -> Void
    /// Click point captured at tap time, threaded into the BlockTextEditor on its first
    /// mount so the cursor lands where the user clicked rather than at end-of-text.
    let initialCursorPoint: CGPoint?

    public init(
        block: Binding<Block>,
        editorFocused: FocusState<BlockID?>.Binding,
        isPageTitle: Bool = false,
        numberingIndex: Int? = nil,
        isSelected: Bool = false,
        isEditing: Bool = false,
        onKey: @escaping (BlockKey) -> KeyPress.Result = { _ in .ignored },
        onEdited: @escaping () -> Void = {},
        onAutotransform: @escaping (BlockTransform, AttributedString) -> Void = { _, _ in },
        onClickAtPoint: @escaping (CGPoint) -> Void = { _ in },
        initialCursorPoint: CGPoint? = nil
    ) {
        self._block = block
        self.isPageTitle = isPageTitle
        self.numberingIndex = numberingIndex
        self.isSelected = isSelected
        self.isEditing = isEditing
        self._editorFocused = editorFocused
        self.onKey = onKey
        self.onEdited = onEdited
        self.onAutotransform = onAutotransform
        self.onClickAtPoint = onClickAtPoint
        self.initialCursorPoint = initialCursorPoint
    }

    public var body: some View {
        content
            .padding(.vertical, BlockSpacing.intrinsicVerticalPadding(block))
            .background(isSelected && !isEditing ? Color.accentColor.opacity(0.12) : Color.clear)
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

        case .toggle(_, _, _, _, let indent):
            toggleRow
                .padding(.leading, CGFloat(indent) * NotionStyle.indentStep)

        case .subpage(_, let title, _, let indent):
            subpageRow(title: title, indent: indent)
        }
    }

    private func paragraphRow(indent: Int) -> some View {
        editableText(font: NotionStyle.body(), fontSize: 16, bold: false, lineSpacing: NotionStyle.bodyLineSpacing)
            .padding(.leading, CGFloat(indent) * NotionStyle.indentStep)
    }

    private func headingRow(level: Int, indent: Int) -> some View {
        let size: CGFloat = (isPageTitle && level == 1) ? NotionStyle.pageTitleSize
                          : level == 1 ? NotionStyle.h1Size
                          : level == 2 ? NotionStyle.h2Size
                                       : NotionStyle.h3Size
        let font = NotionStyle.body(size: size).weight(NotionStyle.headingWeight)
        return editableText(font: font, fontSize: size, bold: true, lineSpacing: NotionStyle.headingLineSpacing)
            .padding(.leading, CGFloat(indent) * NotionStyle.indentStep)
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
        .padding(.leading, CGFloat(indent) * NotionStyle.indentStep)
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
        .padding(.leading, CGFloat(indent) * NotionStyle.indentStep)
    }

    private func dividerRow(indent: Int) -> some View {
        Rectangle()
            .fill(NotionStyle.dividerColor)
            .frame(height: 1)
            .padding(.leading, CGFloat(indent) * NotionStyle.indentStep)
    }

    private var toggleRow: some View {
        ToggleRowView(
            block: $block,
            editorFocused: $editorFocused,
            isSelected: isSelected,
            isEditing: isEditing,
            onKey: onKey,
            onEdited: onEdited,
            onAutotransform: onAutotransform
        )
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
                .font(NotionStyle.body().weight(.medium))
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
                initialCursorPoint: initialCursorPoint
            )
            .foregroundStyle(muted ? NotionStyle.mutedForeground : NotionStyle.foreground)
            .strikethrough(strikethrough)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(InlineRenderer.swiftUIAttributed(block.text, baseFont: font))
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

// MARK: - Toggle (recursive)

public struct ToggleRowView: View {
    @Binding var block: Block
    @FocusState.Binding var editorFocused: BlockID?
    let isSelected: Bool
    let isEditing: Bool
    let onKey: (BlockKey) -> KeyPress.Result
    let onEdited: () -> Void
    let onAutotransform: (BlockTransform, AttributedString) -> Void

    public init(
        block: Binding<Block>,
        editorFocused: FocusState<BlockID?>.Binding,
        isSelected: Bool,
        isEditing: Bool,
        onKey: @escaping (BlockKey) -> KeyPress.Result,
        onEdited: @escaping () -> Void,
        onAutotransform: @escaping (BlockTransform, AttributedString) -> Void = { _, _ in }
    ) {
        self._block = block
        self._editorFocused = editorFocused
        self.isSelected = isSelected
        self.isEditing = isEditing
        self.onKey = onKey
        self.onEdited = onEdited
        self.onAutotransform = onAutotransform
    }

    public var body: some View {
        let childNumbering = NumberingContext.compute(toggleChildren)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Button {
                    if case .toggle(let id, let title, let expanded, let children, let indent) = block {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            block = .toggle(id: id, title: title, expanded: !expanded, children: children, indent: indent)
                        }
                        onEdited()
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: NotionStyle.chevronSize, weight: .medium))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(NotionStyle.foreground)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)

                titleEditableText
            }

            if isExpanded {
                // Toggle children render as Text only — editing toggle children stays out of
                // the M3 minimum until the page-level edit/select model is solid.
                ForEach(toggleChildren, id: \.id) { child in
                    BlockRowReadOnly(block: child, numberingIndex: childNumbering[child.id])
                        .padding(.leading, NotionStyle.indentStep)
                }
            }
        }
    }

    private var isExpanded: Bool {
        if case .toggle(_, _, let expanded, _, _) = block { return expanded }
        return false
    }

    private var toggleChildren: [Block] {
        if case .toggle(_, _, _, let children, _) = block { return children }
        return []
    }

    private var titleBinding: Binding<AttributedString> {
        Binding(
            get: {
                if case .toggle(_, let title, _, _, _) = block { return title }
                return AttributedString()
            },
            set: { newValue in
                if case .toggle(let id, let title, let expanded, let children, let indent) = block {
                    if String(newValue.characters) != String(title.characters) ||
                       !attributedStringMarksEqual(newValue, title) {
                        block = .toggle(id: id, title: newValue, expanded: expanded, children: children, indent: indent)
                        onEdited()
                    }
                }
            }
        )
    }

    @ViewBuilder
    private var titleEditableText: some View {
        if isEditing {
            BlockTextEditor(
                text: titleBinding,
                font: NotionStyle.body(),
                fontSize: 16,
                bold: false,
                lineSpacing: NotionStyle.bodyLineSpacing,
                focused: $editorFocused,
                blockID: block.id,
                onKey: onKey,
                onAutotransform: onAutotransform
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let title: AttributedString = {
                if case .toggle(_, let t, _, _, _) = block { return t }
                return AttributedString()
            }()
            Text(InlineRenderer.swiftUIAttributed(title))
                .font(NotionStyle.body())
                .foregroundStyle(NotionStyle.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A read-only render of a block — used inside expanded toggles where editing isn't wired up
/// in the M3 minimum.
struct BlockRowReadOnly: View {
    let block: Block
    let numberingIndex: Int?

    init(block: Block, numberingIndex: Int? = nil) {
        self.block = block
        self.numberingIndex = numberingIndex
    }

    var body: some View {
        switch block {
        case .paragraph(_, let text, let indent), .quote(_, let text, let indent):
            Text(InlineRenderer.swiftUIAttributed(text))
                .font(NotionStyle.body())
                .foregroundStyle(NotionStyle.foreground)
                .lineSpacing(NotionStyle.bodyLineSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, CGFloat(indent) * NotionStyle.indentStep)
        case .heading(_, let level, let text, let indent):
            let size: CGFloat = level == 1 ? NotionStyle.h1Size : level == 2 ? NotionStyle.h2Size : NotionStyle.h3Size
            Text(InlineRenderer.swiftUIAttributed(text, baseFont: NotionStyle.body(size: size)))
                .font(NotionStyle.body(size: size).weight(NotionStyle.headingWeight))
                .foregroundStyle(NotionStyle.foreground)
                .padding(.leading, CGFloat(indent) * NotionStyle.indentStep)
        case .bullet(_, let text, let indent):
            HStack(alignment: .firstTextBaseline, spacing: NotionStyle.listMarkerGap) {
                Circle()
                    .foregroundStyle(NotionStyle.foreground)
                    .frame(width: NotionStyle.bulletMarkerDiameter, height: NotionStyle.bulletMarkerDiameter)
                    .frame(width: NotionStyle.bulletMarkerColumnWidth, height: NotionStyle.listMarkerFrameHeight, alignment: .trailing)
                    .alignmentGuide(.firstTextBaseline) { dimensions in
                        dimensions[VerticalAlignment.center] + NotionStyle.bulletMarkerBaselineOffset
                    }
                Text(InlineRenderer.swiftUIAttributed(text))
            }
            .padding(.leading, CGFloat(indent) * NotionStyle.indentStep)
        case .numbered(_, let text, let indent):
            HStack(alignment: .firstTextBaseline, spacing: NotionStyle.listMarkerGap) {
                Text("\(numberingIndex ?? 1).")
                    .font(NotionStyle.body())
                    .foregroundStyle(NotionStyle.foreground)
                    .frame(width: NotionStyle.numberedMarkerColumnWidth, alignment: .trailing)
                Text(InlineRenderer.swiftUIAttributed(text))
            }
            .padding(.leading, CGFloat(indent) * NotionStyle.indentStep)
        case .todo(_, let text, let done, let indent):
            HStack(alignment: .firstTextBaseline, spacing: NotionStyle.listMarkerGap) {
                Image(systemName: done ? "checkmark.square.fill" : "square")
                    .font(.system(size: NotionStyle.todoCheckboxSize))
                    .foregroundStyle(done ? NotionStyle.mutedForeground : NotionStyle.foreground)
                    .frame(width: NotionStyle.todoMarkerColumnWidth, alignment: .trailing)
                Text(InlineRenderer.swiftUIAttributed(text))
            }
            .padding(.leading, CGFloat(indent) * NotionStyle.indentStep)
        case .divider(_, let indent):
            Rectangle().fill(NotionStyle.dividerColor).frame(height: 1)
                .padding(.leading, CGFloat(indent) * NotionStyle.indentStep)
        case .code(_, let source, _, let indent):
            Text(source).font(NotionStyle.mono())
                .padding(.leading, CGFloat(indent) * NotionStyle.indentStep)
        case .subpage(_, let title, _, let indent):
            HStack(alignment: .firstTextBaseline, spacing: NotionStyle.listMarkerGap) {
                Image(systemName: "doc.text")
                    .font(.system(size: NotionStyle.pageIconSize))
                    .foregroundStyle(NotionStyle.mutedForeground)
                    .frame(width: NotionStyle.bulletMarkerColumnWidth, height: NotionStyle.listMarkerFrameHeight, alignment: .trailing)
                    .alignmentGuide(.firstTextBaseline) { dimensions in
                        dimensions[VerticalAlignment.center] + NotionStyle.bulletMarkerBaselineOffset
                    }
                Text(title)
                    .font(NotionStyle.body().weight(.medium))
                    .foregroundStyle(NotionStyle.foreground)
                    .lineSpacing(NotionStyle.bodyLineSpacing)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, CGFloat(indent) * NotionStyle.indentStep)
        case .toggle(_, let title, _, _, let indent):
            HStack { Image(systemName: "chevron.right"); Text(InlineRenderer.swiftUIAttributed(title)) }
                .padding(.leading, CGFloat(indent) * NotionStyle.indentStep)
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

func previousBlock(before id: BlockID, in blocks: [Block]) -> Block? {
    guard let i = blocks.firstIndex(where: { $0.id == id }), i > 0 else { return nil }
    return blocks[i - 1]
}

/// Per-block 1-indexed position among consecutive sibling `.numbered` blocks at the same indent.
public enum NumberingContext {
    public static func compute(_ blocks: [Block]) -> [BlockID: Int] {
        var result: [BlockID: Int] = [:]
        var counters: [Int: Int] = [:]
        for block in blocks {
            switch block {
            case .numbered(_, _, let indent):
                let next = (counters[indent] ?? 0) + 1
                counters[indent] = next
                result[block.id] = next
                for key in counters.keys where key > indent {
                    counters[key] = 0
                }
            default:
                counters.removeAll()
            }
        }
        return result
    }
}
