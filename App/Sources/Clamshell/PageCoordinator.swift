import Foundation
import Editor

/// Per-URL page state machine. A coordinator exists while a page is open in
/// any editor, while a closed-page operation holds a transient lease, or while
/// persistence/synchronization work is outstanding. It owns the single
/// canonical `Document` for that interval.
@MainActor
extension Clamshell {
    @MainActor
    final class PageCoordinator {
        let url: URL
        /// Strong while work is outstanding. Clamshell's registry forms a
        /// temporary cycle that `retireIfIdle`/`shutdown` breaks; this keeps a
        /// deferred synchronization from dereferencing a released owner when a
        /// short-lived caller drops its last external Clamshell reference.
        let owner: Clamshell

        private(set) var document: Document?
        private var loadTask: Task<Document, Error>?

        private var subscribers: [UUID: @MainActor (PresenterEvent) -> Void] = [:]
        private(set) var presenter: PresenterHandle?
        private var transientLeaseCount = 0
        private var isShuttingDown = false

        private(set) var currentGeneration: UInt64 = 0
        private(set) var durableGeneration: UInt64 = 0
        private(set) var failedGeneration: UInt64?

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

        init(owner: Clamshell, url: URL, document: Document? = nil) {
            self.owner = owner
            self.url = url.standardizedFileURL
            self.document = document
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
            let candidateURL = candidate.url.standardizedFileURL
            precondition(candidateURL == url)
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
                try await owner.loadDocument(at: url)
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

        func acquireTransientDocument() async throws -> Document {
            transientLeaseCount += 1
            do {
                return try await materializeDocument()
            } catch {
                transientLeaseCount -= 1
                retireIfIdle()
                throw error
            }
        }

        func releaseTransientDocument() {
            precondition(transientLeaseCount > 0)
            transientLeaseCount -= 1
            retireIfIdle()
        }

        func attachEditor(
            onEvent: @escaping @MainActor (PresenterEvent) -> Void
        ) async throws -> OpenPage {
            let document = try await materializeDocument()
            let id = UUID()
            subscribers[id] = onEvent
            if presenter == nil {
                presenter = owner.installPresenter(for: self)
            }
            requestSynchronization()
            return OpenPage(id: id, coordinator: self, document: document)
        }

        func detachEditor(id: UUID) async throws {
            subscribers.removeValue(forKey: id)
            guard subscribers.isEmpty else { return }
            if let presenter {
                owner.removePresenter(presenter)
                self.presenter = nil
            }
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
                tail.modificationDate = candidate.modificationDate
                return tail.task
            }

            let previous = writeTail?.task
            let entry = WriteEntry(
                generation: generation,
                logEntries: commit.logEntries,
                children: candidate.children,
                modificationDate: candidate.modificationDate
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
                    if self.currentGeneration == generation {
                        self.document?.modificationDate = savedMtime
                    }
                    self.failedGeneration = nil
                    self.startSyncLoopIfNeeded()
                } catch {
                    self.failedGeneration = generation
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
