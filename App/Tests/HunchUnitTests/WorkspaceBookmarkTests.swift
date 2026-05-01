import Testing
import Foundation
@testable import Hunch
import Editor

@Suite("Workspace bookmark")
struct WorkspaceBookmarkTests {
    @Test func resolveRestoresHomeRelativePath() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("console-bookmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            WorkspaceBookmark.clear()
            try? FileManager.default.removeItem(at: dir)
        }

        WorkspaceBookmark.clear()
        try WorkspaceBookmark.save(url: dir, homeRelativePath: "home.md")

        let restored = WorkspaceBookmark.resolve()
        #expect(restored?.url.standardizedFileURL == dir.standardizedFileURL)
        #expect(restored?.homeRelativePath == "home.md")
        restored?.url.stopAccessingSecurityScopedResource()
    }
}
