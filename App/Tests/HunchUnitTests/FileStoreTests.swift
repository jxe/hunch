import Testing
import Foundation
@testable import Hunch
import Editor

@Suite("FileStore")
struct FileStoreTests {
    @Test @MainActor func loadDocumentTitleUsesFirstH1WithFilenameFallback() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("console-title-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let titled = dir.appendingPathComponent("alpha.md")
        try "Intro\n\n# Project Alpha\n".write(to: titled, atomically: true, encoding: .utf8)
        #expect(try FileStore().loadDocumentTitle(at: titled) == "Project Alpha")

        let untitled = dir.appendingPathComponent("beta.md")
        try "Just text\n".write(to: untitled, atomically: true, encoding: .utf8)
        #expect(try FileStore().loadDocumentTitle(at: untitled) == "beta")
    }

    @Test func scanFindsMarkdownFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("console-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "# A".write(to: dir.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "ignored".write(to: dir.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let nested = dir.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "# B".write(to: nested.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)

        let entries = try FileStore().scan(workspaceRoot: dir)
        #expect(entries.count == 2)
        #expect(entries.contains { $0.relativePath == "a.md" })
        #expect(entries.contains { $0.relativePath == "nested/b.md" })
    }

    @Test func scanSkipsAssets() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("console-assets-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "# Page".write(to: dir.appendingPathComponent("page.md"), atomically: true, encoding: .utf8)
        let assets = dir.appendingPathComponent(FileStore.assetsDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: assets.appendingPathComponent("foo.png"))
        // A stray .md file accidentally placed inside Assets/ should also be skipped —
        // the folder is reserved for image bytes, not pages.
        try "# Stray".write(to: assets.appendingPathComponent("stray.md"), atomically: true, encoding: .utf8)

        let entries = try FileStore().scan(workspaceRoot: dir)
        #expect(entries.map(\.relativePath) == ["page.md"])
    }

    @Test func scanSkipsWorkspaceTrash() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("console-trash-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "# Keep".write(to: dir.appendingPathComponent("keep.md"), atomically: true, encoding: .utf8)
        let trash = dir.appendingPathComponent(FileStore.trashDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try "# Gone".write(to: trash.appendingPathComponent("gone.md"), atomically: true, encoding: .utf8)

        let entries = try FileStore().scan(workspaceRoot: dir)
        #expect(entries.map(\.relativePath) == ["keep.md"])
    }

    @Test func moveToTrashPreservesRelativePathAndUniquesCollisions() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("console-trash-move-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let nested = dir.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "# One".write(to: nested.appendingPathComponent("page.md"), atomically: true, encoding: .utf8)
        let existingTrash = dir
            .appendingPathComponent(FileStore.trashDirectoryName, isDirectory: true)
            .appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: existingTrash, withIntermediateDirectories: true)
        try "# Old".write(to: existingTrash.appendingPathComponent("page.md"), atomically: true, encoding: .utf8)

        let trashedPath = try FileStore().moveToTrash(relativePath: "nested/page.md", workspaceRoot: dir)

        #expect(trashedPath == "\(FileStore.trashDirectoryName)/nested/page-2.md")
        #expect(!FileManager.default.fileExists(atPath: nested.appendingPathComponent("page.md").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(trashedPath).path))
    }
}
