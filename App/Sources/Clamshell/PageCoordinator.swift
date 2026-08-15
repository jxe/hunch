import Foundation
import Quagmire

/// Per-URL page state machine. A coordinator exists while a page is open in
/// any editor, while a closed-page operation holds a transient lease, or while
/// persistence/synchronization work is outstanding. It owns the single
/// canonical `Document` for that interval.
@MainActor
extension Clamshell {
    /// Stable, lightweight facade for one workspace-relative page. It owns no
    /// live document state; each operation resolves the URL's current retiring
    /// coordinator through its Clamshell.
    @MainActor
    struct Page {
        let owner: Clamshell
        let url: URL

        var relativePath: String { owner.relativePath(of: url) }

        init(owner: Clamshell, url: URL) {
            self.owner = owner
            self.url = url.standardizedFileURL
        }

        func open(
            onEvent: @escaping @MainActor (PresenterEvent) -> Void
        ) async throws -> PageSession {
            let total = perfStart()
            let session = try await owner.coordinator(for: url).attachEditor(page: self, onEvent: onEvent)
            perfEnd(total, "page.open.total", "url=\(url.lastPathComponent)")
            return session
        }

        /// One-shot read that does not seed live-session disk history.
        func readBlocks() async throws -> [Block] {
            try await owner.readEnvelope(at: url).parsed.blocks
        }
    }

    /// One live editor attachment to a `Page`. The session holds the retiring
    /// coordinator for its entire open lifetime and is the host-facing surface
    /// for editor persistence and durability.
    @MainActor
    final class PageSession {
        let page: Page
        let document: Document

        private let id: UUID
        private let coordinator: PageCoordinator
        private var isClosed = false

        fileprivate init(
            page: Page,
            id: UUID,
            coordinator: PageCoordinator,
            document: Document
        ) {
            self.page = page
            self.id = id
            self.coordinator = coordinator
            self.document = document
        }

        @discardableResult
        func enqueueEditorChanges(_ changes: [DocumentChange]) -> Task<Void, Error> {
            precondition(!isClosed, "Cannot persist through a closed PageSession")
            return coordinator.enqueue(.fromEditorChanges(changes), for: document)
        }

        func flush() async throws {
            guard !isClosed else { return }
            try await coordinator.flush()
        }

        func close() async throws {
            guard !isClosed else { return }
            try await coordinator.detachEditor(id: id)
            isClosed = true
        }

        func cloudSyncSnapshot() -> CloudSyncSnapshot {
            page.cloudSyncSnapshot()
        }

        func compactThisDeviceLog() async throws -> LogCompactionResult {
            try await page.compactThisDeviceLog()
        }
    }

    @MainActor
    final class PageCoordinator {
        let url: URL
        /// Strong while work is outstanding. Clamshell's registry forms a
        /// temporary cycle that `retireIfIdle`/`shutdown` breaks; this keeps a
        /// deferred synchronization from dereferencing a released owner when a
        /// short-lived caller drops its last external Clamshell reference.
        let owner: Clamshell

        private(set) var document: Document?
        var modificationDate: Date?
        private var loadTask: Task<Document, Error>?

        private var subscribers: [UUID: @MainActor (PresenterEvent) -> Void] = [:]
        private(set) var presenter: PresenterHandle?
        private var transientLeaseCount = 0
        private var isShuttingDown = false

        private(set) var currentGeneration: UInt64 = 0
        private(set) var durableGeneration: UInt64 = 0

        private var requestedSyncGeneration: UInt64 = 0
        private var completedSyncGeneration: UInt64 = 0
        private var syncTask: Task<Void, Never>?

        /// One ordered write entry. The task waits for its predecessor before
        /// applying log entries and writing Markdown, preserving the existing
        /// log-before-file crash invariant without a separate global chain.
        private final class WriteEntry {
            let id = UUID()
            var throughGeneration: UInt64
            var logEntries: [Patch.Entry]
            var children: [Block]
            var modificationDate: Date?
            var started = false
            var task: Task<Void, Error>!

            init(
                generation: UInt64,
                logEntries: [Patch.Entry],
                children: [Block],
                modificationDate: Date?
            ) {
                self.throughGeneration = generation
                self.logEntries = logEntries
                self.children = children
                self.modificationDate = modificationDate
            }
        }

        private var writeTail: WriteEntry?

        init(
            owner: Clamshell,
            url: URL,
            document: Document? = nil,
            modificationDate: Date? = nil
        ) {
            self.owner = owner
            self.url = url.standardizedFileURL
            self.document = document
            self.modificationDate = modificationDate
        }

        var hasEditorSubscribers: Bool { !subscribers.isEmpty }
        var hasPendingWrite: Bool { writeTail != nil }
        var settledGeneration: UInt64? {
            !hasPendingWrite && currentGeneration == durableGeneration ? currentGeneration : nil
        }

        func remainsSettled(at generation: UInt64) -> Bool {
            settledGeneration == generation
        }

        func bindCanonicalDocument(_ candidate: Document) {
            if let document {
                precondition(document === candidate, "A PageCoordinator cannot own competing Document instances")
            } else {
                document = candidate
            }
        }

        func materializeDocument() async throws -> Document {
            if let document { return document }
            if let loadTask {
                let loaded = try await loadTask.value
                if let document { return document }
                document = loaded
                self.loadTask = nil
                return loaded
            }

            let task = Task<Document, Error> { @MainActor [owner, url] in
                let (raw, parsed) = try await owner.readEnvelope(at: url)
                let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                owner.recordDiskContent(raw, at: url)
                owner.rememberEnvelope(parsed, for: url)
                self.modificationDate = mtime
                return Document(
                    id: DocumentID(parsed.pageID ?? UUID().uuidString),
                    children: parsed.blocks,
                    fallbackTitle: url.deletingPathExtension().lastPathComponent
                )
            }
            loadTask = task
            do {
                let loaded = try await task.value
                loadTask = nil
                if let document { return document }
                document = loaded
                return loaded
            } catch {
                loadTask = nil
                throw error
            }
        }

