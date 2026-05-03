import Testing
import Foundation
@testable import Hunch
import Editor

@Suite("TrashStore")
struct TrashStoreTests {
    private func makeWorkspace() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hunch-trash-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func setHiddenRecursively(at root: URL) throws {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        for var child in children {
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                try setHiddenRecursively(at: child)
            }
            var values = URLResourceValues()
            values.isHidden = true
            try child.setResourceValues(values)
        }
    }

    @Test func listEntriesIncludesPageTrash() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        try "# Old".write(to: root.appendingPathComponent("doomed.md"), atomically: true, encoding: .utf8)
        let fileStore = FileStore()
        _ = try fileStore.moveToTrash(relativePath: "doomed.md", workspaceRoot: root)

        let store = TrashStore(workspaceRoot: root)
        let entries = try await store.listEntries()
        #expect(entries.contains { $0.sourcePath == "doomed.md" })
    }

    @Test func restorePageMovesFileBack() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let original = root.appendingPathComponent("notes.md")
        try "# Notes".write(to: original, atomically: true, encoding: .utf8)
        let fileStore = FileStore()
        _ = try fileStore.moveToTrash(relativePath: "notes.md", workspaceRoot: root)
        #expect(!FileManager.default.fileExists(atPath: original.path))

        let store = TrashStore(workspaceRoot: root)
        let entries = try await store.listEntries()
        let entry = try #require(entries.first)
        let restored = try await store.restorePage(entry)
        #expect(FileManager.default.fileExists(atPath: restored.path))
    }

    @Test func listEntriesIncludesHiddenFiles() async throws {
        // Repro for iCloud-synced Documents: files inside `Trash/` get
        // UF_HIDDEN inherited from the dotfile parent, so the listing must not
        // pass `.skipsHiddenFiles`.
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        try "# Old".write(to: root.appendingPathComponent("doomed.md"), atomically: true, encoding: .utf8)
        let fileStore = FileStore()
        _ = try fileStore.moveToTrash(relativePath: "doomed.md", workspaceRoot: root)

        try setHiddenRecursively(at: root.appendingPathComponent(FileStore.trashDirectoryName, isDirectory: true))

        let store = TrashStore(workspaceRoot: root)
        let entries = try await store.listEntries()
        #expect(entries.contains { $0.sourcePath == "doomed.md" })
    }
}
