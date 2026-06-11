import Foundation
import Editor

/// Per-URL ordered save chain. Owns the coalescing rule (fold into an
/// un-started tail for the same `Document` instance), the started-flag
/// snapshot rule, and head-only self-cleanup. The owner supplies the
/// per-commit body via `work` — for Clamshell that's "apply log entries,
/// then serialize + write the `.md`", so the "log durable before file
/// durable" invariant stays structural: it's one task body, in order.
///
/// `enqueue` is synchronous: the chain entry is installed before it
/// returns, so `isQuiescent(at:)` / `pendingTask(for:)` reflect the
/// commit immediately. That closes the visibility gap that existed when
/// the host bridged to `commit` through an unstructured Task — flush,
/// reconcile gating, close-then-trash sequencing all read the chain and
/// must never observe false quiescence after a commit has fired.
///
/// Why a hand-rolled chain rather than `actor PageWriter`: actor
/// reentrancy lets a second commit start during the first's `await`
/// suspension, which could interleave their file writes — breaking the
/// per-commit "log before file" ordering at the filesystem level. The
/// chain's explicit `await previous?.value` forecloses that.
@MainActor
final class SaveChain {
    /// The owner's per-commit body. Runs strictly after the previous
    /// task for the same URL; `logEntries` is the coalesced snapshot.
    typealias Work = @MainActor (_ doc: Document, _ logEntries: [Patch.Entry]) async throws -> Void

    /// `pendingLogEntries` is mutable so an arriving commit whose
    /// predecessor hasn't started yet can fold its work in instead of
    /// chaining another full save. The task body snapshots the field
    /// after flipping `started` on MainActor — no other MainActor work
    /// can interleave between those two statements, so the read is
    /// race-free.
    private final class ChainEntry {
        let id: UUID
        let doc: Document
        var pendingLogEntries: [Patch.Entry]
        var started: Bool = false
        var task: Task<Void, Error>!

        init(id: UUID, doc: Document, pendingLogEntries: [Patch.Entry]) {
            self.id = id
            self.doc = doc
            self.pendingLogEntries = pendingLogEntries
        }
    }

    private let work: Work
    /// Latest enqueued entry per URL. Absent ⇒ no work pending. Entries
    /// remove themselves when their task finishes (head-only: a newer
    /// entry may have replaced the slot mid-flight and owns it).
    private var chain: [URL: ChainEntry] = [:]

    init(work: @escaping Work) {
        self.work = work
    }

    /// Synchronously install a chain entry and return its task without
    /// awaiting it. After this returns, `isQuiescent(at: doc.url)` is
    /// false until the work completes — there is no enqueue gap for
    /// flush/quiescence readers to fall through.
    ///
    /// The task captures `self` and `entry` strongly; the cycle is
    /// transient (a Task releases its closure on completion). Owner
    /// liveness across pending work is the owner's job — see
    /// `Clamshell.drain()`.
    @discardableResult
    func enqueue(_ logEntries: [Patch.Entry], for doc: Document) -> Task<Void, Error> {
        let url = doc.url

        // Coalesce: if the tail's task hasn't started its body yet (still
        // suspended awaiting its predecessor), fold this commit's log
        // entries into it instead of spawning a second full save — N rapid
        // commits collapse into one log apply + one .md write. Only
        // coalesce on the same Document instance: a fresh Document for the
        // same URL (e.g. conflict merge) needs its own entry so its block
        // snapshot is the one serialized.
        if let tail = chain[url], !tail.started, tail.doc === doc {
            tail.pendingLogEntries.append(contentsOf: logEntries)
            return tail.task
        }

        let previous = chain[url]?.task
        let entry = ChainEntry(id: UUID(), doc: doc, pendingLogEntries: logEntries)
        entry.task = Task<Void, Error> { @MainActor in
            _ = try? await previous?.value
            // From here on, no more coalescing into this entry. Snapshot
            // the merged log entries on the same MainActor tick (no
            // suspension between `started = true` and the read).
            entry.started = true
            let logEntries = entry.pendingLogEntries
            defer {
                // Self-cleanup, success and failure alike: with
                // fire-and-forget enqueue nobody is guaranteed to await
                // this task, so it must clear its own slot — and only its
                // own (a newer entry may have replaced it mid-flight).
                if self.chain[url]?.id == entry.id {
                    self.chain.removeValue(forKey: url)
                }
            }
            do {
                try await self.work(entry.doc, logEntries)
            } catch {
                Diag.log.error("commit failed url=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                throw error
            }
        }
        chain[url] = entry
        return entry.task
    }

    /// Latest pending task for `url`, or nil when quiescent. Awaiting it
    /// gives durability of everything enqueued so far for that URL.
    func pendingTask(for url: URL) -> Task<Void, Error>? {
        chain[url]?.task
    }

    /// True when no work is pending for `url`.
    func isQuiescent(at url: URL) -> Bool {
        chain[url] == nil
    }

    /// Snapshot every pending task and await them all, tolerating
    /// errors (failures have already been logged and surfaced to any
    /// awaiting caller). Used by terminal teardown — see
    /// `Clamshell.drain()`.
    func drainAll() async {
        let tasks = chain.values.compactMap { $0.task }
        for task in tasks {
            _ = try? await task.value
        }
    }
}
