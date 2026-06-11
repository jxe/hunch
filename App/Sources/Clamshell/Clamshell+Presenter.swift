import Foundation
import Editor

@MainActor
private final class PresenterWakeupDebouncer {
    private let delay: Duration
    private let action: @MainActor () async -> Void
    private var task: Task<Void, Never>?
    private var isRunning = false
    private var rerunAfterCurrent = false

    init(
        delay: Duration = .milliseconds(250),
        action: @escaping @MainActor () async -> Void
    ) {
        self.delay = delay
        self.action = action
    }

    func schedule() {
        if isRunning {
            rerunAfterCurrent = true
            return
        }
        task?.cancel()
        task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: self?.delay ?? .milliseconds(250))
            } catch {
                return
            }
            await self?.drain()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        rerunAfterCurrent = false
    }

    private func drain() async {
        task = nil
        isRunning = true
        repeat {
            rerunAfterCurrent = false
            await action()
        } while rerunAfterCurrent
        isRunning = false
    }
}

/// File-presenter watch over a Document's URL. Owns the NSFilePresenter
/// lifecycle, the wakeup debounce, conflict-version merging, disk-content
/// classification (echo / stomp / external), and reconcile-against-log.
/// The host calls `openPage(at:onEvent:)`/`closePage(_:)`; the presenter
/// is installed/removed internally as part of that lifecycle. Host reacts
/// to one `PresenterEvent` per wakeup for UI bookkeeping (banners,
/// workspace rescan, title cache refresh).
@MainActor
extension Clamshell {
    /// A noteworthy outcome of a presenter wakeup (or the deferred
    /// open-page reconcile). Always preceded by Clamshell doing the
    /// filesystem-level work in place — conflict merge, content reload,
    /// journal reconcile; the host reacts only with UI bookkeeping
    /// (banners). Non-noteworthy wakeups (echo, stomp re-save, external
    /// reload, nothing at all) don't emit an event: Clamshell handles
    /// them internally and `@Observable` re-renders cover the UI.
    enum PresenterEvent: Sendable {
        /// iCloud conflict alternates merged into the live doc in place,
        /// salvaging `salvaged` blocks (> 0 by construction —
        /// `resolveConflictVersions` reports `.none` otherwise).
        case conflictMerged(salvaged: Int)

        /// Auto-restore from the recovery-log journal landed `count`
        /// blocks in the live doc.
        case restored(count: Int)
    }

    /// Opaque handle to a registered pair of presenters. Internal — the
    /// host only sees it via `OpenPage` and passes the whole thing back
    /// to `closePage`.
    ///
    /// Two presenters per open page:
    /// 1. `document` watches the `.md` itself. Catches user edits made by
    ///    other apps and foreign-device `.md` syncs.
    /// 2. `history` watches the per-page `.history/<rel>/` directory.
    ///    Catches foreign-device `.jsonl` syncs that arrive without (or
    ///    before) a corresponding `.md` change — eager restore, late
    ///    purge arrivals, etc. Both fire the same wakeup handler; it's
    ///    idempotent and self-debouncing.
    final class PresenterHandle {
        fileprivate let document: DocumentFilePresenter
        fileprivate let history: DocumentHistoryPresenter
        fileprivate let debouncer: PresenterWakeupDebouncer
        fileprivate init(
            document: DocumentFilePresenter,
            history: DocumentHistoryPresenter,
            debouncer: PresenterWakeupDebouncer
        ) {
            self.document = document
            self.history = history
            self.debouncer = debouncer
        }
    }

    /// Install both presenters (`.md` and `.history/<rel>/`) and start
    /// watching for disk changes. The callback fires after Clamshell has
    /// handled the filesystem-level response in place (conflict merge,
    /// content reload, journal reconcile). The host reacts only with
    /// UI/workspace bookkeeping.
    private func installPresenter(
        for doc: Document,
        onEvent: @escaping @MainActor (PresenterEvent) -> Void
    ) -> PresenterHandle {
        let debouncer = PresenterWakeupDebouncer { [weak self, weak doc] in
            guard let self, let doc else { return }
            if let event = await self.handlePresenterWakeup(for: doc) {
                onEvent(event)
            }
        }
        let fire: @Sendable () -> Void = { [weak debouncer] in
            Task { @MainActor in
                debouncer?.schedule()
            }
        }
        let documentPresenter = DocumentFilePresenter(url: doc.url, onChange: fire)
        NSFileCoordinator.addFilePresenter(documentPresenter)

        let rel = relativePath(of: doc.url)
        let historyDir = root
            .appendingPathComponent(RecoveryLog.directoryName, isDirectory: true)
            .appendingPathComponent(rel, isDirectory: true)
        let historyPresenter = DocumentHistoryPresenter(directory: historyDir, onChange: fire)
        NSFileCoordinator.addFilePresenter(historyPresenter)

        return PresenterHandle(
            document: documentPresenter,
            history: historyPresenter,
            debouncer: debouncer
        )
    }

