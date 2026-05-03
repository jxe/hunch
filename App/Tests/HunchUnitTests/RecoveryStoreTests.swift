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

    @Test func recordEditsCapturesDisappearedBlock() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(workspaceRoot: root)

        let prev = "# Title\n\nGold prose.\n\nFiller.\n"
        let next = "# Title\n\nReplacement prose.\n\nFiller.\n"
        try await store.recordEdits(relativePath: "page.md", previousText: prev, newText: next)

        let entries = try await store.list(filter: .page(relativePath: "page.md"))
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.record.cause == .edited)
        #expect(entry.record.markdown.contains("Gold prose"))
    }

    @Test func fingerprintDedupSuppressesIdenticalRereappearance() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(workspaceRoot: root)

        let v1 = "Gold.\n\nFiller.\n"
        let v2 = "Filler.\n"
        let v3 = "Gold.\n\nFiller.\n"
        let v4 = "Filler.\n"

        try await store.recordEdits(relativePath: "p.md", previousText: v1, newText: v2)
        try await store.recordEdits(relativePath: "p.md", previousText: v3, newText: v4)

        let entries = try await store.list(filter: .page(relativePath: "p.md"))
        #expect(entries.count == 1, "second record with identical fingerprint should be deduped")
    }

    @Test func distinctEditedVersionsBothShowUp() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(workspaceRoot: root)

        // V1: "A" → V2: "A'", recording A as lost.
        try await store.recordEdits(
            relativePath: "p.md",
            previousText: "A.\n",
            newText: "A prime.\n"
        )
        // Then V2: "A'" → V3: "A''", recording A' as lost. Distinct fingerprint.
        try await store.recordEdits(
            relativePath: "p.md",
            previousText: "A prime.\n",
            newText: "A double prime.\n"
        )

        let entries = try await store.list(filter: .page(relativePath: "p.md"))
        #expect(entries.count == 2)
    }

    @Test func recordDeletionEmitsDeletedCause() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(workspaceRoot: root)

        let blocks: [Block] = [
            .heading(level: 1, text: AttributedString("Top"), indent: 0),
            .paragraph(text: AttributedString("Stay"), indent: 0),
            .paragraph(text: AttributedString("Goes away"), indent: 0)
        ]
        try await store.recordDeletion(
            relativePath: "p.md",
            previousBlocks: blocks,
            removedIndices: [2]
        )
        let entries = try await store.list(filter: .page(relativePath: "p.md"))
        #expect(entries.count == 1)
        #expect(entries.first?.record.cause == .deleted)
        #expect(entries.first?.record.markdown.contains("Goes away") == true)
    }

    @Test func anchorPointsAtNearestSurvivingPredecessor() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(workspaceRoot: root)

        let prev = "# Top\n\nBefore.\n\nGoes away.\n\nAfter.\n"
        let next = "# Top\n\nBefore.\n\nAfter.\n"
        try await store.recordEdits(relativePath: "p.md", previousText: prev, newText: next)

        let entries = try await store.list(filter: .page(relativePath: "p.md"))
        let lost = try #require(entries.first)
        // Anchor should be the fingerprint of "Before." paragraph in the new text.
        let beforeBlock = BlockParser.parse("Before.\n").first!
        let expectedAnchor = BlockFingerprint.compute(beforeBlock)
        #expect(lost.record.anchorFingerprint == expectedAnchor)
    }

    @Test func purgeRemovesEntry() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(workspaceRoot: root)

        try await store.recordEdits(
            relativePath: "p.md",
            previousText: "Gold.\n",
            newText: "Different.\n"
        )
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
        try await store.recordEdits(
            relativePath: "p.md",
            previousText: "First.\n",
            newText: "Replacement.\n"
        )

        // Hand-write a sibling conflict file with a different record.
        let canonical = root.appendingPathComponent(".history/p.md.jsonl")
        let sibling = root.appendingPathComponent(".history/p.md.jsonl 2")
        let extra = LostBlockRecord(
            source: "p.md",
            recordedAt: Date(),
            cause: .edited,
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

        // Simulate the autotransform sequence: user types "# " (paragraph) then
        // types real heading text. The intermediate paragraph "# " disappears.
        let prev = "# \n\nbody.\n"
        let next = "# Heading\n\nbody.\n"
        try await store.recordEdits(relativePath: "p.md", previousText: prev, newText: next)

        let entries = try await store.list(filter: .page(relativePath: "p.md"))
        // The paragraph "#" (after trim) is residue → no record. The heading
        // "Heading" is new in `next` → also no record. So zero entries.
        #expect(entries.isEmpty, "transient `# ` paragraph should not be recorded")
    }

    @Test func listAllSurfacesAcrossPages() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(workspaceRoot: root)

        try await store.recordEdits(relativePath: "a.md", previousText: "A1.\n", newText: "A2.\n")
        try await store.recordEdits(relativePath: "b.md", previousText: "B1.\n", newText: "B2.\n")

        let all = try await store.list(filter: .all)
        #expect(all.count == 2)
        let sources = Set(all.map { $0.record.source })
        #expect(sources == ["a.md", "b.md"])
    }
}
