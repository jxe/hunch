import SwiftUI

public struct BlockRow: View, Equatable {
    @Binding var block: Block
    /// Depth of this block in the document tree. Replaces the old per-case
    /// `indent` field — passed in by the visible-layout walk so the row
    /// renders the right leading inset without consulting the model directly.
    public let depth: Int
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

    nonisolated public static func == (lhs: BlockRow, rhs: BlockRow) -> Bool {
        lhs.block == rhs.block
            && lhs.depth == rhs.depth
            && lhs.isPageTitle == rhs.isPageTitle
            && lhs.numberingIndex == rhs.numberingIndex
            && lhs.isSelected == rhs.isSelected
            && lhs.isEditing == rhs.isEditing
            && lhs.isExpanded == rhs.isExpanded
            && lhs.isDropTarget == rhs.isDropTarget
            && lhs.isActionMenuTarget == rhs.isActionMenuTarget
            && lhs.mentionActive == rhs.mentionActive
    }
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

    @State private var linkPreviews: [URL: LinkPreview] = [:]
    @Environment(\.linkPreviewProvider) private var linkPreviewProvider: LinkPreviewProvider?

    public init(
        block: Binding<Block>,
        depth: Int,
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
        self.depth = depth
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
        let externalURLs = collectExternalURLs(in: block.text)
        return content
            .padding(.vertical, BlockSpacing.intrinsicVerticalPadding(block))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected && !isEditing ? NotionStyle.selectionBackground : Color.clear)
            .task(id: externalURLs) {
                guard let provider = linkPreviewProvider else { return }
                for url in externalURLs where linkPreviews[url] == nil {
                    if let preview = await provider(url) {
                        if Task.isCancelled { return }
                        linkPreviews[url] = preview
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
            subpageRow(title: pageTitle(path) ?? title)

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
                if case .todo(let text, let isDone) = block.kind {
                    block.kind = .todo(text: text, done: !isDone)
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
        .padding(.leading, CGFloat(depth) * NotionStyle.indentStep)
    }

    private func templateButtonRow() -> some View {
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
        .padding(.leading, CGFloat(depth) * NotionStyle.indentStep)
    }

    private func subpageRow(title: String) -> some View {
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
        .padding(.leading, CGFloat(depth) * NotionStyle.indentStep)
    }

    private func imageRow(source: String, alt: String) -> some View {
        ImageBlockView(source: source, alt: alt)
            .padding(.leading, NotionStyle.nonListLeading(depth: depth))
    }

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
                decoratedText(
                    block.text,
                    baseFont: font,
                    boldFont: NotionStyle.body(size: fontSize, weight: .semibold),
                    fontSize: fontSize,
                    pageTitle: pageTitle,
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

/// Walk an `AttributedString` and gather every `http`/`https` URL referenced
/// by an inline `.link` run. Internal `.md` page links don't go through link
/// previews — they have their own subpage-resolution path (`pageTitle`).
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
    pageTitle: (String) -> String?,
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
               let resolved = pageTitle(url.absoluteString) {
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
