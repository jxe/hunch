import Testing
import Foundation
@testable import Core

@Suite("FileStore")
struct FileStoreTests {
    @Test func writeReadRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("console-test-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = FileStore()
        let source = "# Title\n\nA paragraph.\n\n- one\n- two\n"
        try store.write(source, to: tmp)

        let doc = try store.loadDocument(at: tmp)
        #expect(doc.title == "Title")
        #expect(doc.blocks.count == 4)  // heading, paragraph, bullet, bullet
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
}
