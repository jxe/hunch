import Testing
import Foundation
@testable import Hunch
import Editor

/// Commit-time save model: every `commit(_:to:)` applies the log entries
/// (when non-empty) and writes the .md atomically per call. Calls for the
/// same URL chain so concurrent commits land in order, and the top-level
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
        let doc = Document(url: clamshell.url(for: "p.md"), children: [v0])

        // Initial insert (e.g. user created the block). This drives a save +
        // log apply.
        try await clamshell.commit(
            .fromEditorOps([.insert(hash: v0.atomicHash, parent: nil, block: v0)]),
            to: doc
        )

        // Simulate typing: the editor's textBinding setter updates the model.
        let v1 = Block(id: id, kind: .paragraph(text: attr("hello world")))
        doc.replaceChildren([v1])

        // Editor's `commitLiveText` (blur, focus change, navigation, scenePhase,
        // mutate) opens a transaction whose pre→post diff fires onCommit.
        try await clamshell.commit(
            .fromEditorOps([
                .remove(hash: v0.atomicHash),
                .insert(hash: v1.atomicHash, parent: nil, block: v1)
            ]),
            to: doc
        )

        // 1. .md reflects the latest commit.
        let mdText = try String(contentsOf: doc.url, encoding: .utf8)
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
        let doc = Document(url: clamshell.url(for: "p.md"), children: [block])

        try await clamshell.commit(Commit(logEntries: []), to: doc)

        #expect(FileManager.default.fileExists(atPath: doc.url.path), "empty log entries should still save the .md")
        let mdText = try String(contentsOf: doc.url, encoding: .utf8)
        #expect(mdText.contains("body"))
    }

    /// A burst of commits for the same URL chain — each waits for the
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
        let doc = Document(url: clamshell.url(for: "p.md"), children: [v0])

        let t1 = Task { @MainActor in
            try await clamshell.commit(
                .fromEditorOps([.insert(hash: v0.atomicHash, parent: nil, block: v0)]),
                to: doc
            )
        }
        doc.replaceChildren([v1])
        let t2 = Task { @MainActor in
            try await clamshell.commit(
                .fromEditorOps([.remove(hash: v0.atomicHash),
                                .insert(hash: v1.atomicHash, parent: nil, block: v1)]),
                to: doc
            )
        }
        doc.replaceChildren([v2])
        let t3 = Task { @MainActor in
            try await clamshell.commit(
                .fromEditorOps([.remove(hash: v1.atomicHash),
                                .insert(hash: v2.atomicHash, parent: nil, block: v2)]),
                to: doc
            )
        }

        _ = try await t1.value
        _ = try await t2.value
        _ = try await t3.value
        await clamshell.flush(doc)

        let mdText = try String(contentsOf: doc.url, encoding: .utf8)
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
        let doc = Document(url: clamshell.url(for: "p.md"), children: [block])

        #expect(clamshell.isQuiescent(at: doc.url), "no commits fired yet")
        await clamshell.flush(doc)
        #expect(!FileManager.default.fileExists(atPath: doc.url.path),
                "flush does not trigger a save on a quiescent URL")
    }
}
