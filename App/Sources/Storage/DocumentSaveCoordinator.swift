import Foundation
import Editor

/// Serialises writes per-document URL. Calls to `save(_:)` collapse: if a
/// write is already in flight for the same URL and another `save(_:)` arrives,
/// the newer snapshot replaces any pending one. The in-flight write completes
/// against its own snapshot, then a single follow-up write covers the latest.
/// This is what makes the four autosave triggers (debounce / blur /
/// scenePhase / 30s backstop) safe to fan in here without racing.
public actor DocumentSaveCoordinator {
    private let store: FileStore

    private struct SaveRequest: Sendable {
        var document: Document
        var titleForPath: @Sendable (String) -> String?
    }

    private struct State {
        var inFlight: Task<Void, Error>?
        var pending: SaveRequest?
    }

    private var states: [URL: State] = [:]

    public init(store: FileStore = FileStore()) {
        self.store = store
    }

    public func save(
        _ document: Document,
        resolvingSubpageTitle titleForPath: @Sendable @escaping (String) -> String? = { _ in nil }
    ) async throws {
        let request = SaveRequest(document: document, titleForPath: titleForPath)
        let url = request.document.url
        if states[url]?.inFlight != nil {
            states[url]?.pending = request
            return
        }
        try await runWriteLoop(initial: request)
    }

    /// Awaits any in-flight + pending write for the URL. Useful in tests and
    /// at app shutdown to guarantee the disk is current.
    public func flush(url: URL) async throws {
        while let task = states[url]?.inFlight {
            try await task.value
        }
    }

    private func runWriteLoop(initial: SaveRequest) async throws {
        let url = initial.document.url
        var current = initial
        let store = self.store
        while true {
            let snapshot = current
            let task = Task<Void, Error> { @Sendable [store] in
                try store.save(snapshot.document, resolvingSubpageTitle: snapshot.titleForPath)
            }
            states[url] = State(inFlight: task, pending: nil)
            try await task.value
            if let next = states[url]?.pending {
                states[url]?.pending = nil
                current = next
                continue
            }
            states[url] = nil
            return
        }
    }
}
