import SwiftUI
import Editor
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct ContentView: View {
    @Bindable var workspace: Workspace
    @State private var window: WorkspaceWindow
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @State private var showIconPicker = false
    #endif

    init(workspace: Workspace) {
        self.workspace = workspace
        _window = State(initialValue: WorkspaceWindow(workspace: workspace))
    }

    var body: some View {
        Group {
            if workspace.workspaceURL == nil {
                WorkspacePickerView(workspace: workspace)
            } else {
                NavigationStack(path: $window.path) {
                    rootView
                        .navigationDestination(for: URL.self) { url in
                            pageDetail(for: url)
                        }
                }
                // `initial: true` covers the path-restored-by-tryRestore case where
                // the NavigationStack mounts with a non-empty path; without it
                // `openDocument` would never load and `pageDetail` would render
                // the ProgressView fallback forever.
                .onChange(of: window.path, initial: true) { _, _ in
                    window.handlePathChange()
                }
                .onChange(of: workspace.homeURL, initial: true) { _, _ in
                    window.handlePathChange()
                }
                .sheet(isPresented: $window.showSearch) {
                    SearchSheet(
                        workspace: workspace,
                        excluding: nil,
                        onActivate: { item in
                            window.navigateFromSearch(relativePath: item.id)
                            window.showSearch = false
                        },
                        onSetHome: setHome,
                        onMoveToTrash: moveToTrash,
                        onClose: { window.showSearch = false }
                    )
                }
                .sheet(item: $window.moveRequest) { request in
                    MoveDestinationSheet(
                        workspace: workspace,
                        inDocCandidates: request.inDocCandidates,
                        excluding: window.openDocument?.url,
                        onActivate: { destination in window.resolveMoveRequest(with: destination) },
                        onClose: { window.resolveMoveRequest(with: nil) }
                    )
                }
                .sheet(item: $window.recoveryFilter) { filter in
                    RecoveryView(
                        initialFilter: filter,
                        currentPageRelativePath: window.currentPageRelativePath,
                        entriesStream: { filter, showAllPurged in
                            workspace.streamRecoverableEntries(filter: filter, showAllPurged: showAllPurged)
                        },
                        onRestore: { entry in await window.restoreRecoverable(entry) },
                        onClose: { window.recoveryFilter = nil }
                    )
                    #if os(macOS)
                    .frame(minWidth: 480, minHeight: 480)
                    #endif
                }
            }
        }
        .focusedValue(\.workspaceWindow, window)
        .task { workspace.tryRestore() }
        .onChange(of: workspace.workspaceURL) { _, new in
            // switchWorkspace propagates to every open window — drop our
            // navigation/cache so the next mount starts fresh.
            if new == nil { window.reset() }
        }
        .onChange(of: scenePhase) { _, new in
            if new == .active {
                window.refreshCloudSyncSnapshot()
            } else if let doc = window.openDocument {
                Task { await window.flush(doc) }
            }
        }
        .alert("Error", isPresented: errorBinding) {
            Button("OK") { workspace.error = nil }
        } message: {
            Text(workspace.error ?? "")
        }
        .overlay(alignment: .top) {
            if let banner = workspace.banner {
                BannerView(banner: banner) {
                    if workspace.banner?.id == banner.id { workspace.banner = nil }
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: 480)
                .allowsHitTesting(true)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: workspace.banner?.id)
        #if os(iOS)
        .onShake { showIconPicker = true }
        .sheet(isPresented: $showIconPicker) { IconPickerView() }
        #endif
    }

    /// NavigationStack root: the home page editor when home is set and loaded;
    /// an empty state otherwise (fresh workspace, no home picked yet).
    @ViewBuilder
    private var rootView: some View {
        if let homeURL = workspace.homeURL {
            EditorPage(
                url: homeURL,
                workspace: workspace,
                window: window
            )
            .id(homeURL)
        } else {
            EmptyWorkspaceView(workspace: workspace, window: window)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { workspace.error != nil },
            set: { newValue in if !newValue { workspace.error = nil } }
        )
    }

    private func setHome(_ item: MentionItem) {
        if let entry = workspace.clamshell?.entry(at: item.id) {
            workspace.clamshell?.setHome(relativePath: entry.relativePath)
        }
    }

    private func moveToTrash(_ item: MentionItem) {
        if let entry = workspace.clamshell?.entry(at: item.id) {
            Task { await window.moveToTrash(entry) }
        }
    }

    @ViewBuilder
    private func pageDetail(for url: URL) -> some View {
        // Wrap the editor in a per-URL view so SwiftUI's view-identity gives
        // us a fresh EditorState (and undo controller, focus, etc.) each time
        // the user navigates to a different document. Keep the shell mounted
        // during loading so iOS does not drop the page toolbar.
        EditorPage(
            url: url,
            workspace: workspace,
            window: window
        )
        .id(url)
    }
}

/// Per-URL editor page. Owns an `EditorState` whose lifetime matches the
/// navigation destination's view-identity — pushing a new URL mounts a fresh
/// `EditorPage` (and a fresh `EditorState`); navigating back unmounts it.
/// The `EditorHost` is the window itself; the save lifecycle lives there
/// and is naturally keyed on `openDocument` (one active doc per window).
private struct EditorPage: View {
    let url: URL
    @Bindable var workspace: Workspace
    @Bindable var window: WorkspaceWindow

    @State private var editorState = EditorState()
    @FocusedValue(\.documentUndoController) private var undoController

    var body: some View {
        Group {
            if let document = window.documentForPage(url: url) {
                EditorView(
                    document: document,
                    state: editorState,
                    host: window
                ) {
                    if let snapshot = window.cloudSyncSnapshot {
                        PageSyncFooter(
                            snapshot: snapshot,
                            isCompactingLog: window.isCompactingLog,
                            onCompactLog: { window.compactCurrentPageLog() }
                        )
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(NotionStyle.background)
            }
        }
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .primaryAction) {
                Button {
                    window.showSearch = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("Search Pages")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    undoController?.undoManager.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .foregroundStyle(undoController?.undoManager.canUndo == true ? HierarchicalShapeStyle.primary : .tertiary)
                }
                .accessibilityLabel("Undo")
                .contextMenu {
                    Button {
                        window.recoveryFilter = .page(relativePath: workspace.clamshell?.relativePath(of: url) ?? url.lastPathComponent)
                    } label: {
                        Label("Recover…", systemImage: "clock.arrow.circlepath")
                    }
                }
            }
            if undoController?.undoManager.canRedo == true {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        undoController?.undoManager.redo()
                    } label: {
                        Image(systemName: "arrow.uturn.forward")
                    }
                    .accessibilityLabel("Redo")
                }
            }
            #endif
            ToolbarItem(placement: .primaryAction) {
                RecordingButton(editorState: editorState)
            }
        }
    }
}

