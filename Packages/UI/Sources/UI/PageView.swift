import SwiftUI
import Core

public struct PageView: View {
    public let document: Document
    public let onSubpageTap: (String) -> Void

    public init(document: Document, onSubpageTap: @escaping (String) -> Void = { _ in }) {
        self.document = document
        self.onSubpageTap = onSubpageTap
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(document.blocks.enumerated()), id: \.element.id) { index, block in
                    rowView(for: block)
                        .padding(.top, BlockSpacing.gap(
                            before: block,
                            after: index > 0 ? document.blocks[index - 1] : nil
                        ))
                }
            }
            .frame(maxWidth: NotionStyle.maxContentWidth, alignment: .leading)
            .padding(.horizontal, NotionStyle.pageHorizontalPadding)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(NotionStyle.background)
    }

    @ViewBuilder
    private func rowView(for block: Block) -> some View {
        if case .subpage(_, _, let path) = block {
            Button {
                onSubpageTap(path)
            } label: {
                BlockRow(block)
            }
            .buttonStyle(.plain)
        } else {
            BlockRow(block)
        }
    }
}
