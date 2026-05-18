import Foundation
import Editor

/// File-presenter watch over a Document's URL. Owns the NSFilePresenter
/// lifecycle, the wakeup debounce, conflict-version merging, disk-content
/// classification (echo / stomp / external), and reconcile-against-log.
/// The host calls `openPage(at:onEvent:)`/`closePage(_:)`; the presenter
/// is installed/removed internally as part of that lifecycle. Host reacts
/// to one `PresenterEvent` per wakeup for UI bookkeeping (banners,
/// workspace rescan, title cache refresh).
@MainActor
extension Clamshell {
    /// What happened to the page during a presenter wakeup. Always
    /// preceded by Clamshell doing the filesystem-level work in place
    /// (conflict merge, content reload, journal reconcile). The host
    /// reacts only with UI/workspace bookkeeping.
    public enum PresenterEvent: Sendable {
        /// Presenter woke up but no page-content change was significant.
        /// Sibling files may have changed — host typically rescans the
        /// workspace.
        case noteworthyNothing

        /// External writer rewrote this page; Clamshell swapped the doc's
        /// children + modificationDate in place. Host refreshes title
        /// cache for the doc and rescans the workspace.
        case externallyReloaded

        /// iCloud conflict alternates merged into the live doc in place.
        /// `salvaged` blocks were pulled from alternates; host shows a
        /// banner when count > 0.
        case conflictMerged(salvaged: Int)

        /// Auto-restore from the recovery-log journal landed `count`
        /// blocks in the live doc. Host shows a banner.
        case restored(count: Int)
    }

    /// Opaque handle to a registered presenter. Internal — the host only
    /// sees it via `OpenPage` and passes the whole thing back to `closePage`.
    final class PresenterHandle {
        fileprivate let presenter: DocumentFilePresenter
        fileprivate init(_ presenter: DocumentFilePresenter) {
            self.presenter = presenter
        }
    }

    /// Install a file presenter on `doc.url` and start watching for disk
    /// changes. The callback fires after Clamshell has handled the
    /// filesystem-level response in place (conflict merge, content
    /// reload, journal reconcile). The host reacts only with
    /// UI/workspace bookkeeping.
    func installPresenter(
        for doc: Document,
        onEvent: @escaping @MainActor (PresenterEvent) -> Void
    ) -> PresenterHandle {
        let presenter = DocumentFilePresenter(url: doc.url) { [weak self, weak doc] in
            Task { @MainActor in
                guard let self, let doc else { return }
                let event = await self.handlePresenterWakeup(for: doc)
                onEvent(event)
            }
        }
        NSFileCoordinator.addFilePresenter(presenter)
        return PresenterHandle(presenter)
    }

    /// Tear down a previously-installed presenter. Idempotent.
    func removePresenter(_ handle: PresenterHandle) {
        NSFileCoordinator.removeFilePresenter(handle.presenter)
    }

    /// One open page — the Document the editor renders against and the
    /// file presenter handle. Hand back to `closePage(_:)` to tear down.
    /// The journal fold runs asynchronously after `openPage` returns; any
    /// restored subtrees splice into `document` in place and surface via
    /// `onEvent(.restored(count:))`, same as a presenter-wakeup restore.
    public struct OpenPage {
        public let document: Document
        let presenter: PresenterHandle
    }

