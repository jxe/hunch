import SwiftUI

/// Visual content for a single block — the renderer for paragraph/heading/list/
/// toggle/code/divider/subpage/etc., plus selection background, drop-target
/// halo, and link-preview fetch task. Equatable on its inputs so `.equatable()`
/// can gate body re-evaluation.
///
/// Used standalone by the reorder lift overlay (which wants the visuals without
/// any of the editor's interactive modifiers — gestures, popovers, drag handle
/// — that would interfere with an in-flight drag). For the page editor case,
/// `BlockRow` wraps this struct with the full interactive chain.
public struct BlockRowContent: View, Equatable {
    /// Block content as a value. Mutations route through `onBlockChange` —
    /// keeping the row free of `@Binding` lets `.equatable()` actually gate
    /// `body` (DynamicProperty wrappers like `@Binding` reset per parent
    /// re-render and force body to run regardless of `==`).
    public let block: Block
    public let onBlockChange: (Block) -> Void
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

    nonisolated public static func == (lhs: BlockRowContent, rhs: BlockRowContent) -> Bool {
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
            && lhs.pageTitles == rhs.pageTitles
            && lhs.linkPreviews == rhs.linkPreviews
    }
    /// Plain-typed focus binding (NOT `@FocusState.Binding`). Same reason as
    /// `block` above — `@FocusState.Binding` is a DynamicProperty wrapper that
    /// would defeat `.equatable()`. Held by value here, only consulted inside
    /// `BlockTextEditor` when `isEditing` is true.
    let editorFocused: FocusState<BlockID?>.Binding
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
    /// Resolved titles for every `.md` page reference this row needs to render —
    /// the subpage path for `.subpage` blocks, plus inline page links inside
    /// `block.text`. Pre-resolved at the call site so page renames invalidate
    /// the row's `Equatable` `==` (the parent `pageTitle` closure isn't itself
    /// comparable). Map from the link's `path.md` (matching what `block.kind`
    /// stores for subpages and what `.link` URLs' `absoluteString` carries for
    /// inline page links) to the resolved page title.
    let pageTitles: [String: String]
    /// Forwarded to the BlockTextEditor — called once on its first mount to fetch
    /// the cursor target captured at tap/split/merge time. EditorView constructs
    /// this closure to atomically read-and-clear `EditorState.pendingInitialCursor`.
    let consumeInitialCursor: () -> InitialCursorTarget?

    /// Subset of the host's link-preview cache relevant to this row. Filtered
    /// at the call site to just the URLs in `block.text`, so the dict stays
    /// small and Equatable comparisons are cheap. Async fetches still run
    /// inside this row's `.task` and call `onLinkPreviewLoaded` to write back
    /// to the host's cache.
    let linkPreviews: [URL: LinkPreview]
    let onLinkPreviewLoaded: (URL, LinkPreview) -> Void
    let linkPreviewProvider: LinkPreviewProvider?

    public init(
        block: Block,
        onBlockChange: @escaping (Block) -> Void,
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
        pageTitles: [String: String] = [:],
        linkPreviews: [URL: LinkPreview] = [:],
        onLinkPreviewLoaded: @escaping (URL, LinkPreview) -> Void = { _, _ in },
        linkPreviewProvider: LinkPreviewProvider? = nil,
        consumeInitialCursor: @escaping () -> InitialCursorTarget? = { nil }
    ) {
        self.block = block
        self.onBlockChange = onBlockChange
        self.depth = depth
        self.isPageTitle = isPageTitle
        self.numberingIndex = numberingIndex
        self.isSelected = isSelected
        self.isEditing = isEditing
        self.isExpanded = isExpanded
        self.isDropTarget = isDropTarget
        self.isActionMenuTarget = isActionMenuTarget
        self.editorFocused = editorFocused
        self.onKey = onKey
        self.onEdited = onEdited
        self.onAutotransform = onAutotransform
        self.onMentionTriggerChange = onMentionTriggerChange
        self.mentionActive = mentionActive
        self.onClickAtPoint = onClickAtPoint
        self.onToggleExpansion = onToggleExpansion
        self.onTemplateButtonPress = onTemplateButtonPress
        self.pageTitles = pageTitles
        self.linkPreviews = linkPreviews
        self.onLinkPreviewLoaded = onLinkPreviewLoaded
        self.linkPreviewProvider = linkPreviewProvider
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
    }

