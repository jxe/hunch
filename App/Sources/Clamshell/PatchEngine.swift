import Foundation
import Editor

// MARK: - Journal types
//
// These are pure value types. A `LogJournal` is the engine's input: every
// device's per-page log, side-by-side. The persistence layer (`RecoveryLog`)
// produces journals from disk; the engine never reads files directly.

/// A single record in a per-(device, page) log. Mirrors the on-disk JSONL
/// `Wire` struct in `RecoveryLog`, but as a `Sendable` enum the engine and
/// tests can construct directly without going through the file format.
///
/// Three ops, two flavours:
/// - **Authoritative** (`add`, `purge`) — the device is asserting an intent.
///   `add` claims authorship and makes the hash a valid auto-restore target;
///   `purge` makes it dead.
/// - **Tentative** (`observe`) — the device noticed the block in its `.md`
///   but isn't claiming authorship. Carries the snapshot (markdown + parent)
///   so the Recover sheet can still surface the block if it later goes
///   missing, but does NOT make the hash eligible for auto-restore. Written
///   when reconcile sees a block in `doc` that no device's log has yet —
///   typically because iCloud delivered the foreign device's `.md` before
///   its `.jsonl`. Without `observe`, the engine would either lift (the old
///   bug — synthesize an `add`, then resurrect the block when the foreign
///   device deletes it) or drop the block on the floor (no journal trail
///   for external `vim` edits).
enum LogRecord: Sendable, Hashable {
    case add(counter: UInt64?, hash: String, parent: String?, markdown: String, t: TimeInterval)
    case purge(counter: UInt64?, hash: String, t: TimeInterval)
    case observe(counter: UInt64?, hash: String, parent: String?, markdown: String, t: TimeInterval)

    var hash: String {
        switch self {
        case .add(_, let h, _, _, _): return h
        case .purge(_, let h, _): return h
        case .observe(_, let h, _, _, _): return h
        }
    }

    var counter: UInt64? {
        switch self {
        case .add(let c, _, _, _, _): return c
        case .purge(let c, _, _): return c
        case .observe(let c, _, _, _, _): return c
        }
    }

    var t: TimeInterval {
        switch self {
        case .add(_, _, _, _, let t): return t
        case .purge(_, _, let t): return t
        case .observe(_, _, _, _, let t): return t
        }
    }

    /// `add` and `purge` assert intent and drive `alive`/`tombstoned`.
    /// `observe` only carries a snapshot and doesn't shift status.
    var isAuthoritative: Bool {
        switch self {
        case .add, .purge: return true
        case .observe: return false
        }
    }

    /// `add` and `observe` carry parent + markdown (snapshot of the block at
    /// record time). `purge` does not.
    var carriesSnapshot: Bool {
        switch self {
        case .add, .observe: return true
        case .purge: return false
        }
    }
}

/// One device's per-page log.
struct DeviceLog: Sendable {
    let deviceID: String
    let records: [LogRecord]

    init(deviceID: String, records: [LogRecord]) {
        self.deviceID = deviceID
        self.records = records
    }
}

/// Every device's per-page log, side-by-side. The engine takes a journal in,
/// derives the intent state, and reconciles against the current doc.
struct LogJournal: Sendable {
    let devices: [DeviceLog]

    init(devices: [DeviceLog]) {
        self.devices = devices
    }

    static let empty = LogJournal(devices: [])
}

// MARK: - Patch
//
// A `Patch` is a batch of intent transitions waiting to land on a page's
// recovery log. Editor mutations (`BlockTreeDiff` → adds + purges), engine
// outputs (reconcile's `toAppend` observations + `unrestorable`
// quarantines), and other persistence callers all project to a `Patch`.
// Each entry becomes one log record on disk after `RecoveryLog` mints its
// stamp (counter + deviceID + wall-clock).
//
// Patches are intentionally dumb value types — no counters, no timestamps,
// no device-id. Those are persistence-layer concerns minted at append time.

/// A batch of `add` / `purge` / `observe` entries to be applied to one
/// page's log. See `LogRecord` for the semantic difference between
/// authoritative ops (`add` / `purge`) and tentative (`observe`).
struct Patch: Sendable {
    enum Op: Sendable, Hashable { case add, purge, observe }

    struct Entry: Sendable, Hashable {
        let op: Op
        let hash: String
        /// Parent hash at the moment this entry was authored. Meaningful
        /// for `.add` and `.observe`.
        let parent: String?
        /// Atomic-markdown serialization of the block. Meaningful for
        /// `.add` and `.observe`.
        let markdown: String?

        init(op: Op, hash: String, parent: String? = nil, markdown: String? = nil) {
            self.op = op
            self.hash = hash
            self.parent = parent
            self.markdown = markdown
        }

        static func add(hash: String, parent: String?, markdown: String) -> Entry {
            Entry(op: .add, hash: hash, parent: parent, markdown: markdown)
        }

        static func purge(hash: String) -> Entry {
            Entry(op: .purge, hash: hash)
        }

        static func observe(hash: String, parent: String?, markdown: String) -> Entry {
            Entry(op: .observe, hash: hash, parent: parent, markdown: markdown)
        }
    }

    let entries: [Entry]
    var isEmpty: Bool { entries.isEmpty }

    init(entries: [Entry]) {
        self.entries = entries
    }

    /// Walk a block tree preorder and emit one `.add` entry per block.
    /// A parent's entry precedes its children, so if appended sequentially
    /// each child's recorded `parent` already exists in the log.
    static func adds(from blocks: [Block]) -> Patch {
        var out: [Entry] = []
        walk(blocks, parent: nil, op: .add, into: &out)
        return Patch(entries: out)
    }

    /// Walk a block tree preorder and emit one `.observe` entry per block.
    /// Used when this device sees content from a merge or external source
    /// but should not claim authorship over those hashes.
    static func observations(from blocks: [Block]) -> Patch {
        var out: [Entry] = []
        walk(blocks, parent: nil, op: .observe, into: &out)
        return Patch(entries: out)
    }

