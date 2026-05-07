import SwiftUI
import Editor

/// Unified workspace-wide recovery sheet. Surfaces both deleted whole pages
/// (from `TrashStore`) and lost blocks (from `RecoveryStore`) — anything that
/// disappeared from a doc and can be brought back.
///
/// `filter` is `.all` (everything) or `.page(rel)` (one source page only —
/// used by the editor toolbar's clock button).
public struct RecoveryView: View {
    /// Seed value — the live filter is `@State` so the segmented control can
    /// flip between scopes without the sheet remounting.
    let initialFilter: RecoveryListFilter
    /// Captured at sheet-open time. Empty when triggered from a no-page context
    /// (e.g. the empty-workspace state); in that case the segmented control
    /// hides "This page" and only `.all` is reachable.
    let currentPageRelativePath: String?
    let loadEntries: (RecoveryListFilter) async -> [RecoverableEntry]
    let onRestore: (RecoverableEntry) async -> Bool
    let onClose: () -> Void

    @State private var filter: RecoveryListFilter
    @State private var entries: [RecoverableEntry] = []
    @State private var loadState: LoadState = .loading
    @State private var pendingRestore: RecoverableEntry?
    @State private var selection: RecoverableEntry.ID?

    enum LoadState { case loading, loaded, empty }

    public init(
        initialFilter: RecoveryListFilter,
        currentPageRelativePath: String?,
        loadEntries: @escaping (RecoveryListFilter) async -> [RecoverableEntry],
        onRestore: @escaping (RecoverableEntry) async -> Bool,
        onClose: @escaping () -> Void
    ) {
        self.initialFilter = initialFilter
        self.currentPageRelativePath = currentPageRelativePath
        self.loadEntries = loadEntries
        self.onRestore = onRestore
        self.onClose = onClose
        _filter = State(initialValue: initialFilter)
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if currentPageRelativePath != nil {
                    scopePicker
                        .padding(.horizontal)
                        .padding(.top, 8)
                }
                content
            }
                .navigationTitle("Recover")
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
        .onChange(of: filter) { _, _ in
            Task { await refresh() }
        }
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
    private var scopePicker: some View {
        if let rel = currentPageRelativePath {
            Picker("Scope", selection: scopeBinding) {
                Text("This page").tag(Scope.thisPage)
                Text("All pages").tag(Scope.all)
            }
            .pickerStyle(.segmented)
            .accessibilityHint(rel)
        }
    }

    private enum Scope: Hashable { case thisPage, all }

    private var scopeBinding: Binding<Scope> {
        Binding(
            get: {
                switch filter {
                case .all: return .all
                case .page: return .thisPage
                }
            },
            set: { newValue in
                switch newValue {
                case .all:
                    filter = .all
                case .thisPage:
                    if let rel = currentPageRelativePath {
                        filter = .page(relativePath: rel)
                    }
                }
            }
        )
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
        case .lostBlock: return "square.stack.3d.up"
        }
    }

    private func secondaryLine(for entry: RecoverableEntry) -> String {
        entry.sourcePath
    }

    private func restoreMessage(for entry: RecoverableEntry) -> String {
        switch entry {
        case .deletedPage:
            return "“\(entry.displayTitle)” will be moved back to \(entry.sourcePath)."
        case .lostBlock(let lost):
            let location = lost.parentHash != nil
                ? "inside its original parent (or the closest live ancestor)"
                : "at the top of the page"
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
