import Testing
import Foundation
@testable import Hunch
import Editor

/// Pure tests for the recovery-log engine. Build a `LogJournal` as a value
/// (no filesystem), call `PatchEngine.intent` / `reconcile`, assert on
/// the result. The engine has no I/O, no actors, and no async — these tests
/// run synchronously and deterministically.
@Suite("PatchEngine")
struct PatchEngineTests {
    private func attr(_ s: String) -> AttributedString { AttributedString(s) }

    private func addRecord(
        _ block: Block,
        parent: Block? = nil,
        counter: UInt64? = nil,
        t: TimeInterval = 1
    ) -> LogRecord {
        .add(
            counter: counter,
            hash: block.atomicHash,
            parent: parent?.atomicHash,
            markdown: BlockSerializer.serializeAtomic(block),
            t: t
        )
    }

    private func purgeRecord(
        _ block: Block,
        counter: UInt64? = nil,
        t: TimeInterval = 1
    ) -> LogRecord {
        .purge(counter: counter, hash: block.atomicHash, t: t)
    }

    private func journal(_ pairs: (String, [LogRecord])...) -> LogJournal {
        LogJournal(devices: pairs.map { DeviceLog(deviceID: $0.0, records: $0.1) })
    }

    // MARK: - Plan scenarios

    /// Plan #2: empty doc + `add(X)` → X is restored at top-level.
    @Test func addAloneRestoresIntoEmptyDoc() {
        let x = Block.paragraph(text: attr("X"))
        let intent = PatchEngine.intent(from: journal(("dev-A", [addRecord(x, counter: 1)])))
        let recon = PatchEngine.reconcile(intent: intent, doc: [])

        #expect(recon.inserts.count == 1)
        #expect(recon.inserts.first?.parent == nil, "no live ancestor → top-level")
        #expect(recon.inserts.first?.coveredHashes == [x.atomicHash])
        #expect(recon.restoredHashes == [x.atomicHash])
        #expect(recon.didChange)
    }

    /// Plan #3: `add(X)` then `purge(X)` → X stays absent from reconciliation.
    @Test func purgeAfterAddSuppressesRestore() {
        let x = Block.paragraph(text: attr("X"))
        let intent = PatchEngine.intent(from: journal(("dev-A", [
            addRecord(x, counter: 1),
            purgeRecord(x, counter: 2),
        ])))
        let recon = PatchEngine.reconcile(intent: intent, doc: [])

        #expect(recon.inserts.isEmpty)
        #expect(recon.didChange == false)
    }

    /// Plan #4: `add(X)`, `purge(X)`, `add(X)` → X is restored (latest wins).
    @Test func reAddAfterPurgeRestoresAgain() {
        let x = Block.paragraph(text: attr("X"))
        let intent = PatchEngine.intent(from: journal(("dev-A", [
            addRecord(x, counter: 1),
            purgeRecord(x, counter: 2),
            addRecord(x, counter: 3),
        ])))
        let recon = PatchEngine.reconcile(intent: intent, doc: [])

        #expect(recon.inserts.count == 1)
    }

    /// Plan #6: two devices add X under different parents, higher counter
    /// wins for `parentOf`.
    @Test func parentOfTracksLatestAddAcrossDevices() {
        let p = Block.heading(level: .h1, text: attr("P"))
        let q = Block.heading(level: .h1, text: attr("Q"))
        let x = Block.paragraph(text: attr("X"))
        let intent = PatchEngine.intent(from: journal(
            ("dev-A", [addRecord(x, parent: p, counter: 1)]),
            ("dev-B", [addRecord(x, parent: q, counter: 2)])
        ))

        #expect(intent.parent(of: x.atomicHash) == q.atomicHash)
    }

