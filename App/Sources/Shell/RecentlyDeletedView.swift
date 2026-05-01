import SwiftUI
import Editor

public struct RecentlyDeletedView: View {
    let loadEntries: () async -> [TrashEntry]
    let onRestorePage: (TrashEntry) async -> Bool
    let onRestoreBlocks: (TrashEntry) async -> Bool
    let onClose: () -> Void

    @State private var entries: [TrashEntry] = []
    @State private var selection: TrashEntry.ID?
    @State private var loadState: LoadState = .loading
    @State private var pendingRestore: TrashEntry?

    enum LoadState { case loading, loaded, empty }

    public init(
        loadEntries: @escaping () async -> [TrashEntry],
        onRestorePage: @escaping (TrashEntry) async -> Bool,
        onRestoreBlocks: @escaping (TrashEntry) async -> Bool,
        onClose: @escaping () -> Void
    ) {
        self.loadEntries = loadEntries
        self.onRestorePage = onRestorePage
        self.onRestoreBlocks = onRestoreBlocks
        self.onClose = onClose
    }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle("Recently Deleted")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { onClose() }
                    }
                }
        }
        .task { await refresh() }
        .alert(
            "Restore this item?",
            isPresented: Binding(
                get: { pendingRestore != nil },
                set: { if !$0 { pendingRestore = nil } }
            ),
            presenting: pendingRestore
        ) { entry in
            Button("Restore") {
                Task { await performRestore(entry) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text(restoreMessage(for: entry))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            ContentUnavailableView(
                "Nothing recently deleted",
                systemImage: "trash",
                description: Text("Pages or blocks you delete will appear here.")
            )
        case .loaded:
            list
        }
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(entries) { entry in
                row(for: entry)
                    .tag(entry.id)
                    .contentShape(Rectangle())
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            pendingRestore = entry
                        } label: {
                            Label("Restore", systemImage: "arrow.uturn.backward")
                        }
                        .tint(.blue)
                    }
                    .contextMenu {
                        Button {
                            pendingRestore = entry
                        } label: {
                            Label("Restore", systemImage: "arrow.uturn.backward")
                        }
                    }
            }
        }
        .listStyle(.plain)
    }

    private func row(for entry: TrashEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isPageEntry ? "doc.text" : "square.stack.3d.up")
                .foregroundStyle(NotionStyle.mutedForeground)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayTitle)
                    .font(NotionStyle.body())
                    .foregroundStyle(NotionStyle.foreground)
                    .lineLimit(1)
                Text(secondaryLine(for: entry))
                    .font(NotionStyle.body(size: 12))
                    .foregroundStyle(NotionStyle.mutedForeground)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(entry.timestamp, style: .relative)
                .font(NotionStyle.body(size: 12))
                .foregroundStyle(NotionStyle.mutedForeground)
        }
        .padding(.vertical, 4)
    }

    private func secondaryLine(for entry: TrashEntry) -> String {
        if entry.isPageEntry {
            return entry.sourcePath
        }
        return entry.sourcePath + " · blocks"
    }

    private func restoreMessage(for entry: TrashEntry) -> String {
        if entry.isPageEntry {
            return "“\(entry.displayTitle)” will be moved back to \(entry.sourcePath)."
        }
        return "Blocks will be reinserted into \(entry.sourcePath) at their original positions."
    }

    private func refresh() async {
        loadState = entries.isEmpty ? .loading : .loaded
        let next = await loadEntries()
        entries = next
        loadState = next.isEmpty ? .empty : .loaded
    }

    private func performRestore(_ entry: TrashEntry) async {
        let ok: Bool
        if entry.isPageEntry {
            ok = await onRestorePage(entry)
        } else {
            ok = await onRestoreBlocks(entry)
        }
        if ok {
            await refresh()
        }
    }
}
