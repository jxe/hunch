import Testing
import Foundation
@testable import Hunch
import Editor

@Suite("RecoveryLog")
struct RecoveryLogTests {
    private func makeWorkspace() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hunch-log-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func attr(_ s: String) -> AttributedString { AttributedString(s) }

    private func deviceLogURL(workspace: URL, page rel: String, deviceID: String) -> URL {
        workspace
            .appendingPathComponent(RecoveryLog.directoryName, isDirectory: true)
            .appendingPathComponent(rel, isDirectory: true)
            .appendingPathComponent("\(deviceID).jsonl")
    }

    private func lineCount(at url: URL) -> Int {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    // MARK: - Persistence

    @Test func firstRecordAppendsOnePerAtomicBlock() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RecoveryLog(workspaceRoot: root, deviceID: "dev-A")

        let blocks: [Block] = [
            .heading(level: .h1, text: attr("Title")),
            .paragraph(text: attr("Body."))
        ]
        try await log.record(page: "page.md", blocks: blocks)

        let url = deviceLogURL(workspace: root, page: "page.md", deviceID: "dev-A")
        #expect(lineCount(at: url) == 2)
    }

    @Test func resaveOfSameContentAppendsZeroLines() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RecoveryLog(workspaceRoot: root, deviceID: "dev-A")

        let blocks: [Block] = [.paragraph(text: attr("steady"))]
        try await log.record(page: "p.md", blocks: blocks)
        try await log.record(page: "p.md", blocks: blocks)

