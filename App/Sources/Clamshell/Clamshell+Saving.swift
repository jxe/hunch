import Foundation
import Editor

/// Editor-driven save lifecycle, keyed per URL.
///
/// The save model is commit-time atomic: every `documentDidChange(ops:in:)`
/// applies its op batch to the recovery log and writes the .md file as one
/// awaited sequence, log strictly before file. Concurrent calls for the same
/// URL are chained — each waits for the previous chain entry before its own
/// log + .md write, so a fast burst of commits (typing → focus blur →
/// navigation) lands in order and the file on disk always reflects the
/// last-applied batch.
///
/// There is no debounce, no separate per-op log task, no "armed" state. The
/// editor's commit points (`commitLiveText` → `afterCommit` hook for typing;
/// `mutate(_:_:)` for structural ops) are themselves the save events. To save
/// more often during a long typing burst, the editor would commit more often
/// — none of that is the persistence layer's concern.
@MainActor
extension Clamshell {
    /// Editor mutated `doc` and produced these `ops`. Applies the patch to
    /// the recovery log (when non-empty), then serializes the current `.md`
    /// and writes it. Calls for the same URL are chained — the spawned Task
    /// awaits any pending chain head for that URL before its own work, so
    /// rapid-fire commits land in order. Sync entry so the editor can call
    /// it from the mutation-commit thread without ceremony.
    public func documentDidChange(ops: [EditorOp], in doc: Document) {
        let patch: Patch = ops.isEmpty ? .empty : Patch.from(ops: ops)
        enqueueSave(doc, patch: patch)
    }

    /// Clamshell-internal "save this doc": chains a `.md` write onto the
    /// per-URL save queue with no log apply. Used by paths that mutated the
    /// live doc in place without going through the editor — reconcile's
    /// auto-restore splice, the manual restore splice, anything that already
    /// wrote its own log entries directly. Distinct name (vs.
    /// `documentDidChange`) because no editor actually changed anything;
    /// Clamshell did, and the journal is already current.
    func scheduleSave(_ doc: Document) {
        enqueueSave(doc, patch: .empty)
    }

    /// Force-save `doc` and drain pending writes for its URL. Awaits the
    /// most recent chain entry. For navigation / blur / scenePhase / close.
    @discardableResult
    public func flush(_ doc: Document) async -> Bool {
        guard let pending = saveChain[doc.url] else { return true }
        await pending.value
        saveChain.removeValue(forKey: doc.url)
        return true
    }

    /// True when no work is pending for `url`. The engine's reconcile and
    /// presenter paths gate on this — they assume
    /// `doc.children == parsed(.md)`, which is only true on a settled page.
    func isQuiescent(at url: URL) -> Bool {
        saveChain[url] == nil
    }

    private func enqueueSave(_ doc: Document, patch: Patch) {
        let url = doc.url
        let rel = relativePath(of: url)
        let previous = saveChain[url]
        let task = Task<Void, Never> { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                if !patch.isEmpty {
                    try await self.log.apply(patch, to: rel)
                }
                _ = try self.save(doc)
                self.postSaveBookkeeping(doc)
            } catch {
                Diag.log.error("save failed url=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
        saveChain[url] = task
    }
}