private struct PageSyncFooter: View {
    let snapshot: Clamshell.CloudSyncSnapshot
    let isCompactingLog: Bool
    let onCompactLog: () -> Void
    @State private var showingDetails = false

    var body: some View {
        HStack(spacing: 0) {
            Button {
                showingDetails.toggle()
            } label: {
                Label(statusTitle, systemImage: statusIcon)
                    .font(NotionStyle.body(size: 11, weight: .medium))
                    .foregroundStyle(statusTint)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            #if os(iOS)
            .sheet(isPresented: $showingDetails) {
                PageSyncPopover(
                    snapshot: snapshot,
                    isCompactingLog: isCompactingLog,
                    onCompactLog: onCompactLog
                )
                .presentationDetents([.height(PageSyncPopover.iosSheetHeight(for: snapshot))])
                .presentationDragIndicator(.visible)
            }
            #else
            .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
                PageSyncPopover(
                    snapshot: snapshot,
                    isCompactingLog: isCompactingLog,
                    onCompactLog: onCompactLog
                )
            }
            #endif
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var statusTitle: String {
        switch snapshot.state {
        case .synced: return "iCloud synced"
        case .syncing: return "Syncing"
        case .waiting: return "Waiting for iCloud"
        case .error: return "iCloud issue"
        case .local: return "Local folder"
        }
    }

    private var statusIcon: String {
        switch snapshot.state {
        case .synced: return "icloud"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .waiting: return "icloud.and.arrow.up"
        case .error: return "exclamationmark.icloud"
        case .local: return "folder"
        }
    }

    private var statusTint: Color {
        switch snapshot.state {
        case .synced: return .secondary
        case .syncing: return .blue
        case .waiting: return .orange
        case .error: return .red
        case .local: return NotionStyle.mutedForeground
        }
    }
}

private struct PageSyncPopover: View {
    let snapshot: Clamshell.CloudSyncSnapshot
    let isCompactingLog: Bool
    let onCompactLog: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("iCloud Status")
                .font(NotionStyle.body(size: 13, weight: .semibold))
                .foregroundStyle(NotionStyle.foreground)

            ForEach(snapshot.items) { item in
                PageSyncRow(item: item)
            }

            if canCompactLog {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    compactLogButton
                }
                .controlSize(.small)
            }

            #if os(macOS)
            let revealable = snapshot.items.filter(\.exists)
            if !revealable.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(revealable) { item in
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([item.url])
                        } label: {
                            Label(revealTitle(for: item), systemImage: "arrow.up.forward.app")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .controlSize(.small)
            }
            #endif
        }
        .padding(14)
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 360, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    #if os(iOS)
    static func iosSheetHeight(for snapshot: Clamshell.CloudSyncSnapshot) -> CGFloat {
        let titleHeight: CGFloat = 20
        let rowHeight: CGFloat = 42
        let verticalPadding: CGFloat = 42
        let compactActionHeight: CGFloat = canCompactLog(in: snapshot) ? 50 : 0
        let interItemSpacing = CGFloat(max(snapshot.items.count, 0)) * 12
        return verticalPadding + titleHeight + interItemSpacing + CGFloat(snapshot.items.count) * rowHeight + compactActionHeight
    }
    #endif

