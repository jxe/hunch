import SwiftUI
import Editor

/// One picker view shared by the sidebar, the square.stack sheet, the
/// move-to sheet, and the jump-to sheet. Differences across surfaces are
/// expressed by the wrapper (NavigationStack title, sheet vs. inline) and
/// by which optional callbacks are passed.
///
/// `selection` is a single-item binding driving `List`'s native highlight.
/// Writes are pure storage — they don't activate the row. `onActivate` fires
/// on commit (click or Return on the keyboard cursor).
///
/// Arrow keys move the cursor regardless of whether the search field has
/// focus; Return commits. This works because `.onKeyPress` handlers attached
/// here propagate up from the view's window when keys aren't already
/// consumed by the focused control (TextFields don't consume up/down/return-
/// when-empty in this configuration). Without this hook the sheet's search
/// field would swallow focus and arrow keys would do nothing.
struct PagePickerView: View {
    let items: [MentionItem]
    @Binding var selection: MentionItem.ID?
    let onActivate: (MentionItem) -> Void
    let onSetHome: ((MentionItem) -> Void)?
    let onMoveToTrash: ((MentionItem) -> Void)?

    init(
        items: [MentionItem],
        selection: Binding<MentionItem.ID?>,
        onActivate: @escaping (MentionItem) -> Void,
        onSetHome: ((MentionItem) -> Void)? = nil,
        onMoveToTrash: ((MentionItem) -> Void)? = nil
    ) {
        self.items = items
        self._selection = selection
        self.onActivate = onActivate
        self.onSetHome = onSetHome
        self.onMoveToTrash = onMoveToTrash
    }

    var body: some View {
        List(selection: $selection) {
            if items.isEmpty {
                Text("No matching pages")
                    .font(NotionStyle.body(size: 13))
                    .foregroundStyle(NotionStyle.mutedForeground)
                    .padding(.vertical, 8)
            } else {
                ForEach(items) { item in
                    MentionItemRow(item: item)
                        .tag(item.id)
                        .onTapGesture { onActivate(item) }
                        .modifier(PageRowSwipeActions(
                            item: item,
                            onSetHome: onSetHome,
                            onMoveToTrash: onMoveToTrash
                        ))
                }
            }
        }
        .listStyle(.plain)
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            guard !items.isEmpty else { return .ignored }
            let delta = press.key == .downArrow ? 1 : -1
            let idx = selection.flatMap { id in items.firstIndex(where: { $0.id == id }) }
            let next: Int
            if let idx {
                next = (idx + delta + items.count) % items.count
            } else {
                next = delta > 0 ? 0 : items.count - 1
            }
            selection = items[next].id
            return .handled
        }
        .onKeyPress(.return) {
            guard let id = selection, let item = items.first(where: { $0.id == id }) else { return .ignored }
            onActivate(item)
            return .handled
        }
    }
}

private struct PageRowSwipeActions: ViewModifier {
    let item: MentionItem
    let onSetHome: ((MentionItem) -> Void)?
    let onMoveToTrash: ((MentionItem) -> Void)?

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                if let onSetHome {
                    Button { onSetHome(item) } label: {
                        Label("Set as Home", systemImage: "house")
                    }
                    .tint(.blue)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if let onMoveToTrash {
                    Button(role: .destructive) {
                        onMoveToTrash(item)
                    } label: {
                        Label("Move to Trash", systemImage: "trash")
                    }
                }
            }
            .contextMenu {
                if let onSetHome {
                    Button { onSetHome(item) } label: {
                        Label("Set as Home", systemImage: "house")
                    }
                }
                if let onMoveToTrash {
                    Button(role: .destructive) {
                        onMoveToTrash(item)
                    } label: {
                        Label("Move to Trash", systemImage: "trash")
                    }
                }
            }
    }
}
