import Testing
import Foundation
@testable import Hunch
import Editor

@Suite("RecoveryStore")
struct RecoveryStoreTests {
    private func makeWorkspace() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hunch-recovery-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func snapshotLogsEveryBlock() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(workspaceRoot: root)

        let text = "# Title\n\nGold prose.\n\nFiller.\n"
        try await store.recordSnapshot(relativePath: "page.md", currentText: text)

        // Live page doesn't exist on disk → no fingerprints filtered out → all 3 surface.
        let entries = try await store.list(filter: .page(relativePath: "page.md"))
        #expect(entries.count == 3)
        #expect(entries.allSatisfy { $0.record.cause == .seen })
        let bodies = entries.map(\.record.markdown).joined()
        #expect(bodies.contains("Title"))
        #expect(bodies.contains("Gold prose"))
        #expect(bodies.contains("Filler"))
    }

    @Test func liveBlocksAreFilteredFromListings() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(workspaceRoot: root)

        let v1 = "# Title\n\nGold prose.\n\nFiller.\n"
        try await store.recordSnapshot(relativePath: "page.md", currentText: v1)

        // Now the live page on disk has only Title + Filler — Gold prose was edited out.
        let v2 = "# Title\n\nFiller.\n"
        try v2.write(to: root.appendingPathComponent("page.md"), atomically: true, encoding: .utf8)

        let entries = try await store.list(filter: .page(relativePath: "page.md"))
        #expect(entries.count == 1)
        #expect(entries.first?.record.markdown.contains("Gold prose") == true)
    }

    @Test func successiveEditsAccumulateAllVersions() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(workspaceRoot: root)

        try await store.recordSnapshot(relativePath: "p.md", currentText: "A.\n")
        try await store.recordSnapshot(relativePath: "p.md", currentText: "A prime.\n")
        try await store.recordSnapshot(relativePath: "p.md", currentText: "A double prime.\n")

        // Live doc has only "A double prime." — the other two are recoverable.
        try "A double prime.\n".write(
            to: root.appendingPathComponent("p.md"),
            atomically: true,
            encoding: .utf8
        )

        let entries = try await store.list(filter: .page(relativePath: "p.md"))
        #expect(entries.count == 2)
    }

    @Test func snapshotIsIdempotent() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(workspaceRoot: root)

        let text = "Same.\n"
        try await store.recordSnapshot(relativePath: "p.md", currentText: text)
        try await store.recordSnapshot(relativePath: "p.md", currentText: text)

        let entries = try await store.list(filter: .page(relativePath: "p.md"))
        #expect(entries.count == 1, "duplicate snapshot of same content should be deduped")
    }

    @Test func recordDeletionSnapshotsPriorBlocks() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(workspaceRoot: root)

        let blocks: [Block] = [
            .heading(level: 1, text: AttributedString("Top"), indent: 0),
            .paragraph(text: AttributedString("Stay"), indent: 0),
            .paragraph(text: AttributedString("Goes away"), indent: 0)
        ]
        try await store.recordDeletion(relativePath: "p.md", previousBlocks: blocks)

        // Live page has only Top + Stay — "Goes away" surfaces in Recover.
        try "# Top\n\nStay\n".write(
            to: root.appendingPathComponent("p.md"),
            atomically: true,
            encoding: .utf8
        )

        let entries = try await store.list(filter: .page(relativePath: "p.md"))
        #expect(entries.count == 1)
        #expect(entries.first?.record.markdown.contains("Goes away") == true)
        #expect(entries.first?.record.cause == .seen)
    }

    @Test func anchorPointsAtImmediatePredecessor() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(workspaceRoot: root)

        let text = "# Top\n\nBefore.\n\nGoes away.\n\nAfter.\n"
        try await store.recordSnapshot(relativePath: "p.md", currentText: text)

        // Live page has everything except "Goes away." — that record surfaces.
        let live = "# Top\n\nBefore.\n\nAfter.\n"
        try live.write(to: root.appendingPathComponent("p.md"), atomically: true, encoding: .utf8)

        let entries = try await store.list(filter: .page(relativePath: "p.md"))
        let lost = try #require(entries.first)
        let beforeBlock = BlockParser.parse("Before.\n").first!
        let expectedAnchor = BlockFingerprint.compute(beforeBlock)
        #expect(lost.record.anchorFingerprint == expectedAnchor)
    }

    @Test func purgeRemovesEntry() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(workspaceRoot: root)

        try await store.recordSnapshot(relativePath: "p.md", currentText: "Gold.\n")
        var entries = try await store.list(filter: .page(relativePath: "p.md"))
        let entry = try #require(entries.first)
        try await store.purge(entry)
        entries = try await store.list(filter: .page(relativePath: "p.md"))
        #expect(entries.isEmpty)
    }

    @Test func icloudConflictSiblingIsMergedAndDeleted() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(workspaceRoot: root)

        // Seed canonical with one record.
        try await store.recordSnapshot(relativePath: "p.md", currentText: "First.\n")

        // Hand-write a sibling conflict file with a different record.
        let canonical = root.appendingPathComponent(".history/p.md.jsonl")
        let sibling = root.appendingPathComponent(".history/p.md.jsonl 2")
        let extra = LostBlockRecord(
            source: "p.md",
            recordedAt: Date(),
            cause: .seen,
            originalIndex: 0,
            anchorFingerprint: nil,
            fingerprint: "deadbeefdeadbeef",
            markdown: "Sibling-only block.\n\n"
        )
        let line = try LostBlockRecordCodec.encode(extra) + "\n"
        try line.write(to: sibling, atomically: true, encoding: .utf8)

        let entries = try await store.list(filter: .page(relativePath: "p.md"))
        // Original "First." record + sibling's "deadbeef" record.
        #expect(entries.count == 2)
        // Sibling file should be merged into canonical and deleted.
        #expect(!FileManager.default.fileExists(atPath: sibling.path))
        let canonicalContents = try String(contentsOf: canonical, encoding: .utf8)
        #expect(canonicalContents.contains("deadbeefdeadbeef"))
    }

    @Test func autotransformResidueIsNotRecorded() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(workspaceRoot: root)

        // Snapshot a doc that contains a transient `# ` paragraph alongside real content.
        let text = "# \n\nbody.\n"
        try await store.recordSnapshot(relativePath: "p.md", currentText: text)

        let entries = try await store.list(filter: .page(relativePath: "p.md"))
        // The empty heading-trigger paragraph is residue → not recorded.
        // Only "body." remains in the log.
        #expect(entries.count == 1)
        #expect(entries.first?.record.markdown.contains("body") == true)
    }

    @Test func listAllSurfacesAcrossPages() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(workspaceRoot: root)

        try await store.recordSnapshot(relativePath: "a.md", currentText: "A1.\n")
        try await store.recordSnapshot(relativePath: "b.md", currentText: "B1.\n")

        let all = try await store.list(filter: .all)
        #expect(all.count == 2)
        let sources = Set(all.map { $0.record.source })
        #expect(sources == ["a.md", "b.md"])
    }

    @Test func legacyRecordsRemainReadable() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(workspaceRoot: root)

        // Hand-write a log file with pre-on-entry-model records.
        let logURL = root.appendingPathComponent(".history/p.md.jsonl")
        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let edited = LostBlockRecord(
            source: "p.md",
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            cause: .edited,
            originalIndex: 0,
            anchorFingerprint: nil,
            fingerprint: "1111111111111111",
            markdown: "Edited-out block.\n\n"
        )
        let deleted = LostBlockRecord(
            source: "p.md",
            recordedAt: Date(timeIntervalSince1970: 1_700_000_001),
            cause: .deleted,
            originalIndex: 1,
            anchorFingerprint: nil,
            fingerprint: "2222222222222222",
            markdown: "Deleted block.\n\n"
        )
        let body =
            try LostBlockRecordCodec.encode(edited) + "\n" +
            (try LostBlockRecordCodec.encode(deleted)) + "\n"
        try body.write(to: logURL, atomically: true, encoding: .utf8)

        let entries = try await store.list(filter: .page(relativePath: "p.md"))
        #expect(entries.count == 2)
        let causes = Set(entries.map(\.record.cause))
        #expect(causes == [.edited, .deleted])
    }
}
