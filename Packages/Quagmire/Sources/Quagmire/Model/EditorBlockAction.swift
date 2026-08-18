import Foundation

/// An immutable selected-block snapshot passed to a host-supplied action.
/// The editor captures snapshots in document order and only includes blocks
/// whose text can be replaced without changing their structural identity.
public struct BlockActionSnapshot: Identifiable, Equatable, Sendable {
    public let id: BlockID
    public let kind: BlockKind

    public init(id: BlockID, kind: BlockKind) {
        self.id = id
        self.kind = kind
    }

    public var text: AttributedString {
        Block(id: id, kind: kind).text
    }
}

/// The value passed to an `EditorBlockAction` applicability check and handler.
public struct BlockActionContext: Equatable, Sendable {
    public let blocks: [BlockActionSnapshot]

    public init(blocks: [BlockActionSnapshot]) {
        self.blocks = blocks
    }
}

/// A host action's proposed replacement for one selected block. Actions never
/// mutate the live `Document`; the editor validates and applies these values.
public struct BlockReplacement: Equatable, Sendable {
    public let blockID: BlockID
    public let kind: BlockKind

    public init(blockID: BlockID, kind: BlockKind) {
        self.blockID = blockID
        self.kind = kind
    }
}

/// One host-supplied action shown after the editor's native block actions.
/// Actions are main-actor values because `EditorHost` and the editor UI are
/// main-actor isolated; asynchronous work may still suspend normally.
@MainActor
public struct EditorBlockAction: Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String

    private let applicability: @MainActor (BlockActionContext) -> Bool
    private let handler: @MainActor (BlockActionContext) async throws -> [BlockReplacement]

    public init(
        id: String,
        title: String,
        systemImage: String,
        isApplicable: @escaping @MainActor (BlockActionContext) -> Bool,
        perform: @escaping @MainActor (BlockActionContext) async throws -> [BlockReplacement]
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.applicability = isApplicable
        self.handler = perform
    }

    public func isApplicable(to context: BlockActionContext) -> Bool {
        applicability(context)
    }

    public func perform(in context: BlockActionContext) async throws -> [BlockReplacement] {
        try await handler(context)
    }
}

/// Pure selection and application mechanics shared by every host action.
/// Kept separate from the SwiftUI presentation so stale-write and undo
/// behavior can be verified without standing up an editor view.
@MainActor
enum BlockActionExecution {
    static func context(
        in document: Document,
        selection: Set<BlockID>,
        anchorID: BlockID? = nil
    ) -> BlockActionContext {
        let selected: Set<BlockID>
        if let anchorID, !selection.contains(anchorID) {
            selected = [anchorID]
        } else {
            selected = selection
        }

        var snapshots: [BlockActionSnapshot] = []
        document.walk { block, _, _ in
            guard selected.contains(block.id), block.hasReplaceableText else { return }
            let text = String(block.text.characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            snapshots.append(BlockActionSnapshot(id: block.id, kind: block.kind))
        }
        return BlockActionContext(blocks: snapshots)
    }

    /// Applies all still-current replacements in one named transaction.
    /// Missing blocks, duplicate results, and blocks edited while the action
    /// was suspended are skipped. Returns the number actually applied.
    @discardableResult
    static func apply(
        _ replacements: [BlockReplacement],
        from context: BlockActionContext,
        to document: Document,
        actionName: String
    ) -> Int {
        let snapshots = Dictionary(uniqueKeysWithValues: context.blocks.map { ($0.id, $0) })
        var seen: Set<BlockID> = []
        let applicable = replacements.filter { replacement in
            guard seen.insert(replacement.blockID).inserted,
                  let snapshot = snapshots[replacement.blockID],
                  let current = document.find(replacement.blockID) else {
                return false
            }
            return current.kind == snapshot.kind && current.kind != replacement.kind
        }
        guard !applicable.isEmpty else { return 0 }

        document.transaction(name: actionName) {
            for replacement in applicable {
                document.mutate(replacement.blockID) { block in
                    block.kind = replacement.kind
                }
            }
        }
        return applicable.count
    }
}

private extension Block {
    var hasReplaceableText: Bool {
        switch kind {
        case .paragraph, .heading, .bullet, .numbered, .todo, .quote,
             .toggle, .templateButton:
            true
        case .code, .divider, .documentLink, .image, .unsupported:
            false
        }
    }
}