    /// AttributedString projection of the block's text for editing. Marks (bold/italic/
    /// code/strike/link) survive editing now — no more lossy String round-trip.
    private var textBinding: Binding<AttributedString> {
        Binding(
            get: { block.text },
            set: { newValue in
                if String(newValue.characters) != String(block.text.characters) ||
                   !attributedStringMarksEqual(newValue, block.text) {
                    onBlockChange(block.withText(newValue))
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
            subpageRow(title: pageTitles[path] ?? title)

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
                    var updated = block
                    updated.kind = .todo(text: text, done: !isDone)
                    onBlockChange(updated)
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
                    Text(InlineRenderer.swiftUIAttributed(block.text, baseFont: NotionStyle.body(), resolvingPageTitle: { pageTitles[$0] }))
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
                focused: editorFocused,
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
                    pageTitles: pageTitles,
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

/// Pre-resolve every `.md` page title this row needs to render: the subpage
/// path for `.subpage` blocks plus every inline page-link URL inside the
/// block's text. The result is the value `BlockRow` stores as `pageTitles` and
/// compares in `==`, so a rename of any referenced page changes the map for
/// the rows that mention it (and only those rows) — letting `.equatable()`
/// short-circuit the rest while keeping link titles correct.
func resolvePageTitles(for block: Block, resolver: (String) -> String?) -> [String: String] {
    var result: [String: String] = [:]
    if case .subpage(_, let path) = block.kind, let resolved = resolver(path) {
        result[path] = resolved
    }
    for run in block.text.runs {
        guard let url = run.link, !isExternalLinkURL(url), url.absoluteString.hasSuffix(".md") else { continue }
        let key = url.absoluteString
        if result[key] == nil, let resolved = resolver(key) {
            result[key] = resolved
        }
    }
    return result
}

/// Walk an `AttributedString` and gather every `http`/`https` URL referenced
/// by an inline `.link` run. Internal `.md` page links don't go through link
/// previews — they have their own subpage-resolution path (`pageTitles`).
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
    pageTitles: [String: String],
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
               let resolved = pageTitles[url.absoluteString] {
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

/// Full interactive row for a single block in the page editor — `BlockRowContent`
/// plus the editor's outer modifier chain (gestures, popovers, drag handle,
/// accessibility, etc.). Equatable so `.equatable()` in `EditorView.body` can
/// gate not just the inner content's body but the whole modifier chain — the
/// previous layout stopped at `BlockRowContent.equatable()` and re-walked the
/// outer modifiers every render, which compounded under sustained autorepeat.
///
/// Compares by value props only; closures (gestures, popover content) are
/// captured fresh each render but ignored in `==`. That's safe because every
/// callback either reads observable state through reference types (`state`,
/// `host`, `_document`'s underlying class) at fire time, or captures only
/// `block.id` / `block.kind`, which by definition match if the equality check
/// passed (otherwise the row would have rerendered with fresh closures).
public struct BlockRow: View, Equatable {
    public let content: BlockRowContent

    /// Action-menu popover is currently presenting against this row.
    public let isActionMenuPresented: Bool
    /// Mention popover is currently presenting against this row.
    public let isMentionMenuPresented: Bool
    /// A page pinch gesture is in flight — disable this row's iOS swipe
    /// affordances so the two gestures don't fight.
    public let isPinching: Bool
    /// Opacity to apply to the row — used to dim the source row of an
    /// in-flight reorder lift.
    public let reorderSourceOpacity: Double
    /// True when this row is part of the in-flight reorder lift — surfaces
    /// in accessibility as `reorder-source`.
    public let isReorderingThisBlock: Bool
    /// Drag handle should be visible (cursor hovering near, or this is the
    /// top selected block in a multi-block selection).
    public let isHandleVisible: Bool
    /// Whether this row is the source of an in-flight macOS drag — used to
    /// keep the handle hit-testable / gesture mounted even if the cursor
    /// drifts off the row.
    public let isMacDragSource: Bool
    public let accessibilityID: String
    public let accessibilityLabelText: String

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

    nonisolated public static func == (lhs: BlockRow, rhs: BlockRow) -> Bool {
        lhs.content == rhs.content
            && lhs.isActionMenuPresented == rhs.isActionMenuPresented
            && lhs.isMentionMenuPresented == rhs.isMentionMenuPresented
            && lhs.isPinching == rhs.isPinching
            && lhs.reorderSourceOpacity == rhs.reorderSourceOpacity
            && lhs.isReorderingThisBlock == rhs.isReorderingThisBlock
            && lhs.isHandleVisible == rhs.isHandleVisible
            && lhs.isMacDragSource == rhs.isMacDragSource
            && lhs.accessibilityID == rhs.accessibilityID
            && lhs.accessibilityLabelText == rhs.accessibilityLabelText
    }

    public init(
        content: BlockRowContent,
        isActionMenuPresented: Bool,
        isMentionMenuPresented: Bool,
        isPinching: Bool,
        reorderSourceOpacity: Double,
        isReorderingThisBlock: Bool,
        isHandleVisible: Bool,
        isMacDragSource: Bool,
        accessibilityID: String,
        accessibilityLabelText: String,
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
        self.content = content
        self.isActionMenuPresented = isActionMenuPresented
        self.isMentionMenuPresented = isMentionMenuPresented
        self.isPinching = isPinching
        self.reorderSourceOpacity = reorderSourceOpacity
        self.isReorderingThisBlock = isReorderingThisBlock
        self.isHandleVisible = isHandleVisible
        self.isMacDragSource = isMacDragSource
        self.accessibilityID = accessibilityID
        self.accessibilityLabelText = accessibilityLabelText
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

    public var body: some View {
        content
            .macRowReorder(
                isEnabled: !content.isEditing,
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
                    get: { isMentionMenuPresented },
                    set: { if !$0 { onMentionMenuDismiss() } }
                )
            ) {
                mentionMenuContent()
            }
            .opacity(reorderSourceOpacity)
            .contentShape(Rectangle())
            .iosBlockTouchActions(
                isEnabled: !content.isEditing && !isPinching,
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
                    .opacity(isHandleVisible && !content.isEditing ? 1 : 0)
                    .offset(x: -DragHandle.gutterWidth, y: 2)
                    .onHover(perform: onHandleHover)
                    .onTapGesture(perform: onHandleTap)
                    // Keep the handle hit-testable AND the gesture mounted for
                    // the duration of an in-flight drag. As the cursor leaves
                    // the source row, hoveredBlock shifts to a different row
                    // and `isHandleVisible` flips false; without this override,
                    // `allowsHitTesting(false)` would apply to the still-tracking
                    // view and SwiftUI would silently cancel the gesture — no
                    // `.onEnded` fires, lift gets stuck.
                    .macRowReorder(
                        isEnabled: (isHandleVisible || isMacDragSource) && !content.isEditing,
                        onChanged: onHandleReorderChanged,
                        onEnded: onHandleReorderEnded
                    )
                    .allowsHitTesting(isHandleVisible || isMacDragSource)
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