    /// Plan #7: recorded parent is tombstoned and not in doc → chain
    /// climb exhausts → restored at top-level.
    @Test func staleParentFallsBackToTopLevel() {
        let p = Block.heading(level: .h1, text: attr("P"))
        let q = Block.heading(level: .h1, text: attr("Q"))
        let x = Block.paragraph(text: attr("X"))
        let intent = PatchEngine.intent(from: journal(("dev-A", [
            addRecord(p, counter: 1),
            addRecord(x, parent: p, counter: 2),
            purgeRecord(p, counter: 3),
        ])))
        // Doc has Q (live); P is tombstoned and not in doc; X is alive
        // intent but missing → fall back to top-level.
        let recon = PatchEngine.reconcile(intent: intent, doc: [q])

        #expect(recon.inserts.count == 1)
        #expect(recon.inserts.first?.parent == nil)
    }

    /// Plan #9: reconcile is idempotent — applying the result, then
    /// re-running reconcile, produces no further changes.
    @Test func reconcileIsIdempotent() {
        let x = Block.paragraph(text: attr("X"))
        let y = Block.paragraph(text: attr("Y"))
        let intent = PatchEngine.intent(from: journal(("dev-A", [
            addRecord(x, counter: 1),
            addRecord(y, counter: 2),
        ])))
        let first = PatchEngine.reconcile(intent: intent, doc: [])
        #expect(first.inserts.count == 2)

        // Mock applying the inserts: they're top-level → the new doc is
        // the list of subtrees.
        let doc1 = first.inserts.map(\.subtree)
        let second = PatchEngine.reconcile(intent: intent, doc: doc1)
        #expect(second.inserts.isEmpty)
        #expect(second.didChange == false)
    }

    // MARK: - Recent-bug regression tests

    /// `ba52635` (re-fire loop): once a block is in the doc, re-running
    /// reconcile with the same journal does not re-insert it.
    @Test func reFireLoopDoesNotResurrectAlreadyRestoredBlock() {
        let x = Block.paragraph(text: attr("X"))
        let intent = PatchEngine.intent(from: journal(("dev-A", [addRecord(x, counter: 1)])))
        let r1 = PatchEngine.reconcile(intent: intent, doc: [])
        let doc = r1.inserts.map(\.subtree)
        // Simulate file-presenter wakeup: same journal, doc now contains X.
        let r2 = PatchEngine.reconcile(intent: intent, doc: doc)

        #expect(r2.inserts.isEmpty)
    }

    /// `1232b3d` (ever-tombstoned should NOT poison-pill the latest add):
    /// a third device's later add restores the block, even though an
    /// earlier device purged it.
    @Test func laterAddOverridesPriorPurgeInUnion() {
        let x = Block.paragraph(text: attr("X"))
        let intent = PatchEngine.intent(from: journal(
            ("dev-A", [addRecord(x, counter: 1)]),
            ("dev-B", [purgeRecord(x, counter: 2)]),
            ("dev-C", [addRecord(x, counter: 3)])
        ))
        let recon = PatchEngine.reconcile(intent: intent, doc: [])

        #expect(recon.inserts.count == 1, "latest record is add → alive intent → restored")
    }

    /// Inverse of the above: an even-later purge takes precedence.
    @Test func higherCounterPurgeBeatsLowerCounterAdd() {
        let x = Block.paragraph(text: attr("X"))
        let intent = PatchEngine.intent(from: journal(
            ("dev-A", [addRecord(x, counter: 1)]),
            ("dev-B", [purgeRecord(x, counter: 2)]),
            ("dev-C", [addRecord(x, counter: 3)]),
            ("dev-D", [purgeRecord(x, counter: 4)])
        ))
        let recon = PatchEngine.reconcile(intent: intent, doc: [])

        #expect(recon.inserts.isEmpty)
    }

