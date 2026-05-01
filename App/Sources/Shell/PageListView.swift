import SwiftUI
import Editor

public struct PageListView: View {
    public let entries: [WorkspaceEntry]
    public let homeRelativePath: String?
    public let onSetHome: (WorkspaceEntry) -> Void
    public let onMoveToTrash: (WorkspaceEntry) -> Void
    @Binding public var selection: WorkspaceEntry.ID?
    @Binding public var searchText: String

    public init(
        entries: [WorkspaceEntry],
        homeRelativePath: String? = nil,
        selection: Binding<WorkspaceEntry.ID?>,
        searchText: Binding<String>,
        onSetHome: @escaping (WorkspaceEntry) -> Void = { _ in },
        onMoveToTrash: @escaping (WorkspaceEntry) -> Void = { _ in }
    ) {
        self.entries = entries
        self.homeRelativePath = homeRelativePath
        self.onSetHome = onSetHome
        self.onMoveToTrash = onMoveToTrash
        self._selection = selection
        self._searchText = searchText
    }

    public var body: some View {
        List(selection: $selection) {
            ForEach(filteredEntries) { entry in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title)
                            .font(NotionStyle.body())
                            .foregroundStyle(NotionStyle.foreground)
                        Text(entry.relativePath)
                            .font(NotionStyle.body(size: 12))
                            .foregroundStyle(NotionStyle.mutedForeground)
                    }
                    Spacer(minLength: 8)
                    if entry.relativePath == homeRelativePath {
                        Image(systemName: "house.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(NotionStyle.mutedForeground)
                            .accessibilityLabel("Home page")
                    }
                }
                .contentShape(Rectangle())
                .tag(entry.id)
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button {
                        onSetHome(entry)
                    } label: {
                        Label("Set as Home", systemImage: "house")
                    }
                    .tint(.blue)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        onMoveToTrash(entry)
                    } label: {
                        Label("Move to Trash", systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button {
                        onSetHome(entry)
                    } label: {
                        Label("Set as Home", systemImage: "house")
                    }
                    Button(role: .destructive) {
                        onMoveToTrash(entry)
                    } label: {
                        Label("Move to Trash", systemImage: "trash")
                    }
                }
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
