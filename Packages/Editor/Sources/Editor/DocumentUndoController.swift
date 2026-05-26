import Foundation
import SwiftUI

private struct DocumentUndoControllerKey: EnvironmentKey {
    static let defaultValue: DocumentUndoController? = nil
}

extension EnvironmentValues {
    /// The `DocumentUndoController` for the current `EditorView`. Editor views read this to
    /// register typing transactions and to break coalescing at edit-session boundaries.
    var documentUndoController: DocumentUndoController? {
        get { self[DocumentUndoControllerKey.self] }
        set { self[DocumentUndoControllerKey.self] = newValue }
    }
}

struct DocumentUndoControllerFocusKey: FocusedValueKey {
    typealias Value = DocumentUndoController
}

extension FocusedValues {
    /// The currently-focused `EditorView`'s undo controller. Used by the App-level
    /// CommandGroup that replaces `.undoRedo` so Cmd-Z routes to our shared manager
    /// regardless of which subview holds first responder.
    public var documentUndoController: DocumentUndoController? {
        get { self[DocumentUndoControllerFocusKey.self] }
        set { self[DocumentUndoControllerFocusKey.self] = newValue }
    }
}

/// Owns the `UndoManager` for one open document, plus a couple of editor-layer
/// hooks that don't belong on `Document` itself.
///
/// Mutation and undo registration live on `Document.transaction(...)` directly;
/// this controller mostly exists so the typing path (which lives inside
/// `BlockTextEditor` and reads from environment) can call into the document's
/// transaction API without taking a Document reference through every NSTextView
/// representable layer.
@MainActor
public final class DocumentUndoController {
    public let undoManager: UndoManager

    /// Set by `EditorView` once the document is mounted. Used by `transaction`
    /// and `breakCoalescing` to forward into the document's API.
    weak var document: Document?

    /// Wired by the active `BlockTextEditor` on mount (`makeNSView` /
    /// `makeUIView`) and torn down on unmount. Invoking it commits the live
    /// editor's `NSTextStorage` / `UITextView` text into the model binding
    /// via the coordinator's `commitLiveText`. Callers fire this before any
    /// state mutation that would unmount the live editor (e.g. clicking
    /// into another block) so in-flight text reaches the binding before the
    /// `BlockTextEditor` tears down — otherwise the binding write happens
    /// during SwiftUI's update pass and doesn't reliably propagate to the
    /// read-only `Text` that takes the row's slot. Also wired into
    /// `Document.preMutation` so every transaction flushes in-flight text
    /// before snapshotting.
    var flushActiveText: (() -> Void)?

    public init() {
        self.undoManager = UndoManager()
        self.undoManager.levelsOfUndo = 100
    }

    /// Forward to the document's transaction. Convenience for callers (the
    /// typing path in `BlockTextEditor`) that hold a controller but not a
    /// document directly. Emission happens inside `Document.transaction`
    /// via `didCommitTransaction`.
    @discardableResult
    func transaction(name: String, coalesceKey: AnyHashable? = nil, _ change: () -> Void) -> [EditorOp] {
        document?.transaction(
            name: name,
            coalesceKey: coalesceKey,
            undoManager: undoManager,
            change
        ) ?? []
    }

    /// Force the next coalesce-keyed transaction to register a fresh undo entry
    /// even if its key matches the previous within the coalesce interval. Called
    /// at edit-session boundaries.
    func breakCoalescing() {
        document?.breakCoalescing()
    }
}