    /// `a020bde` (Lamport over wall-clock): the device with the higher
    /// counter wins, regardless of clock skew.
    @Test func lamportCounterBeatsWallClockTimestamp() throws {
        let x = Block.paragraph(text: attr("X"))
        let intent = PatchEngine.intent(from: journal(
            ("dev-A", [addRecord(x, counter: 1, t: 1_000_000_000)]),
            ("dev-B", [purgeRecord(x, counter: 2, t: 1)])
        ))
        let status = try #require(intent.byHash[x.atomicHash])
        if case .alive = status {
            Issue.record("Expected tombstoned (higher counter wins over wall clock)")
        }
    }

    /// Modern records (with counter) strictly succeed legacy ones (no
    /// counter), regardless of wall-clock timestamp.
    @Test func legacyRecordsLoseToModernRegardlessOfTimestamp() throws {
        let x = Block.paragraph(text: attr("X"))
        let intent = PatchEngine.intent(from: journal(
            ("dev-A", [addRecord(x, counter: nil, t: 999_999_999)]),
            ("dev-B", [purgeRecord(x, counter: 1, t: 1)])
        ))
        let status = try #require(intent.byHash[x.atomicHash])
        if case .alive = status {
            Issue.record("Expected tombstoned (modern record beats legacy)")
        }
    }

    /// Tie-break by deviceID lex when counters are equal.
    @Test func deviceIDBreaksTieOnEqualCounters() throws {
        let x = Block.paragraph(text: attr("X"))
        let intent = PatchEngine.intent(from: journal(
            ("dev-A", [addRecord(x, counter: 5)]),
            ("dev-Z", [purgeRecord(x, counter: 5)])
        ))
        let status = try #require(intent.byHash[x.atomicHash])
        if case .alive = status {
            Issue.record("Expected tombstoned (dev-Z > dev-A on lex)")
        }
    }

    // MARK: - Forest assembly + ancestor climb

    /// Parent + child both alive in intent → one nested insert (not two
    /// flat siblings).
    @Test func parentAndChildAssembleAsOneRoot() throws {
        let parent = Block.heading(level: .h1, text: attr("P"))
        let child = Block.paragraph(text: attr("C"))
        let intent = PatchEngine.intent(from: journal(("dev-A", [
            addRecord(parent, counter: 1),
            addRecord(child, parent: parent, counter: 2),
        ])))
        let recon = PatchEngine.reconcile(intent: intent, doc: [])

        #expect(recon.inserts.count == 1)
        let insert = try #require(recon.inserts.first)
        #expect(insert.subtree.children.count == 1, "child nested under parent")
        #expect(insert.coveredHashes == [parent.atomicHash, child.atomicHash])
    }

    /// Parent alive in doc, child alive in intent + missing → child
    /// inserted under the live parent's BlockID.
    @Test func childAttachesToLiveAncestor() {
        let parent = Block.heading(level: .h1, text: attr("P"))
        let child = Block.paragraph(text: attr("C"))
        let intent = PatchEngine.intent(from: journal(("dev-A", [
            addRecord(parent, counter: 1),
            addRecord(child, parent: parent, counter: 2),
        ])))
        let recon = PatchEngine.reconcile(intent: intent, doc: [parent])

        #expect(recon.inserts.count == 1)
        #expect(recon.inserts.first?.parent == parent.id)
    }

    /// Grandchild whose immediate parent is tombstoned climbs to the
    /// grandparent (still alive in doc).
    @Test func chainClimbsThroughTombstonedAncestor() {
        let grand = Block.heading(level: .h1, text: attr("G"))
        let mid = Block.heading(level: .h2, text: attr("M"))
        let leaf = Block.paragraph(text: attr("L"))
        let intent = PatchEngine.intent(from: journal(("dev-A", [
            addRecord(grand, counter: 1),
            addRecord(mid, parent: grand, counter: 2),
            addRecord(leaf, parent: mid, counter: 3),
            purgeRecord(mid, counter: 4),
        ])))
        // Doc has only grand (live); mid is tombstoned and absent; leaf is
        // alive intent but missing → chain climb finds grand.
        let recon = PatchEngine.reconcile(intent: intent, doc: [grand])

        #expect(recon.inserts.count == 1)
        #expect(recon.inserts.first?.parent == grand.id)
    }

