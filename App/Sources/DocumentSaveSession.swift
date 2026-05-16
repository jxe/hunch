import Foundation

/// Save-lifecycle state machine for one open document. Owns the debounce
/// (600ms after `markDirty`), the 30s backstop, the in-flight/pending dance
/// with `Clamshell.save`, and the `flushAndClose` shutdown. The actual save
/// work — serialization, disk write, title-cache refresh — is supplied by the
/// caller via `performSave` / `performFlush` closures; the session only
/// schedules and gates.
///
/// State transition table:
///
/// | from         | event              | to           | side effects                     |
/// |--------------|--------------------|--------------|----------------------------------|
/// | `.clean`     | `markDirty`        | `.dirty`     | schedule 600ms debounce          |
/// | `.dirty`     | `markDirty`        | `.dirty`     | reschedule debounce              |
/// | `.dirty`     | debounce fires     | `.saving`    | call `performSave`               |
/// | `.saving`    | `markDirty`        | `.savingDirty`| (defer; save in flight)         |
/// | `.savingDirty`| `markDirty`       | `.savingDirty`| (defer)                         |
/// | `.saving`    | save succeeds      | `.clean`     | —                                |
/// | `.saving`    | save fails         | `.dirty`     | schedule debounce (retry)        |
/// | `.savingDirty`| save completes    | `.dirty`     | schedule debounce                |
/// | `.*`         | `flushAndClose`    | `.closed`    | cancel debounce+backstop;        |
/// |              |                    |              | fire-and-forget final save+flush |
/// | `.closed`    | any                | `.closed`    | no-op                            |
///
/// Production usage: `WorkspaceWindow` creates a `DocumentSaveSession` per
/// open URL with closures captured against that URL's document, calls
/// `markDirty` on every `host.markDocumentDirty()`, calls `saveNow(force:)`
/// on blur or scenePhase change, and calls `flushAndClose` when the user
/// navigates to a different page.
@MainActor
final class DocumentSaveSession {
    enum State: Equatable {
        case clean
        case dirty
        case saving
        /// `markDirty` fired while a save was in flight — when this save
        /// completes, transition to `.dirty` (re-scheduling the debounce)
        /// rather than `.clean`, because there are unsaved edits.
        case savingDirty
        case closed
    }

    private(set) var state: State = .clean

    /// Debounce window for "user stopped typing → save". Default 600ms.
    static let debounceInterval: Duration = .milliseconds(600)
    /// Periodic save when the user keeps editing without ever stopping
    /// long enough to trigger debounce. Default 30s.
    static let backstopInterval: Duration = .seconds(30)

    private let performSave: () async -> Bool
    private let performFlush: () async -> Void

    private var debounceTask: Task<Void, Never>?
    private var backstopTask: Task<Void, Never>?

    init(
        performSave: @escaping () async -> Bool,
        performFlush: @escaping () async -> Void
    ) {
        self.performSave = performSave
        self.performFlush = performFlush
    }

    /// Convenience for callers that want to read save-pending status.
    var isDirty: Bool { state == .dirty || state == .savingDirty }

    /// Convenience for callers that want to read in-flight save status.
    var isSaving: Bool { state == .saving || state == .savingDirty }

    /// Note that the document was edited. Transitions to `.dirty` and
    /// (re)schedules the 600ms debounce. No-op once `.closed`.
    func markDirty() {
        switch state {
        case .clean, .dirty:
            state = .dirty
            scheduleDebounce()
        case .saving, .savingDirty:
            state = .savingDirty
        case .closed:
            break
        }
    }

    /// Save immediately. Cancels any pending debounce. Returns true on
    /// success or when there was nothing to save; false on save failure.
    /// `force: true` saves even when `.clean` (used by trash-while-dirty
    /// path and absorb-subpage, which need a guaranteed-on-disk snapshot).
    @discardableResult
    func saveNow(force: Bool = false) async -> Bool {
        debounceTask?.cancel()
        debounceTask = nil
        switch state {
        case .closed:
            return true
        case .clean:
            if !force { return true }
        case .dirty, .saving, .savingDirty:
            break
        }
        state = .saving
        let success = await performSave()
        switch state {
        case .saving:
            if success {
                state = .clean
            } else {
                state = .dirty
                scheduleDebounce()
            }
        case .savingDirty:
            state = .dirty
            scheduleDebounce()
        case .closed:
            break  // flushAndClose took over while we were saving
        case .clean, .dirty:
            break  // shouldn't reach (saving transitions handled above)
        }
        return success
    }

    /// Start the 30s backstop autosave. Cancels any prior backstop. Called
    /// after the session is wired up; the loop runs until `flushAndClose`.
    func startBackstop() {
        backstopTask?.cancel()
        backstopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.backstopInterval)
                guard !Task.isCancelled else { return }
                await self?.saveNow()
            }
        }
    }

    /// Cancel all pending tasks and queue a final save + flush. Returns
    /// synchronously; the save + flush survives this caller returning so a
    /// rapid page switch doesn't drop the latest snapshot (the per-URL
    /// `DocumentSaveCoordinator` inside Clamshell handles the queuing).
    /// Idempotent — second call is a no-op.
    func flushAndClose() {
        debounceTask?.cancel(); debounceTask = nil
        backstopTask?.cancel(); backstopTask = nil
        guard state != .closed else { return }
        let wasDirty = isDirty
        state = .closed
        Task { [performSave, performFlush, wasDirty] in
            if wasDirty {
                _ = await performSave()
            }
            await performFlush()
        }
    }

    private func scheduleDebounce() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounceInterval)
            guard !Task.isCancelled else { return }
            await self?.saveNow()
        }
    }
}
