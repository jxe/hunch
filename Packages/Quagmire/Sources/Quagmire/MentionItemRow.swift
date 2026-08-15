import SwiftUI

/// One canonical row layout for every page-list surface in the app — the
/// @-mention popover (Quagmire SPM), the sidebar / square.stack sheet, the
/// move-to sheet, and the jump-to sheet (App). Pinning the chrome here means
/// the four surfaces stay visually consistent without each rebuilding the
/// HStack.
///
/// `isHighlighted` is the popover's selected-row treatment. List-based
/// surfaces leave it false and let `List(selection:)` provide its own
/// highlight.
struct MentionItemRow: View {
    let item: MentionItem
    let isHighlighted: Bool
    let theme: EditorTheme

    init(item: MentionItem, isHighlighted: Bool = false, theme: EditorTheme = .default) {
        self.item = item
        self.isHighlighted = isHighlighted
        self.theme = theme
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc")
                .font(.system(size: 13))
                .foregroundStyle(theme.mutedForeground)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(theme.body(size: 13))
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(theme.body(size: 10))
                        .foregroundStyle(theme.mutedForeground)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if item.isHome {
                Image(systemName: "house.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.mutedForeground)
                    .accessibilityLabel("Home page")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHighlighted ? theme.linkForeground.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
    }
}