    /// Project a batch of editor structural ops onto a Patch: inserts
    /// become `.add` entries, removes become `.purge` entries, order
    /// preserved.
    static func from(ops: [EditorOp]) -> Patch {
        Patch(entries: ops.map { op in
            switch op {
            case .insert(let h, let p, let block):
                return .add(hash: h, parent: p, markdown: BlockSerializer.serializeAtomic(block))
            case .remove(let h):
                return .purge(hash: h)
            }
        })
    }

    private static func walk(_ blocks: [Block], parent: String?, op: Op, into out: inout [Entry]) {
        for block in blocks {
            let h = block.atomicHash
            let markdown = BlockSerializer.serializeAtomic(block)
            switch op {
            case .add:
                out.append(.add(hash: h, parent: parent, markdown: markdown))
            case .observe:
                out.append(.observe(hash: h, parent: parent, markdown: markdown))
            case .purge:
                out.append(.purge(hash: h))
            }
            walk(block.children, parent: h, op: op, into: &out)
        }
    }
}

// MARK: - IntentState

/// Pure derivation of "what does the union of every device's log say about
/// each hash right now?" Computed once per reconciliation pass, then queried
/// many times.
struct IntentState: Sendable {
    struct AddSnapshot: Sendable {
        let parent: String?
        let markdown: String
        let recordedAt: Date
        let counter: UInt64?
        let deviceID: String?

        init(
            parent: String?,
            markdown: String,
            recordedAt: Date,
            counter: UInt64? = nil,
            deviceID: String? = nil
        ) {
            self.parent = parent
            self.markdown = markdown
            self.recordedAt = recordedAt
            self.counter = counter
            self.deviceID = deviceID
        }
    }

    struct PurgeSnapshot: Sendable {
        let purgedAt: Date
        let counter: UInt64?
        let deviceID: String?
    }

    enum Status: Sendable {
        /// Latest authoritative record is an `add`. The block is claimed
        /// alive by at least one device; eligible for auto-restore if it
        /// goes missing from doc (subject to the mtime gate).
        case alive(latestAdd: AddSnapshot)
        /// No authoritative record (no `add` and no `purge`), but at least
        /// one `observe` record carries a snapshot. The block exists in
        /// some device's `.md` view but nobody has claimed authorship —
        /// auto-restore is NOT eligible. Recovery sheet can still surface
        /// the block on demand via the carried snapshot.
        case observed(latestSnapshot: AddSnapshot)
        /// Latest authoritative record is a `purge`. May still carry a
        /// prior `add` or `observe` snapshot (for the "Deleted on purpose"
        /// recovery surface).
        case tombstoned(latestAdd: AddSnapshot?, latestPurge: PurgeSnapshot)
    }

    let byHash: [String: Status]

    init(byHash: [String: Status]) {
        self.byHash = byHash
    }

    /// Latest snapshot's recorded parent for `hash`. Works on `.alive`,
    /// `.observed`, and `.tombstoned` (when the tombstone carries a prior
    /// snapshot).
    func parent(of hash: String) -> String? {
        switch byHash[hash] {
        case .alive(let snapshot): return snapshot.parent
        case .observed(let snapshot): return snapshot.parent
        case .tombstoned(let latestAdd, _): return latestAdd?.parent
        case nil: return nil
        }
    }

    /// Hashes currently tombstoned in the union (latest record is a purge).
    /// Used by ConflictMerger to skip blocks the user explicitly dismissed.
    func tombstones() -> Set<String> {
        var out: Set<String> = []
        for (hash, status) in byHash {
            if case .tombstoned = status { out.insert(hash) }
        }
        return out
    }
}

// MARK: - Engine

/// Pure projection of a per-page recovery-log journal onto the page's
/// document state. The engine has two entry points:
///
/// 1. `intent(from:)` — derive `IntentState` from a journal. Pure, cheap to
///    call repeatedly, no I/O.
/// 2. `reconcile(intent:doc:)` — compute the insertion instructions to bring
///    a document in line with intent. Returns insertions (subtree + live
///    ancestor BlockID) — the caller mutates the live Document via
///    `apply(_:to:)`.
///
/// The engine never reads files, never mutates state, and is fully Sendable
/// at every boundary. All I/O (file reads, log appends, document mutation)
/// happens in the caller.
enum PatchEngine {
    /// Derive the intent state from a per-page journal. Pure: `intent(j) ==
    /// intent(j)` for any `j`.
    ///
    /// Orders records by `(counter, deviceID)` lex when both carry counters
    /// (clock-skew-immune Lamport ordering); falls back to wall-clock `t` for
    /// legacy records written before counters were added. Modern records
    /// (with counter) strictly succeed legacy ones in the order — legacy
    /// records pre-date the upgrade in any realistic scenario.
    static func intent(from journal: LogJournal) -> IntentState {
        // Per hash, we track three things:
        //   - latestAuthoritative: the latest `add` or `purge`. Drives the
        //     alive/tombstoned decision.
        //   - latestSnapshot: the latest record carrying a snapshot (`add`
        //     or `observe`). Drives what markdown + parent we surface for
        //     recovery, regardless of authoritative status.
        //   - hasObserve: any `observe` exists. Lets a hash with no
        //     authoritative record show up as `.observed` rather than
        //     vanishing from the intent.
        var latestAuthoritative: [String: (record: LogRecord, deviceID: String)] = [:]
        var latestSnapshot: [String: (record: LogRecord, deviceID: String)] = [:]
        var hasObserve: Set<String> = []
        for device in journal.devices {
            for record in device.records {
                let hash = record.hash
                if record.isAuthoritative {
                    if let existing = latestAuthoritative[hash] {
                        if isStrictlyAfter(record, on: device.deviceID, than: existing.record, on: existing.deviceID) {
                            latestAuthoritative[hash] = (record, device.deviceID)
                        }
                    } else {
                        latestAuthoritative[hash] = (record, device.deviceID)
                    }
                }
                if record.carriesSnapshot {
                    if let existing = latestSnapshot[hash] {
                        if isStrictlyAfter(record, on: device.deviceID, than: existing.record, on: existing.deviceID) {
                            latestSnapshot[hash] = (record, device.deviceID)
                        }
                    } else {
                        latestSnapshot[hash] = (record, device.deviceID)
                    }
                }
                if case .observe = record {
                    hasObserve.insert(hash)
                }
            }
        }

        var byHash: [String: IntentState.Status] = [:]
        let allHashes = Set(latestAuthoritative.keys).union(hasObserve)
        for hash in allHashes {
            let snapshot = latestSnapshot[hash].flatMap { Self.addSnapshot(from: $0.record, on: $0.deviceID) }
            if let auth = latestAuthoritative[hash] {
                switch auth.record {
                case .add:
                    if let snapshot {
                        byHash[hash] = .alive(latestAdd: snapshot)
                    }
                case .purge:
                    byHash[hash] = .tombstoned(
                        latestAdd: snapshot,
                        latestPurge: IntentState.PurgeSnapshot(
                            purgedAt: Date(timeIntervalSince1970: auth.record.t),
                            counter: auth.record.counter,
                            deviceID: auth.deviceID
                        )
                    )
                case .observe:
                    break // unreachable: observe isn't authoritative
                }
            } else if let snapshot {
                byHash[hash] = .observed(latestSnapshot: snapshot)
            }
        }
        return IntentState(byHash: byHash)
    }

