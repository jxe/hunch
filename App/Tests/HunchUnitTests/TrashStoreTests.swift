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

    @Test func recordsAndListsBlockDeletion() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = TrashStore(workspaceRoot: root)
        let blocks: [Block] = [
            .heading(level: 2, text: AttributedString("Heading"), indent: 0),
            .paragraph(text: AttributedString("body line one"), indent: 0)
        ]
        try await store.recordBlockDeletion(
            source: "Notes/Project.md",
            indices: [3, 4],
            blocks: blocks,
            actionName: "Delete section"
        )

        let entries = try await store.listEntries()
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.isPageEntry == false)
        #expect(entry.sourcePath == "Notes/Project.md")
    }

    @Test func loadDeletedBlocksRoundTripsThroughMarkdown() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = TrashStore(workspaceRoot: root)
        let blocks: [Block] = [
            .bullet(text: AttributedString("alpha"), indent: 0),
            .bullet(text: AttributedString("beta"), indent: 0)
        ]
        try await store.recordBlockDeletion(
            source: "Page.md",
            indices: [0, 1],
            blocks: blocks,
            actionName: "Delete"
        )

        let entries = try await store.listEntries()
        let entry = try #require(entries.first)
        let payload = try await store.loadDeletedBlocks(entry)
        #expect(payload.indices == [0, 1])
        #expect(payload.source == "Page.md")
        #expect(payload.blocks.count == 2)
        #expect(String(payload.blocks[0].text.characters) == "alpha")
        #expect(String(payload.blocks[1].text.characters) == "beta")
    }

    @Test func listEntriesIncludesPageTrash() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        try "# Old".write(to: root.appendingPathComponent("doomed.md"), atomically: true, encoding: .utf8)
        let fileStore = FileStore()
        _ = try fileStore.moveToTrash(relativePath: "doomed.md", workspaceRoot: root)

        let store = TrashStore(workspaceRoot: root)
        let entries = try await store.listEntries()
        #expect(entries.contains { $0.isPageEntry && $0.sourcePath == "doomed.md" })
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
        let entry = try #require(entries.first { $0.isPageEntry })
        let restored = try await store.restorePage(entry)
        #expect(FileManager.default.fileExists(atPath: restored.path))
    }

    @Test func listEntriesIncludesHiddenFiles() async throws {
        // Repro for iCloud-synced Documents: files inside `.Trash/` get
        // UF_HIDDEN inherited from the dotfile parent, so the listing must not
        // pass `.skipsHiddenFiles`.
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        try "# Old".write(to: root.appendingPathComponent("doomed.md"), atomically: true, encoding: .utf8)
        let fileStore = FileStore()
        _ = try fileStore.moveToTrash(relativePath: "doomed.md", workspaceRoot: root)

        let store = TrashStore(workspaceRoot: root)
        try await store.recordBlockDeletion(
            source: "Page.md",
            indices: [0],
            blocks: [.paragraph(text: AttributedString("blk"), indent: 0)],
            actionName: "Delete"
        )

        try setHiddenRecursively(at: root.appendingPathComponent(".Trash", isDirectory: true))

        let entries = try await store.listEntries()
        #expect(entries.contains { $0.isPageEntry && $0.sourcePath == "doomed.md" })
        #expect(entries.contains { !$0.isPageEntry && $0.sourcePath == "Page.md" })
    }

    @Test func deleteRecordRemovesBlockEntryFile() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = TrashStore(workspaceRoot: root)
        try await store.recordBlockDeletion(
            source: "Page.md",
            indices: [0],
            blocks: [.paragraph(text: AttributedString("x"), indent: 0)],
            actionName: "Delete"
        )
        var entries = try await store.listEntries()
        try await store.deleteRecord(#require(entries.first))
        entries = try await store.listEntries()
        #expect(entries.isEmpty)
    }
}
