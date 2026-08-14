import Testing
import Foundation
@testable import Hunch
import Editor

/// Commit-time save model: every `commit(_:to:)` applies the log entries
/// (when non-empty) and writes the .md atomically per call. Calls for the
/// same URL coordinator so concurrent commits land in order, and the top-level
/// `await` propagates durability + errors to the caller. These tests pin
/// the invariants that matter: typing-driven hash changes reach the
/// journal as purge+add, the .md content matches the latest commit, and
/// reconcile against the resulting journal does NOT resurrect prior
/// versions.
@Suite("Clamshell commit-time save")
@MainActor
struct ClamshellSavingTests {
    private func makeRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clamshell-save-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func attr(_ s: String) -> AttributedString { AttributedString(s) }

    /// User types in a paragraph block, then commits (blur / navigation / etc.).
    /// The transaction diff produces a `(.remove(old), .insert(new))` op pair.
    /// After flush, the journal must tombstone the old hash and mark the new
    /// alive — reconcile against this state must not auto-restore the prior
    /// version.
    @Test func typingCommitTombstonesPriorHashAndKeepsCurrentAlive() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)

        let id = BlockID()
        let v0 = Block(id: id, kind: .paragraph(text: attr("hello")))
        let doc = Document(id: DocumentID("p"), children: [v0])

        // Initial insert (e.g. user created the block). This drives a save +
        // log apply.
        try await clamshell.commit(
            .fromEditorChanges([.inserted(block: v0, parent: nil)]),
            to: doc,
            at: clamshell.url(for: "p.md")
        )

        // Simulate typing: the editor's textBinding setter updates the model.
        let v1 = Block(id: id, kind: .paragraph(text: attr("hello world")))
        doc.replaceChildrenFromSystemMutation([v1])

        // Editor's `commitLiveText` (blur, focus change, navigation, scenePhase,
        // mutate) opens a transaction whose pre→post diff fires onCommit.
        try await clamshell.commit(
            .fromEditorChanges([
                .removed(block: v0),
                .inserted(block: v1, parent: nil)
            ]),
            to: doc,
            at: clamshell.url(for: "p.md")
        )

        // 1. .md reflects the latest commit.
        let mdText = try String(contentsOf: clamshell.url(for: "p.md"), encoding: .utf8)
        #expect(mdText.contains("hello world"))

        // 2. Journal: v0 tombstoned, v1 alive.
        let journal = clamshell.log.readJournal(page: "p.md")
        let intent = PatchEngine.intent(from: journal)
        if case .tombstoned = intent.byHash[v0.atomicHash] {
            // expected
        } else {
            Issue.record("expected v0 hash tombstoned after typing commit, got \(String(describing: intent.byHash[v0.atomicHash]))")
        }
        if case .alive = intent.byHash[v1.atomicHash] {
            // expected
        } else {
            Issue.record("expected v1 hash alive, got \(String(describing: intent.byHash[v1.atomicHash]))")
        }

        // 3. Reconcile against the current doc must not auto-restore v0.
        let recon = PatchEngine.reconcile(intent: intent, doc: doc.children)
        #expect(recon.inserts.isEmpty, "no subtrees should auto-restore after typing commit")
        #expect(recon.restoredHashes.isEmpty)
    }

    /// Empty log entries still save the .md — used by reconcile / restore
    /// paths that mutate `doc` in place and need the file rewritten
    /// without an extra log entry (pure reorder/move, or a recon with no
    /// observations to record).
    @Test func emptyLogEntriesStillWriteTheMarkdown() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)

        let block = Block.paragraph(text: attr("body"))
        let doc = Document(id: DocumentID("p"), children: [block])

        try await clamshell.commit(
            Commit(logEntries: []),
            to: doc,
            at: clamshell.url(for: "p.md")
        )

        #expect(FileManager.default.fileExists(atPath: clamshell.url(for: "p.md").path), "empty log entries should still save the .md")
        let mdText = try String(contentsOf: clamshell.url(for: "p.md"), encoding: .utf8)
        #expect(mdText.contains("body"))
        #expect(ClamshellPageEnvelope.parse(mdText).stampTrust == .trusted([:]))
    }

    /// A burst of commits for the same URL coordinator — each waits for the
    /// previous to land before its own log + .md write. Fired as
    /// concurrent Tasks (mirrors the host bridge's fire-and-forget
    /// pattern from `persistCommit`); after draining via flush, the .md
    /// reflects the final commit (not a half-written intermediate state)
    /// and the journal has every batch's records.
    @Test func rapidCommitsLandInOrderAndFlushDrains() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)

        let id = BlockID()
        let v0 = Block(id: id, kind: .paragraph(text: attr("a")))
        let v1 = Block(id: id, kind: .paragraph(text: attr("ab")))
        let v2 = Block(id: id, kind: .paragraph(text: attr("abc")))
        let doc = Document(id: DocumentID("p"), children: [v0])

        let t1 = Task { @MainActor in
            try await clamshell.commit(
            .fromEditorChanges([.inserted(block: v0, parent: nil)]),
            to: doc,
            at: clamshell.url(for: "p.md")
            )
        }
        doc.replaceChildrenFromSystemMutation([v1])
        let t2 = Task { @MainActor in
            try await clamshell.commit(
                .fromEditorChanges([.removed(block: v0),
                                    .inserted(block: v1, parent: nil)]),
                to: doc,
                at: clamshell.url(for: "p.md")
            )
        }
        doc.replaceChildrenFromSystemMutation([v2])
        let t3 = Task { @MainActor in
            try await clamshell.commit(
                .fromEditorChanges([.removed(block: v1),
                                    .inserted(block: v2, parent: nil)]),
                to: doc,
                at: clamshell.url(for: "p.md")
            )
        }

        _ = try await t1.value
        _ = try await t2.value
        _ = try await t3.value
        try await clamshell.coordinator(for: clamshell.url(for: "p.md")).flush()

        let mdText = try String(contentsOf: clamshell.url(for: "p.md"), encoding: .utf8)
        #expect(mdText.contains("abc"), "final .md reflects last commit")

        let intent = PatchEngine.intent(from: clamshell.log.readJournal(page: "p.md"))
        if case .alive = intent.byHash[v2.atomicHash] {} else {
            Issue.record("v2 hash should be alive")
        }
        if case .tombstoned = intent.byHash[v1.atomicHash] {} else {
            Issue.record("v1 hash should be tombstoned")
        }
        if case .tombstoned = intent.byHash[v0.atomicHash] {} else {
            Issue.record("v0 hash should be tombstoned")
        }
    }

    /// Flush on a quiescent URL is a no-op: nothing pending → nothing to
    /// drain. The model is "every commit writes" — if you want bytes on
    /// disk, call `commit(_:to:)` (or open the page, which loads from
    /// disk in the first place). Flush is only for *awaiting* in-flight
    /// writes, not for triggering a save.
    @Test func flushOnQuiescentURLIsNoop() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)

        let block = Block.paragraph(text: attr("standalone"))
        let doc = Document(id: DocumentID("p"), children: [block])

        try await clamshell.coordinator(for: clamshell.url(for: "p.md")).flush()
        #expect(!FileManager.default.fileExists(atPath: clamshell.url(for: "p.md").path),
                "flush does not trigger a save on a quiescent URL")
    }

    @Test func diskClassificationIgnoresPeerSyncStampChanges() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)
        let url = clamshell.url(for: "p.md")
        let body = [Block.paragraph(text: attr("same body"))]
        let localEnvelope = ClamshellPageEnvelope.serialize(
            blocks: body,
            existingFrontmatterLines: nil,
            logFrontier: ["mac": 4]
        )
        let peerEnvelope = ClamshellPageEnvelope.serialize(
            blocks: body,
            existingFrontmatterLines: nil,
            logFrontier: ["iphone": 9]
        )

        clamshell.recordDiskContent(localEnvelope, at: url)
        try peerEnvelope.write(to: url, atomically: true, encoding: .utf8)

        #expect(clamshell.classifyDiskContent(at: url) == .echo)

        let changedEnvelope = ClamshellPageEnvelope.serialize(
            blocks: [Block.paragraph(text: attr("actually changed"))],
            existingFrontmatterLines: nil,
            logFrontier: ["iphone": 10]
        )
        try changedEnvelope.write(to: url, atomically: true, encoding: .utf8)
        #expect(clamshell.classifyDiskContent(at: url) == .external)
    }

    @Test func openingSameURLTwiceSharesOneLiveDocument() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)
        let url = clamshell.url(for: "p.md")
        try "# Title\n\nbody\n".write(to: url, atomically: true, encoding: .utf8)

        let first = try await clamshell.page(at: url).open { _ in }
        let second = try await clamshell.page(at: url).open { _ in }

        #expect(first.document === second.document)

        try await first.close()
        try await second.close()
    }

    @Test func stablePageFacadeReopensAfterCoordinatorRetires() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)
        let page = clamshell.page(atPath: "p.md")
        try "# Title\n\nbody\n".write(to: page.url, atomically: true, encoding: .utf8)

        let first = try await page.open { _ in }
        try await first.close()
        #expect(clamshell.pageCoordinators.isEmpty)

        let second = try await page.open { _ in }
        #expect(second.page.url == page.url)
        #expect(second.document.title == "Title")
        try await second.close()
    }

    @Test func sameURLHandlesSaveOneSharedDocumentShape() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)
        let url = clamshell.url(for: "p.md")
        try "# Title\n".write(to: url, atomically: true, encoding: .utf8)

        let first = try await clamshell.page(at: url).open { _ in }
        let second = try await clamshell.page(at: url).open { _ in }
        let doc = first.document
        #expect(doc === second.document)

        let alpha = Block.paragraph(text: attr("alpha"))
        doc.replaceChildrenFromSystemMutation(doc.children + [alpha])
        try await clamshell.commit(
            Commit(logEntries: Patch.adds(from: [alpha]).entries),
            to: first.document,
            at: url
        )

        let beta = Block.paragraph(text: attr("beta"))
        second.document.replaceChildrenFromSystemMutation(second.document.children + [beta])
        try await clamshell.commit(
            Commit(logEntries: Patch.adds(from: [beta]).entries),
            to: second.document,
            at: url
        )

        let mdText = try String(contentsOf: url, encoding: .utf8)
        #expect(mdText.contains("alpha"))
        #expect(mdText.contains("beta"))

        try await first.close()
        try await second.close()
    }

    @Test func pagesFilterReturnsOnlyLocallyWritablePages() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)

        let writable = clamshell.url(for: "Writable.md")
        let locked = clamshell.url(for: "Locked.md")
        try "# Writable\n".write(to: writable, atomically: true, encoding: .utf8)
        try "# Locked\n".write(to: locked, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o444)],
            ofItemAtPath: locked.path
        )

        try clamshell.rescan()

        let all = Set(clamshell.pages(matching: "").map(\.relativePath))
        #expect(all == ["Writable.md", "Locked.md"])

        let writableOnly = clamshell.pages(
            matching: "",
            filter: .locallyAvailableForWrite
        ).map(\.relativePath)
        #expect(writableOnly == ["Writable.md"])
    }

    @Test func appendBlocksWritesClosedDestinationPage() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)

        let targetURL = clamshell.url(for: "Target.md")
        try "# Target\n".write(to: targetURL, atomically: true, encoding: .utf8)

        let moved = Block.paragraph(text: attr("moved body"))
        try await clamshell.page(atPath: "Target.md").append([moved])

        let mdText = try String(contentsOf: targetURL, encoding: .utf8)
        #expect(mdText.contains("Target"))
        #expect(mdText.contains("moved body"))
        let intent = PatchEngine.intent(from: clamshell.log.readJournal(page: "Target.md"))
        if case .alive = intent.byHash[moved.atomicHash] {} else {
            Issue.record("moved block should be alive in destination journal")
        }
    }

    @Test func appendBlocksMutatesLiveDestinationPage() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)

        let targetURL = clamshell.url(for: "Target.md")
        try "# Target\n".write(to: targetURL, atomically: true, encoding: .utf8)
        let open = try await clamshell.page(at: targetURL).open { _ in }

        let moved = Block.paragraph(text: attr("live moved body"))
        try await clamshell.page(atPath: "Target.md").append([moved])

        #expect(open.document.children.contains { $0.id == moved.id })
        let mdText = try String(contentsOf: targetURL, encoding: .utf8)
        #expect(mdText.contains("live moved body"))

        try await open.close()
    }

    @Test func appendBlocksThrowsBeforeCreatingMissingDestination() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)

        let moved = Block.paragraph(text: attr("should not move"))

        await #expect(throws: Clamshell.AppendBlocksError.self) {
            try await clamshell.page(atPath: "Missing.md").append([moved])
        }
        #expect(!FileManager.default.fileExists(atPath: clamshell.url(for: "Missing.md").path))
    }

    @Test func cloudSyncTargetsUsePageAndThisDeviceLogLocations() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)

        let homeURL = clamshell.url(for: "Home.md")
        let rootTargets = clamshell.page(at: homeURL).cloudSyncSnapshot().items.map(\.target)
        #expect(rootTargets.map(\.kind) == [.page, .thisDeviceLog])
        #expect(rootTargets[0].url == homeURL.standardizedFileURL)
        #expect(relativePath(rootTargets[1].url, under: root) == ".history/Home.md/\(DeviceID.current).jsonl")

        let ideasURL = clamshell.url(for: "Projects/Ideas.md")
        let nestedTargets = clamshell.page(at: ideasURL).cloudSyncSnapshot().items.map(\.target)
        #expect(nestedTargets[0].url == ideasURL.standardizedFileURL)
        #expect(relativePath(nestedTargets[1].url, under: root) == ".history/Projects/Ideas.md/\(DeviceID.current).jsonl")
    }

    @Test func cloudSyncCombinedStatusDerivation() {
        #expect(snapshotState([cloudItem(.synced), cloudItem(.synced, kind: .thisDeviceLog)]) == .synced)
        #expect(snapshotState([cloudItem(.synced), cloudItem(.syncing, kind: .thisDeviceLog)]) == .syncing)
        #expect(snapshotState([cloudItem(.synced), cloudItem(.waiting, kind: .thisDeviceLog)]) == .waiting)
        #expect(snapshotState([cloudItem(.synced), cloudItem(.error, kind: .thisDeviceLog)]) == .error)
        #expect(snapshotState([cloudItem(.local), cloudItem(.local, kind: .thisDeviceLog)]) == .local)
        #expect(snapshotState([cloudItem(.synced), cloudItem(.missingNeutral, kind: .thisDeviceLog, exists: false)]) == .synced)
    }

    @Test func cloudSyncSnapshotIncludesFileSizesAndMissingLogHasNoSize() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)

        let block = Block.paragraph(text: attr("sized body"))
        let doc = Document(id: DocumentID("sized"), children: [block])
        let sizedURL = clamshell.url(for: "Sized.md")
        try await clamshell.commit(Commit(logEntries: Patch.adds(from: doc.children).entries), to: doc, at: sizedURL)

        let snapshot = clamshell.page(at: sizedURL).cloudSyncSnapshot()
        let pageItem = try #require(snapshot.items.first { $0.target.kind == .page })
        let logItem = try #require(snapshot.items.first { $0.target.kind == .thisDeviceLog })
        let pageBytes = Int64(try Data(contentsOf: sizedURL).count)
        let logBytes = Int64(try Data(contentsOf: logItem.url).count)
        #expect(pageItem.byteCount == pageBytes)
        #expect(logItem.byteCount == logBytes)
        #expect(logBytes > 0)

        let noLogURL = clamshell.url(for: "NoLog.md")
        try "# No log\n".write(to: noLogURL, atomically: true, encoding: .utf8)
        let missingSnapshot = clamshell.page(at: noLogURL).cloudSyncSnapshot()
        let missingLogItem = try #require(missingSnapshot.items.first { $0.target.kind == .thisDeviceLog })
        #expect(missingLogItem.status == .missingNeutral)
        #expect(missingLogItem.byteCount == nil)
    }

    private func relativePath(_ url: URL, under root: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
    }

    private func cloudItem(
        _ status: Clamshell.CloudSyncItemStatus,
        kind: Clamshell.CloudSyncTargetKind = .page,
        exists: Bool = true
    ) -> Clamshell.CloudSyncItemSnapshot {
        Clamshell.CloudSyncItemSnapshot(
            target: Clamshell.CloudSyncTarget(
                kind: kind,
                url: URL(fileURLWithPath: "/tmp/\(kind.rawValue)"),
                displayName: kind.rawValue
            ),
            exists: exists,
            status: status,
            detail: nil,
            byteCount: nil
        )
    }

    private func snapshotState(_ items: [Clamshell.CloudSyncItemSnapshot]) -> Clamshell.CloudSyncState {
        Clamshell.CloudSyncSnapshot(items: items).state
    }
}

