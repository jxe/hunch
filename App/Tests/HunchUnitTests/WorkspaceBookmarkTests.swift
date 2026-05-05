import Testing
import Foundation
@testable import Hunch
import Editor

@Suite("Workspace bookmark")
struct WorkspaceBookmarkTests {
    @Test func resolveReturnsTheSavedURL() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("console-bookmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            WorkspaceBookmark.clear()
            try? FileManager.default.removeItem(at: dir)
        }

        WorkspaceBookmark.clear()
        try WorkspaceBookmark.save(url: dir)

        let restored = WorkspaceBookmark.resolve()
        #expect(restored?.standardizedFileURL == dir.standardizedFileURL)
        restored?.stopAccessingSecurityScopedResource()
    }
}