    // MARK: - IntentState query helpers

    @Test func tombstonesEnumeratesPurgedHashes() {
        let p = Block.heading(level: .h1, text: attr("P"))
        let x = Block.paragraph(text: attr("X"))
        let intent = PatchEngine.intent(from: journal(("dev-A", [
            addRecord(p, counter: 1),
            addRecord(x, parent: p, counter: 2),
            purgeRecord(p, counter: 3),
        ])))

        #expect(intent.tombstones() == [p.atomicHash])
    }

    @Test func lostEntriesListsAliveMissingFromLiveSet() {
        let alive = Block.paragraph(text: attr("alive"))
        let missing = Block.paragraph(text: attr("missing"))
        let intent = PatchEngine.intent(from: journal(("dev-A", [
            addRecord(alive, counter: 1),
            addRecord(missing, counter: 2),
        ])))

        let lost = intent.lostEntries(notIn: [alive.atomicHash], source: "p.md")

        #expect(lost.count == 1)
        #expect(lost.first?.hash == missing.atomicHash)
        #expect(lost.first?.source == "p.md")
    }

    // MARK: - Bare-md / external-edit absorption (Phase 2)

    /// Plan #1: empty journal + non-empty doc → observations for every
    /// block, no inserts. This is bare-md import — opening a `.md` file
    /// with no `.history/` produces the seed observations that lift its
    /// content into the journal on first reconcile.
    @Test func bareMdProducesObservationsForEveryBlock() {
        let a = Block.paragraph(text: attr("A"))
        let b = Block.paragraph(text: attr("B"))
        let c = Block.paragraph(text: attr("C"))
        let intent = PatchEngine.intent(from: LogJournal.empty)

        let recon = PatchEngine.reconcile(intent: intent, doc: [a, b, c])

        #expect(recon.inserts.isEmpty)
        #expect(recon.toAppend.count == 3)
        #expect(recon.toAppend.map(\.hash) == [a.atomicHash, b.atomicHash, c.atomicHash])
        #expect(recon.toAppend.allSatisfy { $0.parent == nil })
    }

    /// Plan #8: doc has [A, B, C, NEW], journal has [A, B, C] → one
    /// observation for NEW, no inserts. External-editor scenario where a
    /// foreign markdown tool wrote a block we haven't logged yet.
    @Test func externalEditAbsorbsOnlyTheNewBlock() throws {
        let a = Block.paragraph(text: attr("A"))
        let b = Block.paragraph(text: attr("B"))
        let c = Block.paragraph(text: attr("C"))
        let new = Block.paragraph(text: attr("NEW"))
        let intent = PatchEngine.intent(from: journal(("dev-A", [
            addRecord(a, counter: 1),
            addRecord(b, counter: 2),
            addRecord(c, counter: 3),
        ])))

        let recon = PatchEngine.reconcile(intent: intent, doc: [a, b, c, new])

        #expect(recon.inserts.isEmpty)
        #expect(recon.toAppend.count == 1)
        let obs = try #require(recon.toAppend.first)
        #expect(obs.hash == new.atomicHash)
        #expect(obs.parent == nil)
    }

    /// Observations preserve parent hashes for nested doc structure.
    @Test func observationsRecordRecursiveParentHashes() throws {
        let parent = Block.heading(level: .h1, text: attr("P"))
        let child = Block.paragraph(text: attr("C"))
        let nested = parent.withChildren([child])
        let intent = PatchEngine.intent(from: LogJournal.empty)

        let recon = PatchEngine.reconcile(intent: intent, doc: [nested])

        #expect(recon.toAppend.count == 2)
        let parentObs = try #require(recon.toAppend.first { $0.hash == parent.atomicHash })
        let childObs = try #require(recon.toAppend.first { $0.hash == child.atomicHash })
        #expect(parentObs.parent == nil)
        #expect(childObs.parent == parent.atomicHash)
    }

