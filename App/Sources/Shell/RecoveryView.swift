import SwiftUI
import Editor

/// Unified workspace-wide recovery sheet. Surfaces three kinds of
/// recoverable items, each in its own section: deleted whole pages (from
/// `TrashStore`), lost blocks (recovery-log entries whose hash isn't in
/// `.md`), and intentionally-deleted blocks (log entries whose latest
/// record is a tombstone — visually distinct and capped at 30 days by
/// default, with "Show older" to expand).
///
/// `filter` is `.all` (everything) or `.page(rel)` (one source page only).
/// Inside the sheet a segmented control lets the user flip between scopes
/// without re-opening; on entry from a deeper page it defaults to that page.
struct RecoveryView: View {
    /// Captured at sheet-open time. Empty when triggered from a no-page context
    /// (e.g. the empty-workspace state); in that case the segmented control
    /// hides "This page" and only `.all` is reachable.
    let currentPageRelativePath: String?
    /// Two-pass stream: first emission is the trash + stub list, subsequent
    /// emissions replace stubs with populated entries as bodies load.
    /// `showAllPurged` lifts the default 30-day cap on the purged section.
    let entriesStream: (RecoveryListFilter, Bool) -> AsyncStream<[RecoverableEntry]>
    let onRestore: (RecoverableEntry) async -> Bool
    let onClose: () -> Void

    /// Live filter — seeded from the `initialFilter` init param, then driven by
    /// the segmented control so the sheet doesn't remount on scope change.
    @State private var filter: RecoveryListFilter
    @State private var entries: [RecoverableEntry] = []
    @State private var loadState: LoadState = .loading
    @State private var pendingRestore: RecoverableEntry?
    @State private var selection: RecoverableEntry.ID?
    @State private var showAllPurged: Bool = false

    enum LoadState { case loading, loaded, empty }

    init(
        initialFilter: RecoveryListFilter,
        currentPageRelativePath: String?,
        entriesStream: @escaping (RecoveryListFilter, Bool) -> AsyncStream<[RecoverableEntry]>,
        onRestore: @escaping (RecoverableEntry) async -> Bool,
        onClose: @escaping () -> Void
    ) {
        self.currentPageRelativePath = currentPageRelativePath
        self.entriesStream = entriesStream
        self.onRestore = onRestore
        self.onClose = onClose
        _filter = State(initialValue: initialFilter)
    }

    var body: some View {
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
        .task(id: StreamKey(filter: filter, showAllPurged: showAllPurged)) {
            await consumeStream(for: filter, showAllPurged: showAllPurged)
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
        let pages = entries.filter { if case .deletedPage = $0 { return true } else { return false } }
        let lost = entries.filter { if case .lostBlock = $0 { return true } else { return false } }
        let purged = entries.filter { if case .purgedBlock = $0 { return true } else { return false } }
        return List(selection: $selection) {
            if !pages.isEmpty {
                Section("Pages") {
                    ForEach(pages) { entry in row(for: entry).tag(entry.id) }
                }
            }
            if !lost.isEmpty {
                Section("Lost") {
                    ForEach(lost) { entry in row(for: entry).tag(entry.id) }
                }
            }
            if !purged.isEmpty || showAllPurged {
                Section("Deleted on purpose") {
                    ForEach(purged) { entry in row(for: entry).tag(entry.id) }
                    if !showAllPurged {
                        Button("Show older") { showAllPurged = true }
                            .buttonStyle(.borderless)
                            .font(HunchStyle.body(size: 12))
                            .foregroundStyle(HunchStyle.mutedForeground)
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

    @ViewBuilder
    private func row(for entry: RecoverableEntry) -> some View {
        let isPurged = entry.isPurged
        HStack(spacing: 10) {
            Image(systemName: icon(for: entry))
                .foregroundStyle(HunchStyle.mutedForeground)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.displayTitle)
                        .font(HunchStyle.body())
                        .foregroundStyle(isPurged ? HunchStyle.mutedForeground : HunchStyle.foreground)
                        .lineLimit(1)
                    if entry.nestedCount > 0 {
                        Text("+\(entry.nestedCount) more")
                            .font(HunchStyle.body(size: 11))
                            .foregroundStyle(HunchStyle.mutedForeground)
                    }
                }
                Text(secondaryLine(for: entry))
                    .font(HunchStyle.body(size: 12))
                    .foregroundStyle(HunchStyle.mutedForeground)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(entry.timestamp, style: .relative)
                .font(HunchStyle.body(size: 12))
                .foregroundStyle(HunchStyle.mutedForeground)
        }
        .padding(.vertical, 4)
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

    private func icon(for entry: RecoverableEntry) -> String {
        switch entry {
        case .deletedPage: return "doc.text"
        case .lostBlock: return "square.stack.3d.up"
        case .purgedBlock: return "trash.slash"
        }
    }

    private func secondaryLine(for entry: RecoverableEntry) -> String {
        entry.sourcePath
    }

    private func restoreMessage(for entry: RecoverableEntry) -> String {
        switch entry {
        case .deletedPage:
            return "“\(entry.displayTitle)” will be moved back to \(entry.sourcePath)."
        case .lostBlock(let group):
            let location = group.root.parentHash != nil
                ? "inside its original parent (or the closest live ancestor)"
                : "at the top of the page"
            let extras = group.nestedCount > 0
                ? " (with \(group.nestedCount) nested \(group.nestedCount == 1 ? "block" : "blocks"))"
                : ""
            return "Block\(extras) will be inserted in \(entry.sourcePath) \(location), without overwriting the current contents."
        case .purgedBlock(let group):
            let extras = group.nestedCount > 0
                ? " (with \(group.nestedCount) nested \(group.nestedCount == 1 ? "block" : "blocks"))"
                : ""
            return "This block\(extras) was deleted on purpose. Restore it back into \(entry.sourcePath)?"
        }
    }

    private func consumeStream(for filter: RecoveryListFilter, showAllPurged: Bool) async {
        if entries.isEmpty { loadState = .loading }
        for await next in entriesStream(filter, showAllPurged) {
            entries = next
            loadState = next.isEmpty ? .empty : .loaded
        }
    }

    private func performRestore(_ entry: RecoverableEntry) async {
        if await onRestore(entry) {
            await consumeStream(for: filter, showAllPurged: showAllPurged)
        }
    }
}

private struct StreamKey: Hashable {
    let filter: RecoveryListFilter
    let showAllPurged: Bool
}