    /// Compute insertion instructions to bring `doc` in line with `intent`.
    /// Pure: `reconcile(i, d, m).inserts.applied(to: d)` is deterministic.
    ///
    /// For each hash with `.alive` intent that isn't present in `doc`, the
    /// engine assembles a subtree (pulling in any descendants whose
    /// recorded-parent hash points back into the alive set), climbs the
    /// recorded-parent chain to the closest live ancestor's `BlockID`, and
    /// emits one `Insert` per root.
    ///
    /// `.observed` hashes are never auto-restored — the engine can compute
    /// a snapshot for them (via the Recover sheet) but won't synthesize an
    /// auto-insert. That's the whole point of the `observe` op: see a
    /// foreign-authored block, journal a snapshot, don't take ownership.
    ///
    /// `mdMtime` gates tombstoned removes only. Missing `.alive` hashes are
    /// restored regardless of timestamp: without an explicit purge, a newer
    /// `.md` write might just be an unrelated local edit that raced ahead of
    /// a delayed peer log. When `restoreFutureForeignAdds` is false, foreign
    /// adds beyond the `.md` stamp's trusted frontier are treated as pending
    /// peer state instead of lost local content. Existing live hashes are still
    /// filtered by hash so auto-restore does not duplicate blocks already
    /// present in the doc.
    static func reconcile(
        intent: IntentState,
        doc: [Block],
        mdMtime: Date? = nil,
        trustedFrontier: [String: UInt64]? = nil,
        allowJournalMutations: Bool = true,
        currentDeviceID: String? = nil,
        restoreFutureForeignAdds: Bool = true
    ) -> Reconciliation {
        let toAppend = unloggedObservations(doc: doc, intent: intent)

        guard allowJournalMutations else {
            return Reconciliation(inserts: [], restoredHashes: [], toAppend: toAppend)
        }

        let liveByHash = liveHashes(doc)
        var deferredFutureForeignHashes: [String] = []
        var removes: [Remove] = []
        for (hash, status) in intent.byHash {
            if case .tombstoned(_, let purge) = status {
                guard let blockID = liveByHash[hash] else { continue }
                if !restoreFutureForeignAdds,
                   isFutureForeign(purge, beyond: trustedFrontier, currentDeviceID: currentDeviceID) {
                    deferredFutureForeignHashes.append(hash)
                    continue
                }
                if let mdMtime, purge.purgedAt < mdMtime {
                    // `.md` is newer than the purge — likely an external
                    // re-add (vim'd the block back in after a prior
                    // deletion). Don't strip it out from under the user.
                    continue
                }
                removes.append(Remove(hash: hash, blockID: blockID))
            }
        }

        let hashesRemovedWithSubtrees = removedSubtreeHashes(removeIDs: removes.map(\.blockID), in: doc)
        let effectiveLiveByHash = liveByHash.filter { hash, _ in
            !hashesRemovedWithSubtrees.contains(hash)
        }
        let liveRestoreIdentities = restoreIdentities(doc)

        var aliveEntries: [LostBlock] = []
        for (hash, status) in intent.byHash {
            switch status {
            case .alive(let add):
                guard effectiveLiveByHash[hash] == nil else { continue }
                if isAbsorbed(add, by: trustedFrontier) { continue }
                if !restoreFutureForeignAdds,
                   isFutureForeign(add, beyond: trustedFrontier, currentDeviceID: currentDeviceID) {
                    deferredFutureForeignHashes.append(hash)
                    continue
                }
                if let identity = restoreIdentity(fromMarkdown: add.markdown),
                   liveRestoreIdentities.contains(identity) {
                    continue
                }
                aliveEntries.append(LostBlock.adapt(
                    hash: hash,
                    parentHash: add.parent,
                    markdown: add.markdown,
                    source: "",
                    recordedAt: add.recordedAt
                ))
            case .tombstoned, .observed:
                // `observe` is non-authoritative: it neither restores nor
                // removes. The snapshot is just a recorded sighting.
                continue
            }
        }
        guard !aliveEntries.isEmpty else {
            return Reconciliation(
                inserts: [],
                restoredHashes: [],
                removes: removes,
                toAppend: toAppend,
                deferredFutureForeignHashes: deferredFutureForeignHashes
            )
        }
        let aliveByHash = Dictionary(uniqueKeysWithValues: aliveEntries.map { ($0.hash, $0) })
        let roots = LostBlockForest.assemble(aliveEntries)
        let forestHashes = Set(roots.flatMap { $0.hashes })

        var unrestorable: [UnrestorableEntry] = []
        // Hashes the forest couldn't represent at all — `m` failed to
        // parse, no `Block` could be built. They get quarantined as
        // parse failures with whatever we know from the log entry.
        for (hash, entry) in aliveByHash where !forestHashes.contains(hash) {
            unrestorable.append(UnrestorableEntry(
                hash: hash,
                recordedMarkdown: entry.markdown,
                recordedParent: entry.parentHash,
                recordedAt: entry.recordedAt,
                reason: .parseFailure
            ))
        }

        var inserts: [Insert] = []
        var restoredHashes: [String] = []
        for root in roots {
            // Round-trip check: the parsed subtree's atomic hash MUST match
            // what the journal recorded. If it doesn't, inserting would
            // make doc.children contain a different hash than intent
            // expects → next reconcile reads intent as still-missing →
            // infinite re-fire. Quarantine instead.
            let actualHash = root.block.atomicHash
            if actualHash != root.lost.hash {
                unrestorable.append(UnrestorableEntry(
                    hash: root.lost.hash,
                    recordedMarkdown: root.lost.markdown,
                    recordedParent: root.lost.parentHash,
                    recordedAt: root.lost.recordedAt,
                    reason: .hashMismatch(actualHash: actualHash, parsedKind: kindLabel(root.block.kind))
                ))
                // Also quarantine descendants — they only got pulled in as
                // children of this root and won't be inserted on their own.
                for descendantHash in root.hashes where descendantHash != root.lost.hash {
                    if let descendant = aliveByHash[descendantHash] {
                        unrestorable.append(UnrestorableEntry(
                            hash: descendant.hash,
                            recordedMarkdown: descendant.markdown,
                            recordedParent: descendant.parentHash,
                            recordedAt: descendant.recordedAt,
                            reason: .descendantOfUnrestorableRoot(rootHash: root.lost.hash)
                        ))
                    }
                }
                continue
            }
            let parentID = resolveLiveAncestor(
                startingParentHash: root.lost.parentHash,
                intent: intent,
                liveByHash: effectiveLiveByHash
            )
            inserts.append(Insert(
                subtree: root.block.withFreshIDs(),
                parent: parentID,
                coveredHashes: root.hashes
            ))
            restoredHashes.append(contentsOf: root.hashes)
        }
        return Reconciliation(
            inserts: inserts,
            restoredHashes: restoredHashes,
            removes: removes,
            toAppend: toAppend,
            deferredFutureForeignHashes: deferredFutureForeignHashes,
            unrestorable: unrestorable
        )
    }

