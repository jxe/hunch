import Foundation
import Editor

/// File-presenter watch over a Document's URL. Owns the NSFilePresenter
/// lifecycle, the wakeup debounce, conflict-version merging, disk-content
/// classification (echo / stomp / external), and reconcile-against-log.
/// The host registers via `installPresenter(for:onEvent:)`, holds the
/// returned `PresenterHandle`, and reacts to a single `PresenterEvent` per
/// wakeup for UI bookkeeping (banners, workspace rescan, title cache
/// refresh).
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

    /// Opaque handle to a registered presenter. Pass to
    /// `removePresenter(_:)` to tear down. The host holds at most one
    /// handle per open document.
    public final class PresenterHandle {
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
    public func installPresenter(
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
    public func removePresenter(_ handle: PresenterHandle) {
        NSFileCoordinator.removeFilePresenter(handle.presenter)
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
/// the registrar provides. Internal to the Clamshell module — hosts hold
/// the opaque `PresenterHandle` returned by `installPresenter`.
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
