import Foundation
import Editor

// MARK: - Commit
//
// A `Commit` is one durable unit of work for a single page: log entries to
// append (zero or more) plus the implicit "serialize and write the current
// `.md`." Caller mutates the live `Document` first; `Commit` does not carry
// in-memory mutations. `Clamshell.commit(_:to:)` (the per-URL save chain)
// applies log entries strictly before the file write, awaited end-to-end,
// so the "log at-or-ahead of disk" invariant holds across crashes.
//
// Four call sites build a `Commit`:
//   - Editor: `Commit.fromEditorOps(ops)` projects `[EditorOp]` to add/purge.
//   - Reconcile: `Reconciliation.asCommit()` projects observations +
//     unrestorable quarantines (the doc is mutated separately via
//     `PatchEngine.apply`).
//   - Restore: built by hand in `Clamshell.restoreBlocks` (follow-up purges
//     or fresh adds, plus an optional full-doc add-walk for the closed-page
//     branch where the journal might not yet know about every block in
//     `doc`).
//   - Conflict merge: built by `Clamshell.resolveConflictVersions` as a
//     full-doc observe-walk on the merged tree.

/// One unit of durable work for a single page.
///
/// `logEntries` is zero or more `Patch.Entry`s to append before the `.md`
/// write — may be empty for a pure-reorder commit. Caller is responsible
/// for the in-memory state of `doc.children`: `commit(_:to:)` serializes
/// whatever is there at commit time.
struct Commit: Sendable {
    let logEntries: [Patch.Entry]

    init(logEntries: [Patch.Entry]) {
        self.logEntries = logEntries
    }

    /// Editor's `[EditorOp]` → adds + purges. Empty `ops` means a pure
    /// reorder/move (same hashes, different positions); the resulting
    /// Commit has no log entries but still triggers a `.md` write so the
    /// new shape lands.
    static func fromEditorOps(_ ops: [EditorOp]) -> Commit {
        if ops.isEmpty { return Commit(logEntries: []) }
        return Commit(logEntries: Patch.from(ops: ops).entries)
    }
}

// MARK: - Reconciliation → Commit

extension PatchEngine.Reconciliation {
    /// Project a reconcile result onto a `Commit`. Caller is expected to
    /// have already applied `inserts` + `removes` to the live `Document`
    /// (typically via `PatchEngine.apply(_:to:)`) — those mutations are
    /// in-memory and don't go through the save chain. The `Commit` carries
    /// only what needs to be durably appended to the log: `observe` records
    /// for unlogged-but-in-doc blocks, and `purge` records to quarantine
    /// unrestorable hashes so reconcile stops firing for them.
    ///
    /// Diagnostics the host displays (auto-restore banner, quarantine log
    /// telemetry) live on the source `Reconciliation` — read `restoredHashes`
    /// and `unrestorable` directly. They're not in the `Commit` because
    /// no caller actually needs them *from* the commit return value;
    /// keeping the value type to just `logEntries` makes the commit
    /// API trivially Void-equivalent.
    func asCommit() -> Commit {
        var entries: [Patch.Entry] = []
        entries.reserveCapacity(toAppend.count + unrestorable.count)
        for obs in toAppend {
            entries.append(.observe(hash: obs.hash, parent: obs.parent, markdown: obs.markdown))
        }
        for q in unrestorable {
            entries.append(.purge(hash: q.hash))
        }
        return Commit(logEntries: entries)
    }
}