    private static func isAbsorbed(_ add: IntentState.AddSnapshot, by frontier: [String: UInt64]?) -> Bool {
        guard let frontier,
              let deviceID = add.deviceID,
              let counter = add.counter else { return false }
        return (frontier[deviceID] ?? 0) >= counter
    }

    private static func isFutureForeign(
        _ add: IntentState.AddSnapshot,
        beyond frontier: [String: UInt64]?,
        currentDeviceID: String?
    ) -> Bool {
        guard let frontier,
              let currentDeviceID,
              let deviceID = add.deviceID,
              let counter = add.counter,
              deviceID != currentDeviceID else { return false }
        return (frontier[deviceID] ?? 0) < counter
    }

    private static func isFutureForeign(
        _ purge: IntentState.PurgeSnapshot,
        beyond frontier: [String: UInt64]?,
        currentDeviceID: String?
    ) -> Bool {
        guard let frontier,
              let currentDeviceID,
              let deviceID = purge.deviceID,
              let counter = purge.counter,
              deviceID != currentDeviceID else { return false }
        return (frontier[deviceID] ?? 0) < counter
    }

    /// Short, log-friendly label for a block kind. Just the case name —
    /// avoids dumping payload text into the unified log.
    private static func kindLabel(_ kind: BlockKind) -> String {
        switch kind {
        case .paragraph: return "paragraph"
        case .heading(let level, _): return "heading-h\(level.rawValue)"
        case .bullet: return "bullet"
        case .numbered: return "numbered"
        case .todo: return "todo"
        case .quote: return "quote"
        case .code: return "code"
        case .divider: return "divider"
        case .toggle: return "toggle"
        case .templateButton: return "templateButton"
        case .subpage: return "subpage"
        case .image: return "image"
        }
    }

    /// Walk `doc` preorder; emit one `Observation` per block whose hash isn't
    /// already in `intent`. Preorder so a parent's observation precedes its
    /// children — if the caller appends sequentially, a child's parent ref
    /// always resolves to an already-known hash. (Order doesn't affect the
    /// union's correctness — `(c, deviceID)` ordering handles any sequence —
    /// but readable logs help when debugging by tail.)
    private static func unloggedObservations(doc: [Block], intent: IntentState) -> [Observation] {
        var out: [Observation] = []
        func walk(_ blocks: [Block], parent: String?) {
            for block in blocks {
                let h = block.atomicHash
                if intent.byHash[h] == nil {
                    out.append(Observation(
                        hash: h,
                        parent: parent,
                        markdown: BlockSerializer.serializeAtomic(block)
                    ))
                }
                walk(block.children, parent: h)
            }
        }
        walk(doc, parent: nil)
        return out
    }

    struct Reconciliation: Sendable {
        /// Subtrees to splice into `doc` to bring it in line with intent.
        let inserts: [Insert]
        /// Hashes the inserts covered (root + descendants). For UI / banner.
        let restoredHashes: [String]
        /// Subtrees present in `doc` whose latest journal record is a
        /// `purge` — the journal says these are dead but the doc still
        /// has them. Caller should remove them and re-save the `.md`.
        /// Together with `inserts`, this is how `doc` converges to the
        /// journal's view in steady state ("logs as source of truth").
        let removes: [Remove]
        /// Observations the engine made about blocks present in `doc` but
        /// not in the journal — `observe` records the caller should
        /// append to *this device's* log so the journal records the
        /// snapshot without claiming authorship.
        let toAppend: [Observation]
        /// Foreign adds newer than the `.md` stamp's trusted frontier that the
        /// caller chose not to auto-restore. The default reconciliation path
        /// restores them; specialized callers can defer while awaiting a peer
        /// markdown payload without advancing the journal watermark.
        let deferredFutureForeignHashes: [String]
        /// Hashes the journal classifies as `.alive` but the engine can't
        /// turn into a valid `Insert`: the recorded `m` won't parse, or it
        /// parses to a block whose `atomicHash` doesn't match the recorded
        /// hash. The orchestrator should purge these so they stop firing —
        /// the user loses the recovery option for the specific hash but
        /// the loop stops. Each entry carries enough context (markdown,
        /// reason, parsed kind on mismatch) to debug what's drifting.
        let unrestorable: [UnrestorableEntry]

