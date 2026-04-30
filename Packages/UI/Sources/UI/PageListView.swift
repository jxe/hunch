import SwiftUI
import Core

public struct PageListView: View {
    public let entries: [WorkspaceEntry]
    @Binding public var selection: WorkspaceEntry.ID?
    @Binding public var searchText: String

    public init(
        entries: [WorkspaceEntry],
        selection: Binding<WorkspaceEntry.ID?>,
        searchText: Binding<String>
    ) {
        self.entries = entries
        self._selection = selection
        self._searchText = searchText
    }

    public var body: some View {
        List(selection: $selection) {
            ForEach(filteredEntries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(NotionStyle.body())
                        .foregroundStyle(NotionStyle.foreground)
                    Text(entry.relativePath)
                        .font(NotionStyle.body(size: 12))
                        .foregroundStyle(NotionStyle.mutedForeground)
                }
                .contentShape(Rectangle())
                .tag(entry.id)
            }
        }
        .listStyle(.plain)
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
