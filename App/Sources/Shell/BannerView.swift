import SwiftUI

/// Transient informational banner overlaid at the top of the editor window.
/// Bound to `Workspace.banner`; clears the source when its 4s timer expires
/// or when the user taps it. Last-write-wins across windows — multiple
/// banners arriving in quick succession look like one banner whose text
/// changes (the `.id(banner.id)` modifier restarts the timer on each
/// distinct event).
struct BannerView: View {
    let banner: Workspace.Banner
    let onDismiss: () -> Void

    @State private var dismissTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: banner.systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(iconStyle)
            Text(banner.message)
                .font(.system(size: 13))
                .lineLimit(2)
                // Only the text portion dismisses; the action button below
                // must receive its own taps.
                .contentShape(Rectangle())
                .onTapGesture {
                    dismissTask?.cancel()
                    onDismiss()
                }
            if let action = banner.action {
                Button(action.label) {
                    dismissTask?.cancel()
                    action.handler()
                    onDismiss()
                }
                .font(.system(size: 13, weight: .medium))
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.10), radius: 6, x: 0, y: 2)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
        .task(id: banner.id) {
            dismissTask?.cancel()
            guard let dismissAfter = banner.dismissAfter else { return }
            dismissTask = Task {
                try? await Task.sleep(for: dismissAfter)
                guard !Task.isCancelled else { return }
                onDismiss()
            }
        }
    }

    private var iconStyle: AnyShapeStyle {
        switch banner.kind {
        case .info:
            AnyShapeStyle(HierarchicalShapeStyle.primary)
        case .warning:
            AnyShapeStyle(Color.orange)
        case .error:
            AnyShapeStyle(Color.red)
        }
    }
}
