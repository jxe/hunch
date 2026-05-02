import Testing
import Foundation
@testable import Hunch
import Editor

@Suite("HistoryStore")
struct HistoryStoreTests {
    private func makeWorkspace() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hunch-history-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func snapshotsAreWrittenAndListed() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = HistoryStore(workspaceRoot: root)
        try await store.snapshotIfNeeded(relativePath: "page.md", contents: "# Hello\n")

        let snapshots = try await store.listSnapshots(for: "page.md")
        #expect(snapshots.count == 1)
        #expect(try await store.loadSnapshot(snapshots[0]) == "# Hello\n")
    }

    @Test func snapshotsAreDebouncedByMinInterval() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = HistoryStore(workspaceRoot: root)
        // First snapshot lands.
        try await store.snapshotIfNeeded(
            relativePath: "page.md",
            contents: "v1",
            minInterval: 60
        )
        // Second arrives within minInterval — should be skipped even with new content.
        try await store.snapshotIfNeeded(
            relativePath: "page.md",
            contents: "v2",
            minInterval: 60
        )
        let snapshots = try await store.listSnapshots(for: "page.md")
        #expect(snapshots.count == 1)
    }

    @Test func snapshotsAreCreatedAfterMinIntervalElapses() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = HistoryStore(workspaceRoot: root)
        let earlier = Date().addingTimeInterval(-120)
        try await store.snapshotIfNeeded(
            relativePath: "page.md",
            contents: "v1",
            minInterval: 60,
            date: earlier
        )
        try await store.snapshotIfNeeded(
            relativePath: "page.md",
            contents: "v2",
            minInterval: 60,
            date: Date()
        )
        let snapshots = try await store.listSnapshots(for: "page.md")
        #expect(snapshots.count == 2)
    }

    @Test func snapshotsAreSkippedWhenContentMatchesLatest() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = HistoryStore(workspaceRoot: root)
        let earlier = Date().addingTimeInterval(-120)
        try await store.snapshotIfNeeded(
            relativePath: "page.md",
            contents: "same",
            minInterval: 60,
            date: earlier
        )
        try await store.snapshotIfNeeded(
            relativePath: "page.md",
            contents: "same",
            minInterval: 60,
            date: Date()
        )
        let snapshots = try await store.listSnapshots(for: "page.md")
        #expect(snapshots.count == 1)
    }

    @Test func snapshotsListWhenFilesAreHidden() async throws {
        // Repro for iCloud-synced Documents: files inside `.history/<rel>/` get
        // UF_HIDDEN inherited from the dotfile parent, so the listing must not
        // pass `.skipsHiddenFiles`.
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = HistoryStore(workspaceRoot: root)
        try await store.snapshotIfNeeded(relativePath: "page.md", contents: "v1")

        let snapshotsDir = root.appendingPathComponent(".history/page.md", isDirectory: true)
        for url in try FileManager.default.contentsOfDirectory(at: snapshotsDir, includingPropertiesForKeys: nil) {
            var copy = url
            var values = URLResourceValues()
            values.isHidden = true
            try copy.setResourceValues(values)
        }

        let listed = try await store.listSnapshots(for: "page.md")
        #expect(listed.count == 1)

        // And debounce/identical-content checks must still see the latest snapshot.
        try await store.snapshotIfNeeded(relativePath: "page.md", contents: "v1", minInterval: 60)
        #expect(try await store.listSnapshots(for: "page.md").count == 1)
    }

    @Test func fileStoreScanSkipsHistoryDirectory() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        try "# Keep".write(to: root.appendingPathComponent("keep.md"), atomically: true, encoding: .utf8)
        let store = HistoryStore(workspaceRoot: root)
        try await store.snapshotIfNeeded(relativePath: "keep.md", contents: "# Keep older\n")

        let entries = try FileStore().scan(workspaceRoot: root)
        #expect(entries.map(\.relativePath) == ["keep.md"])
    }
}