    private var canCompactLog: Bool {
        Self.canCompactLog(in: snapshot)
    }

    private static func canCompactLog(in snapshot: Clamshell.CloudSyncSnapshot) -> Bool {
        snapshot.items.contains { $0.target.kind == .thisDeviceLog && $0.exists }
    }

    private var compactLogButton: some View {
        Button {
            onCompactLog()
        } label: {
            Label(isCompactingLog ? "Compacting" : "Compact Log", systemImage: "arrow.down.left.and.arrow.up.right")
        }
        .disabled(isCompactingLog)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    #if os(macOS)
    private func revealTitle(for item: Clamshell.CloudSyncItemSnapshot) -> String {
        switch item.target.kind {
        case .page: return "Reveal Page"
        case .thisDeviceLog: return "Reveal Log"
        }
    }
    #endif
}

private struct PageSyncRow: View {
    let item: Clamshell.CloudSyncItemSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.target.displayName)
                    .font(NotionStyle.body(size: 12, weight: .medium))
                    .foregroundStyle(NotionStyle.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(NotionStyle.body(size: 11))
                    .foregroundStyle(item.status == .error ? .red : NotionStyle.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var detail: String {
        let status: String
        if let detail = item.detail {
            status = detail
        } else {
            status = switch item.status {
            case .synced: "Uploaded to iCloud"
            case .syncing: "Uploading"
            case .waiting: "Pending upload"
            case .error: "Needs attention"
            case .local: "Not in iCloud"
            case .missingNeutral: "No local log yet"
            }
        }
        guard let byteCount = item.byteCount else { return status }
        return "\(status) · \(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))"
    }

    private var icon: String {
        switch item.status {
        case .synced: return "checkmark.circle"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .waiting: return "clock"
        case .error: return "exclamationmark.triangle"
        case .local: return "folder"
        case .missingNeutral: return "minus.circle"
        }
    }

    private var tint: Color {
        switch item.status {
        case .synced: return .green
        case .syncing: return .blue
        case .waiting: return .orange
        case .error: return .red
        case .local, .missingNeutral: return NotionStyle.mutedForeground
        }
    }
}

private struct WorkspacePickerView: View {
    let workspace: Workspace
    @State private var showingOpenPicker = false
    #if os(iOS)
    @State private var showingNameSheet = false
    @State private var newWorkspaceName = "My Notes"
    #endif

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 64))
                .foregroundStyle(NotionStyle.mutedForeground)
            Text("Welcome to Hunch")
                .font(NotionStyle.body(size: 22, weight: .semibold))
                .foregroundStyle(NotionStyle.foreground)
            Text("A workspace is a folder of plain markdown files. Pick one to get started.")
                .font(NotionStyle.body(size: 14))
                .foregroundStyle(NotionStyle.mutedForeground)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            HStack(spacing: 12) {
                Button {
                    createNewWorkspace()
                } label: {
                    Label("Create new workspace", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                Button {
                    showingOpenPicker = true
                } label: {
                    Label("Open a folder", systemImage: "folder")
                }
                .buttonStyle(.bordered)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NotionStyle.background)
        .fileImporter(
            isPresented: $showingOpenPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    workspace.setWorkspace(url)
                }
            case .failure(let error):
                workspace.error = error.localizedDescription
            }
        }
        #if os(iOS)
        .sheet(isPresented: $showingNameSheet) {
            NewWorkspaceNameSheet(
                name: $newWorkspaceName,
                onCancel: { showingNameSheet = false },
                onCreate: { name in
                    showingNameSheet = false
                    createIOSWorkspace(named: name)
                }
            )
        }
        #endif
    }

    private func createNewWorkspace() {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.title = "Create New Workspace"
        panel.message = "Hunch will create a folder here for your markdown files."
        panel.nameFieldLabel = "Workspace name:"
        panel.nameFieldStringValue = "My Notes"
        panel.prompt = "Create"
        panel.canCreateDirectories = true
        panel.allowsOtherFileTypes = true
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK, let url = panel.url {
            workspace.createNewWorkspace(at: url)
        }
        #else
        newWorkspaceName = "My Notes"
        showingNameSheet = true
        #endif
    }

    #if os(iOS)
    private func createIOSWorkspace(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else {
            workspace.error = "Couldn't locate the Documents directory."
            return
        }
        workspace.createNewWorkspace(at: docs.appendingPathComponent(trimmed))
    }
    #endif
}

