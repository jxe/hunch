import SwiftUI

/// Sheet that picks a destination page for "Move to…" from the block action menu.
/// Reuses the editor's existing `suggestPages` callback as its data source — the
/// same ranking + filtering the @-mention popover gets, but presented as a full
/// sheet without the popover's 8-row cap.
struct MoveDestinationPickerView: View {
    let pages: (_ query: String) -> [MentionItem]
    let onPick: (_ pageID: String) -> Void
    let onCancel: () -> Void

    @State private var query: String = ""

    var body: some View {
        NavigationStack {
            let results = pages(query)
            List {
                if results.isEmpty {
                    Text(query.isEmpty ? "No pages in workspace" : "No matching pages")
                        .font(NotionStyle.body(size: 13))
                        .foregroundStyle(NotionStyle.mutedForeground)
                        .padding(.vertical, 8)
                } else {
                    ForEach(results, id: \.id) { item in
                        Button {
                            onPick(item.id)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "doc")
                                    .font(.system(size: 13))
                                    .foregroundStyle(NotionStyle.mutedForeground)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(NotionStyle.body())
                                        .foregroundStyle(NotionStyle.foreground)
                                        .lineLimit(1)
                                    if let subtitle = item.subtitle {
                                        Text(subtitle)
                                            .font(NotionStyle.body(size: 12))
                                            .foregroundStyle(NotionStyle.mutedForeground)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Move to…")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $query, placement: .automatic, prompt: "Search pages")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 480)
        #endif
    }
}
