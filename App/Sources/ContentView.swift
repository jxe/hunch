import SwiftUI
import Core
import UI
import UniformTypeIdentifiers

@MainActor
@Observable
final class WorkspaceModel {
    var workspaceURL: URL?
    var entries: [WorkspaceEntry] = []
    var openDocument: Document?
    var error: String?

    private let store = FileStore()
    private let saver = DocumentSaveCoordinator()
    private var debounceTask: Task<Void, Never>?
    private var backstopTask: Task<Void, Never>?
    private var filePresenter: DocumentFilePresenter?
    private var isDirty = false
    private var isSaving = false

    func tryRestore() {
        if let url = WorkspaceBookmark.resolve() {
            workspaceURL = url
            rescan()
            if let lastPath = UserDefaults.standard.string(forKey: "console.lastOpenPage"),
               let entry = entries.first(where: { $0.relativePath == lastPath }) {
                open(entry)
            }
        }
    }

    func setWorkspace(_ url: URL) {
        do {
            try WorkspaceBookmark.save(url: url)
            workspaceURL = url
            rescan()
        } catch {
            self.error = "Failed to save workspace bookmark: \(error.localizedDescription)"
        }
    }

    /// Drop the currently bookmarked workspace and current open doc. The picker UI
    /// reappears because `workspaceURL` is now nil.
    func switchWorkspace() {
        flushAndClose()
        WorkspaceBookmark.clear()
        UserDefaults.standard.removeObject(forKey: "console.lastOpenPage")
        workspaceURL = nil
        entries = []
        openDocument = nil
    }

    func rescan() {
        guard let workspaceURL else { return }
        do {
            entries = try store.scan(workspaceRoot: workspaceURL)
        } catch {
            self.error = "Failed to scan workspace: \(error.localizedDescription)"
        }
    }

    func open(_ entry: WorkspaceEntry) {
        flushAndClose()
        do {
            openDocument = try store.loadDocument(at: entry.url)
            UserDefaults.standard.set(entry.relativePath, forKey: "console.lastOpenPage")
            isDirty = false
            installFilePresenter(for: entry.url)
            startBackstop()
        } catch {
            self.error = "Failed to load \(entry.relativePath): \(error.localizedDescription)"
        }
    }

    func openSubpage(relativePath: String) {
        guard let workspaceURL else { return }
        flushAndClose()
        let target = workspaceURL.appendingPathComponent(relativePath)
        do {
            openDocument = try store.loadDocument(at: target)
            isDirty = false
            installFilePresenter(for: target)
            startBackstop()
        } catch {
            self.error = "Subpage \(relativePath) not found"
        }
    }

    func closeDocument() {
        flushAndClose()
        removeFilePresenter()
        openDocument = nil
    }

    func markEdited() {
        isDirty = true
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self?.saveNow()
        }
    }

    func saveNow() async {
        debounceTask?.cancel()
        debounceTask = nil
        guard isDirty, let doc = openDocument else { return }
        do {
            isSaving = true
            defer { isSaving = false }
            try await saver.save(doc)
            if openDocument?.url == doc.url {
                openDocument?.modificationDate = modificationDate(for: doc.url)
            }
            isDirty = false
            rescan()
        } catch {
            self.error = "Save failed: \(error.localizedDescription)"
        }
    }

    func flushAndClose() {
        debounceTask?.cancel()
        debounceTask = nil
        backstopTask?.cancel()
        backstopTask = nil
        removeFilePresenter()
        guard let doc = openDocument else { return }
        Task { [saver, doc] in
            try? await saver.flush(url: doc.url)
        }
    }

    private func installFilePresenter(for url: URL) {
        removeFilePresenter()
        let presenter = DocumentFilePresenter(url: url) { [weak self] in
            Task { @MainActor in
                await self?.handlePresentedFileChange()
            }
        }
        NSFileCoordinator.addFilePresenter(presenter)
        filePresenter = presenter
    }

    private func removeFilePresenter() {
        if let filePresenter {
            NSFileCoordinator.removeFilePresenter(filePresenter)
        }
        filePresenter = nil
    }

    private func handlePresentedFileChange() async {
        guard !isSaving, !isDirty, let doc = openDocument else { return }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled, !isSaving, !isDirty, openDocument?.url == doc.url else { return }

        let currentMTime = modificationDate(for: doc.url)
        if currentMTime == doc.modificationDate {
            rescan()
            return
        }

        do {
            openDocument = try store.loadDocument(at: doc.url)
            rescan()
        } catch {
            self.error = "Failed to reload external changes: \(error.localizedDescription)"
        }
    }

    private func modificationDate(for url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func startBackstop() {
        backstopTask?.cancel()
        backstopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await self?.saveNow()
            }
        }
    }
}