    /// Idempotence including absorption: once toAppend has been written
    /// back to the journal, a second reconcile against that updated journal
    /// produces zero toAppend (and still zero inserts).
    @Test func reconcileIsIdempotentIncludingAbsorption() {
        let a = Block.paragraph(text: attr("A"))
        let b = Block.paragraph(text: attr("B"))

        let firstIntent = PatchEngine.intent(from: LogJournal.empty)
        let first = PatchEngine.reconcile(intent: firstIntent, doc: [a, b])
        #expect(first.toAppend.count == 2)
        #expect(first.inserts.isEmpty)

        // Simulate appending the observations to dev-A's log, then re-read.
        let appendedRecords: [LogRecord] = first.toAppend.enumerated().map { idx, obs in
            .add(
                counter: UInt64(idx + 1),
                hash: obs.hash,
                parent: obs.parent,
                markdown: obs.markdown,
                t: 1
            )
        }
        let secondIntent = PatchEngine.intent(from: journal(("dev-A", appendedRecords)))
        let second = PatchEngine.reconcile(intent: secondIntent, doc: [a, b])

        #expect(second.toAppend.isEmpty)
        #expect(second.inserts.isEmpty)
        #expect(second.didChange == false)
    }

    /// Blocks logged by a peer device are NOT re-observed by us — the
    /// engine checks intent (the union), not just our own log.
    @Test func peerDeviceObservationsArentDuplicated() {
        let a = Block.paragraph(text: attr("A"))
        // dev-B logged A; we (dev-A) are reconciling for the first time.
        let intent = PatchEngine.intent(from: journal(("dev-B", [addRecord(a, counter: 1)])))

        let recon = PatchEngine.reconcile(intent: intent, doc: [a])

        #expect(recon.toAppend.isEmpty, "intent already covers A via dev-B; no need for us to re-log")
        #expect(recon.inserts.isEmpty)
    }

    // MARK: - Phase 3 defense: hash-mismatch quarantine

    /// Recorded markdown won't parse → mark unrestorable so the
    /// orchestrator can purge the hash and stop the reconcile path from
    /// firing on it forever.
    @Test func malformedMarkdownGoesToUnrestorable() throws {
        let badHash = String(repeating: "f", count: 64)
        let intent = IntentState(byHash: [
            badHash: .alive(latestAdd: .init(
                parent: nil,
                markdown: "",
                recordedAt: Date()
            ))
        ])
        let recon = PatchEngine.reconcile(intent: intent, doc: [])

        #expect(recon.inserts.isEmpty)
        #expect(recon.unrestorable.count == 1)
        let entry = try #require(recon.unrestorable.first)
        #expect(entry.hash == badHash)
        if case .parseFailure = entry.reason {} else {
            Issue.record("expected .parseFailure, got \(entry.reason)")
        }
    }

    /// Recorded markdown parses fine, but the parsed block's `atomicHash`
    /// doesn't match the recorded hash → unrestorable. Inserting anyway
    /// would re-fire reconcile forever (doc gets a block with a different
    /// hash than intent expects).
    @Test func hashMismatchOnRoundTripGoesToUnrestorable() throws {
        let realBlock = Block.paragraph(text: attr("real content"))
        let fakeHash = String(repeating: "0", count: 64)
        let intent = IntentState(byHash: [
            fakeHash: .alive(latestAdd: .init(
                parent: nil,
                markdown: BlockSerializer.serializeAtomic(realBlock),
                recordedAt: Date()
            ))
        ])
        let recon = PatchEngine.reconcile(intent: intent, doc: [])

        #expect(recon.inserts.isEmpty)
        #expect(recon.unrestorable.count == 1)
        let entry = try #require(recon.unrestorable.first)
        #expect(entry.hash == fakeHash)
        if case .hashMismatch(let actual, let kind) = entry.reason {
            #expect(actual == realBlock.atomicHash)
            #expect(kind == "paragraph")
        } else {
            Issue.record("expected .hashMismatch, got \(entry.reason)")
        }
    }

