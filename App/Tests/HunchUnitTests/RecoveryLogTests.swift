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

    private func counters(at url: URL) throws -> [UInt64] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line -> UInt64? in
            guard let data = String(line).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return (obj["c"] as? UInt64) ?? (obj["c"] as? Int).flatMap { UInt64(exactly: $0) }
        }
    }

    private func encodedWire(
        op: String,
        hash: String,
        parent: String? = nil,
        markdown: String? = nil,
        t: TimeInterval,
        counter: UInt64
    ) throws -> String {
        var object: [String: Any] = [
            "c": counter,
            "h": hash,
            "op": op,
            "t": t
        ]
        object["p"] = parent ?? NSNull()
        object["m"] = markdown ?? NSNull()
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    private func encodedLegacyWire(
        op: String,
        hash: String,
        parent: String? = nil,
        markdown: String? = nil,
        t: TimeInterval
    ) throws -> String {
        var object: [String: Any] = [
            "h": hash,
            "op": op,
            "t": t
        ]
        object["p"] = parent ?? NSNull()
        object["m"] = markdown ?? NSNull()
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    // MARK: - Persistence

    @MainActor
    @Test func literalPreRefactorJSONLFoldsAndRestoresWithoutHashDrift() throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = root
            .appendingPathComponent(RecoveryLog.directoryName, isDirectory: true)
            .appendingPathComponent("page.md", isDirectory: true)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        let fixtureURL = history.appendingPathComponent("old-device.jsonl")
        let fixture = "{\"op\":\"add\",\"h\":\"f22d3f2e0f58dfcb24fd8f482629178b6b45cf62695b1921085df4c79911a9ca\",\"p\":null,\"m\":\"Hello\",\"t\":1700000000}\n"
        try fixture.write(to: fixtureURL, atomically: true, encoding: .utf8)

        let log = RecoveryLog(workspaceRoot: root, deviceID: "current-device")
        let intent = PatchEngine.intent(from: log.readJournal(page: "page.md"))
        let expectedHash = "f22d3f2e0f58dfcb24fd8f482629178b6b45cf62695b1921085df4c79911a9ca"
        guard case .alive = intent.byHash[expectedHash] else {
            Issue.record("literal legacy add should fold as alive")
            return
        }

        let reconciliation = PatchEngine.reconcile(intent: intent, doc: [])
        let restored = Document(id: DocumentID("legacy-fixture"), children: [])
        PatchEngine.apply(reconciliation, to: restored)
        #expect(restored.children.count == 1)
        #expect(restored.children.first?.atomicHash == expectedHash)

        let serialized = BlockSerializer.serializeAtomic(try #require(restored.children.first))
        #expect(BlockParser.parse(serialized).first?.atomicHash == expectedHash)
    }

    @Test func firstRecordAppendsOnePerAtomicBlock() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RecoveryLog(workspaceRoot: root, deviceID: "dev-A")

        let blocks: [Block] = [
            .heading(level: .h1, text: attr("Title")),
            .paragraph(text: attr("Body."))
        ]
        try await log.apply(Patch.adds(from: blocks), to: "page.md")

        let url = deviceLogURL(workspace: root, page: "page.md", deviceID: "dev-A")
        #expect(lineCount(at: url) == 2)
    }

    /// Duplicate `add` records for the same hash collapse to one intent.
    /// The log may have N adds (no write-time dedup) but the union's
    /// latest-wins fold keeps the hash alive once — idempotence at the
    /// intent level.
    @Test func duplicateAddsCollapseToOneAliveIntent() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RecoveryLog(workspaceRoot: root, deviceID: "dev-A")

        let block = Block.paragraph(text: attr("steady"))
        try await log.apply(Patch.adds(from: [block]), to: "p.md")
        try await log.apply(Patch.adds(from: [block]), to: "p.md")
        try await log.apply(Patch.adds(from: [block]), to: "p.md")

        let journal = log.readJournal(page: "p.md")
        let intent = PatchEngine.intent(from: journal)
        guard case .alive = intent.byHash[block.atomicHash] else {
            Issue.record("expected alive intent after three duplicate adds")
            return
        }
    }

    @Test func compactOwnLogCollapsesDuplicateAdds() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RecoveryLog(workspaceRoot: root, deviceID: "dev-A")

        let block = Block.paragraph(text: attr("steady"))
        try await log.apply(Patch.adds(from: [block]), to: "p.md")
        try await log.apply(Patch.adds(from: [block]), to: "p.md")
        try await log.apply(Patch.adds(from: [block]), to: "p.md")

        let result = try await log.compactOwnLog(page: "p.md", mdMtime: nil)
        let url = deviceLogURL(workspace: root, page: "p.md", deviceID: "dev-A")
        #expect(result.originalRecordCount == 3)
        #expect(result.compactedRecordCount == 1)
        #expect(lineCount(at: url) == 1)

        let intent = PatchEngine.intent(from: log.readJournal(page: "p.md"))
        guard case .alive = intent.byHash[block.atomicHash] else {
            Issue.record("expected duplicate adds to compact to one alive intent")
            return
        }
    }

    @Test func compactOwnLogDropsOwnAddWhenForeignNewerAddSupersedesIt() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let own = RecoveryLog(workspaceRoot: root, deviceID: "dev-A")
        let foreign = RecoveryLog(workspaceRoot: root, deviceID: "dev-B")

        let block = Block.paragraph(text: attr("newer device owns this now"))
        try await own.apply(Patch.adds(from: [block]), to: "p.md")
        try await foreign.apply(Patch.adds(from: [block]), to: "p.md")

        let result = try await own.compactOwnLog(page: "p.md", mdMtime: nil)
        let ownURL = deviceLogURL(workspace: root, page: "p.md", deviceID: "dev-A")
        #expect(result.originalRecordCount == 1)
        #expect(result.compactedRecordCount == 0)
        #expect(lineCount(at: ownURL) == 0)

        let intent = PatchEngine.intent(from: own.readJournal(page: "p.md"))
        guard case .alive = intent.byHash[block.atomicHash] else {
            Issue.record("foreign newer add should preserve alive intent after own compaction")
            return
        }
    }

    @Test func compactOwnLogKeepsOwnSnapshotNeededByForeignRecentPurge() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let own = RecoveryLog(workspaceRoot: root, deviceID: "dev-A")
        let foreign = RecoveryLog(workspaceRoot: root, deviceID: "dev-B")

        let block = Block.paragraph(text: attr("recently deleted elsewhere"))
        try await own.apply(Patch.adds(from: [block]), to: "p.md")
        try await foreign.apply(Patch(entries: [.purge(hash: block.atomicHash)]), to: "p.md")

        let result = try await own.compactOwnLog(page: "p.md", mdMtime: nil)
        let ownURL = deviceLogURL(workspace: root, page: "p.md", deviceID: "dev-A")
        #expect(result.originalRecordCount == 1)
        #expect(result.compactedRecordCount == 1)
        #expect(lineCount(at: ownURL) == 1)

        let purged = await own.enumeratePurged(page: "p.md", since: nil)
        #expect(purged.contains { $0.hash == block.atomicHash && $0.markdown.contains("recently deleted elsewhere") })
    }

    @Test func compactOwnLogDropsOwnSnapshotForExpiredForeignPurge() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RecoveryLog(workspaceRoot: root, deviceID: "dev-A")

        let block = Block.paragraph(text: attr("old foreign delete"))
        let h = block.atomicHash
        let markdown = BlockSerializer.serializeAtomic(block)
        let ownURL = deviceLogURL(workspace: root, page: "p.md", deviceID: "dev-A")
        let foreignURL = deviceLogURL(workspace: root, page: "p.md", deviceID: "dev-B")
        try FileManager.default.createDirectory(
            at: ownURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encodedWire(op: "add", hash: h, markdown: markdown, t: 90, counter: 1)
            .write(to: ownURL, atomically: true, encoding: .utf8)
        try encodedWire(op: "purge", hash: h, t: 100, counter: 2)
            .write(to: foreignURL, atomically: true, encoding: .utf8)

        let result = try await log.compactOwnLog(
            page: "p.md",
            mdMtime: nil,
            now: Date(timeIntervalSince1970: 100 + 31 * 24 * 60 * 60)
        )
        #expect(result.originalRecordCount == 1)
        #expect(result.compactedRecordCount == 0)
        #expect(lineCount(at: ownURL) == 0)

        let intent = PatchEngine.intent(from: log.readJournal(page: "p.md"))
        if case .tombstoned(let latestAdd, _) = intent.byHash[h] {
            if latestAdd != nil {
                Issue.record("expired foreign-purge snapshot should be dropped from own log")
            }
        } else {
            Issue.record("foreign purge should still keep the hash tombstoned")
        }
        let purged = await log.enumeratePurged(page: "p.md", since: nil)
        #expect(!purged.contains { $0.hash == h })
    }

    @Test func compactOwnLogPreservesTombstonedRecoveryState() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RecoveryLog(workspaceRoot: root, deviceID: "dev-A")

        let block = Block.paragraph(text: attr("deleted but recoverable"))
        try await log.apply(Patch.adds(from: [block]), to: "p.md")
        try await log.apply(Patch(entries: [.purge(hash: block.atomicHash)]), to: "p.md")

        let result = try await log.compactOwnLog(page: "p.md", mdMtime: nil)
        let url = deviceLogURL(workspace: root, page: "p.md", deviceID: "dev-A")
        #expect(result.originalRecordCount == 2)
        #expect(result.compactedRecordCount == 2)
        #expect(lineCount(at: url) == 2)

        let purged = await log.enumeratePurged(page: "p.md", since: nil)
        #expect(purged.contains { $0.hash == block.atomicHash && $0.markdown.contains("deleted but recoverable") })
    }

    @Test func compactOwnLogDropsExpiredPurgedSnapshotButKeepsTombstone() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RecoveryLog(workspaceRoot: root, deviceID: "dev-A")

        let block = Block.paragraph(text: attr("old deleted payload"))
        let h = block.atomicHash
        let markdown = BlockSerializer.serializeAtomic(block)
        let escaped = markdown
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let addLine = "{\"c\":1,\"h\":\"\(h)\",\"m\":\"\(escaped)\",\"op\":\"add\",\"p\":null,\"t\":90}\n"
        let purgeLine = "{\"c\":2,\"h\":\"\(h)\",\"m\":null,\"op\":\"purge\",\"p\":null,\"t\":100}\n"
        let url = deviceLogURL(workspace: root, page: "p.md", deviceID: "dev-A")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try (addLine + purgeLine).write(to: url, atomically: true, encoding: .utf8)

        let result = try await log.compactOwnLog(
            page: "p.md",
            mdMtime: nil,
            now: Date(timeIntervalSince1970: 100 + 31 * 24 * 60 * 60)
        )
        #expect(result.originalRecordCount == 2)
        #expect(result.compactedRecordCount == 1)
        #expect(lineCount(at: url) == 1)

        let intent = PatchEngine.intent(from: log.readJournal(page: "p.md"))
        if case .tombstoned(let latestAdd, _) = intent.byHash[h] {
            if case .some = latestAdd {
                Issue.record("expired purged snapshot should drop recoverable markdown")
            }
        } else {
            Issue.record("expected old purge compaction to keep the tombstone")
        }
        let purged = await log.enumeratePurged(page: "p.md", since: nil)
        #expect(!purged.contains { $0.hash == h })
    }

    @Test func compactOwnLogPrunesExpiredTombstoneWhenStampedFrontierCoversKnownDevices() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RecoveryLog(workspaceRoot: root, deviceID: "dev-A")

        let block = Block.paragraph(text: attr("known deleted"))
        let h = block.atomicHash
        let markdown = BlockSerializer.serializeAtomic(block)
        let url = deviceLogURL(workspace: root, page: "p.md", deviceID: "dev-A")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try (
            encodedWire(op: "add", hash: h, markdown: markdown, t: 90, counter: 1) +
            encodedWire(op: "purge", hash: h, t: 100, counter: 2)
        ).write(to: url, atomically: true, encoding: .utf8)

        // V1 is known-device scoped: a valid stamp that covers every
        // currently present log proves the visible journal has absorbed the
        // tombstone, but it cannot speak for a never-before-seen offline
        // device that may arrive later.
        let result = try await log.compactOwnLog(
            page: "p.md",
            mdMtime: nil,
            trustedFrontier: ["dev-A": 2],
            now: Date(timeIntervalSince1970: 100 + 31 * 24 * 60 * 60)
        )
        #expect(result.originalRecordCount == 2)
        #expect(result.compactedRecordCount == 0)
        #expect(lineCount(at: url) == 0)
    }

    @Test func compactOwnLogKeepsExpiredTombstoneWhenKnownDeviceHasUnfrontieredRecord() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RecoveryLog(workspaceRoot: root, deviceID: "dev-A")

        let deleted = Block.paragraph(text: attr("not safe yet"))
        let other = Block.paragraph(text: attr("new foreign tail"))
        let h = deleted.atomicHash
        let ownURL = deviceLogURL(workspace: root, page: "p.md", deviceID: "dev-A")
        let foreignURL = deviceLogURL(workspace: root, page: "p.md", deviceID: "dev-B")
        try FileManager.default.createDirectory(
            at: ownURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try (
            encodedWire(op: "add", hash: h, markdown: BlockSerializer.serializeAtomic(deleted), t: 90, counter: 1) +
            encodedWire(op: "purge", hash: h, t: 100, counter: 2)
        ).write(to: ownURL, atomically: true, encoding: .utf8)
        try encodedWire(
            op: "add",
            hash: other.atomicHash,
            markdown: BlockSerializer.serializeAtomic(other),
            t: 110,
            counter: 3
        ).write(to: foreignURL, atomically: true, encoding: .utf8)

        let result = try await log.compactOwnLog(
            page: "p.md",
            mdMtime: nil,
            trustedFrontier: ["dev-A": 2, "dev-B": 2],
            now: Date(timeIntervalSince1970: 100 + 31 * 24 * 60 * 60)
        )
        #expect(result.originalRecordCount == 2)
        #expect(result.compactedRecordCount == 1)
        #expect(lineCount(at: ownURL) == 1)
    }

    @Test func compactOwnLogKeepsExpiredTombstoneForLegacyNilCounterLog() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RecoveryLog(workspaceRoot: root, deviceID: "dev-A")

        let block = Block.paragraph(text: attr("legacy tombstone"))
        let h = block.atomicHash
        let url = deviceLogURL(workspace: root, page: "p.md", deviceID: "dev-A")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try (
            encodedLegacyWire(op: "add", hash: h, markdown: BlockSerializer.serializeAtomic(block), t: 90) +
            encodedLegacyWire(op: "purge", hash: h, t: 100)
        ).write(to: url, atomically: true, encoding: .utf8)

        let result = try await log.compactOwnLog(
            page: "p.md",
            mdMtime: nil,
            trustedFrontier: ["dev-A": 999],
            now: Date(timeIntervalSince1970: 100 + 31 * 24 * 60 * 60)
        )
        #expect(result.originalRecordCount == 2)
        #expect(result.compactedRecordCount == 1)
        #expect(lineCount(at: url) == 1)
    }

    @Test func compactOwnLogPreservesObserveOnlyState() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RecoveryLog(workspaceRoot: root, deviceID: "dev-A")

        let block = Block.paragraph(text: attr("observed elsewhere"))
        try await log.apply(Patch.observations(from: [block]), to: "p.md")

        let result = try await log.compactOwnLog(page: "p.md", mdMtime: nil)
        let url = deviceLogURL(workspace: root, page: "p.md", deviceID: "dev-A")
        #expect(result.originalRecordCount == 1)
        #expect(result.compactedRecordCount == 1)
        #expect(lineCount(at: url) == 1)

        let intent = PatchEngine.intent(from: log.readJournal(page: "p.md"))
        guard case .observed = intent.byHash[block.atomicHash] else {
            Issue.record("expected observe-only hash to remain observed")
            return
        }
    }

    @Test func compactOwnLogKeepsLatestSnapshotPlusTombstone() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RecoveryLog(workspaceRoot: root, deviceID: "dev-A")

        let block = Block.paragraph(text: attr("moved then deleted"))
        let h = block.atomicHash
        let markdown = BlockSerializer.serializeAtomic(block)
        try await log.apply(Patch(entries: [.add(hash: h, parent: "old-parent", markdown: markdown)]), to: "p.md")
        try await log.apply(Patch(entries: [.observe(hash: h, parent: "new-parent", markdown: markdown)]), to: "p.md")
        try await log.apply(Patch(entries: [.purge(hash: h)]), to: "p.md")

        let result = try await log.compactOwnLog(page: "p.md", mdMtime: nil)
        let url = deviceLogURL(workspace: root, page: "p.md", deviceID: "dev-A")
        #expect(result.originalRecordCount == 3)
        #expect(result.compactedRecordCount == 2)
        #expect(lineCount(at: url) == 2)

        let intent = PatchEngine.intent(from: log.readJournal(page: "p.md"))
        if case .tombstoned = intent.byHash[h] {
            #expect(intent.parent(of: h) == "new-parent")
        } else {
            Issue.record("expected compacted add + observe + purge to remain tombstoned")
        }
    }

    @Test func compactOwnLogKeepsCountersMonotonicForSubsequentAppends() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RecoveryLog(workspaceRoot: root, deviceID: "dev-A")

        let first = Block.paragraph(text: attr("first"))
        try await log.apply(Patch.adds(from: [first]), to: "p.md")
        try await log.apply(Patch.adds(from: [first]), to: "p.md")
        _ = try await log.compactOwnLog(page: "p.md", mdMtime: nil)

        let second = Block.paragraph(text: attr("second"))
        try await log.apply(Patch.adds(from: [second]), to: "p.md")

        let url = deviceLogURL(workspace: root, page: "p.md", deviceID: "dev-A")
        let counters = try counters(at: url)
        #expect(counters == [2, 3])
        #expect(counters == counters.sorted())
        #expect(Set(counters).count == counters.count)
    }

    @Test func nestedChildrenRecordTheirImmediateParent() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RecoveryLog(workspaceRoot: root, deviceID: "dev-A")

        let child = Block.paragraph(text: attr("Body of toggle"))
        let toggle = Block.toggle(title: attr("Outer"), children: [child])
        try await log.apply(Patch.adds(from: [toggle]), to: "p.md")

        // Both blocks are still alive, so listLostBlocks returns nothing.
        // To assert the parent header was written, we check the file contents.
        let url = deviceLogURL(workspace: root, page: "p.md", deviceID: "dev-A")
        let text = try String(contentsOf: url, encoding: .utf8)
        let toggleHash = toggle.atomicHash
        let childHash = child.atomicHash
        #expect(text.contains("\"h\":\"\(toggleHash)\""))
        #expect(text.contains("\"h\":\"\(childHash)\""))
        #expect(text.contains("\"p\":\"\(toggleHash)\""))   // child's parent is toggle
    }

    // MARK: - Recovery via Clamshell

    @MainActor
    /// When the editor records an explicit purge for a block the user deleted,
    /// the Recover sheet's "Lost" list no longer surfaces it — the log union's
    /// latest record for that hash is a `purge`.
    @Test func explicitPurgeSuppressesDeletedBlock() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)
        let url = root.appendingPathComponent("p.md")

        let keep = Block.paragraph(text: attr("Keep"))
        let lose = Block.paragraph(text: attr("Lose"))
        let doc = Document(id: DocumentID("p"), children: [keep, lose])
        try await clamshell.commit(Commit(logEntries: Patch.adds(from: doc.children).entries), to: doc, at: url)

        // Editor deletes `lose` — splice, derive ops, fire the canonical
        // editor save path so the purge is logged and the .md saved.
        doc.replaceChildrenFromSystemMutation([keep])
        try await clamshell.commit(.fromEditorChanges([.removed(block: lose)]), to: doc, at: url)

        let lost = await clamshell.listLostBlocks(filter: .page(relativePath: "p.md"))
        #expect(lost.isEmpty, "explicit purge should suppress the deleted block")
    }

    /// External (non-Hunch) loss of a block whose log entry exists from a
    /// prior save surfaces as a lost block — Hunch can't infer intent from
    /// a write it didn't author, so no purge fires and the log union's
    /// latest record is still `add`.
    @MainActor
    @Test func externalLossOfBlockSurfacesAsLost() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)
        let url = root.appendingPathComponent("p.md")

        let doc = Document(
            id: DocumentID("p"),
            children: [
                Block.paragraph(text: attr("Keep")),
                Block.paragraph(text: attr("Lose"))
            ]
        )
        try await clamshell.commit(Commit(logEntries: Patch.adds(from: doc.children).entries), to: doc, at: url)

        // Simulate an external editor / iCloud stomp: overwrite .md directly,
        // bypassing the Clamshell save + editor op-stream so no purge fires.
        try "# p\n\nKeep\n".write(to: url, atomically: true, encoding: .utf8)

        let lost = await clamshell.listLostBlocks(filter: .page(relativePath: "p.md"))
        #expect(lost.count == 1)
        #expect(lost.first?.markdown.contains("Lose") == true)
    }

    /// Delete-then-recreate cycle: the editor's explicit `purgeHash` writes a
    /// `purge`, the recreate writes a fresh `add` with a newer `t`. The
    /// latest-wins union picks the new add → the block is alive again and
    /// the log union exposes no lost entry.
    @MainActor
    @Test func recreatedBlockOverridesExplicitPurge() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)
        let url = root.appendingPathComponent("p.md")

        let ghost = Block.paragraph(text: attr("ghost"))
        let doc = Document(id: DocumentID("p"), children: [ghost])
        try await clamshell.commit(Commit(logEntries: Patch.adds(from: doc.children).entries), to: doc, at: url)

        // Editor deletes the ghost: empty children + purge op.
        doc.replaceChildrenFromSystemMutation([])
        try await clamshell.commit(.fromEditorChanges([.removed(block: ghost)]), to: doc, at: url)

        // Intermediate: explicitly purged, so nothing is "lost".
        var lost = await clamshell.listLostBlocks(filter: .page(relativePath: "p.md"))
        #expect(lost.isEmpty)

        // Subsecond timestamps could collide with the prior purge; sleep
        // through a millisecond boundary so latest-wins picks the new add.
        try await Task.sleep(for: .milliseconds(20))
        let revived = Block.paragraph(text: attr("ghost"))
        doc.replaceChildrenFromSystemMutation([revived])
        try await clamshell.commit(.fromEditorChanges([.inserted(block: revived, parent: nil)]), to: doc, at: url)
        lost = await clamshell.listLostBlocks(filter: .page(relativePath: "p.md"))
        #expect(lost.isEmpty, "alive in .md, latest-record is add → not lost")
    }

    /// The first save records `body` with `toggle`'s hash as its parent in
    /// the log. The journal's intent state still carries the parent
    /// metadata even after a later purge — for hashes whose latest record
    /// is an `add`. Here we keep `body` live so the latest record stays as
    /// `add`; the question is whether the parent metadata was recorded at
    /// first observation.
    @MainActor
    @Test func nestedChildRecordsParentHashThroughClamshell() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)
        let url = root.appendingPathComponent("p.md")

        let body = Block.paragraph(text: attr("inside"))
        let toggle = Block.toggle(title: attr("Outer"), children: [body])
        let doc = Document(id: DocumentID("p"), children: [toggle])
        try await clamshell.commit(Commit(logEntries: Patch.adds(from: doc.children).entries), to: doc, at: url)

        let toggleHash = toggle.atomicHash
        let bodyHash = body.atomicHash
        let intent = PatchEngine.intent(from: clamshell.log.readJournal(page: "p.md"))
        #expect(intent.parent(of: bodyHash) == toggleHash)
    }

    /// Tombstoning a foreign hash via the editor's `purgeHash` path
    /// suppresses it from `listLostBlocks` even though the original `add`
    /// came from another device. The Recover sheet's dismiss action goes
    /// through this same path.
    @MainActor
    @Test func purgeTombstoneSuppressesForeignLostBlock() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)
        let url = root.appendingPathComponent("p.md")

        let doc = Document(id: DocumentID("p"), children: [])
        try await clamshell.commit(Commit(logEntries: []), to: doc, at: url)
        // (empty page on disk, journal empty)

        let foreignBlock = Block.paragraph(text: attr("ghost"))
        let h = foreignBlock.atomicHash
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

        var lost = await clamshell.listLostBlocks(filter: .page(relativePath: "p.md"))
        #expect(lost.contains(where: { $0.hash == h }))
        try await clamshell.log.apply(Patch(entries: [.purge(hash: h)]), to: "p.md")
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
        let doc = Document(id: DocumentID("p"), children: [])
        try await clamshell.commit(Commit(logEntries: []), to: doc, at: url)

        // Hand-write a foreign device's log entry.
        let foreignBlock = Block.paragraph(text: attr("from another device"))
        let h = foreignBlock.atomicHash
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

        let doc = Document(
            id: DocumentID("p"),
            children: [Block.paragraph(text: attr("alive"))]
        )
        try await clamshell.commit(Commit(logEntries: Patch.adds(from: doc.children).entries), to: doc, at: url)

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

    /// Re-adding a hash after it was tombstoned: the new `add` has a later
    /// `t` than the prior `purge`, so latest-wins picks the add and the
    /// block is alive again. `listLostBlocks` excludes it (alive in .md).
    @MainActor
    @Test func newAddOverridesEarlierPurge() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RecoveryLog(workspaceRoot: root, deviceID: "dev-A")

        let block = Block.paragraph(text: attr("phoenix"))
        try await log.apply(Patch.adds(from: [block]), to: "p.md")
        // 1ms guarantees a fresh timestamp; precision of `t` is ms.
        try await Task.sleep(for: .milliseconds(2))
        try await log.apply(Patch(entries: [.purge(hash: block.atomicHash)]), to: "p.md")
        try await Task.sleep(for: .milliseconds(2))
        // Re-add the same hash: a higher counter on the fresh `add` beats
        // the prior purge in the union (latest `(c, deviceID)` wins).
        try await log.apply(
            Patch(entries: [.add(
                hash: block.atomicHash,
                parent: nil,
                markdown: BlockSerializer.serializeAtomic(block)
            )]),
            to: "p.md"
        )

        // Plant the block as alive in .md so the live-set check excludes it
        // — the assertion is that it doesn't surface as "lost" even though
        // a purge exists in the log.
        try BlockSerializer.serialize([block])
            .write(to: root.appendingPathComponent("p.md"), atomically: true, encoding: .utf8)

        let lost = await log.enumerate(page: "p.md")
        #expect(lost.contains(where: { $0.hash == block.atomicHash }) == false)
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

    // MARK: - Purged blocks (intentional deletions, restorable)

    /// After the editor explicitly purges a block, the hash's latest record
    /// is a purge. `enumeratePurged` surfaces it with the markdown
    /// reconstructed from the prior `add`, so the Recover sheet can offer to
    /// bring it back.
    @MainActor
    @Test func enumeratePurgedSurfacesExplicitlyPurgedBlocks() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)
        let url = root.appendingPathComponent("p.md")

        let keep = Block.paragraph(text: attr("Keep"))
        let lose = Block.paragraph(text: attr("Lose"))
        let doc = Document(id: DocumentID("p"), children: [keep, lose])
        try await clamshell.commit(Commit(logEntries: Patch.adds(from: doc.children).entries), to: doc, at: url)

        doc.replaceChildrenFromSystemMutation([keep])
        try await clamshell.commit(.fromEditorChanges([.removed(block: lose)]), to: doc, at: url)

        let purged = await clamshell.listPurgedBlocks(
            filter: .page(relativePath: "p.md"),
            since: nil
        )
        #expect(purged.count == 1)
        #expect(purged.first?.markdown.contains("Lose") == true)
    }

    /// `since:` caps the surfaced purges to recent records. The default
    /// 30-day cap drops anything older; `since: nil` disables the cap.
    @MainActor
    @Test func enumeratePurgedRespectsSinceCap() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)
        let url = root.appendingPathComponent("p.md")

        // Plant an ancient purge by hand-writing the log.
        let block = Block.paragraph(text: attr("ancient"))
        let h = block.atomicHash
        let m = BlockSerializer.serializeAtomic(block)
        let escaped = m
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let addLine = "{\"h\":\"\(h)\",\"m\":\"\(escaped)\",\"op\":\"add\",\"p\":null,\"t\":1.0}\n"
        let purgeLine = "{\"h\":\"\(h)\",\"m\":null,\"op\":\"purge\",\"p\":null,\"t\":2.0}\n"
        let logURL = deviceLogURL(workspace: root, page: "p.md", deviceID: "dev-A")
        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try (addLine + purgeLine).write(to: logURL, atomically: true, encoding: .utf8)

        // Plant the live .md so it's a valid scan target.
        let live = Document(id: DocumentID("p"), children: [])
        try await clamshell.commit(Commit(logEntries: []), to: live, at: url)

        // Default 30-day cap excludes the ancient purge.
        let recent = await clamshell.listPurgedBlocks(filter: .page(relativePath: "p.md"))
        #expect(!recent.contains(where: { $0.hash == h }))

        // since: nil sees everything.
        let all = await clamshell.listPurgedBlocks(filter: .page(relativePath: "p.md"), since: nil)
        #expect(all.contains(where: { $0.hash == h }))
    }

    /// A later `add` (e.g. from another device) overrides an earlier `purge`
    /// under latest-`t` semantics — the block is alive in the union again
    /// and surfaces as "lost" when the live `.md` doesn't yet include it.
    /// No sticky poison-pill carries the historical purge forward.
    @MainActor
    @Test func laterAddOverridesEarlierPurgeInUnion() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)
        let url = root.appendingPathComponent("p.md")

        let block = Block.paragraph(text: attr("phoenix"))
        let doc = Document(id: DocumentID("p"), children: [block])
        try await clamshell.commit(Commit(logEntries: Patch.adds(from: doc.children).entries), to: doc, at: url)

        doc.replaceChildrenFromSystemMutation([])
        try await clamshell.commit(.fromEditorChanges([.removed(block: block)]), to: doc, at: url)

        // External writer brings the hash back into the log via a foreign
        // device's add with a counter strictly greater than anything our
        // device has minted on this page.
        let h = block.atomicHash
        let m = BlockSerializer.serializeAtomic(block)
        let escaped = m
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let now = Date().timeIntervalSince1970
        let line = "{\"c\":9999,\"h\":\"\(h)\",\"m\":\"\(escaped)\",\"op\":\"add\",\"p\":null,\"t\":\(now + 10)}\n"
        let foreignURL = deviceLogURL(workspace: root, page: "p.md", deviceID: "dev-B")
        try line.write(to: foreignURL, atomically: true, encoding: .utf8)

        let lost = await clamshell.listLostBlocks(filter: .page(relativePath: "p.md"))
        #expect(lost.contains(where: { $0.hash == h }),
                "later add should win over earlier purge → hash surfaces as lost")
    }

    /// `unpurgeBlock` appends a fresh `add` with a current timestamp. The
    /// union picks the new add as latest → the hash is no longer surfaced
    /// as purged or lost.
    @MainActor
    @Test func unpurgeBlockLiftsTombstone() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)
        let url = root.appendingPathComponent("p.md")

        let doomed = Block.paragraph(text: attr("doomed"))
        let doc = Document(id: DocumentID("p"), children: [doomed])
        try await clamshell.commit(Commit(logEntries: Patch.adds(from: doc.children).entries), to: doc, at: url)

        doc.replaceChildrenFromSystemMutation([])
        try await clamshell.commit(.fromEditorChanges([.removed(block: doomed)]), to: doc, at: url)

        // It's now purged.
        let purgedBefore = await clamshell.listPurgedBlocks(
            filter: .page(relativePath: "p.md"),
            since: nil
        )
        #expect(purgedBefore.count == 1)
        let entry = try #require(purgedBefore.first)

        // Sleep across a ms boundary so the fresh add's timestamp beats the
        // purge (the counter would suffice either way; t is for display).
        try await Task.sleep(for: .milliseconds(20))
        let block = Block.paragraph(text: attr("doomed"))
        try await clamshell.log.apply(
            Patch(entries: [.add(
                hash: block.atomicHash,
                parent: entry.parentHash,
                markdown: BlockSerializer.serializeAtomic(block)
            )]),
            to: "p.md"
        )

        let purgedAfter = await clamshell.listPurgedBlocks(
            filter: .page(relativePath: "p.md"),
            since: nil
        )
        #expect(purgedAfter.isEmpty)
    }

    // MARK: - Lamport counter

    /// Each record this device writes carries a per-page counter, monotonic
    /// across the session. The first call mints `c == 1`, subsequent calls
    /// strictly increment. Hydrates lazily from the union of every device's
    /// log on first observation.
    @MainActor
    @Test func recordsCarryMonotonicLamportCounter() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RecoveryLog(workspaceRoot: root, deviceID: "dev-A")

        try await log.apply(Patch.adds(from: [
            .paragraph(text: attr("first")),
            .paragraph(text: attr("second"))
        ]), to: "p.md")
        try await log.apply(Patch.adds(from: [
            .paragraph(text: attr("first")),
            .paragraph(text: attr("second")),
            .paragraph(text: attr("third"))
        ]), to: "p.md")

        let url = deviceLogURL(workspace: root, page: "p.md", deviceID: "dev-A")
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let counters = lines.compactMap { line -> UInt64? in
            guard let data = String(line).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return (obj["c"] as? UInt64) ?? (obj["c"] as? Int).flatMap { UInt64(exactly: $0) }
        }
        #expect(counters.count == 5, "2 adds from first apply + 3 from second; no write-time dedup")
        #expect(counters == counters.sorted(), "counters strictly monotonic")
        #expect(Set(counters).count == counters.count, "no duplicate counters")
    }

    /// When two devices write the same hash, the higher-counter record wins
    /// regardless of wall-clock skew. This is the clock-skew-immunity
    /// property: a slow-clock device whose `t` is small still wins on `c`.
    @MainActor
    @Test func unionPrefersHigherCounterOverWallClock() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)
        let url = root.appendingPathComponent("p.md")

        let block = Block.paragraph(text: attr("phoenix"))
        let doc = Document(id: DocumentID("p"), children: [block])
        try await clamshell.commit(Commit(logEntries: Patch.adds(from: doc.children).entries), to: doc, at: url)

        doc.replaceChildrenFromSystemMutation([])
        try await clamshell.commit(.fromEditorChanges([.removed(block: block)]), to: doc, at: url)

        // Foreign device: counter 9999 but wall-clock 100s in the *past*.
        let h = block.atomicHash
        let m = BlockSerializer.serializeAtomic(block)
        let escaped = m
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let pastT = Date().timeIntervalSince1970 - 100
        let line = "{\"c\":9999,\"h\":\"\(h)\",\"m\":\"\(escaped)\",\"op\":\"add\",\"p\":null,\"t\":\(pastT)}\n"
        let foreignURL = deviceLogURL(workspace: root, page: "p.md", deviceID: "dev-B")
        try line.write(to: foreignURL, atomically: true, encoding: .utf8)

        let lost = await clamshell.listLostBlocks(filter: .page(relativePath: "p.md"))
        #expect(lost.contains(where: { $0.hash == h }),
                "higher counter wins regardless of past wall-clock t")
    }

    /// Regression for the iPhone → Mac delayed-log case: the Mac may save
    /// `p.md` after the phone-authored add, then receive the phone's `.jsonl`
    /// later. The tail reconcile should still restore the add-backed block
    /// because no purge says it was intentionally deleted.
    @Test func tailReconcileRestoresForeignAddOlderThanMdMtime() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RecoveryLog(workspaceRoot: root, deviceID: "dev-A")

        let local = Block.paragraph(text: attr("local edit"))
        try await log.apply(Patch.adds(from: [local]), to: "p.md")

        let mdMtime = Date(timeIntervalSince1970: 200)
        let initial = await log.reconcileAgainst(page: "p.md", doc: [local], mdMtime: mdMtime)
        switch initial {
        case .folded(let recon, _):
            #expect(recon.inserts.isEmpty)
        case .skipped:
            Issue.record("first reconcile should establish a watermark via full fold")
        }

        let foreign = Block.paragraph(text: attr("from phone"))
        let h = foreign.atomicHash
        let m = BlockSerializer.serializeAtomic(foreign)
        let escaped = m
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let line = "{\"c\":9999,\"h\":\"\(h)\",\"m\":\"\(escaped)\",\"op\":\"add\",\"p\":null,\"t\":100}\n"
        let foreignURL = deviceLogURL(workspace: root, page: "p.md", deviceID: "dev-B")
        try FileManager.default.createDirectory(
            at: foreignURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try line.write(to: foreignURL, atomically: true, encoding: .utf8)

        let outcome = await log.reconcileAgainst(page: "p.md", doc: [local], mdMtime: mdMtime)
        guard case .folded(let recon, .tail) = outcome else {
            Issue.record("expected tail fold after foreign log growth, got \(outcome)")
            return
        }
        #expect(recon.inserts.count == 1)
        #expect(recon.restoredHashes == [h])
    }

    @Test func legacyUnstampedReconcileRestoresMissingForeignAdd() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RecoveryLog(workspaceRoot: root, deviceID: "dev-A")

        let foreign = Block.paragraph(text: attr("legacy restore"))
        let h = foreign.atomicHash
        let foreignURL = deviceLogURL(workspace: root, page: "p.md", deviceID: "dev-B")
        try FileManager.default.createDirectory(
            at: foreignURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encodedWire(
            op: "add",
            hash: h,
            markdown: BlockSerializer.serializeAtomic(foreign),
            t: 100,
            counter: 10
        ).write(to: foreignURL, atomically: true, encoding: .utf8)

        let outcome = await log.reconcileAgainst(page: "p.md", doc: [], mdMtime: nil)
        guard case .folded(let recon, .full) = outcome else {
            Issue.record("expected full fold for unstamped legacy page, got \(outcome)")
            return
        }
        #expect(recon.inserts.count == 1)
        #expect(recon.restoredHashes == [h])
    }

    @Test func stampedFrontierRestoresForeignAddAfterFrontier() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RecoveryLog(workspaceRoot: root, deviceID: "dev-A")

        let foreign = Block.paragraph(text: attr("late log tail"))
        let h = foreign.atomicHash
        let foreignURL = deviceLogURL(workspace: root, page: "p.md", deviceID: "dev-B")
        try FileManager.default.createDirectory(
            at: foreignURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encodedWire(
            op: "add",
            hash: h,
            markdown: BlockSerializer.serializeAtomic(foreign),
            t: 100,
            counter: 11
        ).write(to: foreignURL, atomically: true, encoding: .utf8)

        let outcome = await log.reconcileAgainst(
            page: "p.md",
            doc: [],
            mdMtime: nil,
            trustedFrontier: ["dev-B": 10]
        )
        guard case .folded(let recon, .full) = outcome else {
            Issue.record("expected full fold for stamped page, got \(outcome)")
            return
        }
        #expect(recon.inserts.count == 1)
        #expect(recon.restoredHashes == [h])
    }

    @Test func stampedFrontierCanDeferFutureForeignAddForPassiveOpen() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RecoveryLog(workspaceRoot: root, deviceID: "dev-A")

        let foreign = Block.paragraph(text: attr("future peer file"))
        let h = foreign.atomicHash
        let foreignURL = deviceLogURL(workspace: root, page: "p.md", deviceID: "dev-B")
        try FileManager.default.createDirectory(
            at: foreignURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encodedWire(
            op: "add",
            hash: h,
            markdown: BlockSerializer.serializeAtomic(foreign),
            t: 100,
            counter: 11
        ).write(to: foreignURL, atomically: true, encoding: .utf8)

        let outcome = await log.reconcileAgainst(
            page: "p.md",
            doc: [],
            mdMtime: nil,
            trustedFrontier: ["dev-B": 10],
            restoreFutureForeignAdds: false
        )
        guard case .folded(let recon, .full) = outcome else {
            Issue.record("expected full fold for stamped page, got \(outcome)")
            return
        }
        #expect(recon.inserts.isEmpty)
        #expect(recon.restoredHashes.isEmpty)
        let lost = await log.enumerate(page: "p.md", trustedFrontier: ["dev-B": 10])
        #expect(lost.contains(where: { $0.hash == h }))

        let retry = await log.reconcileAgainst(
            page: "p.md",
            doc: [],
            mdMtime: nil,
            trustedFrontier: ["dev-B": 10],
            restoreFutureForeignAdds: true
        )
        guard case .folded(let retryRecon, .full) = retry else {
            Issue.record("deferred peer state should not advance the watermark, got \(retry)")
            return
        }
        #expect(retryRecon.restoredHashes == [h])
    }

    @Test func stampedFrontierSuppressesForeignAddAtOrBeforeFrontier() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RecoveryLog(workspaceRoot: root, deviceID: "dev-A")

        let foreign = Block.paragraph(text: attr("already absorbed"))
        let h = foreign.atomicHash
        let foreignURL = deviceLogURL(workspace: root, page: "p.md", deviceID: "dev-B")
        try FileManager.default.createDirectory(
            at: foreignURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encodedWire(
            op: "add",
            hash: h,
            markdown: BlockSerializer.serializeAtomic(foreign),
            t: 100,
            counter: 10
        ).write(to: foreignURL, atomically: true, encoding: .utf8)

        let frontier: [String: UInt64] = ["dev-B": 10]
        let outcome = await log.reconcileAgainst(
            page: "p.md",
            doc: [],
            mdMtime: nil,
            trustedFrontier: frontier
        )
        guard case .folded(let recon, .full) = outcome else {
            Issue.record("expected full fold for stamped page, got \(outcome)")
            return
        }
        #expect(recon.inserts.isEmpty)
        #expect(recon.restoredHashes.isEmpty)
        let lost = await log.enumerate(page: "p.md", trustedFrontier: frontier)
        #expect(!lost.contains(where: { $0.hash == h }))
    }

    @Test func invalidStampedReconcileSuppressesRestoreButRecordsObservations() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RecoveryLog(workspaceRoot: root, deviceID: "dev-A")

        let local = Block.paragraph(text: attr("external survivor"))
        let foreign = Block.paragraph(text: attr("do not restore on invalid stamp"))
        let foreignURL = deviceLogURL(workspace: root, page: "p.md", deviceID: "dev-B")
        try FileManager.default.createDirectory(
            at: foreignURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encodedWire(
            op: "add",
            hash: foreign.atomicHash,
            markdown: BlockSerializer.serializeAtomic(foreign),
            t: 100,
            counter: 10
        ).write(to: foreignURL, atomically: true, encoding: .utf8)

        let outcome = await log.reconcileAgainst(
            page: "p.md",
            doc: [local],
            mdMtime: nil,
            trustedFrontier: nil,
            allowJournalMutations: false
        )
        guard case .folded(let recon, .full) = outcome else {
            Issue.record("expected full fold for invalid stamped page, got \(outcome)")
            return
        }
        #expect(recon.inserts.isEmpty)
        #expect(recon.restoredHashes.isEmpty)
        #expect(recon.toAppend.map(\.hash) == [local.atomicHash])
    }

    /// A foreign device's record that lands on disk after our initial counter
    /// hydration must still raise our next-mint above the foreign max. Without
    /// the per-call foreign rescan, our `nextCounter[rel]` cache strands us
    /// below the foreign's counter and our next purge can lose to a stale
    /// foreign add even though we observed it first.
    @MainActor
    @Test func freshForeignRecordRaisesNextCounter() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RecoveryLog(workspaceRoot: root, deviceID: "dev-A")

        // Session start: our device records, hydrating nextCounter to 2.
        try await log.apply(Patch.adds(from: [.paragraph(text: attr("first"))]), to: "p.md")

        // Foreign device's log lands on disk via iCloud — counter 9999, well
        // above anything we know about. Hand-planted to simulate the sync.
        let foreign = Block.paragraph(text: attr("from-elsewhere"))
        let h = foreign.atomicHash
        let m = BlockSerializer.serializeAtomic(foreign)
        let escaped = m
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let line = "{\"c\":9999,\"h\":\"\(h)\",\"m\":\"\(escaped)\",\"op\":\"add\",\"p\":null,\"t\":\(Date().timeIntervalSince1970)}\n"
        let foreignURL = deviceLogURL(workspace: root, page: "p.md", deviceID: "dev-B")
        try FileManager.default.createDirectory(
            at: foreignURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try line.write(to: foreignURL, atomically: true, encoding: .utf8)

        // Now we record again. The new add must mint a counter strictly
        // above 9999 — the per-call foreign rescan picks up B's record.
        try await log.apply(Patch.adds(from: [
            .paragraph(text: attr("first")),
            .paragraph(text: attr("second"))
        ]), to: "p.md")

        let ourURL = deviceLogURL(workspace: root, page: "p.md", deviceID: "dev-A")
        let text = try String(contentsOf: ourURL, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let counters = lines.compactMap { line -> UInt64? in
            guard let data = String(line).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return (obj["c"] as? UInt64) ?? (obj["c"] as? Int).flatMap { UInt64(exactly: $0) }
        }
        let ourLatest = try #require(counters.max())
        #expect(ourLatest > 9999,
                "post-foreign mint should strictly exceed foreign max=9999, got \(ourLatest)")
    }

    /// The dual of the above: if we purge a hash after observing a foreign
    /// add for it, our purge's counter must beat the foreign add's counter
    /// so the union picks our purge as the latest record. Without the
    /// per-call rescan, our purge counter strands below the foreign's and
    /// the data silently resurrects.
    @MainActor
    @Test func purgeAfterForeignAddWinsViaCausalCounter() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)
        let url = root.appendingPathComponent("p.md")

        // Empty live page; hydrate our nextCounter low.
        let doc = Document(id: DocumentID("p"), children: [])
        try await clamshell.commit(Commit(logEntries: []), to: doc, at: url)

        // Foreign device's add for hash H lands on disk with counter 500.
        let block = Block.paragraph(text: attr("to-purge"))
        let h = block.atomicHash
        let m = BlockSerializer.serializeAtomic(block)
        let escaped = m
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let now = Date().timeIntervalSince1970
        let line = "{\"c\":500,\"h\":\"\(h)\",\"m\":\"\(escaped)\",\"op\":\"add\",\"p\":null,\"t\":\(now)}\n"
        let foreignURL = deviceLogURL(workspace: root, page: "p.md", deviceID: "dev-B")
        try FileManager.default.createDirectory(
            at: foreignURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try line.write(to: foreignURL, atomically: true, encoding: .utf8)

        // Our device purges H. The purge counter must exceed 500 so the
        // union picks the purge as latest and H is tombstoned, not alive.
        try await clamshell.log.apply(Patch(entries: [.purge(hash: h)]), to: "p.md")

        let intent = PatchEngine.intent(from: clamshell.log.readJournal(page: "p.md"))
        switch intent.byHash[h] {
        case .tombstoned: break
        case .alive: Issue.record("expected tombstoned, got alive — purge lost the union race")
        case .observed: Issue.record("expected tombstoned, got observed")
        case .none: Issue.record("expected tombstoned, got no status")
        }
    }

    /// Modern records (with `c`) always beat legacy records (without `c`)
    /// in the union, regardless of `t`. This is the migration story: legacy
    /// records pre-date the upgrade and can never appear strictly after a
    /// modern one in a coherent timeline.
    @MainActor
    @Test func modernRecordBeatsLegacyRegardlessOfTime() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)
        let url = root.appendingPathComponent("p.md")

        // Seed with an empty live page so the live-set excludes nothing.
        let doc = Document(id: DocumentID("p"), children: [])
        try await clamshell.commit(Commit(logEntries: []), to: doc, at: url)

        // Plant a legacy add with t = far future (no `c` field).
        let block = Block.paragraph(text: attr("legacy-ghost"))
        let h = block.atomicHash
        let m = BlockSerializer.serializeAtomic(block)
        let escaped = m
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let futureT = Date().timeIntervalSince1970 + 10_000
        let legacyAdd = "{\"h\":\"\(h)\",\"m\":\"\(escaped)\",\"op\":\"add\",\"p\":null,\"t\":\(futureT)}\n"
        let legacyURL = deviceLogURL(workspace: root, page: "p.md", deviceID: "legacy-dev")
        try FileManager.default.createDirectory(
            at: legacyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try legacyAdd.write(to: legacyURL, atomically: true, encoding: .utf8)

        // Now our device purges. The purge record carries `c`.
        try await clamshell.log.apply(Patch(entries: [.purge(hash: h)]), to: "p.md")
        try await Task.sleep(for: .milliseconds(40))

        let lost = await clamshell.listLostBlocks(filter: .page(relativePath: "p.md"))
        #expect(!lost.contains(where: { $0.hash == h }),
                "modern purge (with c) wins over legacy add (no c) regardless of t")
    }

    // MARK: - Phase 2: cache-after-purge invariant

    /// Type X → delete X → type X again. After the cache-after-purge fix,
    /// the second observation of X emits a fresh `add` (instead of being
    /// silently skipped by the device cache). The log ends with three
    /// records (add, purge, add) and the union considers X alive.
    @MainActor
    @Test func retypingPurgedContentEmitsFreshAdd() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RecoveryLog(workspaceRoot: root, deviceID: "dev-A")

        let block = Block.paragraph(text: attr("retype-me"))
        let h = block.atomicHash

        // 1) Initial save records the add.
        try await log.apply(Patch.adds(from: [block]), to: "p.md")
        // 2) Editor purges (explicit user delete).
        try await log.apply(Patch(entries: [.purge(hash: h)]), to: "p.md")
        // 3) User retypes identical content. Without the fix the device
        //    cache still says "already observed" and this is silently
        //    dropped; with the fix the cache forgot X on purge so a
        //    fresh add lands.
        try await log.apply(Patch.adds(from: [block]), to: "p.md")

        let url = deviceLogURL(workspace: root, page: "p.md", deviceID: "dev-A")
        #expect(lineCount(at: url) == 3, "add + purge + fresh add")

        // Plant the block as alive in .md and check the union: latest
        // record for h is the fresh add, so X is alive intent (not lost,
        // not tombstoned).
        try BlockSerializer.serialize([block])
            .write(to: root.appendingPathComponent("p.md"), atomically: true, encoding: .utf8)
        let lost = await log.enumerate(page: "p.md")
        let purged = await log.enumeratePurged(page: "p.md", since: nil)
        #expect(!lost.contains(where: { $0.hash == h }))
        #expect(!purged.contains(where: { $0.hash == h }),
                "latest record is the fresh add, not the purge")
    }

    /// Across a hydration boundary (new RecoveryLog instance reading our
    /// existing log file), the cache-after-purge invariant still holds —
    /// hydration replays add/purge transitions, so a hash purged before
    /// hydration starts in the "not observed" state.
    @MainActor
    @Test func purgeSurvivesHydrationAcrossSessions() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let block = Block.paragraph(text: attr("survive-hydration"))
        let h = block.atomicHash

        // Session 1: add + purge.
        let log1 = RecoveryLog(workspaceRoot: root, deviceID: "dev-A")
        try await log1.apply(Patch.adds(from: [block]), to: "p.md")
        try await log1.apply(Patch(entries: [.purge(hash: h)]), to: "p.md")

        // Session 2: cold actor, hydrates from the existing log file.
        // Retyping the block must produce a fresh add — the hydrated
        // cache should treat X as "not observed" because the purge
        // followed the add.
        let log2 = RecoveryLog(workspaceRoot: root, deviceID: "dev-A")
        try await log2.apply(Patch.adds(from: [block]), to: "p.md")

        let url = deviceLogURL(workspace: root, page: "p.md", deviceID: "dev-A")
        #expect(lineCount(at: url) == 3, "second session's add should append, not skip")
    }

    // MARK: - Semantic editor-change projection

    /// Applying an ops patch writes mixed inserts and removes as one ordered
    /// batch with sequential per-page counters. The remove-then-insert
    /// Clamshell's purge-then-add ordering is preserved on disk.
    @MainActor
    @Test func appendOpsWritesMixedBatchSequentially() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RecoveryLog(workspaceRoot: root, deviceID: "dev-A")

        let gone = Block.paragraph(text: attr("gone"))
        let arriving = Block.paragraph(text: attr("arriving"))
        let changes: [DocumentChange] = [
            .removed(block: gone),
            .inserted(block: arriving, parent: nil),
        ]
        try await log.apply(Patch.from(changes: changes), to: "p.md")

        let url = deviceLogURL(workspace: root, page: "p.md", deviceID: "dev-A")
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        #expect(lines.count == 2, "remove + insert = two records")

        let records = lines.compactMap { line -> [String: Any]? in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        #expect(records[0]["op"] as? String == "purge")
        #expect(records[1]["op"] as? String == "add")
        let c0 = (records[0]["c"] as? UInt64) ?? UInt64(records[0]["c"] as? Int ?? -1)
        let c1 = (records[1]["c"] as? UInt64) ?? UInt64(records[1]["c"] as? Int ?? -1)
        #expect(c1 == c0 + 1, "counters sequential within batch")
    }

    /// Empty op batches perform zero I/O (no file write, no log churn).
    @MainActor
    @Test func appendOpsWithEmptyBatchIsNoop() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RecoveryLog(workspaceRoot: root, deviceID: "dev-A")

        try await log.apply(Patch.from(changes: []), to: "p.md")
        let url = deviceLogURL(workspace: root, page: "p.md", deviceID: "dev-A")
        #expect(!FileManager.default.fileExists(atPath: url.path),
                "empty batch should not create the log file")
    }

    /// After `remove(hash)`, the device cache forgets the hash — so a
    /// subsequent `insert` of identical content emits a fresh add (intent
    /// flips back to alive). Mirrors today's purge-then-add flow.
    @MainActor
    @Test func appendOpsRemoveThenInsertProducesFreshAdd() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RecoveryLog(workspaceRoot: root, deviceID: "dev-A")

        let block = Block.paragraph(text: attr("retype"))
        try await log.apply(Patch.adds(from: [block]), to: "p.md")
        try await log.apply(Patch.from(changes: [.removed(block: block)]), to: "p.md")
        try await log.apply(Patch.from(changes: [
            .inserted(block: block, parent: nil)
        ]), to: "p.md")

        let url = deviceLogURL(workspace: root, page: "p.md", deviceID: "dev-A")
        #expect(lineCount(at: url) == 3, "initial add + purge + fresh add")
    }

    /// Same-device Turn Into: paragraph → bullet on a stable BlockID.
    /// Clamshell's semantic-change projection must tombstone the old paragraph hash so
    /// reconcile against the post-change live doc doesn't resurrect the
    /// pre-edit paragraph as a "lost block." Repros the iPhone bug where a
    /// voice-recorded paragraph converted to a bullet came back at the
    /// bottom of the page with a "Restored 1 block from another device"
    /// banner.
    @MainActor
    @Test func turnIntoOnSameDeviceDoesNotAutoRestorePriorKind() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RecoveryLog(workspaceRoot: root, deviceID: "dev-A")

        let id = BlockID()
        let paragraph = Block(id: id, kind: .paragraph(text: attr("voice note")))
        try await log.apply(Patch.adds(from: [paragraph]), to: "p.md")

        let bullet = Block(id: id, kind: .bullet(text: attr("voice note")))
        let changes = RecoveryChangeDiff.derive(pre: [paragraph], post: [bullet])
        try await log.apply(Patch.from(changes: changes), to: "p.md")

        let journal = log.readJournal(page: "p.md")
        let intent = PatchEngine.intent(from: journal)

        if case .tombstoned = intent.byHash[paragraph.atomicHash] {
            // expected
        } else {
            Issue.record("expected paragraph hash tombstoned, got \(String(describing: intent.byHash[paragraph.atomicHash]))")
        }
        if case .alive = intent.byHash[bullet.atomicHash] {
            // expected
        } else {
            Issue.record("expected bullet hash alive after Turn Into")
        }

        let recon = PatchEngine.reconcile(intent: intent, doc: [bullet])
        #expect(recon.inserts.isEmpty, "no subtrees should auto-restore")
        #expect(recon.restoredHashes.isEmpty, "no hashes flagged for restore")
    }

    // MARK: - Move

    @Test func moveMigratesWatermarkSoNewPathSkipsRefold() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RecoveryLog(workspaceRoot: root, deviceID: "dev-A")

        let block = Block.paragraph(text: attr("hello"))
        try await log.apply(Patch.adds(from: [block]), to: "old.md")

        let mdMtime = Date(timeIntervalSince1970: 200)
        let initial = await log.reconcileAgainst(page: "old.md", doc: [block], mdMtime: mdMtime)
        guard case .folded = initial else {
            Issue.record("first reconcile should establish a watermark via full fold")
            return
        }

        try await log.move(fromPage: "old.md", toPage: "new.md")

        let oldDir = root
            .appendingPathComponent(RecoveryLog.directoryName, isDirectory: true)
            .appendingPathComponent("old.md", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: oldDir.path))
        #expect(FileManager.default.fileExists(
            atPath: deviceLogURL(workspace: root, page: "new.md", deviceID: "dev-A").path
        ))

        let outcome = await log.reconcileAgainst(page: "new.md", doc: [block], mdMtime: mdMtime)
        guard case .skipped = outcome else {
            Issue.record("watermark should travel with the move; got \(outcome)")
            return
        }
    }

    @Test func moveMigratesWatermarkPersistently() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let block = Block.paragraph(text: attr("hello"))
        let mdMtime = Date(timeIntervalSince1970: 200)
        do {
            let log = RecoveryLog(workspaceRoot: root, deviceID: "dev-A")
            try await log.apply(Patch.adds(from: [block]), to: "old.md")
            _ = await log.reconcileAgainst(page: "old.md", doc: [block], mdMtime: mdMtime)
            try await log.move(fromPage: "old.md", toPage: "new.md")
        }

        let fresh = RecoveryLog(workspaceRoot: root, deviceID: "dev-A")
        let outcome = await fresh.reconcileAgainst(page: "new.md", doc: [block], mdMtime: mdMtime)
        guard case .skipped = outcome else {
            Issue.record("migrated watermark should persist across instances; got \(outcome)")
            return
        }
    }

    @Test func moveContinuesCounterSequenceAtNewPath() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RecoveryLog(workspaceRoot: root, deviceID: "dev-A")

        let first = Block.paragraph(text: attr("one"))
        try await log.apply(Patch.adds(from: [first]), to: "old.md")
        try await log.move(fromPage: "old.md", toPage: "new.md")

        let second = Block.paragraph(text: attr("two"))
        try await log.apply(Patch.adds(from: [second]), to: "new.md")

        let url = deviceLogURL(workspace: root, page: "new.md", deviceID: "dev-A")
        let minted = try counters(at: url)
        #expect(minted.count == 2)
        #expect(zip(minted, minted.dropFirst()).allSatisfy { $1 == $0 + 1 },
                "counters should continue without reset or gap across the move, got \(minted)")
    }
}
