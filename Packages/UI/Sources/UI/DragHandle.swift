import SwiftUI

/// Grip rendered in the left gutter of a hovered block row. Clicking does nothing
/// (no inline action menu yet) — its only job is to be the SwiftUI `.draggable`
/// source so the row's text-area gestures aren't disturbed.
struct DragHandle: View {
    /// Visible width of the handle. The row's hit area extends this far into the
    /// leading gutter via a custom `contentShape`, so hovering the handle keeps the
    /// row's hover state alive.
    static let gutterWidth: CGFloat = 28

    var body: some View {
        DragGripGlyph(dotSize: 3)
            .foregroundStyle(NotionStyle.mutedForeground)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(NotionStyle.foreground.opacity(0.05))
            )
            .frame(width: Self.gutterWidth, height: 28)
            .contentShape(Rectangle())
    }
}

private struct DragGripGlyph: View {
    let dotSize: CGFloat

    var body: some View {
        HStack(spacing: dotSize) {
            gripColumn
            gripColumn
        }
    }

    private var gripColumn: some View {
        VStack(spacing: dotSize) {
            gripDot
            gripDot
            gripDot
        }
    }

    private var gripDot: some View {
        RoundedRectangle(cornerRadius: dotSize / 2, style: .continuous)
            .frame(width: dotSize, height: dotSize)
    }
}


/// Visual carried under the cursor while a drag is in progress. SwiftUI lifts it via
/// `.draggable(_:preview:)`. Stays compact so the cursor can find drop zones easily.
struct DragPreviewChip: View {
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            DragGripGlyph(dotSize: 2.5)
            Text(count == 1 ? "Block" : "\(count) blocks")
                .font(NotionStyle.body(size: 12))
        }
        .foregroundStyle(NotionStyle.foreground)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(NotionStyle.background)
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        )
    }
}
