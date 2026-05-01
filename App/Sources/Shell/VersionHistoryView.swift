import SwiftUI
import Editor

public struct VersionHistoryView: View {
    let pageTitle: String
    let relativePath: String
    let loadSnapshots: () async -> [HistorySnapshot]
    let loadContent: (HistorySnapshot) async -> String?
    let onRestore: (HistorySnapshot) async -> Bool
    let onClose: () -> Void

    @State private var snapshots: [HistorySnapshot] = []
    @State private var selection: HistorySnapshot.ID?
    @State private var preview: String = ""
    @State private var loadState: LoadState = .loading
    @State private var pendingRestore: HistorySnapshot?

    enum LoadState { case loading, loaded, empty }

    public init(
        pageTitle: String,
        relativePath: String,
        loadSnapshots: @escaping () async -> [HistorySnapshot],
        loadContent: @escaping (HistorySnapshot) async -> String?,
        onRestore: @escaping (HistorySnapshot) async -> Bool,
        onClose: @escaping () -> Void
    ) {
        self.pageTitle = pageTitle
        self.relativePath = relativePath
        self.loadSnapshots = loadSnapshots
        self.loadContent = loadContent
        self.onRestore = onRestore
        self.onClose = onClose
    }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle("Version History · \(pageTitle)")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { onClose() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Restore") {
                            if let snapshot = currentSnapshot {
                                pendingRestore = snapshot
                            }
                        }
                        .disabled(currentSnapshot == nil)
                    }
                }
        }
        .task { await refresh() }
        .onChange(of: selection) { _, _ in
            Task { await refreshPreview() }
        }
        .alert(
            "Restore this version?",
            isPresented: Binding(
                get: { pendingRestore != nil },
                set: { if !$0 { pendingRestore = nil } }
            ),
            presenting: pendingRestore
        ) { snapshot in
            Button("Restore") {
                Task { await performRestore(snapshot) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { snapshot in
            Text("The current contents of \(pageTitle) will be replaced with the version from \(formatted(snapshot.timestamp)). The replaced version will be added to history so you can revert.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            ContentUnavailableView(
                "No saved versions yet",
                systemImage: "clock.arrow.circlepath",
                description: Text("Earlier versions will appear here as you edit and save the page.")
            )
        case .loaded:
            HStack(spacing: 0) {
                listColumn
                    .frame(minWidth: 220, idealWidth: 260)
                Divider()
                previewColumn
            }
        }
    }

    private var listColumn: some View {
        List(selection: $selection) {
            ForEach(snapshots) { snapshot in
                VStack(alignment: .leading, spacing: 2) {
                    Text(formatted(snapshot.timestamp))
                        .font(NotionStyle.body())
                        .foregroundStyle(NotionStyle.foreground)
                    Text(snapshot.timestamp, style: .relative)
                        .font(NotionStyle.body(size: 12))
                        .foregroundStyle(NotionStyle.mutedForeground)
                }
                .padding(.vertical, 4)
                .tag(snapshot.id)
            }
        }
        .listStyle(.plain)
    }

    private var previewColumn: some View {
        ScrollView {
            Text(preview.isEmpty ? "Select a version to preview." : preview)
                .font(NotionStyle.body())
                .foregroundStyle(preview.isEmpty ? NotionStyle.mutedForeground : NotionStyle.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(16)
        }
        .frame(maxWidth: .infinity)
    }

    private var currentSnapshot: HistorySnapshot? {
        guard let selection else { return nil }
        return snapshots.first(where: { $0.id == selection })
    }

    private func formatted(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private func refresh() async {
        loadState = snapshots.isEmpty ? .loading : .loaded
        let next = await loadSnapshots()
        snapshots = next
        loadState = next.isEmpty ? .empty : .loaded
        if selection == nil, let first = next.first {
            selection = first.id
        }
        await refreshPreview()
    }

    private func refreshPreview() async {
        guard let snapshot = currentSnapshot else {
            preview = ""
            return
        }
        preview = (await loadContent(snapshot)) ?? ""
    }

    private func performRestore(_ snapshot: HistorySnapshot) async {
        if await onRestore(snapshot) {
            onClose()
        }
    }
}
