import SwiftUI
import Editor

/// Unified workspace-wide recovery sheet. Surfaces both deleted whole pages
/// (from `TrashStore`) and lost blocks (from `RecoveryStore`) — anything that
/// disappeared from a doc and can be brought back.
///
/// `filter` is `.all` (everything) or `.page(rel)` (one source page only —
/// used by the editor toolbar's clock button).
public struct RecoveryView: View {
    let filter: RecoveryListFilter
    let loadEntries: (RecoveryListFilter) async -> [RecoverableEntry]
    let onRestore: (RecoverableEntry) async -> Bool
    let onClose: () -> Void

    @State private var entries: [RecoverableEntry] = []
    @State private var loadState: LoadState = .loading
    @State private var pendingRestore: RecoverableEntry?
    @State private var selection: RecoverableEntry.ID?

    enum LoadState { case loading, loaded, empty }

    public init(
        filter: RecoveryListFilter,
        loadEntries: @escaping (RecoveryListFilter) async -> [RecoverableEntry],
        onRestore: @escaping (RecoverableEntry) async -> Bool,
        onClose: @escaping () -> Void
    ) {
        self.filter = filter
        self.loadEntries = loadEntries
        self.onRestore = onRestore
        self.onClose = onClose
    }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle(navigationTitleText)
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

    private var navigationTitleText: String {
        switch filter {
        case .all: return "Recover"
        case .page(let rel): return "Recover · \(rel)"
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
                "Nothing to recover",
                systemImage: "clock.arrow.circlepath",
                description: Text("Pages and blocks you delete or edit out will appear here.")
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
                    .onTapGesture { pendingRestore = entry }
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
        #if os(macOS)
        .onKeyPress(.return) {
            guard let id = selection, let entry = entries.first(where: { $0.id == id }) else { return .ignored }
            pendingRestore = entry
            return .handled
        }
        #endif
        .onChange(of: entries) { _, new in
            if selection == nil { selection = new.first?.id }
        }
    }

    private func row(for entry: RecoverableEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(for: entry))
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

    private func icon(for entry: RecoverableEntry) -> String {
        switch entry {
        case .deletedPage: return "doc.text"
        case .lostBlock(let lost):
            switch lost.record.cause {
            case .deleted: return "square.stack.3d.up"
            case .edited: return "pencil"
            case .seen: return "clock.arrow.circlepath"
            }
        }
    }

    private func secondaryLine(for entry: RecoverableEntry) -> String {
        switch entry {
        case .deletedPage: return entry.sourcePath
        case .lostBlock(let lost):
            switch lost.record.cause {
            case .deleted: return entry.sourcePath + " · deleted"
            case .edited: return entry.sourcePath + " · edited out"
            case .seen: return entry.sourcePath
            }
        }
    }

    private func restoreMessage(for entry: RecoverableEntry) -> String {
        switch entry {
        case .deletedPage:
            return "“\(entry.displayTitle)” will be moved back to \(entry.sourcePath)."
        case .lostBlock(let lost):
            let location = lost.record.anchorFingerprint != nil
                ? "after the original anchor block"
                : "at the end of the page"
            return "Block will be inserted in \(entry.sourcePath) \(location), without overwriting the current contents."
        }
    }

    private func refresh() async {
        loadState = entries.isEmpty ? .loading : .loaded
        let next = await loadEntries(filter)
        entries = next
        loadState = next.isEmpty ? .empty : .loaded
    }

    private func performRestore(_ entry: RecoverableEntry) async {
        if await onRestore(entry) {
            await refresh()
        }
    }
}
