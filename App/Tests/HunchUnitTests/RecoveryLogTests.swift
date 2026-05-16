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

        let lose = Block.paragraph(text: attr("Lose"))
        try clamshell.writeImmediately(Document(
            url: url,
            children: [Block.paragraph(text: attr("Keep")), lose],
            modificationDate: nil
        ))
        try await Task.sleep(for: .milliseconds(80))

        try clamshell.writeImmediately(Document(
            url: url,
            children: [Block.paragraph(text: attr("Keep"))],
            modificationDate: nil
        ))
        // The editor would call `purgeHash` for the removed block — simulate it.
        try await clamshell.purgeHash(lose.atomicHash, in: "p.md")
        try await Task.sleep(for: .milliseconds(80))

        let lost = await clamshell.listLostBlocks(filter: .page(relativePath: "p.md"))
        #expect(lost.isEmpty, "explicit purge should suppress the deleted block")
    }

    /// External (non-Hunch) loss of a block whose log entry exists from a
    /// prior save surfaces as a lost block — no save fired to auto-tombstone,
    /// so the log union's latest record is still `add`.
    @MainActor
    @Test func externalLossOfBlockSurfacesAsLost() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)
        let url = root.appendingPathComponent("p.md")

        try clamshell.writeImmediately(Document(
            url: url,
            children: [
                Block.paragraph(text: attr("Keep")),
                Block.paragraph(text: attr("Lose"))
            ],
            modificationDate: nil
        ))
        try await Task.sleep(for: .milliseconds(80))

        // Simulate an external editor / iCloud stomp: overwrite .md directly,
        // bypassing the Clamshell save path so no auto-tombstone fires.
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
        try clamshell.writeImmediately(Document(
            url: url, children: [ghost], modificationDate: nil
        ))
        try await Task.sleep(for: .milliseconds(80))
        try clamshell.writeImmediately(Document(
            url: url, children: [], modificationDate: nil
        ))
        try await clamshell.purgeHash(ghost.atomicHash, in: "p.md")
        try await Task.sleep(for: .milliseconds(80))

        // Intermediate: explicitly purged, so nothing is "lost".
        var lost = await clamshell.listLostBlocks(filter: .page(relativePath: "p.md"))
        #expect(lost.isEmpty)

        // Subsecond timestamps could collide with the prior purge; sleep
        // through a millisecond boundary so latest-wins picks the new add.
        try await Task.sleep(for: .milliseconds(20))
        try clamshell.writeImmediately(Document(
            url: url,
            children: [Block.paragraph(text: attr("ghost"))],
            modificationDate: nil
        ))
        try await Task.sleep(for: .milliseconds(80))
        lost = await clamshell.listLostBlocks(filter: .page(relativePath: "p.md"))
        #expect(lost.isEmpty, "alive in .md, latest-record is add → not lost")
    }

    /// The first save records `body` with `toggle`'s hash as its parent in the
    /// log. Even after auto-tombstone-on-save fires for `body` on the second
    /// save, `parentHash(forPage:hash:)` still returns the parent — but only
    /// for hashes whose latest record is an `add`. Here we keep `body` live
    /// so the latest record stays as `add`; the question is whether the
    /// parent metadata was recorded at first observation.
    @MainActor
    @Test func nestedChildRecordsParentHashThroughClamshell() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)
        let url = root.appendingPathComponent("p.md")

        let body = Block.paragraph(text: attr("inside"))
        let toggle = Block.toggle(title: attr("Outer"), children: [body])
        try clamshell.writeImmediately(Document(
            url: url, children: [toggle], modificationDate: nil
        ))
        try await Task.sleep(for: .milliseconds(80))

        let toggleHash = toggle.atomicHash
        let bodyHash = body.atomicHash
        let recorded = await clamshell.parentHash(forPage: "p.md", hash: bodyHash)
        #expect(recorded == toggleHash)
    }

    /// Explicit `purgeLostBlock` still works for the case where a block is
    /// surfaced as lost via another device's log (auto-tombstone never ran
    /// because our device didn't perform the deletion). The Recover sheet's
    /// dismiss action exercises this path.
    @MainActor
    @Test func purgeTombstoneSuppressesForeignLostBlock() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)
        let url = root.appendingPathComponent("p.md")

        try clamshell.writeImmediately(Document(
            url: url, children: [], modificationDate: nil
        ))
        try await Task.sleep(for: .milliseconds(40))

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
        let entry = try #require(lost.first(where: { $0.hash == h }))
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
            url: url, children: [], modificationDate: nil
        ))
        try await Task.sleep(for: .milliseconds(40))

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

        try clamshell.writeImmediately(Document(
            url: url,
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

    /// Re-adding a hash after it was tombstoned: the new `add` has a later
    /// `t` than the prior `purge`, so latest-wins picks the add and the
    /// block is alive again. `listLostBlocks` excludes it (alive in .md).
    @MainActor
    @Test func newAddOverridesEarlierPurge() async throws {
        let root = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RecoveryLog(workspaceRoot: root, deviceID: "dev-A")

        let block = Block.paragraph(text: attr("phoenix"))
        try await log.record(page: "p.md", blocks: [block])
        // 1ms guarantees a fresh timestamp; precision of `t` is ms.
        try await Task.sleep(for: .milliseconds(2))
        try await log.record(
            page: "p.md",
            blocks: [],
            removing: [block.atomicHash]
        )
        try await Task.sleep(for: .milliseconds(2))
        try await log.record(page: "p.md", blocks: [block])

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

        let lose = Block.paragraph(text: attr("Lose"))
        try clamshell.writeImmediately(Document(
            url: url,
            children: [Block.paragraph(text: attr("Keep")), lose],
            modificationDate: nil
        ))
        try await Task.sleep(for: .milliseconds(80))

        try clamshell.writeImmediately(Document(
            url: url,
            children: [Block.paragraph(text: attr("Keep"))],
            modificationDate: nil
        ))
        try await clamshell.purgeHash(lose.atomicHash, in: "p.md")
        try await Task.sleep(for: .milliseconds(80))

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
        try clamshell.writeImmediately(Document(
            url: url, children: [], modificationDate: nil
        ))
        try await Task.sleep(for: .milliseconds(40))

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
        try clamshell.writeImmediately(Document(
            url: url, children: [block], modificationDate: nil
        ))
        try await Task.sleep(for: .milliseconds(40))
        try clamshell.writeImmediately(Document(
            url: url, children: [], modificationDate: nil
        ))
        try await clamshell.purgeHash(block.atomicHash, in: "p.md")
        try await Task.sleep(for: .milliseconds(40))

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
        try clamshell.writeImmediately(Document(
            url: url,
            children: [doomed],
            modificationDate: nil
        ))
        try await Task.sleep(for: .milliseconds(40))
        try clamshell.writeImmediately(Document(
            url: url, children: [], modificationDate: nil
        ))
        try await clamshell.purgeHash(doomed.atomicHash, in: "p.md")
        try await Task.sleep(for: .milliseconds(40))

        // It's now purged.
        let purgedBefore = await clamshell.listPurgedBlocks(
            filter: .page(relativePath: "p.md"),
            since: nil
        )
        #expect(purgedBefore.count == 1)
        let entry = try #require(purgedBefore.first)

        // Sleep across a ms boundary so the reAdd timestamp beats the purge.
        try await Task.sleep(for: .milliseconds(20))
        let block = Block.paragraph(text: attr("doomed"))
        try await clamshell.unpurgeBlock(block, in: "p.md", parentHash: entry.parentHash)

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

        try await log.record(page: "p.md", blocks: [
            .paragraph(text: attr("first")),
            .paragraph(text: attr("second"))
        ])
        try await log.record(page: "p.md", blocks: [
            .paragraph(text: attr("first")),
            .paragraph(text: attr("second")),
            .paragraph(text: attr("third"))
        ])

        let url = deviceLogURL(workspace: root, page: "p.md", deviceID: "dev-A")
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let counters = lines.compactMap { line -> UInt64? in
            guard let data = String(line).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return (obj["c"] as? UInt64) ?? (obj["c"] as? Int).flatMap { UInt64(exactly: $0) }
        }
        #expect(counters.count == 3, "three add records")
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
        try clamshell.writeImmediately(Document(
            url: url, children: [block], modificationDate: nil
        ))
        try await Task.sleep(for: .milliseconds(40))
        try clamshell.writeImmediately(Document(
            url: url, children: [], modificationDate: nil
        ))
        try await clamshell.purgeHash(block.atomicHash, in: "p.md")
        try await Task.sleep(for: .milliseconds(40))

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
        try clamshell.writeImmediately(Document(
            url: url, children: [], modificationDate: nil
        ))
        try await Task.sleep(for: .milliseconds(40))

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
        try await clamshell.purgeHash(h, in: "p.md")
        try await Task.sleep(for: .milliseconds(40))

        let lost = await clamshell.listLostBlocks(filter: .page(relativePath: "p.md"))
        #expect(!lost.contains(where: { $0.hash == h }),
                "modern purge (with c) wins over legacy add (no c) regardless of t")
    }
}