    // MARK: - Observe op semantics

    private func observeRecord(
        _ block: Block,
        parent: Block? = nil,
        counter: UInt64? = nil,
        t: TimeInterval = 1
    ) -> LogRecord {
        .observe(
            counter: counter,
            hash: block.atomicHash,
            parent: parent?.atomicHash,
            markdown: BlockSerializer.serializeAtomic(block),
            t: t
        )
    }

    /// `observe` alone produces `.observed`, not `.alive`. The block is
    /// in the intent (so we don't re-observe it), but it is NOT eligible
    /// for auto-restore — the engine can't claim authorship from a
    /// non-authoritative record.
    @Test func observeAloneIsObservedNotAlive() {
        let x = Block.paragraph(text: attr("X"))
        let intent = PatchEngine.intent(from: journal(("dev-A", [observeRecord(x, counter: 1)])))

        guard case .observed(let snapshot) = intent.byHash[x.atomicHash] else {
            Issue.record("expected .observed, got \(String(describing: intent.byHash[x.atomicHash]))")
            return
        }
        #expect(snapshot.markdown == BlockSerializer.serializeAtomic(x))

        let recon = PatchEngine.reconcile(intent: intent, doc: [])
        #expect(recon.inserts.isEmpty, "observe alone is never auto-restored")
        #expect(recon.didChange == false)
    }

    /// `observe` then later `add` → `.alive`. Authorship was eventually
    /// claimed; auto-restore becomes eligible again.
    @Test func addAfterObservePromotesToAlive() {
        let x = Block.paragraph(text: attr("X"))
        let intent = PatchEngine.intent(from: journal(("dev-A", [
            observeRecord(x, counter: 1),
            addRecord(x, counter: 2),
        ])))

        guard case .alive = intent.byHash[x.atomicHash] else {
            Issue.record("expected .alive after add, got \(String(describing: intent.byHash[x.atomicHash]))")
            return
        }
        let recon = PatchEngine.reconcile(intent: intent, doc: [])
        #expect(recon.inserts.count == 1)
    }

    /// `observe` then `purge` → `.tombstoned` with the observe's snapshot
    /// surfaced for the Recover sheet. This is the external-edit recovery
    /// path: vim adds a block, Hunch journals an observe, user deletes in
    /// Hunch — the markdown survives in the tombstone.
    @Test func purgeAfterObserveTombstonesWithSnapshot() throws {
        let x = Block.paragraph(text: attr("X"))
        let intent = PatchEngine.intent(from: journal(("dev-A", [
            observeRecord(x, counter: 1),
            purgeRecord(x, counter: 2),
        ])))

        guard case .tombstoned(let latestAdd, _) = intent.byHash[x.atomicHash] else {
            Issue.record("expected .tombstoned, got \(String(describing: intent.byHash[x.atomicHash]))")
            return
        }
        let snapshot = try #require(latestAdd)
        #expect(snapshot.markdown == BlockSerializer.serializeAtomic(x), "observe snapshot survives the tombstone")
    }

    /// An `observe`-tombstoned hash surfaces in the Recover sheet via the
    /// preserved snapshot, even though no device ever claimed authorship
    /// with an `add`.
    @Test func observeThenPurgeShowsInPurgedEntries() {
        let x = Block.paragraph(text: attr("X"))
        let intent = PatchEngine.intent(from: journal(("dev-A", [
            observeRecord(x, counter: 1),
            purgeRecord(x, counter: 2),
        ])))

        let purged = intent.purgedEntries(notIn: [], source: "p.md", since: nil)
        #expect(purged.count == 1)
        #expect(purged.first?.hash == x.atomicHash)
    }

