import Foundation

/// Holds the one in-flight `@`-mention query so a newer keystroke cancels the
/// older one.
///
/// A reference rather than a value because `EditorView` is a struct whose
/// methods are non-mutating, and because the point is shared identity: every
/// call has to be able to cancel whatever the previous call started. Held by
/// `EditorView` as `@State`, so it lives as long as the editing session.
///
/// Cancellation is the courtesy; correctness comes from the caller re-checking
/// that the menu still wants this query before applying results. A cancelled
/// task that has already returned would otherwise still be racing.
@MainActor
final class MentionSearch {
    private var task: Task<Void, Never>?

    func run(_ operation: @escaping @MainActor () async -> Void) {
        task?.cancel()
        task = Task { @MainActor in
            await operation()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
