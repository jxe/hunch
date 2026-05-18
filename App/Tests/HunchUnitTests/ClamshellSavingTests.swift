import Testing
import Foundation
@testable import Hunch
import Editor

/// Commit-time save model: every `documentDidChange(ops:in:)` applies the
/// patch to the log (when non-empty) and writes the .md atomically per call.
/// Calls for the same URL chain so concurrent commits land in order, and
/// `flush(_:)` drains pending work before returning. These tests pin the
/// invariants that matter: typing-driven hash changes reach the journal as
/// purge+add, the .md content matches the latest commit, and reconcile
/// against the resulting journal does NOT resurrect prior versions.
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
    /// The afterCommit hook produces a `(.remove(old), .insert(new))` op pair.
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
        clamshell.documentDidChange(
            ops: [.insert(hash: v0.atomicHash, parent: nil, block: v0)],
            in: doc
        )
        _ = await clamshell.flush(doc)

        // Simulate typing: the editor's textBinding setter updates the model.
        let v1 = Block(id: id, kind: .paragraph(text: attr("hello world")))
        doc.replaceChildren([v1])

        // afterCommit fires at the next commitLiveText (blur, focus change,
        // navigation, scenePhase, mutate) and emits the typing diff.
        clamshell.documentDidChange(
            ops: [
                .remove(hash: v0.atomicHash),
                .insert(hash: v1.atomicHash, parent: nil, block: v1)
            ],
            in: doc
        )
        _ = await clamshell.flush(doc)

        // 1. .md reflects the latest commit.
        let mdText = try String(contentsOf: doc.url, encoding: .utf8)
        #expect(mdText.contains("hello world"))

        // 2. Journal: v0 tombstoned, v1 alive.
        let journal = clamshell.log.readJournal(page: "p.md")
        let intent = PatchEngine.intent(from: journal)
        if case .tombstoned = intent.status(of: v0.atomicHash) {
            // expected
        } else {
            Issue.record("expected v0 hash tombstoned after typing commit, got \(String(describing: intent.status(of: v0.atomicHash)))")
        }
        if case .alive = intent.status(of: v1.atomicHash) {
            // expected
        } else {
            Issue.record("expected v1 hash alive, got \(String(describing: intent.status(of: v1.atomicHash)))")
        }

        // 3. Reconcile against the current doc must not auto-restore v0.
        let recon = PatchEngine.reconcile(intent: intent, doc: doc.children)
        #expect(recon.inserts.isEmpty, "no subtrees should auto-restore after typing commit")
        #expect(recon.restoredHashes.isEmpty)
    }

    /// Empty ops still save the .md — used by reconcile / restore paths that
    /// mutate `doc` in place and need the file rewritten without an extra log
    /// entry.
    @Test func emptyOpsStillWritesTheMarkdown() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)

        let block = Block.paragraph(text: attr("body"))
        let doc = Document(url: clamshell.url(for: "p.md"), children: [block])

        clamshell.documentDidChange(ops: [], in: doc)
        _ = await clamshell.flush(doc)

        #expect(FileManager.default.fileExists(atPath: doc.url.path), "empty ops should still save the .md")
        let mdText = try String(contentsOf: doc.url, encoding: .utf8)
        #expect(mdText.contains("body"))
    }

    /// A burst of commits for the same URL chain — each waits for the
    /// previous to land before its own log + .md write. After draining via
    /// flush, the .md reflects the final commit (not a half-written
    /// intermediate state) and the journal has every batch's records.
    @Test func rapidCommitsLandInOrderAndFlushDrains() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)

        let id = BlockID()
        let v0 = Block(id: id, kind: .paragraph(text: attr("a")))
        let v1 = Block(id: id, kind: .paragraph(text: attr("ab")))
        let v2 = Block(id: id, kind: .paragraph(text: attr("abc")))
        let doc = Document(url: clamshell.url(for: "p.md"), children: [v0])

        clamshell.documentDidChange(
            ops: [.insert(hash: v0.atomicHash, parent: nil, block: v0)],
            in: doc
        )
        doc.replaceChildren([v1])
        clamshell.documentDidChange(
            ops: [.remove(hash: v0.atomicHash),
                  .insert(hash: v1.atomicHash, parent: nil, block: v1)],
            in: doc
        )
        doc.replaceChildren([v2])
        clamshell.documentDidChange(
            ops: [.remove(hash: v1.atomicHash),
                  .insert(hash: v2.atomicHash, parent: nil, block: v2)],
            in: doc
        )

        _ = await clamshell.flush(doc)

        let mdText = try String(contentsOf: doc.url, encoding: .utf8)
        #expect(mdText.contains("abc"), "final .md reflects last commit")

        let intent = PatchEngine.intent(from: clamshell.log.readJournal(page: "p.md"))
        if case .alive = intent.status(of: v2.atomicHash) {} else {
            Issue.record("v2 hash should be alive")
        }
        if case .tombstoned = intent.status(of: v1.atomicHash) {} else {
            Issue.record("v1 hash should be tombstoned")
        }
        if case .tombstoned = intent.status(of: v0.atomicHash) {} else {
            Issue.record("v0 hash should be tombstoned")
        }
    }

    /// Flush on a quiescent URL is a no-op: nothing pending → nothing to
    /// drain. The model is "every commit writes" — if you want bytes on
    /// disk, call `documentDidChange` (or open the page, which loads from
    /// disk in the first place). Flush is only for *awaiting* in-flight
    /// writes, not for triggering a save.
    @Test func flushOnQuiescentURLIsNoop() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)

        let block = Block.paragraph(text: attr("standalone"))
        let doc = Document(url: clamshell.url(for: "p.md"), children: [block])

        #expect(clamshell.isQuiescent(at: doc.url), "no commits fired yet")
        let ok = await clamshell.flush(doc)
        #expect(ok, "flush on quiescent URL returns true (nothing to await)")
        #expect(!FileManager.default.fileExists(atPath: doc.url.path),
                "flush does not trigger a save on a quiescent URL")
    }
}