        let url = deviceLogURL(workspace: root, page: "p.md", deviceID: "dev-A")
        #expect(lineCount(at: url) == 1, "no new line on identical re-save")
    }

    @Test func editingOneBlockAppendsOneLine() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RecoveryLog(workspaceRoot: root, deviceID: "dev-A")

        try await log.record(page: "p.md", blocks: [
            .paragraph(text: attr("alpha")),
            .paragraph(text: attr("beta"))
        ])
        try await log.record(page: "p.md", blocks: [
            .paragraph(text: attr("alpha")),
            .paragraph(text: attr("beta-edited"))
        ])

        let url = deviceLogURL(workspace: root, page: "p.md", deviceID: "dev-A")
        #expect(lineCount(at: url) == 3, "alpha + beta + beta-edited")
    }

    @Test func nestedChildrenRecordTheirImmediateParent() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RecoveryLog(workspaceRoot: root, deviceID: "dev-A")

        let child = Block.paragraph(text: attr("Body of toggle"))
        let toggle = Block.toggle(title: attr("Outer"), children: [child])
        try await log.record(page: "p.md", blocks: [toggle])

        // Both blocks are still alive, so listLostBlocks returns nothing.
        // To assert the parent header was written, we check the file contents.
        let url = deviceLogURL(workspace: root, page: "p.md", deviceID: "dev-A")
        let text = try String(contentsOf: url, encoding: .utf8)
        let toggleHash = BlockFingerprint.atomicHash(toggle)
        let childHash = BlockFingerprint.atomicHash(child)
        #expect(text.contains("\"h\":\"\(toggleHash)\""))
        #expect(text.contains("\"h\":\"\(childHash)\""))
        #expect(text.contains("\"p\":\"\(toggleHash)\""))   // child's parent is toggle
    }

    // MARK: - Recovery via Clamshell

    @MainActor
    @Test func deletedBlockSurfacesAsLost() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)
        let url = root.appendingPathComponent("p.md")

        try clamshell.writeImmediately(Document(
            url: url, title: "p",
            children: [
                Block.paragraph(text: attr("Keep")),
                Block.paragraph(text: attr("Lose"))
            ],
            modificationDate: nil
        ))
        try await Task.sleep(for: .milliseconds(80))

        try clamshell.writeImmediately(Document(
            url: url, title: "p",
            children: [Block.paragraph(text: attr("Keep"))],
            modificationDate: nil
        ))
        try await Task.sleep(for: .milliseconds(80))

        let lost = await clamshell.listLostBlocks(filter: .page(relativePath: "p.md"))
        #expect(lost.count == 1)
        #expect(lost.first?.markdown.contains("Lose") == true)
    }

    @MainActor
    @Test func recreatedBlockClearsItFromLost() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)
        let url = root.appendingPathComponent("p.md")

        try clamshell.writeImmediately(Document(
            url: url, title: "p",
            children: [Block.paragraph(text: attr("ghost"))],
            modificationDate: nil
        ))
        try await Task.sleep(for: .milliseconds(80))
        try clamshell.writeImmediately(Document(
            url: url, title: "p", children: [], modificationDate: nil
        ))
        try await Task.sleep(for: .milliseconds(80))

        var lost = await clamshell.listLostBlocks(filter: .page(relativePath: "p.md"))
        #expect(lost.count == 1)

        try clamshell.writeImmediately(Document(
            url: url, title: "p",
            children: [Block.paragraph(text: attr("ghost"))],
            modificationDate: nil
        ))
        try await Task.sleep(for: .milliseconds(80))
        lost = await clamshell.listLostBlocks(filter: .page(relativePath: "p.md"))
        #expect(lost.isEmpty)
    }

    @MainActor
    @Test func deletedChildOfLiveToggleRecordsToggleAsParent() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)
        let url = root.appendingPathComponent("p.md")

        let body = Block.paragraph(text: attr("inside"))
        let toggle = Block.toggle(title: attr("Outer"), children: [body])
        try clamshell.writeImmediately(Document(
            url: url, title: "p", children: [toggle], modificationDate: nil
        ))
        try await Task.sleep(for: .milliseconds(80))

        try clamshell.writeImmediately(Document(
            url: url, title: "p",
            children: [Block.toggle(title: attr("Outer"), children: [])],
            modificationDate: nil
        ))
        try await Task.sleep(for: .milliseconds(80))

        let lost = await clamshell.listLostBlocks(filter: .page(relativePath: "p.md"))
        #expect(lost.count == 1)
        let toggleHash = BlockFingerprint.atomicHash(toggle)
        #expect(lost.first?.parentHash == toggleHash)
    }

    @MainActor
    @Test func purgeTombstoneSuppressesLostBlock() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)
        let url = root.appendingPathComponent("p.md")

        try clamshell.writeImmediately(Document(
            url: url, title: "p",
            children: [Block.paragraph(text: attr("ghost"))],
            modificationDate: nil
        ))
        try await Task.sleep(for: .milliseconds(80))
        try clamshell.writeImmediately(Document(
            url: url, title: "p", children: [], modificationDate: nil
        ))
        try await Task.sleep(for: .milliseconds(80))

        var lost = await clamshell.listLostBlocks(filter: .page(relativePath: "p.md"))
        let entry = try #require(lost.first)
        try await clamshell.purgeLostBlock(entry)
        lost = await clamshell.listLostBlocks(filter: .page(relativePath: "p.md"))
        #expect(lost.isEmpty, "purge tombstone should suppress entry")
    }

    @MainActor
    @Test func secondDeviceLogMergesIntoRecovery() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)
        let url = root.appendingPathComponent("p.md")

        // Plant an empty live page so the live-set check excludes nothing.
        try clamshell.writeImmediately(Document(
            url: url, title: "p", children: [], modificationDate: nil
        ))
        try await Task.sleep(for: .milliseconds(40))

        // Hand-write a foreign device's log entry.
        let foreignBlock = Block.paragraph(text: attr("from another device"))
        let h = BlockFingerprint.atomicHash(foreignBlock)
        let m = BlockSerializer.serializeAtomic(foreignBlock)
        let escaped = m
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let line = "{\"h\":\"\(h)\",\"m\":\"\(escaped)\",\"op\":\"add\",\"p\":null,\"t\":1714867200.0}\n"
        let foreignURL = deviceLogURL(workspace: root, page: "p.md", deviceID: "dev-B")
        try FileManager.default.createDirectory(
            at: foreignURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try line.write(to: foreignURL, atomically: true, encoding: .utf8)

        let lost = await clamshell.listLostBlocks(filter: .page(relativePath: "p.md"))
        #expect(lost.contains(where: { $0.hash == h }))
    }

    @MainActor
    @Test func trashingPageMovesHistoryDir() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)
        let url = root.appendingPathComponent("p.md")

        try clamshell.writeImmediately(Document(
            url: url, title: "p",
            children: [Block.paragraph(text: attr("alive"))],
            modificationDate: nil
        ))
        try await Task.sleep(for: .milliseconds(80))

        let liveHistoryDir = root
            .appendingPathComponent(RecoveryLog.directoryName)
            .appendingPathComponent("p.md")
        #expect(FileManager.default.fileExists(atPath: liveHistoryDir.path))

        _ = try clamshell.moveToTrash(at: url)
        try await Task.sleep(for: .milliseconds(80))

        let trashedHistoryDir = root
            .appendingPathComponent(RecoveryLog.directoryName)
            .appendingPathComponent("Trash/p.md")
        #expect(FileManager.default.fileExists(atPath: trashedHistoryDir.path))
        #expect(!FileManager.default.fileExists(atPath: liveHistoryDir.path))
    }

    @MainActor
    @Test func clamshellInitDeletesLegacyBlocksDir() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let blocks = root.appendingPathComponent(".blocks")
        try FileManager.default.createDirectory(at: blocks, withIntermediateDirectories: true)
        try "stale".write(
            to: blocks.appendingPathComponent("garbage.md"),
            atomically: true, encoding: .utf8
        )
        #expect(FileManager.default.fileExists(atPath: blocks.path))

        _ = Clamshell(root: root)
        #expect(!FileManager.default.fileExists(atPath: blocks.path))
    }
}
