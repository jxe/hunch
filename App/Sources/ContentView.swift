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
    @State private var showingSwitchPicker = false
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
            if new != .active {
                Task { await window.flush() }
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
    }

    /// NavigationStack root: the home page editor when home is set and loaded;
    /// an empty state otherwise (fresh workspace, no home picked yet).
    @ViewBuilder
    private var rootView: some View {
        if let homeURL = workspace.homeURL {
            if let document = window.documentForPage(url: homeURL) {
                EditorPage(
                    url: homeURL,
                    document: document,
                    workspace: workspace,
                    window: window
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(NotionStyle.background)
            }
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
        if let entry = workspace.entries.first(where: { $0.relativePath == item.id }) {
            workspace.setHome(entry)
        }
    }

    private func moveToTrash(_ item: MentionItem) {
        if let entry = workspace.entries.first(where: { $0.relativePath == item.id }) {
            Task { await window.moveToTrash(entry) }
        }
    }

    @ViewBuilder
    private func pageDetail(for url: URL) -> some View {
        if let document = window.documentForPage(url: url) {
            // Wrap the editor in a per-URL view so SwiftUI's view-identity gives
            // us a fresh EditorState (and undo controller, focus, etc.) each
            // time the user navigates to a different document. The Editor
            // contract is one EditorState per document; navigating to a new
            // page mounts a new EditorPage with new state.
            EditorPage(
                url: url,
                document: document,
                workspace: workspace,
                window: window
            )
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(NotionStyle.background)
        }
    }
}

/// Per-URL editor page. Owns an `EditorState` whose lifetime matches the
/// navigation destination's view-identity — pushing a new URL mounts a fresh
/// `EditorPage` (and a fresh `EditorState`); navigating back unmounts it.
/// The `EditorHost` is the window itself; the save lifecycle lives there
/// and is naturally keyed on `openDocument` (one active doc per window).
private struct EditorPage: View {
    let url: URL
    let document: Document
    @Bindable var workspace: Workspace
    @Bindable var window: WorkspaceWindow

    @State private var editorState = EditorState()
    @FocusedValue(\.documentUndoController) private var undoController

    var body: some View {
        EditorView(
            document: document,
            state: editorState,
            host: window
        )
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
                        window.recoveryFilter = .page(relativePath: workspace.relativePath(of: url))
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
        workspace.clamshell?.pages(matching: query, excluding: excluding) ?? []
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
                    guard let path = workspace.createSubpage(title: "Untitled", requestedPath: nil, initialContent: nil),
                          let entry = workspace.entries.first(where: { $0.relativePath == path }) else { return }
                    workspace.setHome(entry)
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
