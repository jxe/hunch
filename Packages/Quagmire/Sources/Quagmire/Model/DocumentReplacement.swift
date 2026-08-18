import Foundation

/// How a system-driven tree replacement relates to the tree it replaced.
///
/// Reported to `Document.didReplaceChildren`. The distinction matters because
/// a host does two quite different things through the same door: it reloads a
/// document from scratch, and it splices into the one already open. Treating
/// the second like the first is what makes undo evaporate every time another
/// window appends a block or a backend hands back a completed document.
public enum DocumentReplacement: Sendable, Equatable {
    /// The host spliced into the existing tree. Every block that survived kept
    /// its `BlockID` and its parent, so selection, cursor, and expansion state
    /// remain meaningful, and outstanding undo entries were rebased rather than
    /// discarded.
    case reconciled

    /// The host supplied an entirely new tree — a fresh parse of external
    /// content, or a merge result. Nothing about the previous id set is
    /// guaranteed and the undo stack was discarded.
    case wholesale
}

/// One transaction's pre-mutation tree, held by reference so that a later
/// reconciled system replacement can rewrite it in place.
///
/// `Document`'s undo entries restore whole trees. Boxing the tree is what lets
/// a system change reach *into* an already-registered undo entry and fold
/// itself in, rather than the entry having to be thrown away. The box is owned
/// by the closure registered with `UndoManager`; nothing else retains it.
final class UndoTreeSnapshot {
    var blocks: [Block]

    init(_ blocks: [Block]) {
        self.blocks = blocks
    }
}
