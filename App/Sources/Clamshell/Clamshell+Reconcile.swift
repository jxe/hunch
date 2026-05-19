import Foundation
import Editor

/// Engine orchestration: reconcile an open `Document` against its journal,
/// and restore a single lost or purged block back into its source page.
///
/// These used to live on the host (`WorkspaceWindow`) where they leaked
/// engine plumbing — reading the journal, deriving intent, building the
/// catch-up patch, splicing into the live doc, arming the debounce — into
/// the navigation layer. The host now owns only "which doc is open" and
/// "what banner to show"; everything else lives here.
@MainActor
extension Clamshell {
    /// What to bring back. `.lost` = latest record is an `add` but the hash
    /// isn't in the page's `.md`; `.purged` = latest record is a `purge`
    /// but a prior `add` still carries markdown + parent.
    enum RecoveryTarget: Sendable {
        case lost(LostBlock)
        case purged(PurgedBlock)

        var source: String {
            switch self {
            case .lost(let entry): return entry.source
            case .purged(let entry): return entry.source
            }
        }

        var hash: String {
            switch self {
            case .lost(let entry): return entry.hash
            case .purged(let entry): return entry.hash
            }
        }
    }

    enum RestoreError: Error {
        /// The source page no longer exists on disk (trashed since the
        /// Recover sheet was populated). Carries the workspace-relative path.
        case pageMissing(String)
        /// The recorded markdown for the chosen root failed to parse, or
        /// parses to a different hash than the log claims.
        case unparseable
    }

    /// Reconcile-against-journal on a live `Document`: mutate `doc` in
    /// place if the engine finds blocks to splice. Gated on
    /// `isQuiescent(at:)` — the engine assumes `doc.children ==
    /// parsed(.md)`, only true on a settled page. Returns nil when the
    /// gate fires, so the caller can distinguish "deferred, retry after
    /// flush" from "ran and found nothing." Used both by openPage (the
    /// initial post-load fold, deferred so it doesn't block first
    /// paint) and by presenter wakeups.
    @discardableResult
    func reconcileLive(_ doc: Document) async throws -> PatchEngine.ReconcileSummary? {
        guard isQuiescent(at: doc.url) else {
            Diag.merge.log("reconcileLive deferred url=\(doc.url.lastPathComponent, privacy: .public)")
            return nil
        }
        return try await runReconcile(on: doc)
    }

    /// Shared body: run the pure reconciliation, apply the catch-up
    /// patch, splice inserts, mark the file dirty. Caller has already
    /// decided which Document to operate on.
    private func runReconcile(on doc: Document) async throws -> PatchEngine.ReconcileSummary {
        let url = doc.url
        let rel = relativePath(of: url)
        let foldT = perfStart()
        let docChildren = doc.children
        let mdMtime = doc.modificationDate
        let outcome = await log.reconcileAgainst(
            page: rel,
            doc: docChildren,
            mdMtime: mdMtime
        )
        switch outcome {
        case .skipped:
            perfEnd(foldT, "runReconcile.skipped", "rel=\(rel)")
            return PatchEngine.ReconcileSummary(restoredHashes: [])
        case .folded(let recon, let mode):
            perfEnd(foldT, "runReconcile.folded", "rel=\(rel) mode=\(mode) inserts=\(recon.inserts.count) removes=\(recon.removes.count) observe=\(recon.toAppend.count) quarantine=\(recon.unrestorable.count)")
            // `toAppend` is emitted as `observe`, not `add`. The engine's
            // observations describe blocks the doc has but no device's log
            // has claimed yet — typically because iCloud delivered the
            // foreign device's `.md` before its `.jsonl`. Recording these
            // as `observe` keeps a snapshot for the Recover sheet without
            // making the hash auto-restore-eligible, so a subsequent
            // foreign delete won't trigger a spurious resurrect.
            var entries: [Patch.Entry] = []
            entries.reserveCapacity(recon.toAppend.count + recon.unrestorable.count)
            for obs in recon.toAppend {
                entries.append(.observe(hash: obs.hash, parent: obs.parent, markdown: obs.markdown))
            }
            for q in recon.unrestorable {
                entries.append(.purge(hash: q.hash))
            }
            Self.logUnrestorables(recon.unrestorable, url: url)

            if !entries.isEmpty {
                let applyT = perfStart()
                try await log.apply(Patch(entries: entries), to: rel)
                perfEnd(applyT, "runReconcile.logApply", "entries=\(entries.count)")
            }

            if recon.didChange {
                PatchEngine.apply(recon, to: doc)
                // `doc` is mutated in place (subtree removes + subtree
                // inserts). The journal already has the records that
                // make this consistent (`add`/`purge` per device). Save
                // the `.md` through the per-URL save chain so concurrent
                // user commits stay ordered.
                enqueueSave(doc, patch: .empty)
                let restoredCount = recon.restoredHashes.count
                let removedCount = recon.removes.count
                let removedHashes = recon.removes.map(\.hash).joined(separator: ",")
                Diag.merge.log("auto-restore url=\(url.lastPathComponent, privacy: .public) restored=\(restoredCount, privacy: .public) removed=\(removedCount, privacy: .public) roots=\(recon.inserts.count, privacy: .public) restoredHashes=\(recon.restoredHashes.joined(separator: ","), privacy: .public) removedHashes=\(removedHashes, privacy: .public)")
            }

            return PatchEngine.ReconcileSummary(restoredHashes: recon.restoredHashes)
        }
    }

