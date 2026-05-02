import Foundation
import SwiftUI

private struct DocumentUndoManagerKey: EnvironmentKey {
    static let defaultValue: UndoManager? = nil
}

private struct DocumentUndoControllerKey: EnvironmentKey {
    static let defaultValue: DocumentUndoController? = nil
}

extension EnvironmentValues {
    /// The shared document-level `UndoManager` for the current `EditorView`. Distinct from
    /// SwiftUI's built-in `\.undoManager` (which is read-only and tied to the responder
    /// chain) — this one we control and inject explicitly.
    var documentUndoManager: UndoManager? {
        get { self[DocumentUndoManagerKey.self] }
        set { self[DocumentUndoManagerKey.self] = newValue }
    }

    /// The `DocumentUndoController` for the current `EditorView`. Editor views read this to
    /// register typing-session snapshots on focus loss.
    var documentUndoController: DocumentUndoController? {
        get { self[DocumentUndoControllerKey.self] }
        set { self[DocumentUndoControllerKey.self] = newValue }
    }
}

public struct DocumentUndoControllerFocusKey: FocusedValueKey {
    public typealias Value = DocumentUndoController
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

/// Document-level undo coordinator. One instance per open document.
///
/// `UndoManager.registerUndo(withTarget:)` requires a class target — `EditorView`
/// is a struct, so this small class owns the manager and routes undo events
/// back into the page via the `apply` closure (set by `EditorView` on appear).
///
/// NSTextView's typing-undo also feeds this manager via the Coordinator's
/// `undoManager(for:)` delegate hook, so Cmd-Z walks one unified timeline.
@MainActor
public final class DocumentUndoController {
    public let undoManager: UndoManager
    /// Set by `EditorView` once mounted. Receives a snapshot of `[Block]` to
    /// restore. The closure is responsible for fixing up cursor/selection
    /// against the new block set and for re-registering the inverse for redo.
    var apply: (([Block]) -> Void)?
    /// Set by `EditorView`. Restores a single block's text — used for typing-burst
    /// undo entries. Closure must re-register the inverse so redo works.
    var applyTextChange: ((BlockID, AttributedString) -> Void)?

    /// Time-window for coalescing consecutive typing entries on the same block. Within
    /// this window, additional `registerTextChange` calls are folded into the existing
    /// entry (the one with the burst's starting text). Tuned to match common rapid-typing
    /// cadence — one burst per ~second of continuous typing.
    private static let coalesceInterval: TimeInterval = 1.0
    private var lastTextChangeBlock: BlockID?
    private var lastTextChangeTime: Date?

    public init() {
        self.undoManager = UndoManager()
        self.undoManager.levelsOfUndo = 100
    }

    public func reset() {
        undoManager.removeAllActions()
        lastTextChangeBlock = nil
        lastTextChangeTime = nil
    }

    /// Force the next `registerTextChange` to start a new entry, even if it's within
    /// the coalesce interval. Called at edit-session boundaries and around structural
    /// ops so a typing burst doesn't merge across them.
    func breakTextCoalescing() {
        lastTextChangeBlock = nil
        lastTextChangeTime = nil
    }

    func register(_ blocks: [Block], name: String) {
        undoManager.registerUndo(withTarget: self) { target in
            target.apply?(blocks)
        }
        undoManager.setActionName(name)
        breakTextCoalescing()
    }

    /// Register a typing undo. Coalesces with the previous registration if it's for the
    /// same block within `coalesceInterval` — meaning the user gets one undo per ~1s
    /// burst of typing rather than one per character, while still surviving editor
    /// unmount because the entry references only the model (BlockID + AttributedString),
    /// never the NSTextView.
    func registerTextChange(blockID: BlockID, oldText: AttributedString, name: String = "Type") {
        let now = Date()
        if let lastBlock = lastTextChangeBlock, lastBlock == blockID,
           let lastTime = lastTextChangeTime,
           now.timeIntervalSince(lastTime) < Self.coalesceInterval {
            // Coalesce: the existing entry already captures the burst's starting text.
            // Just bump the timer so further keystrokes keep extending the burst.
            lastTextChangeTime = now
            return
        }
        undoManager.registerUndo(withTarget: self) { target in
            target.applyTextChange?(blockID, oldText)
        }
        undoManager.setActionName(name)
        lastTextChangeBlock = blockID
        lastTextChangeTime = now
    }
}