    /// `observed` hashes don't show up in `lostEntries` — they're not
    /// eligible for auto-restore so they shouldn't be advertised as
    /// "lost" either.
    @Test func observedHashesAreNotLost() {
        let x = Block.paragraph(text: attr("X"))
        let intent = PatchEngine.intent(from: journal(("dev-A", [observeRecord(x, counter: 1)])))

        let lost = intent.lostEntries(notIn: [], source: "p.md")
        #expect(lost.isEmpty, "observe-only hashes aren't lost; they're just snapshots")
    }

    /// Foreign device `observe` records don't trigger re-observation by
    /// us — the intent already covers the hash.
    @Test func observedHashesArentReObserved() {
        let a = Block.paragraph(text: attr("A"))
        let intent = PatchEngine.intent(from: journal(("dev-B", [observeRecord(a, counter: 1)])))

        let recon = PatchEngine.reconcile(intent: intent, doc: [a])

        #expect(recon.toAppend.isEmpty, "intent covers A via dev-B's observe — no need to re-observe")
        #expect(recon.inserts.isEmpty)
    }

    // MARK: - mtime gate on auto-restore

    /// Latest `add` is OLDER than the `.md` mtime → the `.md` has had a
    /// chance to intentionally drop the block (e.g. a foreign device
    /// deleted it and synced the `.md` before its purge log). Trust the
    /// `.md` and don't auto-restore.
    @Test func autoRestoreSuppressedWhenAddOlderThanMd() {
        let x = Block.paragraph(text: attr("X"))
        let addT: TimeInterval = 100
        let mdMtime = Date(timeIntervalSince1970: 200)
        let intent = PatchEngine.intent(from: journal(("dev-A", [addRecord(x, counter: 1, t: addT)])))

        let gated = PatchEngine.reconcile(intent: intent, doc: [], mdMtime: mdMtime)
        let ungated = PatchEngine.reconcile(intent: intent, doc: [], mdMtime: nil)

        #expect(gated.inserts.isEmpty, ".md is newer than the add → trust .md, skip restore")
        #expect(ungated.inserts.count == 1, "without the gate, the engine restores")
    }

    /// Latest `add` is NEWER than the `.md` mtime → crash-recovery shape.
    /// log.apply landed but save() didn't update the `.md` before the
    /// crash; the journal genuinely knows something the `.md` doesn't.
    /// Restore.
    @Test func autoRestoreFiresWhenAddNewerThanMd() {
        let x = Block.paragraph(text: attr("X"))
        let addT: TimeInterval = 200
        let mdMtime = Date(timeIntervalSince1970: 100)
        let intent = PatchEngine.intent(from: journal(("dev-A", [addRecord(x, counter: 1, t: addT)])))

        let recon = PatchEngine.reconcile(intent: intent, doc: [], mdMtime: mdMtime)
        #expect(recon.inserts.count == 1, "add is newer than .md → restore")
    }

    /// `mdMtime: nil` disables the gate (used by tests and manual
    /// recover paths).
    @Test func nilMdMtimeDisablesGate() {
        let x = Block.paragraph(text: attr("X"))
        let intent = PatchEngine.intent(from: journal(("dev-A", [addRecord(x, counter: 1, t: 1)])))

        let recon = PatchEngine.reconcile(intent: intent, doc: [], mdMtime: nil)
        #expect(recon.inserts.count == 1)
    }

    // MARK: - Engine removes (tombstoned-in-doc)

    /// `(tombstoned in journal, present in doc)` → engine emits a
    /// `Remove`. This is the symmetric counterpart to auto-restore: when
    /// a foreign device's purge eventually syncs, doc converges to the
    /// journal's view by dropping the stale block.
    @Test func tombstonedInDocProducesRemove() throws {
        let x = Block.paragraph(text: attr("X"))
        let intent = PatchEngine.intent(from: journal(("dev-A", [
            addRecord(x, counter: 1, t: 100),
            purgeRecord(x, counter: 2, t: 200),
        ])))

        let recon = PatchEngine.reconcile(intent: intent, doc: [x])

        #expect(recon.inserts.isEmpty)
        #expect(recon.removes.count == 1)
        let remove = try #require(recon.removes.first)
        #expect(remove.hash == x.atomicHash)
        #expect(remove.blockID == x.id)
        #expect(recon.didChange)
    }

