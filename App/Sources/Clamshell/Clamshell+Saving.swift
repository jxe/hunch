import Foundation
import Editor

/// Editor-driven save lifecycle, keyed per URL.
///
/// Per-URL `SaveState` is an explicit state machine:
///
/// - **clean** — entry absent; no work pending.
/// - **armed** — a 600ms debounce is running; `latestLogTask` (if any) is
///   the most recent log-apply Task. Awaited at save time so the log is
///   at-or-ahead of the `.md` on disk.
/// - **saving** — a file write is in flight; `queued` (if any) captures
///   edits that arrived during the save. The save Task itself transitions
///   state on completion: with queued ⇒ back to `.armed`; without ⇒ clean.
///
/// Multi-window same-URL: a second window's `documentDidChange` reaches
/// markDirty for the same URL; whichever transition matches the current
/// state (armed/saving) refreshes or queues the latest Document reference.
@MainActor
extension Clamshell {
    static let debounceInterval: Duration = .milliseconds(600)

    enum SaveState {
        case armed(Armed)
        case saving(Saving)

        struct Armed {
            var latest: Document
            var debounce: Task<Void, Never>
            /// The log actor serializes applies per page, so awaiting the
            /// most recent task guarantees every prior batch is also durable.
            var latestLogTask: Task<Void, Error>?
        }

        struct Saving {
            var savingDoc: Document
            var savingTask: Task<Bool, Never>
            /// Edits that arrived during this save. On completion the save
            /// Task drains these into a fresh `.armed` state instead of
            /// returning to clean.
            var queued: Queued?
        }

        struct Queued {
            var latest: Document
            var latestLogTask: Task<Void, Error>?
        }
    }

    /// Editor mutated `doc` and produced these `ops`. Non-empty op batches
    /// project to a `Patch` and are spawned as a tracked log-apply Task
    /// (awaited at save time so the log lands at-or-ahead of the file);
    /// the 600ms debounce is (re)armed regardless. Empty ops mean a text-
    /// only typing edit or pure reorder — no log work, just markDirty.
    /// Sync so the editor can call it from the mutation-commit thread
    /// without ceremony.
    public func documentDidChange(ops: [EditorOp], in doc: Document) {
        guard !ops.isEmpty else { markDirty(doc); return }
        let patch = Patch.from(ops: ops)
        let page = relativePath(of: doc.url)
        let logTask: Task<Void, Error> = Task { [log] in
            try await log.apply(patch, to: page)
        }
        scheduleDebouncedSave(for: doc, logTask: logTask)
    }

    /// `doc` was mutated structurally by something other than the editor's
    /// op pipeline (reconcile splice, manual restore) and the journal is
    /// already correct — only the `.md` is stale. Arm a debounced save
    /// without logging. Internal: outside callers go through
    /// `documentDidChange(ops:in:)` (with empty ops for the "no new log
    /// info" case).
    func markDirty(_ doc: Document) {
        scheduleDebouncedSave(for: doc, logTask: nil)
    }

    /// Force-save `doc` and drain pending writes for its URL. Returns when
    /// the bytes are on disk.
    @discardableResult
    public func flush(_ doc: Document) async -> Bool {
        let url = doc.url
        // Drain any in-flight save. `saveCompleted` runs inside the saving
        // Task before `.value` returns, so by the time we resume the state
        // has transitioned to `.armed` (if edits queued) or `.clean`.
        if case .saving(let s) = saveStates[url] {
            _ = await s.savingTask.value
        }
        // If a fresh `.armed` was drained from the queue, cancel its
        // debounce and barrier on its log — we're taking over.
        if case .armed(let a) = saveStates[url] {
            a.debounce.cancel()
            await awaitLog(a.latestLogTask)
            saveStates[url] = nil
        }
        let task = driveSave(doc)
        let success = await task.value
        try? await saver.flush(url: url)
        return success
    }

    /// True when no work is pending for `url`. The engine's reconcile and
    /// presenter paths gate on this — they assume
    /// `doc.children == parsed(.md)`, which is only true on a settled page.
    func isQuiescent(at url: URL) -> Bool {
        saveStates[url] == nil
    }

    // MARK: - State machine transitions

    /// `.clean → .armed`, `.armed → .armed` (refresh debounce, merge log
    /// task), `.saving → .saving(queued: …)`. The single state-transition
    /// primitive every public mutator funnels through.
    private func scheduleDebouncedSave(for doc: Document, logTask: Task<Void, Error>?) {
        let url = doc.url
        switch saveStates[url] {
        case nil:
            saveStates[url] = .armed(.init(
                latest: doc,
                debounce: makeDebounce(url: url),
                latestLogTask: logTask
            ))
        case .armed(let a):
            a.debounce.cancel()
            saveStates[url] = .armed(.init(
                latest: doc,
                debounce: makeDebounce(url: url),
                latestLogTask: logTask ?? a.latestLogTask
            ))
        case .saving(var s):
            s.queued = .init(
                latest: doc,
                latestLogTask: logTask ?? s.queued?.latestLogTask
            )
            saveStates[url] = .saving(s)
        }
    }

    private func makeDebounce(url: URL) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(for: Self.debounceInterval)
            guard !Task.isCancelled else { return }
            await self?.debounceElapsed(url: url)
        }
    }

    /// `.armed → .saving`. No-op otherwise (cancelled debounce, raced flush).
    private func debounceElapsed(url: URL) async {
        guard case .armed(let a) = saveStates[url] else { return }
        await awaitLog(a.latestLogTask)
        _ = await driveSave(a.latest).value
    }

    /// Synchronously transition to `.saving` and return the in-flight Task.
    /// The Task itself calls `saveCompleted` before returning, so any
    /// awaiter of `task.value` sees the state already settled.
    private func driveSave(_ doc: Document) -> Task<Bool, Never> {
        let url = doc.url
        let task = Task<Bool, Never> { @MainActor [weak self] in
            guard let self else { return false }
            let success: Bool
            do {
                _ = try await self.save(doc)
                self.didSave?(doc)
                success = true
            } catch {
                Diag.log.error("save failed url=\(doc.url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                success = false
            }
            self.saveCompleted(url: url)
            return success
        }
        saveStates[url] = .saving(.init(savingDoc: doc, savingTask: task, queued: nil))
        return task
    }

    /// `.saving → .armed` if edits queued during the save; `.saving →
    /// .clean` otherwise.
    private func saveCompleted(url: URL) {
        guard case .saving(let s) = saveStates[url] else { return }
        if let q = s.queued {
            saveStates[url] = .armed(.init(
                latest: q.latest,
                debounce: makeDebounce(url: url),
                latestLogTask: q.latestLogTask
            ))
        } else {
            saveStates[url] = nil
        }
    }

    private func awaitLog(_ task: Task<Void, Error>?) async {
        guard let task else { return }
        do { try await task.value }
        catch {
            Diag.log.error("log apply failed error=\(error.localizedDescription, privacy: .public)")
        }
    }
}