private final class DocumentFilePresenter: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue.main
    private let onChange: @Sendable () -> Void

    init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.presentedItemURL = url
        self.onChange = onChange
        super.init()
    }

    func presentedItemDidChange() {
        onChange()
    }

    func presentedItemDidMove(to newURL: URL) {
        onChange()
    }
}

struct ContentView: View {
    @Bindable var model: WorkspaceModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.workspaceURL == nil {
                WorkspacePickerView(model: model)
            } else if model.openDocument != nil {
                PageDetailContainer(model: model)
            } else {
                NavigationSplitView {
                    sidebar
                } detail: {
                    Text("Select a page")
                        .foregroundStyle(NotionStyle.mutedForeground)
                }
            }
        }
        .task { model.tryRestore() }
        .onChange(of: scenePhase) { _, new in
            if new != .active {
                Task { await model.saveNow() }
            }
        }
        .alert("Error", isPresented: errorBinding) {
            Button("OK") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.error != nil },
            set: { newValue in if !newValue { model.error = nil } }
        )
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Pages")
                .font(NotionStyle.body(size: 13).weight(.semibold))
                .foregroundStyle(NotionStyle.mutedForeground)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            PageListView(entries: model.entries) { entry in
                model.open(entry)
            }
        }
        .navigationTitle(model.workspaceURL?.lastPathComponent ?? "Workspace")
    }
}

private struct PageDetailContainer: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Pages")
                    .font(NotionStyle.body(size: 13).weight(.semibold))
                    .foregroundStyle(NotionStyle.mutedForeground)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                PageListView(entries: model.entries) { entry in
                    model.open(entry)
                }
            }
            .navigationTitle(model.workspaceURL?.lastPathComponent ?? "Workspace")
        } detail: {
            #if os(iOS)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button {
                        model.closeDocument()
                    } label: {
                        Image(systemName: "chevron.left")
                        Text("Pages")
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                pageContent
            }
            #else
            pageContent
            #endif
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        if model.openDocument != nil {
            PageView(
                document: Binding(
                    get: { model.openDocument ?? Document(url: URL(fileURLWithPath: "/dev/null"), title: "", blocks: []) },
                    set: { model.openDocument = $0 }
                ),
                onSubpageTap: { relativePath in
                    model.openSubpage(relativePath: relativePath)
                },
                onEdited: {
                    model.markEdited()
                },
                onBlur: {
                    Task { await model.saveNow() }
                },
                onPinchClose: {
                    model.closeDocument()
                }
            )
        }
    }
}

private struct WorkspacePickerView: View {
    let model: WorkspaceModel
    @State private var showingPicker = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 64))
                .foregroundStyle(NotionStyle.mutedForeground)
            Text("Choose a workspace folder")
                .font(NotionStyle.body(size: 18).weight(.semibold))
                .foregroundStyle(NotionStyle.foreground)
            Text("Pick a folder of .md files. Console will use it as the source of truth.")
                .font(NotionStyle.body(size: 14))
                .foregroundStyle(NotionStyle.mutedForeground)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Choose folder") {
                showingPicker = true
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NotionStyle.background)
        .fileImporter(
            isPresented: $showingPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    model.setWorkspace(url)
                }
            case .failure(let error):
                model.error = error.localizedDescription
            }
        }
    }
}
