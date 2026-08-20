import SwiftUI
import Quagmire
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct ContentView: View {
    @Bindable var workspace: Workspace
    @State private var window: WorkspaceWindow
    @State private var recordingSession = VoiceRecordingSession()
    @State private var renameSuggestionTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Bindable var quickActions: QuickActionRouter
    @State private var showIconPicker = false
    #endif

    #if os(iOS)
    init(workspace: Workspace, quickActions: QuickActionRouter) {
        self.workspace = workspace
        self.quickActions = quickActions
        _window = State(initialValue: WorkspaceWindow(workspace: workspace))
    }
    #else
    init(workspace: Workspace) {
        self.workspace = workspace
        _window = State(initialValue: WorkspaceWindow(workspace: workspace))
    }
    #endif

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
                // Offer to rename the file when the H1 title diverges from the
                // filename. Debounced: the title recomputes on every committed
                // transaction while the user is typing the heading, so wait for
                // a pause before prompting.
                .onChange(of: window.openDocument?.title) { _, _ in
                    renameSuggestionTask?.cancel()
                    renameSuggestionTask = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        guard !Task.isCancelled else { return }
                        window.evaluateRenameSuggestion()
                    }
                }
                .sheet(isPresented: $window.showSearch) {
                    PageSearchSheet(
                        workspace: workspace,
                        excluding: nil,
                        onActivate: { item in
                            window.navigateFromSearch(relativePath: item.id.rawValue)
                            window.showSearch = false
                        },
                        onSetHome: setHome,
                        onMoveToTrash: moveToTrash,
                        onClose: { window.showSearch = false }
                    )
                }
                .sheet(isPresented: $window.showAddToPageSearch) {
                    PageSearchSheet(
                        workspace: workspace,
                        excluding: window.currentPageURL,
                        title: "Add This Page to…",
                        onActivate: { item in
                            Task {
                                if await window.appendCurrentPageLink(to: item.id.rawValue) {
                                    window.showAddToPageSearch = false
                                }
                            }
                        },
                        onClose: { window.showAddToPageSearch = false }
                    )
                }
                .sheet(item: $window.moveRequest) { request in
                    MoveDestinationSheet(
                        workspace: workspace,
                        inDocCandidates: request.inDocCandidates,
                        excluding: window.currentPageURL,
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
                .confirmationDialog(
                    "Move page to Trash?",
                    isPresented: subpageTrashPromptPresented,
                    titleVisibility: .visible
                ) {
                    if let prompt = window.pendingSubpageTrashPrompt {
                        Button("Move to Trash", role: .destructive) {
                            movePromptedSubpageToTrash(prompt)
                        }
                    }
                    Button("Keep Page", role: .cancel) {
                        window.pendingSubpageTrashPrompt = nil
                    }
                } message: {
                    if let prompt = window.pendingSubpageTrashPrompt {
                        Text("\"\(prompt.title)\" no longer has any links pointing to it.")
                    }
                }
            }
        }
        .focusedValue(\.workspaceWindow, window)
        .task {
            workspace.tryRestore()
            forwardPendingVoiceRecording()
        }
        .onChange(of: workspace.workspaceURL) { _, new in
            // switchWorkspace propagates to every open window — drop our
            // navigation/cache so the next mount starts fresh.
            if new == nil {
                recordingSession.cancel()
                window.reset()
            }
        }
        .onChange(of: scenePhase) { _, new in
            if new == .active {
                window.refreshCloudSyncSnapshot()
                forwardPendingVoiceRecording()
            } else if let doc = window.openDocument {
                Task { await window.flush(doc) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: VoiceRecordingLaunchRequest.notificationName)) { _ in
            forwardPendingVoiceRecording()
        }
        .alert("Recording", isPresented: recordingErrorBinding) {
            Button("OK") { recordingSession.errorMessage = nil }
        } message: {
            Text(recordingSession.errorMessage ?? "")
        }
        .alert("Recover Recording?", isPresented: recordingRecoveryBinding) {
            Button("Transcribe and Add") {
                Task { await recordingSession.recoverPendingRecording(using: window) }
            }
            Button("Later", role: .cancel) {
                recordingSession.deferPendingRecovery()
            }
        } message: {
            Text(recordingRecoveryMessage)
        }
        .alert("Error", isPresented: errorBinding) {
            Button("OK") { workspace.error = nil }
        } message: {
            Text(workspace.error ?? "")
        }
        .overlay(alignment: .top) {
            if let banner = presentedBanner {
                BannerView(banner: banner) {
                    dismissPresentedBanner(banner)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: 480)
                .allowsHitTesting(true)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: presentedBanner?.id)
        #if os(iOS)
        .onChange(of: quickActions.iconPickerRequestID, initial: true) { _, _ in
            if quickActions.consumeIconPickerRequest() {
                showIconPicker = true
            }
        }
        .sheet(isPresented: $showIconPicker) { IconPickerView() }
        #endif
    }

    /// Workspace failures and reconcile results take precedence, but a
    /// persistent page action remains underneath and can reappear after the
    /// transient workspace banner dismisses.
    private var presentedBanner: Workspace.Banner? {
        workspace.banner ?? window.pageBanner
    }

    private func dismissPresentedBanner(_ banner: Workspace.Banner) {
        if workspace.banner?.id == banner.id {
            workspace.banner = nil
        }
        if window.pageBanner?.id == banner.id {
            window.pageBanner = nil
        }
    }

    /// NavigationStack root: the home page editor when home is set and loaded;
    /// an empty state otherwise (fresh workspace, no home picked yet).
    @ViewBuilder
    private var rootView: some View {
        if let homeURL = workspace.homeURL {
            EditorPage(
                url: homeURL,
                workspace: workspace,
                window: window,
                recordingSession: recordingSession
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

    private var recordingErrorBinding: Binding<Bool> {
        Binding(
            get: { recordingSession.errorMessage != nil },
            set: { newValue in
                if !newValue { recordingSession.errorMessage = nil }
            }
        )
    }

    private var recordingRecoveryBinding: Binding<Bool> {
        Binding(
            get: {
                recordingSession.pendingRecovery != nil
                    && recordingSession.errorMessage == nil
            },
            set: { _ in }
        )
    }

    private var recordingRecoveryMessage: String {
        guard let recording = recordingSession.pendingRecovery else { return "" }
        let date = recording.createdAt.formatted(date: .abbreviated, time: .shortened)
        return "Hunch preserved an unfinished recording from \(date). It will be transcribed and added to its original page."
    }

    private func forwardPendingVoiceRecording() {
        guard VoiceRecordingLaunchRequest.consumePendingStart() else { return }
        // Defer state changes off NotificationCenter's synchronous delivery;
        // an intent can post while SwiftUI is updating this view hierarchy.
        Task { @MainActor in
            guard let homePageID = workspace.homeRelativePath else {
                recordingSession.reportMissingHome()
                return
            }
            await recordingSession.toggleFromShortcut(homePageID: homePageID, window: window)
        }
    }

    private var subpageTrashPromptPresented: Binding<Bool> {
        Binding(
            get: { window.pendingSubpageTrashPrompt != nil },
            set: { newValue in
                if !newValue {
                    window.pendingSubpageTrashPrompt = nil
                }
            }
        )
    }

    private func setHome(_ item: MentionItem) {
        if let entry = workspace.clamshell?.entry(at: item.id.rawValue) {
            workspace.clamshell?.setHome(relativePath: entry.relativePath)
        }
    }

    private func moveToTrash(_ item: MentionItem) {
        if let entry = workspace.clamshell?.entry(at: item.id.rawValue) {
            Task { await window.moveToTrash(entry) }
        }
    }

    private func movePromptedSubpageToTrash(_ prompt: WorkspaceWindow.SubpageTrashPrompt) {
        guard let entry = workspace.clamshell?.entry(at: prompt.pageID) else {
            window.pendingSubpageTrashPrompt = nil
            return
        }
        Task { await window.moveToTrash(entry) }
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
            window: window,
            recordingSession: recordingSession
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
    let recordingSession: VoiceRecordingSession

    @State private var editorState = EditorState()
    @FocusedValue(\.documentUndoController) private var undoController
    @FocusedValue(\.editorCommands) private var editorCommands

    var body: some View {
        Group {
            if let document = window.documentForPage(url: url) {
                EditorView(
                    document: document,
                    state: editorState,
                    host: window,
                    configuration: HunchStyle.editorConfiguration
                ) {
                    VStack(spacing: 0) {
                        BacklinksFooter(workspace: workspace, window: window, url: url)
                        if let snapshot = window.cloudSyncSnapshot {
                            PageSyncFooter(
                                snapshot: snapshot,
                                isCompactingLog: window.isCompactingLog,
                                onCompactLog: { window.compactCurrentPageLog() }
                            )
                        }
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(HunchStyle.background)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .hunchEscapeKeyDown)) { _ in
            editorCommands?.perform(.escape)
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
                    undoController?.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .foregroundStyle(undoController?.canUndo == true ? HierarchicalShapeStyle.primary : .tertiary)
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
            if undoController?.canRedo == true {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        undoController?.redo()
                    } label: {
                        Image(systemName: "arrow.uturn.forward")
                    }
                    .accessibilityLabel("Redo")
                }
            }
            #endif
            ToolbarItem(placement: .primaryAction) {
                RecordingButton(
                    editorState: editorState,
                    recordingSession: recordingSession,
                    window: window
                )
            }
        }
    }
}

/// "Linked from" list shown below the page content — the pages that link to
/// this one. Pure host UI reading `Clamshell.linkGraph` (no editor changes);
/// reactive via `@Observable`, so it fills in when the graph build/patch lands
/// and updates as links change. Calling `linkGraphOrBuild()` in `body` warms
/// the graph in the background whenever a page opens.
private struct BacklinksFooter: View {
    @Bindable var workspace: Workspace
    @Bindable var window: WorkspaceWindow
    let url: URL

    var body: some View {
        let backlinks: [String] = {
            guard let clamshell = workspace.clamshell,
                  let graph = clamshell.linkGraphOrBuild() else { return [] }
            return graph.backlinks(of: clamshell.relativePath(of: url))
        }()
        if !backlinks.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Linked from")
                    .font(HunchStyle.body(size: 11, weight: .semibold))
                    .foregroundStyle(HunchStyle.mutedForeground)
                    .textCase(.uppercase)
                ForEach(backlinks, id: \.self) { pageID in
                    Button {
                        window.openSubpage(relativePath: pageID)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 12))
                                .foregroundStyle(HunchStyle.mutedForeground)
                            Text(title(for: pageID))
                                .font(HunchStyle.body(size: 14))
                                .foregroundStyle(HunchStyle.foreground)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 24)
            .padding(.bottom, 8)
        }
    }

    private func title(for pageID: String) -> String {
        workspace.clamshell?.entry(at: pageID)?.title ?? pageID
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
                    .font(HunchStyle.body(size: 11, weight: .medium))
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
        case .local: return HunchStyle.mutedForeground
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
                .font(HunchStyle.body(size: 13, weight: .semibold))
                .foregroundStyle(HunchStyle.foreground)

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
                    .font(HunchStyle.body(size: 12, weight: .medium))
                    .foregroundStyle(HunchStyle.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(HunchStyle.body(size: 11))
                    .foregroundStyle(item.status == .error ? .red : HunchStyle.mutedForeground)
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
        case .local, .missingNeutral: return HunchStyle.mutedForeground
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
                .foregroundStyle(HunchStyle.mutedForeground)
            Text("Welcome to Hunch")
                .font(HunchStyle.body(size: 22, weight: .semibold))
                .foregroundStyle(HunchStyle.foreground)
            Text("A workspace is a folder of plain markdown files. Pick one to get started.")
                .font(HunchStyle.body(size: 14))
                .foregroundStyle(HunchStyle.mutedForeground)
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
        .background(HunchStyle.background)
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
                .foregroundStyle(HunchStyle.mutedForeground)
            Text("Pick a page to open by default")
                .font(HunchStyle.body(size: 18, weight: .semibold))
                .foregroundStyle(HunchStyle.foreground)
            Text("Choose one from your workspace, or create a new page.")
                .font(HunchStyle.body(size: 14))
                .foregroundStyle(HunchStyle.mutedForeground)
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
                    guard let path = workspace.createDocument(title: "Untitled", requestedPath: nil, initialContent: nil) else { return }
                    workspace.clamshell?.setHome(relativePath: path)
                } label: {
                    Label("New page", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HunchStyle.background)
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
