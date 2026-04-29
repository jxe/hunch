import SwiftUI
import Core

public struct PageListView: View {
    public let entries: [WorkspaceEntry]
    public let onSelect: (WorkspaceEntry) -> Void
    @State private var searchText = ""

    public init(entries: [WorkspaceEntry], onSelect: @escaping (WorkspaceEntry) -> Void) {
        self.entries = entries
        self.onSelect = onSelect
    }

    public var body: some View {
        List {
            ForEach(filteredEntries) { entry in
                Button {
                    onSelect(entry)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title)
                            .font(NotionStyle.body())
                            .foregroundStyle(NotionStyle.foreground)
                        Text(entry.relativePath)
                            .font(NotionStyle.body(size: 12))
                            .foregroundStyle(NotionStyle.mutedForeground)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.plain)
        .searchable(text: $searchText, placement: .automatic, prompt: "Search pages")
    }

    private var filteredEntries: [WorkspaceEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        return entries.filter { entry in
            entry.title.localizedStandardContains(query) ||
            entry.relativePath.localizedStandardContains(query)
        }
    }
}
