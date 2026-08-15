import SwiftUI

/// Grip rendered in the left gutter of a hovered block row. Clicking does nothing
/// (no inline action menu yet) — its only job is to host the row's reorder
/// DragGesture so the row's text-area gestures aren't disturbed.
struct DragHandle: View {
    let theme: EditorTheme
    /// Visible width of the handle. The row's hit area extends this far into the
    /// leading gutter via a custom `contentShape`, so hovering the handle keeps the
    /// row's hover state alive.
    static let gutterWidth: CGFloat = 28

    var body: some View {
        DragGripGlyph(dotSize: 2.8)
            .foregroundStyle(theme.foreground.opacity(0.32))
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(theme.foreground.opacity(0.018))
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