    /// Tombstoned-not-in-doc → no remove (nothing to strip; already gone).
    @Test func tombstonedNotInDocProducesNoRemove() {
        let x = Block.paragraph(text: attr("X"))
        let intent = PatchEngine.intent(from: journal(("dev-A", [
            addRecord(x, counter: 1),
            purgeRecord(x, counter: 2),
        ])))

        let recon = PatchEngine.reconcile(intent: intent, doc: [])

        #expect(recon.removes.isEmpty)
        #expect(recon.didChange == false)
    }

    /// mtime gate also applies to removes (symmetrically with inserts).
    /// `.md mtime > purge.t` means the `.md` was written *after* the
    /// purge — likely an external re-add (vim'd back in). Don't strip
    /// it out from under the user.
    @Test func removeSuppressedWhenPurgeOlderThanMd() {
        let x = Block.paragraph(text: attr("X"))
        let purgeT: TimeInterval = 100
        let mdMtime = Date(timeIntervalSince1970: 200)
        let intent = PatchEngine.intent(from: journal(("dev-A", [
            addRecord(x, counter: 1, t: 50),
            purgeRecord(x, counter: 2, t: purgeT),
        ])))

        let gated = PatchEngine.reconcile(intent: intent, doc: [x], mdMtime: mdMtime)
        let ungated = PatchEngine.reconcile(intent: intent, doc: [x], mdMtime: nil)

        #expect(gated.removes.isEmpty, ".md is newer than the purge → trust .md, skip remove")
        #expect(ungated.removes.count == 1, "without the gate, the engine removes")
    }

    /// Purge newer than `.md` → remove fires. Mirrors the crash-recovery
    /// case for inserts: the journal knows something the `.md` hasn't
    /// caught up to yet, and we propagate it.
    @Test func removeFiresWhenPurgeNewerThanMd() {
        let x = Block.paragraph(text: attr("X"))
        let mdMtime = Date(timeIntervalSince1970: 100)
        let intent = PatchEngine.intent(from: journal(("dev-A", [
            addRecord(x, counter: 1, t: 50),
            purgeRecord(x, counter: 2, t: 200),
        ])))

        let recon = PatchEngine.reconcile(intent: intent, doc: [x], mdMtime: mdMtime)
        #expect(recon.removes.count == 1, "purge is newer than .md → remove")
    }

    /// `.observed` status never produces a remove (or an insert). It's
    /// a snapshot, not an intent.
    @Test func observedInDocProducesNoRemoveOrInsert() {
        let x = Block.paragraph(text: attr("X"))
        let intent = PatchEngine.intent(from: journal(("dev-A", [observeRecord(x, counter: 1)])))

        let recon = PatchEngine.reconcile(intent: intent, doc: [x])

        #expect(recon.inserts.isEmpty)
        #expect(recon.removes.isEmpty)
        #expect(recon.didChange == false)
    }

    @Test func purgedEntriesRespectSinceWindow() {
        let x = Block.paragraph(text: attr("X"))
        let now = Date()
        let oldPurge = IntentState(byHash: [
            x.atomicHash: .tombstoned(
                latestAdd: .init(parent: nil, markdown: BlockSerializer.serializeAtomic(x), recordedAt: now.addingTimeInterval(-3600)),
                purgedAt: now.addingTimeInterval(-7200)
            )
        ])

        let withCap = oldPurge.purgedEntries(notIn: [], source: "p.md", since: now.addingTimeInterval(-1800))
        let noCap = oldPurge.purgedEntries(notIn: [], source: "p.md", since: nil)

        #expect(withCap.isEmpty, "purge older than the cap is excluded")
        #expect(noCap.count == 1, "nil cap returns everything")
    }
}
