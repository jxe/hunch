import SwiftUI
import Core

public struct PageListView: View {
    public let entries: [WorkspaceEntry]
    public let onSelect: (WorkspaceEntry) -> Void

    public init(entries: [WorkspaceEntry], onSelect: @escaping (WorkspaceEntry) -> Void) {
        self.entries = entries
        self.onSelect = onSelect
    }

    public var body: some View {
        List {
            ForEach(entries) { entry in
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
    }
}