        var didChange: Bool { !inserts.isEmpty || !removes.isEmpty }

        init(
            inserts: [Insert],
            restoredHashes: [String],
            removes: [Remove] = [],
            toAppend: [Observation] = [],
            deferredFutureForeignHashes: [String] = [],
            unrestorable: [UnrestorableEntry] = []
        ) {
            self.inserts = inserts
            self.restoredHashes = restoredHashes
            self.removes = removes
            self.toAppend = toAppend
            self.deferredFutureForeignHashes = deferredFutureForeignHashes
            self.unrestorable = unrestorable
        }
    }

    /// A block currently in `doc` whose latest authoritative record is a
    /// `purge`. Caller removes it via `Document.removeSubtree(blockID)`
    /// (PatchEngine.apply does this for the standard auto-apply flow).
    struct Remove: Sendable {
        /// Atomic hash of the block being stripped.
        let hash: String
        /// `BlockID` of the block in `doc`. Passed straight to
        /// `Document.removeSubtree(_:)`.
        let blockID: BlockID

        init(hash: String, blockID: BlockID) {
            self.hash = hash
            self.blockID = blockID
        }
    }

    struct Insert: Sendable {
        /// Subtree to splice in. IDs are already fresh (`withFreshIDs()`
        /// applied) — caller can hand it straight to `Document.insertSubtrees`.
        let subtree: Block
        /// `BlockID` of the live ancestor under which the subtree should be
        /// inserted (end of children). `nil` means top-level.
        let parent: BlockID?
        /// Atomic hashes covered by this subtree, root included. Used by the
        /// manual-restore path to purge the whole subtree post-insert.
        let coveredHashes: Set<String>

        init(subtree: Block, parent: BlockID?, coveredHashes: Set<String>) {
            self.subtree = subtree
            self.parent = parent
            self.coveredHashes = coveredHashes
        }
    }

    /// One hash the engine quarantined from reconciliation. Carries enough
    /// context to debug *why* the recorded entry can't be restored and what
    /// blocks the loop. The orchestrator logs these and purges the hash so
    /// it stops firing reconcile.
    struct UnrestorableEntry: Sendable {
        enum Reason: Sendable {
            /// `BlockParser.parse(recordedMarkdown)` returned no blocks.
            case parseFailure
            /// `parse(recordedMarkdown).first.atomicHash != recordedHash`.
            /// The recorded markdown round-trips to *something*, but its
            /// hash doesn't match what the log claimed. Carries the actual
            /// hash + parsed block kind for diagnosis.
            case hashMismatch(actualHash: String, parsedKind: String)
            /// A descendant in a subtree whose root was unrestorable. The
            /// engine pulls descendants into the same `Root` via the forest
            /// assembly; if the root can't be inserted, neither can its
            /// children (as their own roots). Quarantined together so the
            /// log stops surfacing them all.
            case descendantOfUnrestorableRoot(rootHash: String)
        }

        let hash: String
        let recordedMarkdown: String
        let recordedParent: String?
        let recordedAt: Date
        let reason: Reason

        init(
            hash: String,
            recordedMarkdown: String,
            recordedParent: String?,
            recordedAt: Date,
            reason: Reason
        ) {
            self.hash = hash
            self.recordedMarkdown = recordedMarkdown
            self.recordedParent = recordedParent
            self.recordedAt = recordedAt
            self.reason = reason
        }
    }

    /// A "this content exists" observation the engine wants the persistence
    /// layer to append as a fresh `add` record. The engine omits the counter
    /// + timestamp — they're persistence-layer concerns minted at append time.
    struct Observation: Sendable {
        let hash: String
        let parent: String?
        let markdown: String

        init(hash: String, parent: String?, markdown: String) {
            self.hash = hash
            self.parent = parent
            self.markdown = markdown
        }
    }

    /// Build the insertion for a single explicitly-chosen `rootHash` against
    /// `candidates` (the flat lost / purged set for the page). Used by the
    /// manual Recover-sheet path: caller picks one entry, engine assembles
    /// the subtree and resolves the live ancestor. Returns `nil` when the
    /// hash can't be assembled (markdown unparseable or absent from
    /// candidates).
    static func insertion(
        rootHash: String,
        candidates: [LostBlock],
        intent: IntentState,
        doc: [Block]
    ) -> Insert? {
        guard let root = LostBlockForest.assemble(candidates, rootedAt: rootHash) else {
            return nil
        }
        let liveByHash = liveHashes(doc)
        let parentID = resolveLiveAncestor(
            startingParentHash: root.lost.parentHash,
            intent: intent,
            liveByHash: liveByHash
        )
        return Insert(
            subtree: root.block.withFreshIDs(),
            parent: parentID,
            coveredHashes: root.hashes
        )
    }

    // MARK: - Conflict merge

    struct ConflictMergeResult: Sendable {
        let merged: [Block]
        let salvagedHashes: [String]
    }

