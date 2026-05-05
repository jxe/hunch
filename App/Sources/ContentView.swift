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
    @State private var pageSearchText = ""
    /// Sidebar's keyboard cursor (visual highlight). Mirrors the currently-open
    /// page when no arrow nav has happened; arrow keys move it independently
    /// of the navstack. Activation (click or Return) calls `window.open` and
    /// the sidebar re-syncs on the next path change.
    @State private var sidebarCursor: MentionItem.ID?
    /// Same idea for the square.stack sheet.
    @State private var pageListSheetCursor: MentionItem.ID?

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
                .onChange(of: window.path, initial: true) { _, newPath in
                    window.handlePathChange()
                    // Keep the sidebar's keyboard cursor pinned to whatever's
                    // currently navigated. Without this, arrow keys would resume
                    // from a stale highlight after the user clicked a row.
                    sidebarCursor = newPath.first.flatMap { url in
                        workspace.entries.first(where: { $0.url == url })?.relativePath
                    }
                }
                .sheet(isPresented: $window.showPageList) {
                    pageListSheet
                }
                .sheet(item: $window.moveRequest) { _ in
                    PagePickerSheet(
                        title: "Move to…",
                        workspace: workspace,
                        excluding: window.openDocument?.url,
                        onPick: { item in window.resolveMoveRequest(with: item.id) },
                        onCancel: { window.resolveMoveRequest(with: nil) }
                    )
                }
                .sheet(isPresented: $window.showJumpTo) {
                    PagePickerSheet(
                        title: "Jump to Page…",
                        workspace: workspace,
                        excluding: window.openDocument?.url,
                        onPick: { item in
                            window.jumpTo(item.id)
                            window.showJumpTo = false
                        },
                        onCancel: { window.showJumpTo = false }
                    )
                }
                .sheet(item: $window.recoveryFilter) { filter in
                    RecoveryView(
                        filter: filter,
                        loadEntries: { filter in await workspace.listRecoverableEntries(filter: filter) },
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
    /// the page-list sidebar otherwise (fresh workspace, no home picked yet).
    @ViewBuilder
    private var rootView: some View {
        if let homeURL = workspace.homeURL {
            if let document = window.documentForPage(url: homeURL) {
                EditorPage(
                    url: homeURL,
                    document: document,
                    workspace: workspace,
                    window: window,
                    onShowPageList: { window.showPageList = true }
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(NotionStyle.background)
            }
        } else {
            sidebar
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { workspace.error != nil },
            set: { newValue in if !newValue { workspace.error = nil } }
        )
    }

    /// Activate a row from any page-picker surface: navigate to the page and,
    /// when called from a sheet (`dismissSheet: true`), close it.
    private func activate(_ item: MentionItem, dismissSheet: Bool) {
        guard let entry = workspace.entries.first(where: { $0.relativePath == item.id }) else { return }
        window.open(entry)
        if dismissSheet { window.showPageList = false }
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

    /// Page-list sheet shown from the home toolbar icon. Mirrors the sidebar's
    /// content (PagePickerView + Recently Deleted) but in a modal context.
    private var pageListSheet: some View {
        NavigationStack {
            PagePickerView(
                items: workspace.pages(matching: pageSearchText, excluding: nil),
                selection: $pageListSheetCursor,
                onActivate: { item in activate(item, dismissSheet: true) },
                onSetHome: setHome,
                onMoveToTrash: moveToTrash
            )
            .navigationTitle("Pages")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $pageSearchText, placement: .automatic, prompt: "Search pages")
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        window.showPageList = false
                        window.recoveryFilter = .all
                    } label: {
                        Label("Recover", systemImage: "clock.arrow.circlepath")
                    }
                    .help("Recently Deleted")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { window.showPageList = false }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 480)
        #endif
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Pages")
                .font(NotionStyle.body(size: 13, weight: .semibold))
                .foregroundStyle(NotionStyle.mutedForeground)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            PagePickerView(
                items: workspace.pages(matching: pageSearchText, excluding: nil),
                selection: $sidebarCursor,
                onActivate: { item in activate(item, dismissSheet: false) },
                onSetHome: setHome,
                onMoveToTrash: moveToTrash
            )
            Divider()
            Button {
                window.recoveryFilter = .all
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 11))
                    Text("Recover")
                        .font(NotionStyle.body(size: 12))
                    Spacer()
                }
                .foregroundStyle(NotionStyle.mutedForeground)
                .contentShape(Rectangle())
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        }
        .navigationTitle(workspace.workspaceURL?.lastPathComponent ?? "Workspace")
        .searchable(text: $pageSearchText, placement: .automatic, prompt: "Search pages")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
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
    /// Non-nil only for the home root: adds a toolbar button that surfaces
    /// the page-list sheet. Subpages get `nil` and don't show the icon.
    var onShowPageList: (() -> Void)? = nil

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
            linkPreviewProvider: workspace.linkPreviewService.provider()
        )
        .toolbar {
            if let onShowPageList {
                ToolbarItem(placement: .navigation) {
                    Button(action: onShowPageList) {
                        Image(systemName: "square.stack")
                    }
                    .accessibilityLabel("Show Page List")
                }
            }
            #if os(iOS)
            ToolbarItem(placement: .primaryAction) {
                Button {
                    undoController?.undoManager.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .accessibilityLabel("Undo")
                .disabled(!(undoController?.undoManager.canUndo ?? false))
                .contextMenu {
                    Button {
                        window.recoveryFilter = .page(relativePath: workspace.relativePath(of: url))
                    } label: {
                        Label("Recover lost blocks…", systemImage: "clock.arrow.circlepath")
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
            #else
            // macOS keeps the clock toolbar icon — there's no toolbar Undo to long-press.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    window.recoveryFilter = .page(relativePath: workspace.relativePath(of: url))
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .accessibilityLabel("Recover")
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

/// Sheet shell shared by the move-to and jump-to flows. Owns its own search
/// query so each presentation starts fresh. The currently-open document is
/// always excluded — both flows are about navigating somewhere else.
private struct PagePickerSheet: View {
    let title: String
    let workspace: Workspace
    let excluding: URL?
    let onPick: (MentionItem) -> Void
    let onCancel: () -> Void

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
                onActivate: { item in onPick(item) }
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
                    Button("Cancel", action: onCancel)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 480)
        #endif
    }
}
