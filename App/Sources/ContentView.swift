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

    func rescan() {
        guard let workspaceURL else { return }
        do {
            entries = try store.scan(workspaceRoot: workspaceURL)
        } catch {
            self.error = "Failed to scan workspace: \(error.localizedDescription)"
        }
    }

    func open(_ entry: WorkspaceEntry) {
        do {
            openDocument = try store.loadDocument(at: entry.url)
            UserDefaults.standard.set(entry.relativePath, forKey: "console.lastOpenPage")
        } catch {
            self.error = "Failed to load \(entry.relativePath): \(error.localizedDescription)"
        }
    }

    func openSubpage(relativePath: String) {
        guard let workspaceURL else { return }
        let target = workspaceURL.appendingPathComponent(relativePath)
        do {
            openDocument = try store.loadDocument(at: target)
        } catch {
            self.error = "Subpage \(relativePath) not found"
        }
    }

    func closeDocument() {
        openDocument = nil
    }
}

struct ContentView: View {
    @State private var model = WorkspaceModel()

    var body: some View {
        Group {
            if model.workspaceURL == nil {
                WorkspacePickerView(model: model)
            } else if let document = model.openDocument {
                PageDetailContainer(model: model, document: document)
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
            HStack {
                Text("Pages")
                    .font(NotionStyle.body(size: 13).weight(.semibold))
                    .foregroundStyle(NotionStyle.mutedForeground)
                Spacer()
                Button {
                    model.rescan()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
            }
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
    let model: WorkspaceModel
    let document: Document

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Pages")
                        .font(NotionStyle.body(size: 13).weight(.semibold))
                        .foregroundStyle(NotionStyle.mutedForeground)
                    Spacer()
                    Button {
                        model.rescan()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                PageListView(entries: model.entries) { entry in
                    model.open(entry)
                }
            }
            .navigationTitle(model.workspaceURL?.lastPathComponent ?? "Workspace")
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    #if os(iOS)
                    Button {
                        model.closeDocument()
                    } label: {
                        Image(systemName: "chevron.left")
                        Text("Pages")
                    }
                    #endif
                    Text(document.title)
                        .font(NotionStyle.body(size: 16).weight(.semibold))
                        .foregroundStyle(NotionStyle.foreground)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                PageView(document: document) { relativePath in
                    model.openSubpage(relativePath: relativePath)
                }
            }
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
