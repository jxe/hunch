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

    /// Cancels the active editor's delayed typing checkpoint. Undo/redo and
    /// system-driven document replacement use this before changing the model so
    /// a stale timer cannot recommit text after the change.
    var cancelActiveTextCheckpoint: (() -> Void)?

    /// True while the native editor contains text that has not reached the
    /// document yet. This makes undo availability reflect live typing during
    /// the checkpoint delay and suppresses redo as soon as a new edit begins.
    var hasActiveTextChanges: (() -> Bool)?

    /// Reloads the mounted native text view from the document after undo/redo.
    /// The native view owns the live cursor while editing, so waiting for a
    /// SwiftUI update would both lag and lose useful caret placement context.
    var synchronizeActiveText: ((Document) -> Void)?

    public init() {
        self.undoManager = UndoManager()
        self.undoManager.levelsOfUndo = 100
        // Editor transactions explicitly bound their own logical actions. Avoid
        // run-loop event grouping so a live-text flush can be immediately undone
        // without leaving Foundation's scheduled event-group closer out of sync.
        self.undoManager.groupsByEvent = false
    }

    public var canUndo: Bool { undoManager.canUndo || hasActiveTextChanges?() == true }
    public var canRedo: Bool { hasActiveTextChanges?() != true && undoManager.canRedo }

    /// Commit the current typing burst before undoing so Cmd-Z works even when
    /// the 750 ms checkpoint has not fired yet. Closing the event group makes
    /// that just-registered typing transaction the top undo action immediately.
    public func undo() {
        cancelActiveTextCheckpoint?()
        flushActiveText?()
        closeOpenUndoGroups()
        guard undoManager.canUndo else { return }
        undoManager.undo()
        if let document { synchronizeActiveText?(document) }
    }

    /// Redo through the same active-editor synchronization path. If live text
    /// was dirty, flushing it correctly invalidates the old redo stack before
    /// this checks `canRedo`, matching standard editor behavior.
    public func redo() {
        cancelActiveTextCheckpoint?()
        flushActiveText?()
        closeOpenUndoGroups()
        guard undoManager.canRedo else { return }
        undoManager.redo()
        if let document { synchronizeActiveText?(document) }
    }

    /// Forward to the document's transaction. Convenience for callers (the
    /// typing path in `BlockTextEditor`) that hold a controller but not a
    /// document directly. Emission happens inside `Document.transaction`
    /// via `didCommitTransaction`.
    @discardableResult
    func transaction(name: String, coalesceKey: AnyHashable? = nil, _ change: () -> Void) -> [DocumentChange] {
        guard let document else { return [] }
        let opensGroup = undoManager.groupingLevel == 0
        if opensGroup { undoManager.beginUndoGrouping() }
        defer { if opensGroup { undoManager.endUndoGrouping() } }
        return document.transaction(
            name: name,
            coalesceKey: coalesceKey,
            undoManager: undoManager,
            change
        )
    }

    /// Force the next coalesce-keyed transaction to register a fresh undo entry
    /// even if its key matches the previous within the coalesce interval. Called
    /// at edit-session boundaries.
    func breakCoalescing() {
        document?.breakCoalescing()
    }

    private func closeOpenUndoGroups() {
        while undoManager.groupingLevel > 0 {
            undoManager.endUndoGrouping()
        }
    }
}