        private func acquireTransientDocument() async throws -> Document {
            transientLeaseCount += 1
            do {
                return try await materializeDocument()
            } catch {
                transientLeaseCount -= 1
                retireIfIdle()
                throw error
            }
        }

        private func releaseTransientDocument() {
            precondition(transientLeaseCount > 0)
            transientLeaseCount -= 1
            retireIfIdle()
        }

        /// Run a closed-page operation against the URL's canonical document,
        /// retaining the coordinator for the full async operation and always
        /// releasing the transient lease afterward.
        func withTransientDocument<T>(
            _ operation: (Document) async throws -> T
        ) async throws -> T {
            let document = try await acquireTransientDocument()
            defer { releaseTransientDocument() }
            return try await operation(document)
        }

        func attachEditor(
            page: Page,
            onEvent: @escaping @MainActor (PresenterEvent) -> Void
        ) async throws -> PageSession {
            let document = try await materializeDocument()
            let id = UUID()
            subscribers[id] = onEvent
            if presenter == nil {
                presenter = owner.installPresenter(for: self)
            }
            requestSynchronization()
            return PageSession(page: page, id: id, coordinator: self, document: document)
        }

        func detachEditor(id: UUID) async throws {
            subscribers.removeValue(forKey: id)
            guard subscribers.isEmpty else { return }
            if let presenter {
                owner.removePresenter(presenter)
                self.presenter = nil
            }
            // The initial/open-page synchronization is deliberately
            // asynchronous. Once the final editor detaches there is no live
            // document to update or subscriber to notify, so cancel and join
            // it before retiring the coordinator instead of letting a closed
            // page remain registered until that fold happens to finish.
            syncTask?.cancel()
            _ = await syncTask?.value
            syncTask = nil
            try await flush()
            retireIfIdle()
        }

        func broadcast(_ event: PresenterEvent) {
            for subscriber in Array(subscribers.values) {
                subscriber(event)
            }
        }

        /// Synchronously installs the page's next durable generation. This is
        /// deliberately non-async so blur/navigation flushes cannot miss an
        /// editor commit that has already fired.
        @discardableResult
        func enqueue(_ commit: Commit, for candidate: Document) -> Task<Void, Error> {
            bindCanonicalDocument(candidate)
            currentGeneration &+= 1
            let generation = currentGeneration

            if let tail = writeTail, !tail.started {
                tail.logEntries.append(contentsOf: commit.logEntries)
                tail.throughGeneration = generation
                tail.children = candidate.children
                tail.modificationDate = modificationDate
                return tail.task
            }

            let previous = writeTail?.task
            let entry = WriteEntry(
                generation: generation,
                logEntries: commit.logEntries,
                children: candidate.children,
                modificationDate: modificationDate
            )
            entry.task = Task<Void, Error> { @MainActor [weak self, entry] in
                _ = try? await previous?.value
                guard let self else { return }
                entry.started = true
                let logEntries = entry.logEntries
                let generation = entry.throughGeneration
                let children = entry.children
                let modificationDate = entry.modificationDate
                defer {
                    if self.writeTail?.id == entry.id {
                        self.writeTail = nil
                    }
                    self.retireIfIdle()
                }
                do {
                    let savedMtime = try await self.owner.persist(
                        url: self.url,
                        children: children,
                        previousModificationDate: modificationDate,
                        logEntries: logEntries
                    )
                    self.durableGeneration = max(self.durableGeneration, generation)
                    if self.currentGeneration == generation { self.modificationDate = savedMtime }
                    self.startSyncLoopIfNeeded()
                } catch {
                    Diag.log.error("commit failed url=\(self.url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                    throw error
                }
            }
            writeTail = entry
            return entry.task
        }

        func flush() async throws {
            guard let pending = writeTail?.task else { return }
            try await pending.value
        }

        func requestSynchronization() {
            guard !isShuttingDown else { return }
            requestedSyncGeneration &+= 1
            startSyncLoopIfNeeded()
        }

        private func startSyncLoopIfNeeded() {
            guard !isShuttingDown,
                  syncTask == nil,
                  completedSyncGeneration < requestedSyncGeneration else { return }
            syncTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.runSyncLoop()
                self.syncTask = nil
                self.retireIfIdle()
            }
        }

        private func runSyncLoop() async {
            while !Task.isCancelled,
                  completedSyncGeneration < requestedSyncGeneration {
                let requested = requestedSyncGeneration
                do {
                    try await flush()
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      !isShuttingDown,
                      settledGeneration != nil,
                      let document else { return }
                if let event = await owner.synchronizePage(self, document: document) {
                    broadcast(event)
                }
                completedSyncGeneration = requested
            }
        }

        func shutdown() async {
            isShuttingDown = true
            if let presenter {
                owner.removePresenter(presenter)
                self.presenter = nil
            }
            syncTask?.cancel()
            _ = await syncTask?.value
            syncTask = nil
            _ = try? await flush()
            subscribers.removeAll()
        }

        private func retireIfIdle() {
            guard subscribers.isEmpty,
                  transientLeaseCount == 0,
                  writeTail == nil,
                  syncTask == nil,
                  !isShuttingDown else { return }
            document = nil
            owner.removeCoordinatorIfIdle(self)
        }
    }
}