    /// Merge alternate-version block trees into a survivor, splicing any
    /// block whose atomic hash isn't in the survivor and isn't tombstoned
    /// in `intent`. Spliced blocks land under their alternate-recorded
    /// parent when that parent is alive in the merged tree, otherwise
    /// climb the recorded-parent chain (via `intent.parent(of:)`) to the
    /// nearest live ancestor, otherwise top-level.
    ///
    /// Pure: no I/O, no log writes. Caller writes the merged result.
    /// Used by `Clamshell.Page.resolveConflicts()` to absorb iCloud
    /// sibling-file conflicts (`<page> 2.md`) — independent edits on
    /// two devices end up additive instead of clobbering each other.
    @MainActor
    static func mergeConflict(
        survivor: [Block],
        alternates: [[Block]],
        intent: IntentState
    ) -> ConflictMergeResult {
        var liveHashes: Set<String> = []
        collectAtomicHashes(survivor, into: &liveHashes)

        let doc = Document(
            url: URL(fileURLWithPath: "/conflict-merge"),
            children: survivor
        )

        var hashToID: [String: BlockID] = [:]
        rebuildHashToID(doc.children, into: &hashToID)

        let tombstones = intent.tombstones()
        var salvaged: [String] = []

        for alternate in alternates {
            walkAlternate(
                blocks: alternate,
                parentInAlternate: nil,
                doc: doc,
                liveHashes: &liveHashes,
                hashToID: &hashToID,
                tombstones: tombstones,
                intent: intent,
                salvaged: &salvaged
            )
        }

        doc.enforceHeadingContainment()
        return ConflictMergeResult(merged: doc.children, salvagedHashes: salvaged)
    }

    @MainActor
    private static func walkAlternate(
        blocks: [Block],
        parentInAlternate: String?,
        doc: Document,
        liveHashes: inout Set<String>,
        hashToID: inout [String: BlockID],
        tombstones: Set<String>,
        intent: IntentState,
        salvaged: inout [String]
    ) {
        for block in blocks {
            let hash = block.atomicHash
            if liveHashes.contains(hash) || tombstones.contains(hash) {
                walkAlternate(
                    blocks: block.children,
                    parentInAlternate: hash,
                    doc: doc,
                    liveHashes: &liveHashes,
                    hashToID: &hashToID,
                    tombstones: tombstones,
                    intent: intent,
                    salvaged: &salvaged
                )
                continue
            }

            let parentID = resolveLiveAncestorViaIntent(
                directParentHash: parentInAlternate,
                hashToID: hashToID,
                intent: intent
            )
            let shell = Block(id: BlockID(), kind: block.kind, children: [])
            let siblingCount = (parentID.flatMap { doc.find($0)?.children } ?? doc.children).count
            _ = doc.insertSubtree(shell, at: DropPath(parent: parentID, position: siblingCount))

            liveHashes.insert(hash)
            hashToID[hash] = shell.id
            salvaged.append(hash)

            walkAlternate(
                blocks: block.children,
                parentInAlternate: hash,
                doc: doc,
                liveHashes: &liveHashes,
                hashToID: &hashToID,
                tombstones: tombstones,
                intent: intent,
                salvaged: &salvaged
            )
        }
    }

    private static func resolveLiveAncestorViaIntent(
        directParentHash: String?,
        hashToID: [String: BlockID],
        intent: IntentState
    ) -> BlockID? {
        var current = directParentHash
        var safety = 64
        var seen: Set<String> = []
        while let hash = current, safety > 0, seen.insert(hash).inserted {
            if let id = hashToID[hash] { return id }
            current = intent.parent(of: hash)
            safety -= 1
        }
        return nil
    }

    private static func rebuildHashToID(_ blocks: [Block], into map: inout [String: BlockID]) {
        for block in blocks {
            map[block.atomicHash] = block.id
            rebuildHashToID(block.children, into: &map)
        }
    }

    private static func collectAtomicHashes(_ blocks: [Block], into out: inout Set<String>) {
        for block in blocks {
            out.insert(block.atomicHash)
            collectAtomicHashes(block.children, into: &out)
        }
    }

    // MARK: - Internals

    private static func isStrictlyAfter(
        _ a: LogRecord, on aDevice: String,
        than b: LogRecord, on bDevice: String
    ) -> Bool {
        if let ac = a.counter, let bc = b.counter {
            if ac != bc { return ac > bc }
            return aDevice > bDevice
        }
        if a.counter != nil { return true }
        if b.counter != nil { return false }
        return a.t > b.t
    }

    private static func addSnapshot(from record: LogRecord, on deviceID: String) -> IntentState.AddSnapshot? {
        switch record {
        case .add(_, _, let parent, let markdown, let t),
             .observe(_, _, let parent, let markdown, let t):
            return IntentState.AddSnapshot(
                parent: parent,
                markdown: markdown,
                recordedAt: Date(timeIntervalSince1970: t),
                counter: record.counter,
                deviceID: deviceID
            )
        case .purge:
            return nil
        }
    }

    /// Hash → BlockID for every block in `doc` (preorder, first-wins on
    /// duplicate hashes).
    private static func liveHashes(_ blocks: [Block]) -> [String: BlockID] {
        var out: [String: BlockID] = [:]
        func walk(_ blocks: [Block]) {
            for block in blocks {
                let h = block.atomicHash
                if out[h] == nil { out[h] = block.id }
                walk(block.children)
            }
        }
        walk(blocks)
        return out
    }

    private enum RestoreIdentity: Hashable {
        case subpage(pageID: String)
    }

    private static func restoreIdentities(_ blocks: [Block]) -> Set<RestoreIdentity> {
        var out: Set<RestoreIdentity> = []
        func walk(_ blocks: [Block]) {
            for block in blocks {
                if let identity = restoreIdentity(from: block) {
                    out.insert(identity)
                }
                walk(block.children)
            }
        }
        walk(blocks)
        return out
    }

    private static func restoreIdentity(fromMarkdown markdown: String) -> RestoreIdentity? {
        guard let block = BlockParser.parse(markdown).first else { return nil }
        return restoreIdentity(from: block)
    }

    private static func restoreIdentity(from block: Block) -> RestoreIdentity? {
        switch block.kind {
        case .subpage(_, let pageID):
            return .subpage(pageID: pageID)
        case .paragraph, .heading, .bullet, .numbered, .todo, .quote, .code, .divider, .toggle, .templateButton, .image:
            return nil
        }
    }

    private static func removedSubtreeHashes(removeIDs: [BlockID], in blocks: [Block]) -> Set<String> {
        guard !removeIDs.isEmpty else { return [] }
        let removeIDs = Set(removeIDs)
        var out: Set<String> = []
        func collect(_ block: Block) {
            out.insert(block.atomicHash)
            for child in block.children {
                collect(child)
            }
        }
        func walk(_ blocks: [Block]) {
            for block in blocks {
                if removeIDs.contains(block.id) {
                    collect(block)
                } else {
                    walk(block.children)
                }
            }
        }
        walk(blocks)
        return out
    }