#if os(iOS)
private struct NewWorkspaceNameSheet: View {
    @Binding var name: String
    let onCancel: () -> Void
    let onCreate: (String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Workspace name", text: $name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)
                } footer: {
                    Text("A folder by this name will be created in Hunch's Documents directory — visible in the Files app under On My iPhone → Hunch.")
                }
            }
            .navigationTitle("New Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate(name)
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
#endif

/// Unified search sheet. Used both for navigation (set-home / move-to-trash
/// rows enabled, activate pushes via the caller's `onActivate`) and for the
/// block-move destination picker (set-home / move-to-trash absent, activate
/// completes the move). The sheet itself is mode-agnostic; the caller wires
/// the appropriate callbacks.
private struct SearchSheet: View {
    let workspace: Workspace
    let excluding: URL?
    var title: String = "Search"
    let onActivate: (MentionItem) -> Void
    var onSetHome: ((MentionItem) -> Void)? = nil
    var onMoveToTrash: ((MentionItem) -> Void)? = nil
    let onClose: () -> Void

    @State private var query: String = ""
    @State private var cursor: MentionItem.ID?

    private var items: [MentionItem] {
        guard let clamshell = workspace.clamshell else { return [] }
        let home = clamshell.homeRelativePath
        return clamshell.pages(matching: query, excluding: excluding)
            .map { $0.asMentionItem(homeRelativePath: home) }
    }

    var body: some View {
        NavigationStack {
            PagePickerView(
                items: items,
                selection: $cursor,
                onActivate: onActivate,
                onSetHome: onSetHome,
                onMoveToTrash: onMoveToTrash
            )
            .onAppear {
                if cursor == nil { cursor = items.first?.id }
            }
            .onChange(of: query) { _, _ in
                cursor = items.first?.id
            }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $query, placement: .automatic, prompt: "Search pages")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onClose)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 480)
        #endif
    }
}

/// Shown as the NavigationStack root when no workspace home page is set.
/// Two ways forward: search the workspace for an existing page (which can
/// then be set as home) or create a fresh page that becomes home.
private struct EmptyWorkspaceView: View {
    @Bindable var workspace: Workspace
    @Bindable var window: WorkspaceWindow
    #if os(iOS)
    @State private var showingSwitchPicker = false
    #endif

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundStyle(NotionStyle.mutedForeground)
            Text("Pick a page to open by default")
                .font(NotionStyle.body(size: 18, weight: .semibold))
                .foregroundStyle(NotionStyle.foreground)
            Text("Choose one from your workspace, or create a new page.")
                .font(NotionStyle.body(size: 14))
                .foregroundStyle(NotionStyle.mutedForeground)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            HStack(spacing: 12) {
                Button {
                    window.showSearch = true
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .buttonStyle(.bordered)
                Button {
                    guard let path = workspace.createPage(title: "Untitled", requestedPath: nil, initialContent: nil) else { return }
                    workspace.clamshell?.setHome(relativePath: path)
                } label: {
                    Label("New page", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NotionStyle.background)
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingSwitchPicker = true
                } label: {
                    Image(systemName: "folder.badge.gearshape")
                }
                .accessibilityLabel("Switch Workspace")
            }
        }
        .fileImporter(
            isPresented: $showingSwitchPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    window.reset()
                    workspace.switchWorkspace()
                    workspace.setWorkspace(url)
                }
            case .failure(let error):
                workspace.error = error.localizedDescription
            }
        }
        #endif
    }
}
