import Foundation
import Editor

/// Editor-driven save lifecycle, keyed per URL.
///
/// Editor mutations call `documentDidChange(ops:in:)` and the lifecycle is
/// hidden from the host: log appends are routed automatically, the
/// 600ms debounce coalesces follow-on edits, and `didSave` fires after
/// each successful write so the host can refresh per-doc bookkeeping
/// without owning a timer.
///
/// Multi-window same-URL: a per-URL `PendingSave` captures the latest
/// `Document` handed in, so a second window's `documentDidChange` replaces
/// the first window's pending snapshot before the debounce fires. This
/// extends the per-URL coalescing the underlying
/// `DocumentSaveCoordinator` already does for in-flight writes.
@MainActor
extension Clamshell {
    static let debounceInterval: Duration = .milliseconds(600)

    /// Editor or external mutator just changed `doc`. Non-empty `ops` spawn
    /// a log-apply Task — tracked on the pending entry so the save side
    /// can await its durability before writing the `.md`. The 600ms
    /// debounce is (re)armed regardless. Empty `ops` means a text-only
    /// typing edit or a pure reorder/move — nothing to log, but the
    /// debounce still fires.
    ///
    /// Synchronous so the host can call it from the mutation-commit thread
    /// without ceremony; durability happens off-actor and is barriered at
    /// save time (see `awaitLogDurable`).
    public func documentDidChange(ops: [EditorOp], in doc: Document) {
        let url = doc.url
        if !ops.isEmpty {
            let patch = Patch.from(ops: ops)
            let page = relativePath(of: url)
            let task: Task<Void, Error> = Task { [log] in
                try await log.apply(patch, to: page)
            }
            var entry = pending[url] ?? PendingSave(debounceTask: nil, pendingDoc: doc, isSaving: false)
            entry.latestLogTask = task
            pending[url] = entry
        }
        scheduleDebouncedSave(for: doc)
    }

    /// Force-save `doc` and drain pending writes for its URL. Returns when
    /// the bytes are on disk. Use for blur, scenePhase backgrounding,
    /// navigation-away, app shutdown — anything that needs a guaranteed
    /// on-disk snapshot before continuing.
    @discardableResult
    public func flush(_ doc: Document) async -> Bool {
        let url = doc.url
        pending[url]?.debounceTask?.cancel()
        pending[url]?.debounceTask = nil
        await awaitLogDurable(url: url)
        let success = await performSave(doc)
        try? await saver.flush(url: url)
        clearPendingIfQuiet(url: url, after: doc)
        return success
    }

    /// Block until the latest log-apply Task for `url` has completed. The
    /// log actor serializes apply calls, so awaiting the latest task
    /// guarantees every prior batch's effects are also durable. Errors are
    /// logged but not propagated — the file save still proceeds, and the
    /// next open's reconcile lifts any unlogged content via observations.
    private func awaitLogDurable(url: URL) async {
        guard let task = pending[url]?.latestLogTask else { return }
        do {
            try await task.value
        } catch {
            Diag.log.error("log apply failed url=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
        pending[url]?.latestLogTask = nil
    }

    /// True if there is no pending or in-flight save for `url`. Reconcile
    /// and presenter paths gate on this — the engine's invariant is
    /// `doc.children == parsed(.md)`, only true when nothing is pending.
    public func isClean(at url: URL) -> Bool {
        pending[url] == nil
    }

    private func scheduleDebouncedSave(for doc: Document) {
        let url = doc.url
        var entry = pending[url] ?? PendingSave(debounceTask: nil, pendingDoc: doc, isSaving: false)
        entry.pendingDoc = doc
        entry.debounceTask?.cancel()
        entry.debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounceInterval)
            guard !Task.isCancelled else { return }
            await self?.fireScheduledSave(url: url)
        }
        pending[url] = entry
    }

    private func fireScheduledSave(url: URL) async {
        guard let entry = pending[url], !entry.isSaving else { return }
        let doc = entry.pendingDoc
        pending[url]?.debounceTask = nil
        await awaitLogDurable(url: url)
        _ = await performSave(doc)
        clearPendingIfQuiet(url: url, after: doc)
    }

    private func performSave(_ doc: Document) async -> Bool {
        pending[doc.url]?.isSaving = true
        do {
            _ = try await save(doc)
            pending[doc.url]?.isSaving = false
            didSave?(doc)
            return true
        } catch {
            Diag.log.error("save failed url=\(doc.url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            pending[doc.url]?.isSaving = false
            return false
        }
    }

    /// Drop the pending entry if nothing arrived during the save — i.e. the
    /// pendingDoc is still the one we just wrote and no debounce is armed.
    /// A new edit during the save leaves the entry in place so its debounce
    /// keeps running.
    private func clearPendingIfQuiet(url: URL, after doc: Document) {
        guard let post = pending[url],
              post.pendingDoc === doc,
              !post.isSaving,
              post.debounceTask == nil,
              post.latestLogTask == nil else { return }
        pending[url] = nil
    }
}