    /// Load `url`, install the file presenter, and return immediately.
    /// The journal fold (reconcile-against-log) is **deferred**: it runs
    /// in a background Task after `openPage` returns, and any auto-
    /// restored subtrees fire `onEvent(.restored(count:))` so the host
    /// shows the same banner it would for a presenter-wakeup restore.
    /// Symmetric inverse: `closePage(_:)`.
    ///
    /// Why deferred: on iCloud workspaces, materializing the per-device
    /// `.history/<rel>/<device-id>.jsonl` files dominates time-to-page
    /// (4 device logs × ~1s of cold-cache fault-in). The common case has
    /// nothing to restore, so paying that cost on the critical path is
    /// pure latency. If the journal does have lost-but-alive blocks,
    /// they appear a few seconds after the editor renders, with a
    /// banner — same UX as iCloud delivering a foreign device's writes
    /// mid-session.
    ///
    /// `onEvent` fires after every presenter wakeup AND once after the
    /// deferred-reconcile background Task completes (only if it
    /// restored anything). Filesystem-level work is already done by the
    /// time the callback runs.
    @MainActor
    public func openPage(
        at url: URL,
        onEvent: @escaping @MainActor (PresenterEvent) -> Void
    ) async throws -> OpenPage {
        let total = perfStart()
        // Fast path: read + parse off MainActor. Skip the journal fold —
        // it's deferred below.
        let readT = perfStart()
        let files = self.files
        let (raw, blocks): (String, [Block]) = try await Task.detached(priority: .userInitiated) { [files, url] in
            let raw = try files.read(url)
            let blocks = BlockParser.parse(raw)
            return (raw, blocks)
        }.value
        perfEnd(readT, "openPage.read+parse", "url=\(url.lastPathComponent) bytes=\(raw.utf8.count) blocks=\(blocks.count)")
        let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        recordDiskContent(raw, at: url)
        let document = Document(url: url, children: blocks, modificationDate: mtime)

        let presT = perfStart()
        let presenter = installPresenter(for: document, onEvent: onEvent)
        perfEnd(presT, "openPage.installPresenter", "url=\(url.lastPathComponent)")

        // Deferred reconcile. `reconcileLive` gates on `isQuiescent`; if
        // the user is mid-save when this runs, it returns nil and the
        // next presenter wakeup (after the save completes) retries.
        Task { @MainActor [weak self, weak document] in
            guard let self, let document else { return }
            let deferredT = perfStart()
            do {
                if let summary = try await self.reconcileLive(document), summary.didChange {
                    onEvent(.restored(count: summary.restoredHashes.count))
                }
                perfEnd(deferredT, "openPage.deferredReconcile", "url=\(url.lastPathComponent)")
            } catch {
                Diag.merge.error("deferred reconcile failed url=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }

        perfEnd(total, "openPage.total", "url=\(url.lastPathComponent)")
        return OpenPage(document: document, presenter: presenter)
    }

    /// Symmetric inverse of `openPage`: flush any pending writes for the
    /// document and tear down its file presenter. Idempotent on repeated
    /// calls with the same `OpenPage`.
    @MainActor
    public func closePage(_ open: OpenPage) async {
        _ = await flush(open.document)
        removePresenter(open.presenter)
    }

    /// Internal wakeup handler. Runs the three filesystem-level phases —
    /// conflict-version merge, disk-content classification, reconcile
    /// against journal — and returns one event for the host. iCloud
    /// often delivers the `.md` and a sibling `.history/<rel>/<other-
    /// device>.jsonl` in the same burst; running reconcile on every
    /// wakeup catches the second case even when the `.md` hash hasn't
    /// moved. Priority for the returned event: conflictMerged > restored
    /// > externallyReloaded > noteworthyNothing.
    private func handlePresenterWakeup(for doc: Document) async -> PresenterEvent {
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return .noteworthyNothing }
        let url = doc.url

        // 1. iCloud conflict alternates. When merged into the live doc,
        //    the post-write `didSave` already reseeds the host's mtime
        //    + title cache via Clamshell's callback.
        var conflictSalvaged: Int? = nil
        do {
            let resolution = try await resolveConflictVersions(at: url, againstLive: doc)
            if resolution.liveDocumentMutated {
                conflictSalvaged = resolution.salvaged
            }
        } catch {
            Diag.merge.error("presenter resolve failed url=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }

        // 2. echo / stomp / external. Skipped when conflict merge
        //    already rewrote the doc — that path supersedes any
        //    classification of the prior disk state.
        var externallyReloaded = false
        if conflictSalvaged == nil {
            switch classifyDiskContent(at: url, expectingModificationDate: doc.modificationDate) {
            case .unchanged, .unreadable:
                break
            case .echo:
                if let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                    doc.modificationDate = mtime
                }
            case .stomp:
                if isQuiescent(at: url) {
                    Task { await self.flush(doc) }
                }
            case .external:
                if isQuiescent(at: url) {
                    do {
                        let reloaded = try loadDocument(at: url)
                        doc.replaceChildren(reloaded.children)
                        doc.modificationDate = reloaded.modificationDate
                        externallyReloaded = true
                    } catch {
                        Diag.merge.error("presenter reload failed url=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }

        // 3. Reconcile against the journal. Idempotent: already-live
        //    hashes produce no inserts; already-logged hashes produce no
        //    observations. Returns nil when the page isn't quiescent —
        //    the next wakeup retries.
        var restoredCount = 0
        do {
            if let summary = try await reconcileLive(doc), summary.didChange {
                restoredCount = summary.restoredHashes.count
            }
        } catch {
            Diag.merge.error("presenter reconcile failed url=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }

        if let salvaged = conflictSalvaged {
            return .conflictMerged(salvaged: salvaged)
        }
        if restoredCount > 0 {
            return .restored(count: restoredCount)
        }
        if externallyReloaded {
            return .externallyReloaded
        }
        return .noteworthyNothing
    }
}

/// NSFilePresenter shim. `presentedItemURL` is immutable across the
/// presenter's lifetime; the wakeup dispatches to a `@Sendable` closure
/// the registrar provides. Internal to the Clamshell module — the host
/// never names this type or its `PresenterHandle` wrapper directly.
final class DocumentFilePresenter: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue.main
    private let onChange: @Sendable () -> Void

    init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.presentedItemURL = url
        self.onChange = onChange
        super.init()
    }

    func presentedItemDidChange() { onChange() }
    func presentedItemDidMove(to newURL: URL) { onChange() }
}
