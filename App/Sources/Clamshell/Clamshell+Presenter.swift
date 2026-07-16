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

/// File-presenter integration for a page coordinator. The coordinator owns
/// lifecycle and sticky synchronization state; this file supplies the two
/// NSFilePresenters and the conflict/classify/reconcile synchronization effect.
/// The host calls `Page.open(onEvent:)`/`PageSession.close()`; the presenter
/// is installed/removed internally as part of that lifecycle. The host reacts
/// to noteworthy `PresenterEvent`s for UI bookkeeping (banners).
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
        /// `Page.resolveConflicts()` returns zero otherwise).
        case conflictMerged(salvaged: Int)

        /// Auto-restore from the recovery-log journal landed `count`
        /// blocks in the live doc.
        case restored(count: Int)
    }

    /// Opaque handle to a registered pair of presenters. Internal — the
    /// host only sees its effects through a `PageSession`.
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
    func installPresenter(for page: PageCoordinator) -> PresenterHandle {
        let url = page.url
        let debouncer = PresenterWakeupDebouncer { [weak page] in
            page?.requestSynchronization()
        }
        let fire: @Sendable () -> Void = { [weak debouncer] in
            Task { @MainActor in
                debouncer?.schedule()
            }
        }
        let documentPresenter = DocumentFilePresenter(url: url, onChange: fire)
        NSFileCoordinator.addFilePresenter(documentPresenter)

        let rel = relativePath(of: url)
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
    func removePresenter(_ handle: PresenterHandle) {
        handle.debouncer.cancel()
        NSFileCoordinator.removeFilePresenter(handle.document)
        NSFileCoordinator.removeFilePresenter(handle.history)
    }

    /// Terminal teardown: await every pending save, then tear down any
    /// remaining page coordinators (presenters removed, registry cleared).
    /// The owner must call this before releasing the Clamshell so pending
    /// coordinator generations reach disk. See
    /// `Workspace.switchWorkspace()` for the canonical call site.
    func drain() async {
        let coordinators = Array(pageCoordinators.values)
        for coordinator in coordinators {
            await coordinator.shutdown()
        }
        pageCoordinators.removeAll()
    }

    /// Internal wakeup handler. Runs the three filesystem-level phases —
    /// conflict-version merge, disk-content classification, reconcile
    /// against journal — and returns one event for the host, or nil when
    /// nothing noteworthy happened. iCloud
    /// often delivers the `.md` and a sibling `.history/<rel>/<other-
    /// device>.jsonl` in the same burst; running reconcile on every wakeup
    /// catches same-device crash recovery and already-absorbed peer records.
    /// A future peer log that arrives before its `.md` is deferred so the
    /// later external reload preserves the peer edit's exact placement.
    /// Priority for the returned event: conflictMerged > restored.
    func synchronizePage(_ page: PageCoordinator, document doc: Document) async -> PresenterEvent? {
        let url = doc.url

        precondition(page.document === doc)

        // 1. iCloud conflict alternates. When merged into the live doc,
        //    the post-write `didSave` already reseeds the host's mtime
        //    + title cache via Clamshell's callback.
        var conflictSalvaged: Int? = nil
        do {
            let salvaged = try await self.page(at: url).resolveConflicts()
            if salvaged > 0 {
                conflictSalvaged = salvaged
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
                do {
                    try await commit(Commit(logEntries: []), to: doc)
                } catch {
                    Diag.log.error("stomp rewrite failed url=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                }
            case .external:
                // Quiescence is guaranteed by the upfront flush.
                guard let generation = page.settledGeneration else {
                    page.requestSynchronization()
                    break
                }
                do {
                    let (raw, parsed) = try await readEnvelope(at: url)
                    let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    guard page.remainsSettled(at: generation) else {
                        // The user edited while the coordinated read was in
                        // flight. Keep the canonical local tree and retry once
                        // that newer generation is durable.
                        page.requestSynchronization()
                        break
                    }
                    recordDiskContent(raw, at: url)
                    rememberEnvelope(parsed, for: url)
                    doc.replaceChildrenFromExternalReload(parsed.blocks)
                    doc.modificationDate = mtime
                } catch {
                    Diag.merge.error("presenter reload failed url=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                }
            }
        }

        // 3. Reconcile against the journal. Idempotent: already-live
        //    hashes produce no inserts; already-logged hashes produce no
        //    observations. Returns nil when a newer local generation landed
        //    during the fold; the coordinator retains a sticky retry request.
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
