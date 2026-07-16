import Testing
import Foundation
@testable import Hunch
import Editor

/// Pins the synchronous-enqueue contract of the page coordinator: a write
/// generation is installed before `enqueueEditorOps` returns, so `flush` and
/// close-then-trash sequencing cannot overlook a commit between its firing
/// and its bytes landing. Also pins coalescing, ordering, and self-cleanup.
@Suite("PageCoordinator persistence semantics")
@MainActor
struct PageCoordinatorTests {
    private struct LogWire: Encodable {
        let op: String
        let h: String
        let p: String?
        let m: String
        let t: TimeInterval
        let c: UInt64
    }

    private func makeRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("page-coordinator-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func attr(_ s: String) -> AttributedString { AttributedString(s) }

    /// The regression test for the headline bug: after a fire-and-forget
    /// enqueue, the page must immediately read as non-quiescent, and
    /// `flush` must await the write.
    @Test func enqueueIsSynchronouslyVisibleAndFlushAwaitsIt() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)

        let block = Block.paragraph(text: attr("keystroke"))
        let doc = Document(url: clamshell.url(for: "p.md"), children: [block])

        let page = clamshell.coordinator(for: doc)
        page.enqueue(
            .fromEditorOps([.insert(hash: block.atomicHash, parent: nil, block: block)]),
            for: doc
        )
        #expect(page.hasPendingWrite, "enqueue must install the write generation before returning")