    /// Walk the recorded-parent chain (via `intent`) until a hash is found
    /// that's live in `doc`. Returns that block's `BlockID`; `nil` = top-level
    /// (chain exhausted without a live hit).
    private static func resolveLiveAncestor(
        startingParentHash: String?,
        intent: IntentState,
        liveByHash: [String: BlockID]
    ) -> BlockID? {
        var current = startingParentHash
        var seen: Set<String> = []
        var safety = 64
        while let hash = current, safety > 0, seen.insert(hash).inserted {
            if let id = liveByHash[hash] { return id }
            current = intent.parent(of: hash)
            safety -= 1
        }
        return nil
    }
}

// MARK: - Apply (MainActor convenience)

@MainActor
extension PatchEngine {
    /// Apply `recon` to a live `Document`. Strips every block in
    /// `recon.removes` (subtree-removal — descendants come with the
    /// root), then inserts every subtree from `recon.inserts` under its
    /// resolved parent, then re-runs heading containment. Returns true
    /// if any mutation happened.
    ///
    /// Removes go first: if a tombstoned parent and a tombstoned child
    /// are both flagged, removing the parent strips the child as a side
    /// effect — `removeSubtree` is then a no-op for the child's id.
    @discardableResult
    static func apply(_ recon: Reconciliation, to doc: Document) -> Bool {
        guard !recon.inserts.isEmpty || !recon.removes.isEmpty else { return false }
        let removedIDs = Set(recon.removes.map(\.blockID))
        let restoredHashes = Set(recon.restoredHashes)
        let preexistingRestoredHashes = restoredHashes.intersection(Set(liveHashes(doc.children).keys))
        let nonPreexistingRestoredHashes = restoredHashes.subtracting(preexistingRestoredHashes)
        for remove in recon.removes {
            guard let block = doc.find(remove.blockID) else { continue }
            if hasSurvivingDescendant(block, excludingIDs: removedIDs, excludingHashes: nonPreexistingRestoredHashes) {
                _ = doc.removeBlockLiftingChildren(remove.blockID)
            } else {
                _ = doc.removeSubtree(remove.blockID)
            }
        }
        for insert in recon.inserts {
            let currentHashes = Set(liveHashes(doc.children).keys)
            let duplicateHashes = insert.coveredHashes.intersection(currentHashes)
            guard let subtree = insert.subtree.removingSubtrees(withHashes: duplicateHashes) else {
                continue
            }
            let siblings = insert.parent.flatMap(doc.find)?.children ?? doc.children
            let position = dropPosition(
                beforeFirstHashIn: duplicateHashes,
                under: insert.parent,
                fallback: siblings.count,
                in: doc.children
            )
            _ = doc.insertSubtrees(
                [subtree],
                at: DropPath(parent: insert.parent, position: position)
            )
        }
        doc.enforceHeadingContainment()
        return true
    }

    private static func hasSurvivingDescendant(
        _ block: Block,
        excludingIDs removedIDs: Set<BlockID>,
        excludingHashes restoredHashes: Set<String>
    ) -> Bool {
        for child in block.children {
            let childWillBeRemovedOrRestored =
                removedIDs.contains(child.id) || restoredHashes.contains(child.atomicHash)
            if !childWillBeRemovedOrRestored ||
                hasSurvivingDescendant(child, excludingIDs: removedIDs, excludingHashes: restoredHashes) {
                return true
            }
        }
        return false
    }

    private static func dropPosition(
        beforeFirstHashIn hashes: Set<String>,
        under parentID: BlockID?,
        fallback: Int,
        in rootBlocks: [Block]
    ) -> Int {
        guard !hashes.isEmpty else { return fallback }
        let siblings: [Block]
        if let parentID {
            guard let parent = find(parentID, in: rootBlocks) else { return fallback }
            siblings = parent.children
        } else {
            siblings = rootBlocks
        }
        for (index, block) in siblings.enumerated() {
            if block.containsAnyAtomicHash(in: hashes) {
                return index
            }
        }
        return fallback
    }

    private static func find(_ id: BlockID, in blocks: [Block]) -> Block? {
        for block in blocks {
            if block.id == id { return block }
            if let found = find(id, in: block.children) {
                return found
            }
        }
        return nil
    }
}

private extension Block {
    func removingSubtrees(withHashes hashes: Set<String>) -> Block? {
        guard !hashes.contains(atomicHash) else { return nil }
        return withChildren(children.compactMap { $0.removingSubtrees(withHashes: hashes) })
    }

    func containsAnyAtomicHash(in hashes: Set<String>) -> Bool {
        if hashes.contains(atomicHash) { return true }
        return children.contains { $0.containsAnyAtomicHash(in: hashes) }
    }
}

// MARK: - ReconcileSummary

extension PatchEngine {
    /// Side-effect-free description of what a reconcile pass spliced in
    /// (auto-restore). Used for the post-restore banner and the
    /// `.restored(count:)` presenter event.
    struct ReconcileSummary: Sendable {
        let restoredHashes: [String]
        var didChange: Bool { !restoredHashes.isEmpty }
    }
}

// MARK: - UI-facing enumeration helpers

// MARK: - LostBlockForest

/// Pure transform from a flat list of `LostBlock` records into the roots of
/// a forest of `Block` trees. Each lost block whose recorded `parentHash`
/// points to another lost block becomes a child of that parent in the
/// assembled tree, so a parent + its descendants restore as one nested
/// subtree instead of N flat siblings. Cycle-safe.
struct LostBlockForest {
    struct Root: Sendable {
        /// Originating record for the root (used by callers to look up the
        /// recorded `parentHash` for live-ancestor resolution).
        let lost: LostBlock
        /// Assembled tree with children attached. IDs are still the parser's;
        /// callers should `withFreshIDs()` once before inserting.
        let block: Block
        /// Atomic hashes covered by this root (including the root itself).
        /// Used by the manual-restore path to purge the whole subtree post-
        /// insert and by the Recover sheet to badge "+N more" affordances.
        let hashes: Set<String>
    }

