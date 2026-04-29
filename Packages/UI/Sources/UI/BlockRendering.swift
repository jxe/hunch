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
    public let block: Block

    public init(_ block: Block) {
        self.block = block
    }

    public var body: some View {
        content
            .padding(.vertical, BlockSpacing.intrinsicVerticalPadding(block))
    }

    @ViewBuilder
    private var content: some View {
        switch block {
        case .paragraph(_, let text):
            paragraphRow(text)

        case .heading(_, let level, let text):
            headingRow(level: level, text: text)

        case .bullet(_, let text, let indent):
            listMarkerRow(marker: "•", indent: indent, text: text)

        case .numbered(_, let text, let indent):
            listMarkerRow(marker: "1.", indent: indent, text: text)

        case .todo(_, let text, let done, let indent):
            todoRow(text: text, done: done, indent: indent)

        case .quote(_, let text):
            quoteRow(text)

        case .code(_, let source, let language):
            codeRow(source: source, language: language)

        case .divider:
            dividerRow

        case .toggle(_, let title, let expanded, let children):
            ToggleRowView(title: title, initiallyExpanded: expanded, children: children)

        case .subpage(_, let title, _):
            subpageRow(title: title)
        }
    }

    // MARK: paragraph
    private func paragraphRow(_ text: AttributedString) -> some View {
        Text(InlineRenderer.swiftUIAttributed(text))
            .font(NotionStyle.body())
            .foregroundStyle(NotionStyle.foreground)
            .lineSpacing(NotionStyle.bodyLineSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: heading
    private func headingRow(level: Int, text: AttributedString) -> some View {
        let size: CGFloat = level == 1 ? NotionStyle.h1Size
                         : level == 2 ? NotionStyle.h2Size
                                      : NotionStyle.h3Size
        return Text(InlineRenderer.swiftUIAttributed(text, baseFont: NotionStyle.body(size: size)))
            .font(NotionStyle.body(size: size).weight(NotionStyle.headingWeight))
            .foregroundStyle(NotionStyle.foreground)
            .lineSpacing(NotionStyle.headingLineSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: list markers
    private func listMarkerRow(marker: String, indent: Int, text: AttributedString) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker)
                .font(NotionStyle.body())
                .foregroundStyle(NotionStyle.foreground)
                .frame(width: 16, alignment: .leading)
            Text(InlineRenderer.swiftUIAttributed(text))
                .font(NotionStyle.body())
                .foregroundStyle(NotionStyle.foreground)
                .lineSpacing(NotionStyle.bodyLineSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(indent) * NotionStyle.indentStep)
    }

    private func todoRow(text: AttributedString, done: Bool, indent: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: done ? "checkmark.square.fill" : "square")
                .foregroundStyle(done ? NotionStyle.mutedForeground : NotionStyle.foreground)
                .frame(width: 16)
            Text(InlineRenderer.swiftUIAttributed(text))
                .font(NotionStyle.body())
                .foregroundStyle(done ? NotionStyle.mutedForeground : NotionStyle.foreground)
                .strikethrough(done)
                .lineSpacing(NotionStyle.bodyLineSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(indent) * NotionStyle.indentStep)
    }

    // MARK: quote
    private func quoteRow(_ text: AttributedString) -> some View {
        // .notion-quote { font-size: 1.2em; padding: 0.2em 0.9em; border-left: 3px solid currentcolor }
        let quoteFontSize: CGFloat = 16 * 1.2
        return HStack(spacing: 14) {
            Rectangle()
                .fill(NotionStyle.foreground)
                .frame(width: 3)
            Text(InlineRenderer.swiftUIAttributed(text, baseFont: NotionStyle.body(size: quoteFontSize)))
                .font(NotionStyle.body(size: quoteFontSize))
                .foregroundStyle(NotionStyle.foreground)
                .lineSpacing(NotionStyle.bodyLineSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: code
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
    }

    // MARK: divider
    private var dividerRow: some View {
        Rectangle()
            .fill(NotionStyle.dividerColor)
            .frame(height: 1)
    }

    // MARK: subpage
    private func subpageRow(title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: NotionStyle.pageIconSize))
                .foregroundStyle(NotionStyle.mutedForeground)
            Text(title)
                .font(NotionStyle.body())
                .foregroundStyle(NotionStyle.foreground)
                .underline()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Toggle (recursive)

public struct ToggleRowView: View {
    let title: AttributedString
    @State private var expanded: Bool
    let children: [Block]

    public init(title: AttributedString, initiallyExpanded: Bool, children: [Block]) {
        self.title = title
        self._expanded = State(initialValue: initiallyExpanded)
        self.children = children
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        expanded.toggle()
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: NotionStyle.chevronSize, weight: .medium))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(NotionStyle.foreground)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                Text(InlineRenderer.swiftUIAttributed(title))
                    .font(NotionStyle.body())
                    .foregroundStyle(NotionStyle.foreground)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if expanded {
                BlockStack(blocks: children)
                    .padding(.leading, NotionStyle.indentStep)
            }
        }
    }
}

// MARK: - BlockStack: a vertical list of blocks with sibling-aware gaps

/// Renders a `[Block]` with `BlockSpacing.gap(...)` injected as `.padding(.top, ...)` on each
/// row except the first. This is the only path through which sibling spacing is applied —
/// `BlockRow` itself only knows about its own intrinsic padding.
public struct BlockStack: View {
    public let blocks: [Block]

    public init(blocks: [Block]) {
        self.blocks = blocks
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                BlockRow(block)
                    .padding(.top, BlockSpacing.gap(
                        before: block,
                        after: index > 0 ? blocks[index - 1] : nil
                    ))
            }
        }
    }
}