        try await page.flush()
        let mdText = try String(contentsOf: doc.url, encoding: .utf8)
        #expect(mdText.contains("keystroke"), "flush must await the enqueued write")
    }

    /// Write entries self-clean when their task finishes — quiescence
    /// must not require a flush to clear a completed-save corpse.
    @Test func completedCommitSelfCleansWithoutFlush() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)

        let block = Block.paragraph(text: attr("body"))
        let doc = Document(url: clamshell.url(for: "p.md"), children: [block])

        let page = clamshell.coordinator(for: doc)
        let task = page.enqueue(Commit(logEntries: []), for: doc)
        try await task.value
        #expect(!page.hasPendingWrite, "a finished coordinator write must clear its own slot")
    }

    /// Two enqueues for the same Document before the first starts fold
    /// into one write entry: same task, both batches' log entries land.
    @Test func rapidEnqueuesForSameDocumentCoalesce() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)

        let a = Block.paragraph(text: attr("alpha"))
        let b = Block.paragraph(text: attr("beta"))
        let doc = Document(url: clamshell.url(for: "p.md"), children: [a, b])

        let page = clamshell.coordinator(for: doc)
        let first = page.enqueue(
            .fromEditorOps([.insert(hash: a.atomicHash, parent: nil, block: a)]),
            for: doc
        )
        let second = page.enqueue(
            .fromEditorOps([.insert(hash: b.atomicHash, parent: nil, block: b)]),
            for: doc
        )
        #expect(first == second, "an un-started tail for the same Document must coalesce")
        #expect(page.currentGeneration == 2)

        try await second.value
        #expect(page.durableGeneration == 2)
        let intent = PatchEngine.intent(from: clamshell.log.readJournal(page: "p.md"))
        if case .alive = intent.byHash[a.atomicHash] {} else {
            Issue.record("first batch's add must survive coalescing")
        }
        if case .alive = intent.byHash[b.atomicHash] {} else {
            Issue.record("second batch's add must survive coalescing")
        }
        let mdText = try String(contentsOf: doc.url, encoding: .utf8)
        #expect(mdText.contains("alpha") && mdText.contains("beta"))
    }

    /// Unawaited enqueues for evolving content land in order: the final
    /// .md reflects the last commit's snapshot.
    @Test func unawaitedEnqueuesLandInOrder() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)

        let id = BlockID()
        let doc = Document(url: clamshell.url(for: "p.md"), children: [])
        let page = clamshell.coordinator(for: doc)
        var lastHash = ""
        for text in ["a", "ab", "abc"] {
            let block = Block(id: id, kind: .paragraph(text: attr(text)))
            doc.replaceChildrenFromSystemMutation([block])
            page.enqueue(
                .fromEditorOps([.insert(hash: block.atomicHash, parent: nil, block: block)]),
                for: doc
            )
            lastHash = block.atomicHash
        }

        try await page.flush()
        let mdText = try String(contentsOf: doc.url, encoding: .utf8)
        #expect(mdText.contains("abc"), "final .md must reflect the last enqueued commit")
        let intent = PatchEngine.intent(from: clamshell.log.readJournal(page: "p.md"))
        if case .alive = intent.byHash[lastHash] {} else {
            Issue.record("last commit's hash must be alive in the journal")
        }
    }

    /// A transient closed-page operation and a subsequently attached editor
    /// share one canonical Document while their lifetimes overlap.
    @Test func transientAndEditorLeasesShareCanonicalDocument() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)

        let url = clamshell.url(for: "p.md")
        try "# P\n\nseed\n".write(to: url, atomically: true, encoding: .utf8)
        let page = clamshell.coordinator(for: url)
        try await page.withTransientDocument { transient in
            let open = try await clamshell.page(at: url).open { _ in }
            #expect(open.document === transient)

            let block = Block.paragraph(text: attr("shared canonical"))
            transient.replaceChildrenFromSystemMutation(transient.children + [block])
            try await clamshell.commit(.fromEditorOps([.insert(hash: block.atomicHash, parent: nil, block: block)]), to: transient)
            try await open.close()
        }

        let mdText = try String(contentsOf: url, encoding: .utf8)
        #expect(mdText.contains("shared canonical"))
    }

    /// Teardown contract: `drain()` awaits unawaited commits and tears
    /// down remaining live pages, so an owner that drains before dropping
    /// its reference can never lose in-flight work.
    @Test func drainAwaitsPendingCommitsAndClosesCoordinators() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)

        let url = clamshell.url(for: "p.md")
        try "# P\n\nseed\n".write(to: url, atomically: true, encoding: .utf8)
        let open = try await clamshell.page(at: url).open { _ in }
        #expect(clamshell.pageCoordinators[url]?.hasEditorSubscribers == true)

        let block = Block.paragraph(text: attr("last keystroke"))
        open.document.replaceChildrenFromSystemMutation(open.document.children + [block])
        open.enqueueEditorOps([.insert(hash: block.atomicHash, parent: nil, block: block)])

        await clamshell.drain()

        let mdText = try String(contentsOf: url, encoding: .utf8)
        #expect(mdText.contains("last keystroke"), "drain must await the pending commit")
        #expect(clamshell.pageCoordinators.isEmpty, "drain must tear down page coordinators")
    }

    /// iCloud may deliver a peer's recovery log before the corresponding
    /// Markdown page. The stale Mac must not reconstruct that record at the
    /// end of its parent and write the reconstruction back; it should leave
    /// the page untouched until the peer Markdown arrives, then refresh with
    /// the peer's exact sibling order.
    @Test func peerLogBeforeMarkdownWaitsForAuthoritativePagePlacement() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)
        let url = clamshell.url(for: "p.md")

        let before = Block.paragraph(text: attr("before"))
        let inserted = Block.paragraph(text: attr("from iPhone"))
        let after = Block.paragraph(text: attr("after"))
        let staleSection = Block.heading(
            level: .h2,
            text: attr("Section"),
            children: [before, after]
        )
        let staleEnvelope = ClamshellPageEnvelope.serialize(
            blocks: [staleSection],
            existingFrontmatterLines: nil,
            logFrontier: ["iphone-peer": 10]
        )
        try staleEnvelope.write(to: url, atomically: true, encoding: .utf8)

        let coordinator = clamshell.coordinator(for: url)
        let document = try await coordinator.materializeDocument()

        let historyDirectory = root
            .appendingPathComponent(RecoveryLog.directoryName, isDirectory: true)
            .appendingPathComponent("p.md", isDirectory: true)
        try FileManager.default.createDirectory(
            at: historyDirectory,
            withIntermediateDirectories: true
        )
        let peerLogURL = historyDirectory.appendingPathComponent("iphone-peer.jsonl")
        let wire = LogWire(
            op: "add",
            h: inserted.atomicHash,
            p: staleSection.atomicHash,
            m: BlockSerializer.serializeAtomic(inserted),
            t: Date().timeIntervalSince1970,
            c: 11
        )
        var logData = try JSONEncoder().encode(wire)
        logData.append(contentsOf: Data("\n".utf8))
        try logData.write(to: peerLogURL)

        let deferred = try await clamshell.reconcileLive(document)
        #expect(deferred?.didChange == false)
        #expect(document.children[0].children.map(\.atomicHash) == [before.atomicHash, after.atomicHash])
        #expect(try String(contentsOf: url, encoding: .utf8) == staleEnvelope)

        let peerSection = Block.heading(
            level: .h2,
            text: attr("Section"),
            children: [before, inserted, after]
        )
        let peerEnvelope = ClamshellPageEnvelope.serialize(
            blocks: [peerSection],
            existingFrontmatterLines: nil,
            logFrontier: ["iphone-peer": 11]
        )
        try peerEnvelope.write(to: url, atomically: true, encoding: .utf8)
        document.modificationDate = .distantPast

        let event = await clamshell.synchronizePage(coordinator, document: document)
        if case .some = event {
            Issue.record("refreshing the peer Markdown should not report an auto-restore")
        }
        #expect(document.children[0].children.map(\.atomicHash) == [
            before.atomicHash,
            inserted.atomicHash,
            after.atomicHash,
        ])
    }
}