    static func assemble(_ entries: [LostBlock]) -> [Root] {
        let (parsed, byHash) = buildIndex(entries)
        guard !byHash.isEmpty else { return [] }
        let childrenByParent = buildChildrenByParent(byHash: byHash)
        let rootHashes = byHash.values.compactMap { entry -> String? in
            if let p = entry.parentHash, byHash[p] != nil { return nil }
            return entry.hash
        }
        let sortedRoots = rootHashes.sorted { lhs, rhs in
            (byHash[lhs]?.recordedAt ?? .distantPast)
                < (byHash[rhs]?.recordedAt ?? .distantPast)
        }
        return sortedRoots.compactMap { hash in
            buildRoot(
                hash: hash,
                parsed: parsed,
                byHash: byHash,
                childrenByParent: childrenByParent
            )
        }
    }

    /// Single-root overload: assemble only the subtree rooted at `rootedAt`
    /// from the entries (descendants pulled in by parentHash linkage).
    /// Returns nil if `rootedAt` isn't in the entries.
    static func assemble(_ entries: [LostBlock], rootedAt: String) -> Root? {
        let (parsed, byHash) = buildIndex(entries)
        guard byHash[rootedAt] != nil else { return nil }
        let childrenByParent = buildChildrenByParent(byHash: byHash)
        return buildRoot(
            hash: rootedAt,
            parsed: parsed,
            byHash: byHash,
            childrenByParent: childrenByParent
        )
    }

    private static func buildChildrenByParent(byHash: [String: LostBlock]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for entry in byHash.values {
            guard let p = entry.parentHash, byHash[p] != nil else { continue }
            out[p, default: []].append(entry.hash)
        }
        return out
    }

    private static func buildIndex(_ entries: [LostBlock])
        -> (parsed: [String: Block], byHash: [String: LostBlock])
    {
        var parsed: [String: Block] = [:]
        var byHash: [String: LostBlock] = [:]
        for entry in entries {
            guard let block = BlockParser.parse(entry.markdown).first else { continue }
            // Defensive: dupe hash → keep the latest recordedAt for ordering.
            if let existing = byHash[entry.hash], existing.recordedAt >= entry.recordedAt {
                continue
            }
            parsed[entry.hash] = block
            byHash[entry.hash] = entry
        }
        return (parsed, byHash)
    }

    private static func buildRoot(
        hash: String,
        parsed: [String: Block],
        byHash: [String: LostBlock],
        childrenByParent: [String: [String]]
    ) -> Root? {
        guard let lost = byHash[hash], let block = parsed[hash] else { return nil }
        var visited: Set<String> = []
        var hashes: Set<String> = []
        let assembled = attach(
            hash: hash,
            block: block,
            parsed: parsed,
            byHash: byHash,
            childrenByParent: childrenByParent,
            visited: &visited,
            hashes: &hashes
        )
        return Root(lost: lost, block: assembled, hashes: hashes)
    }

    private static func attach(
        hash: String,
        block: Block,
        parsed: [String: Block],
        byHash: [String: LostBlock],
        childrenByParent: [String: [String]],
        visited: inout Set<String>,
        hashes: inout Set<String>
    ) -> Block {
        guard visited.insert(hash).inserted else { return block }
        hashes.insert(hash)
        let childHashes = (childrenByParent[hash] ?? []).sorted { lhs, rhs in
            (byHash[lhs]?.recordedAt ?? .distantPast)
                < (byHash[rhs]?.recordedAt ?? .distantPast)
        }
        let children = childHashes.compactMap { childHash -> Block? in
            guard let childBlock = parsed[childHash] else { return nil }
            return attach(
                hash: childHash,
                block: childBlock,
                parsed: parsed,
                byHash: byHash,
                childrenByParent: childrenByParent,
                visited: &visited,
                hashes: &hashes
            )
        }
        return block.withChildren(children)
    }
}

// MARK: - IntentState query helpers

extension IntentState {
    /// `LostBlock` entries for the Recover sheet: hashes whose latest record
    /// is an `add` and aren't currently alive in the page's `.md`. Sorted by
    /// `recordedAt` descending.
    func lostEntries(
        notIn liveHashes: Set<String>,
        source: String,
        trustedFrontier: [String: UInt64]? = nil
    ) -> [LostBlock] {
        var out: [LostBlock] = []
        for (hash, status) in byHash {
            guard case .alive(let add) = status, !liveHashes.contains(hash) else { continue }
            if let deviceID = add.deviceID,
               let counter = add.counter,
               (trustedFrontier?[deviceID] ?? 0) >= counter {
                continue
            }
            out.append(LostBlock.adapt(
                hash: hash,
                parentHash: add.parent,
                markdown: add.markdown,
                source: source,
                recordedAt: add.recordedAt
            ))
        }
        return out.sorted { $0.recordedAt > $1.recordedAt }
    }

    /// `PurgedBlock` entries for the Recover sheet's "Deleted on purpose"
    /// section: hashes whose latest record is a `purge` but a prior `add`
    /// still carries the markdown + parent metadata. Excludes hashes currently
    /// alive in the page's `.md` (a re-add already brought them back). `since`
    /// caps to recent purges (nil = no cap).
    func purgedEntries(notIn liveHashes: Set<String>, source: String, since: Date?) -> [PurgedBlock] {
        var out: [PurgedBlock] = []
        let cutoff = since?.timeIntervalSince1970
        for (hash, status) in byHash {
            guard case .tombstoned(let latestAdd, let purge) = status,
                  let add = latestAdd,
                  !liveHashes.contains(hash) else { continue }
            let purgedAt = purge.purgedAt
            if let cutoff, purgedAt.timeIntervalSince1970 < cutoff { continue }
            out.append(PurgedBlock.adapt(
                hash: hash,
                parentHash: add.parent,
                markdown: add.markdown,
                source: source,
                purgedAt: purgedAt
            ))
        }
        return out.sorted { $0.purgedAt > $1.purgedAt }
    }
}