    /// Restore a single lost or purged block into its source page. Pass
    /// `liveDoc` when the source page is currently open in some window so
    /// the splice mutates the same `Document` the editor renders; pass nil
    /// to load-from-disk and persist via the awaited `write(_:patch:)`.
    ///
    /// Lost-restore appends one `.purge` per covered hash so the Recover
    /// sheet stops surfacing the row. Purged-restore appends a fresh `.add`
    /// per covered hash so the union's latest record flips back to alive.
    /// Both happen in one batched log write.
    func restoreBlocks(_ target: RecoveryTarget, liveDoc: Document?) async throws {
        let source = target.source
        let pageURL = url(for: source)
        guard FileManager.default.fileExists(atPath: pageURL.path) else {
            throw RestoreError.pageMissing(source)
        }

        let (doc, isLive) = try await resolveRestoreDoc(pageURL: pageURL, liveDoc: liveDoc)

        let journal = log.readJournal(page: source)
        let intent = PatchEngine.intent(from: journal)

        // Build the candidate pool the engine will assemble a subtree from.
        // For lost: pull every alive-but-missing entry from intent. For
        // purged: pull every tombstoned-with-prior-add entry, adapted to the
        // engine's `LostBlock`-shape (recordedAt := purgedAt for forest sort).
        // The fallback candidate is the single row the user clicked — used
        // when the journal raced ahead of the UI (e.g. another device purged
        // the hash between sheet population and click).
        let candidates: [LostBlock]
        let fallback: LostBlock
        let purgedByHash: [String: PurgedBlock]
        switch target {
        case .lost(let entry):
            candidates = intent.lostEntries(notIn: [], source: source)
            fallback = entry
            purgedByHash = [:]
        case .purged(let entry):
            let all = await log.enumeratePurged(page: source, since: nil)
            candidates = all.map { p in
                LostBlock.adapt(
                    hash: p.hash,
                    parentHash: p.parentHash,
                    markdown: p.markdown,
                    source: p.source,
                    recordedAt: p.purgedAt
                )
            }
            fallback = LostBlock.adapt(
                hash: entry.hash,
                parentHash: entry.parentHash,
                markdown: entry.markdown,
                source: entry.source,
                recordedAt: entry.purgedAt
            )
            purgedByHash = Dictionary(uniqueKeysWithValues: all.map { ($0.hash, $0) })
        }

        guard let insert = PatchEngine.insertion(
            rootHash: target.hash,
            candidates: candidates,
            intent: intent,
            doc: doc.children
        ) ?? PatchEngine.insertion(
            rootHash: target.hash,
            candidates: [fallback],
            intent: intent,
            doc: doc.children
        ) else {
            throw RestoreError.unparseable
        }

        PatchEngine.apply(
            PatchEngine.Reconciliation(
                inserts: [insert],
                restoredHashes: Array(insert.coveredHashes)
            ),
            to: doc
        )

        // The follow-up patch differs by target kind: lost-restore writes
        // purges to silence the row; purged-restore writes fresh adds to
        // flip intent back to alive. Counter mints monotonically, so the
        // new records beat the prior latest in `(c, deviceID)` lex.
        let followUp: Patch
        switch target {
        case .lost:
            followUp = Patch(entries: insert.coveredHashes.map { .purge(hash: $0) })
        case .purged:
            var addEntries: [Patch.Entry] = []
            for hash in insert.coveredHashes {
                guard let record = purgedByHash[hash],
                      let parsed = BlockParser.parse(record.markdown).first else { continue }
                addEntries.append(.add(
                    hash: parsed.atomicHash,
                    parent: record.parentHash,
                    markdown: BlockSerializer.serializeAtomic(parsed)
                ))
            }
            followUp = Patch(entries: addEntries)
        }

        if isLive {
            // Splice already mutated `doc` in place; save the .md through
            // the per-URL save chain and apply the follow-up patch to the
            // log separately (it carries the tombstones / fresh adds the
            // restore needed).
            enqueueSave(doc, patch: .empty)
            if !followUp.isEmpty {
                do {
                    try await log.apply(followUp, to: source)
                } catch {
                    Diag.merge.error("restore follow-up failed page=\(source, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                }
            }
        } else {
            // Closed page: log the follow-up (purges-for-lost or
            // adds-for-purged) and the doc-blocks observation in one
            // batched apply, then write the merged .md. The doc-blocks
            // catch-up matches the `write(_:patch:)` full-doc-walk shape so
            // any bare-md absorbed at load time reaches the journal.
            let combined = Patch(entries: Patch.adds(from: doc.children).entries + followUp.entries)
            do {
                try await writeClosedPage(doc, patch: combined)
            } catch {
                Diag.merge.error("restore write failed page=\(source, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                throw error
            }
        }

    }

    private func resolveRestoreDoc(pageURL: URL, liveDoc: Document?) async throws -> (Document, Bool) {
        if let liveDoc, liveDoc.url == pageURL {
            return (liveDoc, true)
        }
        let doc = try await loadDocument(at: pageURL)
        return (doc, false)
    }

    private static func logUnrestorables(_ entries: [PatchEngine.UnrestorableEntry], url: URL) {
        guard !entries.isEmpty else { return }
        let hashList = entries.map(\.hash).joined(separator: ",")
        Diag.merge.error("reconcile quarantining url=\(url.lastPathComponent, privacy: .public) count=\(entries.count, privacy: .public) hashes=\(hashList, privacy: .public)")
        for entry in entries {
            let reasonLabel: String
            switch entry.reason {
            case .parseFailure: reasonLabel = "parseFailure"
            case .hashMismatch(let actual, let kind): reasonLabel = "hashMismatch actual=\(actual) kind=\(kind)"
            case .descendantOfUnrestorableRoot(let rootHash): reasonLabel = "descendantOf=\(rootHash)"
            }
            let mdPreview = entry.recordedMarkdown
                .prefix(160)
                .replacingOccurrences(of: "\n", with: "\\n")
            Diag.merge.error("unrestorable hash=\(entry.hash, privacy: .public) reason=\(reasonLabel, privacy: .public) parent=\(entry.recordedParent ?? "nil", privacy: .public) recordedAt=\(entry.recordedAt.timeIntervalSince1970, privacy: .public) md=\(String(mdPreview), privacy: .public)")
        }
    }
}
