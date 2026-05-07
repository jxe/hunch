import SwiftUI
import Editor
import UniformTypeIdentifiers

private let markdownFileType = UTType(filenameExtension: "md") ?? .plainText

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
                .sheet(item: $window.moveRequest) { _ in
                    SearchSheet(
                        workspace: workspace,
                        excluding: window.openDocument?.url,
                        title: "Move to…",
                        onActivate: { item in window.resolveMoveRequest(with: item.id) },
                        onClose: { window.resolveMoveRequest(with: nil) }
                    )
                }
                .sheet(item: $window.recoveryFilter) { filter in
                    RecoveryView(
                        initialFilter: filter,
                        currentPageRelativePath: window.currentPageRelativePath,
                        entriesStream: { filter in workspace.streamRecoverableEntries(filter: filter) },
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
                Task { await window.saveNow() }
            }
        }
        .alert("Error", isPresented: errorBinding) {
            Button("OK") { workspace.error = nil }
        } message: {
            Text(workspace.error ?? "")
        }
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
            _ = window.moveToTrash(entry)
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
private struct EditorPage: View {
    let url: URL
    let document: Document
    @Bindable var workspace: Workspace
    @Bindable var window: WorkspaceWindow

    @State private var editorState = EditorState()
    @Environment(\.scenePhase) private var scenePhase
    @FocusedValue(\.documentUndoController) private var undoController

    var body: some View {
        EditorView(
            document: Binding(
                get: { window.documentForPage(url: url) ?? document },
                set: { window.updateDocumentForPage($0) }
            ),
            state: editorState,
            suggestPages: { query in
                workspace.pages(matching: query, excluding: window.openDocument?.url)
            },
            onSubpageTap: { pageID in
                window.openSubpage(relativePath: pageID)
            },
            pageTitle: { pageID in
                workspace.pageTitle(for: pageID)
            },
            onCreateSubpage: { title, requestedID, initialContent in
                workspace.createSubpage(title: title, requestedPath: requestedID, initialContent: initialContent)
            },
            onLoadSubpage: { pageID in
                workspace.loadSubpage(relativePath: pageID)
            },
            onAbsorbSubpage: { pageID in
                workspace.moveSubpageToTrash(relativePath: pageID)
            },
            onAppendToSubpage: { pageID, blocks in
                window.appendToSubpage(relativePath: pageID, blocks: blocks)
            },
            onRequestMoveDestination: { blockIDs, completion in
                window.requestMoveDestination(blockIDs: blockIDs, completion: completion)
            },
            onNavigateBack: {
                window.goBack()
            },
            onEdited: {
                window.markEdited()
            },
            onBlur: {
                Task { await window.saveNow() }
            },
            onRecordBlockDeletion: { indices, blocks, actionName in
                window.recordBlockDeletion(indices: indices, blocks: blocks, actionName: actionName)
            },
            serializeBlocksForPasteboard: { blocks in
                BlockSerializer.serialize(blocks)
            },
            parseBlocksFromPasteboard: { string in
                let blocks = BlockParser.parse(string)
                return blocks.isEmpty ? nil : blocks
            },
            linkPreviewProvider: workspace.linkPreviewService.provider(),
            onSaveImages: { items in
                workspace.saveImages(items)
            },
            imageURLResolver: { source in
                workspace.imageURL(for: source)
            }
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
                if undoController?.undoManager.canUndo == true {
                    Button {
                        undoController?.undoManager.undo()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .accessibilityLabel("Undo")
                    .contextMenu { recoverMenuItem(for: url) }
                } else {
                    Menu {
                        recoverMenuItem(for: url)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("More")
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
                EditorRecordingButton(state: editorState)
            }
        }
        .onAppear { forwardPendingVoiceRecording() }
        .onChange(of: scenePhase) { _, new in
            if new == .active { forwardPendingVoiceRecording() }
        }
        .onReceive(NotificationCenter.default.publisher(for: VoiceRecordingLaunchRequest.notificationName)) { _ in
            // The intent fires from another process and writes the pending-start
            // flag before posting the notification — consume the flag too so a
            // later `.active` transition doesn't fire a second time.
            _ = VoiceRecordingLaunchRequest.consumePendingStart()
            // Defer the state mutation off the publisher's synchronous delivery —
            // if the notification posts during a SwiftUI render pass the inline
            // assign trips "Modifying state during view update".
            Task { @MainActor in
                editorState.requestToggleVoiceRecording()
            }
        }
    }

    private func forwardPendingVoiceRecording() {
        guard VoiceRecordingLaunchRequest.consumePendingStart() else { return }
        editorState.requestToggleVoiceRecording()
    }

    #if os(iOS)
    @ViewBuilder
    private func recoverMenuItem(for url: URL) -> some View {
        Button {
            window.recoveryFilter = .page(relativePath: workspace.relativePath(of: url))
        } label: {
            Label("Recover…", systemImage: "clock.arrow.circlepath")
        }
    }
    #endif
}

private struct WorkspacePickerView: View {
    let workspace: Workspace
    @State private var showingPicker = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 64))
                .foregroundStyle(NotionStyle.mutedForeground)
            Text("Choose a key file")
                .font(NotionStyle.body(size: 18, weight: .semibold))
                .foregroundStyle(NotionStyle.foreground)
            Text("Pick the .md file Hunch should open by default. Its folder becomes the workspace.")
                .font(NotionStyle.body(size: 14))
                .foregroundStyle(NotionStyle.mutedForeground)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Choose key file") {
                showingPicker = true
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NotionStyle.background)
        .fileImporter(
            isPresented: $showingPicker,
            allowedContentTypes: [markdownFileType],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    workspace.setWorkspaceFromKeyFile(url)
                }
            case .failure(let error):
                workspace.error = error.localizedDescription
            }
        }
    }
}

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
        workspace.pages(matching: query, excluding: excluding)
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
            Text("No home page")
                .font(NotionStyle.body(size: 18, weight: .semibold))
                .foregroundStyle(NotionStyle.foreground)
            Text("Search to pick an existing page, or create a new one.")
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
            allowedContentTypes: [markdownFileType],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    window.reset()
                    workspace.switchWorkspace()
                    workspace.setWorkspaceFromKeyFile(url)
                }
            case .failure(let error):
                workspace.error = error.localizedDescription
            }
        }
        #endif
    }
}