@Suite("Clamshell frontmatter envelope")
struct ClamshellFrontmatterTests {
    private func attr(_ s: String) -> AttributedString { AttributedString(s) }

    @Test func unstampedMarkdownParsesAndSerializesWithTrustedStamp() throws {
        let source = "# Title\n\nBody\n"
        let parsed = ClamshellPageEnvelope.parse(source)

        #expect(parsed.frontmatterLines == nil)
        #expect(parsed.stampTrust == .none)
        #expect(parsed.blocks.count == 1)

        let serialized = ClamshellPageEnvelope.serialize(
            blocks: parsed.blocks,
            existingFrontmatterLines: parsed.frontmatterLines,
            logFrontier: ["dev-A": 42]
        )
        let reparsed = ClamshellPageEnvelope.parse(serialized)
        #expect(BlockSerializer.serialize(reparsed.blocks) == BlockSerializer.serialize(parsed.blocks))
        #expect(reparsed.stampTrust == .trusted(["dev-A": 42]))
        #expect(serialized.contains("clamshell: {\"bodyHash\":\"sha256:"))
        #expect(serialized.contains("\"logFrontier\":{\"dev-A\":42}"))
    }

    @Test func userFrontmatterIsPreservedWhileClamshellIsInsertedAndUpdated() throws {
        let blocks: [Block] = [
            .heading(level: .h1, text: attr("Project")),
            .paragraph(text: attr("notes"))
        ]
        let source = """
        ---
        title: Project
        clamshell: {"v":1,"bodyHash":"sha256:not-it","logFrontier":{"old":1}}
        tags: [draft, sync]
        ---
        # Project

        notes
        """
        let parsed = ClamshellPageEnvelope.parse(source)

        let serialized = ClamshellPageEnvelope.serialize(
            blocks: blocks,
            existingFrontmatterLines: parsed.frontmatterLines,
            logFrontier: ["dev-A": 7, "dev-B": 9]
        )
        let clamshellLineCount = serialized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("clamshell:") }
            .count

        #expect(serialized.contains("title: Project"))
        #expect(serialized.contains("tags: [draft, sync]"))
        #expect(clamshellLineCount == 1)
        #expect(!serialized.contains("sha256:not-it"))
        #expect(ClamshellPageEnvelope.parse(serialized).stampTrust == .trusted(["dev-A": 7, "dev-B": 9]))
    }

    @Test func malformedOrBodyMismatchedStampIsUntrusted() throws {
        let valid = ClamshellPageEnvelope.serialize(
            blocks: [.paragraph(text: attr("original"))],
            existingFrontmatterLines: nil,
            logFrontier: ["dev-A": 1]
        )
        let editedBody = valid.replacingOccurrences(of: "original", with: "externally edited")
        let malformed = """
        ---
        clamshell: definitely-not-json
        ---
        original
        """

        #expect(ClamshellPageEnvelope.parse(valid).stampTrust == .trusted(["dev-A": 1]))
        #expect(ClamshellPageEnvelope.parse(editedBody).stampTrust == .invalid)
        #expect(ClamshellPageEnvelope.parse(malformed).stampTrust == .invalid)
    }
}