    /// Tear down previously-installed presenters. Idempotent.
    private func removePresenter(_ handle: PresenterHandle) {
        handle.debouncer.cancel()
        NSFileCoordinator.removeFilePresenter(handle.document)
        NSFileCoordinator.removeFilePresenter(handle.history)
    }

    /// One open page — the Document the editor renders against and the
    /// file presenter handle. Hand back to `closePage(_:)` to tear down.
    /// The journal fold runs asynchronously after `openPage` returns; any
    /// restored subtrees splice into `document` in place and surface via
    /// `onEvent(.restored(count:))`, same as a presenter-wakeup restore.
    struct OpenPage {
        fileprivate let id: UUID
        let document: Document
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
    /// `onEvent` fires only for noteworthy outcomes — a conflict merge or
    /// a journal restore that mutated the live doc — whether from a
    /// presenter wakeup or the deferred-reconcile background Task.
    /// Filesystem-level work is already done by the time the callback
    /// runs; non-noteworthy wakeups are handled internally and emit
    /// nothing.
    @MainActor
    func openPage(
        at url: URL,
        onEvent: @escaping @MainActor (PresenterEvent) -> Void
    ) async throws -> OpenPage {
        let url = url.standardizedFileURL
        let subscriberID = UUID()
        if let live = livePages[url] {
            live.subscribers[subscriberID] = onEvent
            return OpenPage(id: subscriberID, document: live.document)
        }

        let total = perfStart()
        // Fast path: read + parse off MainActor. Skip the journal fold —
        // it's deferred below.
        let readT = perfStart()
        let (raw, parsed) = try await readEnvelope(at: url)
        perfEnd(readT, "openPage.read+parse", "url=\(url.lastPathComponent) bytes=\(raw.utf8.count) blocks=\(parsed.blocks.count)")
        let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        recordDiskContent(raw, at: url)
        rememberEnvelope(parsed, for: url)
        let document = Document(url: url, children: parsed.blocks, modificationDate: mtime)

        let presT = perfStart()
        let presenter = installPresenter(for: document) { [weak self] event in
            self?.broadcastPresenterEvent(event, for: url)
        }
        perfEnd(presT, "openPage.installPresenter", "url=\(url.lastPathComponent)")

        livePages[url] = LivePage(
            url: url,
            document: document,
            presenter: presenter,
            firstSubscriberID: subscriberID,
            onEvent: onEvent
        )

        // Deferred reconcile. `reconcileLive` gates on `isQuiescent`; if
        // the user is mid-save when this runs, it returns nil and the
        // next presenter wakeup (after the save completes) retries.
        Task(priority: .utility) { @MainActor [weak self, weak document] in
            guard let self, let document else { return }
            let deferredT = perfStart()
            do {
                if let summary = try await self.reconcileLive(document), summary.didChange {
                    self.broadcastPresenterEvent(
                        .restored(count: summary.restoredHashes.count),
                        for: url
                    )
                }
                perfEnd(deferredT, "openPage.deferredReconcile", "url=\(url.lastPathComponent)")
            } catch {
                Diag.merge.error("deferred reconcile failed url=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }

        perfEnd(total, "openPage.total", "url=\(url.lastPathComponent)")
        return OpenPage(id: subscriberID, document: document)
    }

    /// Symmetric inverse of `openPage`: flush any pending writes for the
    /// document and tear down its file presenter. Idempotent on repeated
    /// calls with the same `OpenPage`.
    @MainActor
    func closePage(_ open: OpenPage) async throws {
        let url = open.document.url.standardizedFileURL
        guard let live = livePages[url], live.document === open.document else {
            try await flush(open.document)
            return
        }
        live.subscribers.removeValue(forKey: open.id)
        guard live.subscribers.isEmpty else { return }
        try await flush(open.document)
        removePresenter(live.presenter)
        livePages.removeValue(forKey: url)
    }

    func liveDocument(at url: URL) -> Document? {
        livePages[url.standardizedFileURL]?.document
    }

    /// Terminal teardown: await every pending save, then tear down any
    /// remaining live pages (presenters removed, registry cleared). The
    /// owner must hold a strong reference to this Clamshell until drain
    /// returns — the save-chain work captures `self` weakly, so disposing
    /// before drain can silently drop pending commits. See
    /// `Workspace.switchWorkspace()` for the canonical call site.
    func drain() async {
        await drainSaveChain()
        for live in livePages.values {
            removePresenter(live.presenter)
        }
        livePages.removeAll()
    }

    private func broadcastPresenterEvent(_ event: PresenterEvent, for url: URL) {
        guard let live = livePages[url.standardizedFileURL] else { return }
        let subscribers = Array(live.subscribers.values)
        for subscriber in subscribers {
            subscriber(event)
        }
    }

    /// Internal wakeup handler. Runs the three filesystem-level phases —
    /// conflict-version merge, disk-content classification, reconcile
    /// against journal — and returns one event for the host, or nil when
    /// nothing noteworthy happened. iCloud
    /// often delivers the `.md` and a sibling `.history/<rel>/<other-
    /// device>.jsonl` in the same burst; running reconcile on every
    /// wakeup catches the second case even when the `.md` hash hasn't
    /// moved. Priority for the returned event: conflictMerged > restored.
    private func handlePresenterWakeup(for doc: Document) async -> PresenterEvent? {
        let url = doc.url

        // Drain any pending save so doc.children, the journal, and .md
        // are coherent before we classify or reconcile. Cheap when
        // nothing is in flight (chain entries self-clean on completion,
        // so this is a no-op on a settled page); essential when Mac is
        // actively editing as iOS's bytes land.
        do {
            try await flush(doc)
        } catch {
            Diag.log.error("presenter flush failed url=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }

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
        //    classification of the prior disk state. External reloads
        //    swap the doc's children in place; no event — @Observable
        //    re-renders carry the new content to the UI.
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
                    Task {
                        do {
                            try await self.flush(doc)
                        } catch {
                            Diag.log.error("stomp flush failed url=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                        }
                    }
                }
            case .external:
                // Quiescence is guaranteed by the upfront flush.
                do {
                    let reloaded = try await loadDocument(at: url)
                    doc.replaceChildrenFromExternalReload(reloaded.children)
                    doc.modificationDate = reloaded.modificationDate
                } catch {
                    Diag.merge.error("presenter reload failed url=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
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
        return nil
    }
}

/// NSFilePresenter shim watching the page's `.md` itself.
/// `presentedItemURL` is immutable across the presenter's lifetime; the
/// wakeup dispatches to a `@Sendable` closure the registrar provides.
/// Internal to the Clamshell module — the host never names this type or
/// its `PresenterHandle` wrapper directly.
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

/// NSFilePresenter shim watching the per-page `.history/<rel>/` directory
/// for foreign `.jsonl` changes. macOS routes per-subitem notifications to
/// directory presenters; we treat any change as "a peer device's log
/// updated, run reconcile." Fires the same closure as the `.md`-watching
/// presenter — the wakeup handler is idempotent and 250ms-debounced, so a
/// burst from both presenters during a multi-file iCloud sync coalesces
/// cleanly.
///
/// Note: NSFilePresenter tolerates a non-existent `presentedItemURL`.
/// Pages with no log activity yet have no `.history/<rel>/` dir on disk
/// — that's fine, the presenter sits dormant until the dir materialises
/// (typically via a foreign device's first log sync, which `iCloud`
/// reports as a `presentedSubitemDidAppear`).
final class DocumentHistoryPresenter: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue.main
    private let onChange: @Sendable () -> Void

    init(directory: URL, onChange: @escaping @Sendable () -> Void) {
        self.presentedItemURL = directory
        self.onChange = onChange
        super.init()
    }

    func presentedSubitemDidChange(at url: URL) { onChange() }
    func presentedSubitemDidAppear(at url: URL) { onChange() }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { onChange() }
}
