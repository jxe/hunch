import Foundation

/// Where the move-to picker can land moving blocks. Either another page in
/// the workspace (host's opaque page id) or a heading/toggle in the current
/// document (editor-supplied `BlockID`).
public enum MoveDestination: Sendable, Hashable {
    case page(String)
    case block(BlockID)
}

/// A heading or toggle in the current document offered as an in-doc move
/// destination. The editor walks the document and produces these; the host
/// renders them and passes the picked id back as `MoveDestination.block`.
///
/// `depth` is the block's tree depth (0 = root) so the picker can indent the
/// row to surface the page outline. `title` already has the "Untitled
/// heading" / "Untitled toggle" fallback applied so the search field always
/// has something to match.
public struct InDocMoveTarget: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case heading(level: HeadingLevel)
        case toggle
    }

    public let id: BlockID
    public let title: String
    public let kind: Kind
    public let depth: Int

    public init(id: BlockID, title: String, kind: Kind, depth: Int) {
        self.id = id
        self.title = title
        self.kind = kind
        self.depth = depth
    }
}
