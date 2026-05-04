import SwiftUI
import Editor

/// One picker view shared by the sidebar, the square.stack sheet, the
/// move-to sheet, and the jump-to sheet. Differences across surfaces are
/// expressed by the wrapper (NavigationStack title, sheet vs. inline) and
/// by which optional callbacks are passed.
///
/// `selection` is a single-item binding that drives `List`'s native highlight
/// + keyboard nav. The sidebar binds it to the currently-open page; sheets
/// bind to a transient `@State` and act on the write to navigate / dismiss.
struct PagePickerView: View {
    let items: [MentionItem]
    @Binding var selection: MentionItem.ID?
    let onSetHome: ((MentionItem) -> Void)?
    let onMoveToTrash: ((MentionItem) -> Void)?

    init(
        items: [MentionItem],
        selection: Binding<MentionItem.ID?>,
        onSetHome: ((MentionItem) -> Void)? = nil,
        onMoveToTrash: ((MentionItem) -> Void)? = nil
    ) {
        self.items = items
        self._selection = selection
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
                        .modifier(PageRowSwipeActions(
                            item: item,
                            onSetHome: onSetHome,
                            onMoveToTrash: onMoveToTrash
                        ))
                }
            }
        }
        .listStyle(.plain)
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
