import Testing
import Foundation
@testable import Hunch
import Editor

@Suite("BlockPool")
struct BlockPoolTests {
    private func makeWorkspace() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hunch-pool-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func attr(_ s: String) -> AttributedString { AttributedString(s) }

    // MARK: - Persistence

    @Test func firstSavePersistsTopLevelBlocks() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let pool = BlockPool(workspaceRoot: root)

        let blocks: [Block] = [
            .heading(level: .h1, text: attr("Title")),
            .paragraph(text: attr("Body."))
        ]
        try await pool.persist(page: "page.md", blocks: blocks)

        let entries = try await pool.enumerate(page: "page.md")
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.parentHash == nil })
    }

    @Test func nestedChildrenRecordTheirImmediateParent() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let pool = BlockPool(workspaceRoot: root)

        let child = Block.paragraph(text: attr("Body of toggle"))
        let toggle = Block.toggle(title: attr("Outer"), children: [child])
        try await pool.persist(page: "p.md", blocks: [toggle])

        let entries = try await pool.enumerate(page: "p.md")
        #expect(entries.count == 2)
        let toggleHash = BlockFingerprint.atomicHash(toggle)
        let childHash = BlockFingerprint.atomicHash(child)
        let toggleEntry = try #require(entries.first { $0.hash == toggleHash })
        let childEntry = try #require(entries.first { $0.hash == childHash })
        #expect(toggleEntry.parentHash == nil)
        #expect(childEntry.parentHash == toggleHash)
    }

    @Test func resaveOfSameContentWritesNoNewFiles() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let pool = BlockPool(workspaceRoot: root)

        let blocks: [Block] = [.paragraph(text: attr("steady"))]
        try await pool.persist(page: "p.md", blocks: blocks)
        let pageDir = root
            .appendingPathComponent(BlockPool.directoryName, isDirectory: true)
            .appendingPathComponent("p.md", isDirectory: true)
        let firstURL = try #require(
            FileManager.default.contentsOfDirectory(atPath: pageDir.path).first
        )
        let firstFullURL = pageDir.appendingPathComponent(firstURL)
        let mtime1 = try firstFullURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        // Pause so mtime advances on touch.
        try await Task.sleep(for: .milliseconds(50))
        try await pool.persist(page: "p.md", blocks: blocks)
        let names = try FileManager.default.contentsOfDirectory(atPath: pageDir.path)
        #expect(names.count == 1, "no new pool file on identical re-save")
        let mtime2 = try firstFullURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        #expect(mtime2 != nil)
        if let m1 = mtime1, let m2 = mtime2 {
            #expect(m2 > m1, "touch advances mtime on re-save")
        }
    }

    @Test func editingOneBlockProducesOneNewPoolFile() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let pool = BlockPool(workspaceRoot: root)

        let v1: [Block] = [
            .paragraph(text: attr("alpha")),
            .paragraph(text: attr("beta"))
        ]
        try await pool.persist(page: "p.md", blocks: v1)
        let v2: [Block] = [
            .paragraph(text: attr("alpha")),
            .paragraph(text: attr("beta-edited"))
        ]
        try await pool.persist(page: "p.md", blocks: v2)

        let entries = try await pool.enumerate(page: "p.md")
        #expect(entries.count == 3, "alpha + old beta + new beta-edited")
    }

    // MARK: - Recovery flow via Clamshell

    @MainActor
    @Test func deletedBlockSurfacesAsLost() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)

        let url = root.appendingPathComponent("p.md")
        let v1 = [
            Block.paragraph(text: attr("Keep")),
            Block.paragraph(text: attr("Lose"))
        ]
        let doc1 = Document(url: url, title: "p", children: v1, modificationDate: nil)
        try clamshell.writeImmediately(doc1)

        // Pool work is fired off as a Task — wait for it to settle.
        try await Task.sleep(for: .milliseconds(50))

        // Now save a doc without "Lose" — the block becomes orphaned.
        let v2 = [Block.paragraph(text: attr("Keep"))]
        let doc2 = Document(url: url, title: "p", children: v2, modificationDate: nil)
        try clamshell.writeImmediately(doc2)
        try await Task.sleep(for: .milliseconds(50))

        let lost = try await clamshell.listLostBlocks(filter: .page(relativePath: "p.md"))
        #expect(lost.count == 1)
        #expect(lost.first?.markdown.contains("Lose") == true)
    }

    @MainActor
    @Test func restoringRecreatedBlockClearsItFromLost() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)
        let url = root.appendingPathComponent("p.md")

        try clamshell.writeImmediately(Document(
            url: url, title: "p",
            children: [Block.paragraph(text: attr("ghost"))],
            modificationDate: nil
        ))
        try await Task.sleep(for: .milliseconds(50))
        try clamshell.writeImmediately(Document(
            url: url, title: "p",
            children: [],
            modificationDate: nil
        ))
        try await Task.sleep(for: .milliseconds(50))
        var lost = try await clamshell.listLostBlocks(filter: .page(relativePath: "p.md"))
        #expect(lost.count == 1)

        // Re-create the same content; it should re-enter the live set and stop showing as lost.
        try clamshell.writeImmediately(Document(
            url: url, title: "p",
            children: [Block.paragraph(text: attr("ghost"))],
            modificationDate: nil
        ))
        try await Task.sleep(for: .milliseconds(50))
        lost = try await clamshell.listLostBlocks(filter: .page(relativePath: "p.md"))
        #expect(lost.isEmpty)
    }

    @MainActor
    @Test func deletedChildOfToggleRecordsToggleAsParent() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)
        let url = root.appendingPathComponent("p.md")

        let body = Block.paragraph(text: attr("inside"))
        let toggle = Block.toggle(title: attr("Outer"), children: [body])
        try clamshell.writeImmediately(Document(
            url: url, title: "p", children: [toggle], modificationDate: nil
        ))
        try await Task.sleep(for: .milliseconds(50))

        // Drop the toggle's body, keep the toggle.
        let emptyToggle = Block.toggle(title: attr("Outer"), children: [])
        try clamshell.writeImmediately(Document(
            url: url, title: "p", children: [emptyToggle], modificationDate: nil
        ))
        try await Task.sleep(for: .milliseconds(50))

        let lost = try await clamshell.listLostBlocks(filter: .page(relativePath: "p.md"))
        #expect(lost.count == 1)
        let toggleHash = BlockFingerprint.atomicHash(toggle)
        #expect(lost.first?.parentHash == toggleHash)
    }

    @MainActor
    @Test func trashingAPageMovesItsPoolDir() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)
        let url = root.appendingPathComponent("p.md")

        try clamshell.writeImmediately(Document(
            url: url, title: "p",
            children: [Block.paragraph(text: attr("alive"))],
            modificationDate: nil
        ))
        try await Task.sleep(for: .milliseconds(50))

        let livePoolDir = root
            .appendingPathComponent(BlockPool.directoryName)
            .appendingPathComponent("p.md")
        #expect(FileManager.default.fileExists(atPath: livePoolDir.path))

        _ = try clamshell.moveToTrash(at: url)
        try await Task.sleep(for: .milliseconds(50))

        let trashedPoolDir = root
            .appendingPathComponent(BlockPool.directoryName)
            .appendingPathComponent("Trash/p.md")
        #expect(FileManager.default.fileExists(atPath: trashedPoolDir.path))
        #expect(!FileManager.default.fileExists(atPath: livePoolDir.path))
    }

    @MainActor
    @Test func clamshellInitDeletesLegacyHistoryDir() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        // Plant a fake `.history/` left over from an older build.
        let history = root.appendingPathComponent(".history")
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        try "stale".write(
            to: history.appendingPathComponent("p.md.jsonl"),
            atomically: true, encoding: .utf8
        )
        #expect(FileManager.default.fileExists(atPath: history.path))

        _ = Clamshell(root: root)
        #expect(!FileManager.default.fileExists(atPath: history.path))
    }
}
