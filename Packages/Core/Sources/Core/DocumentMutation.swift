import Foundation

extension Block {
    /// Returns a copy of this block with its text replaced. No-op for blocks
    /// that don't carry an `AttributedString` body (code/divider/subpage).
    /// Toggle returns a copy with the *title* replaced; toggle children are
    /// unchanged.
    public func withText(_ newText: AttributedString) -> Block {
        switch self {
        case .paragraph(let id, _):
            return .paragraph(id: id, text: newText)
        case .heading(let id, let level, _):
            return .heading(id: id, level: level, text: newText)
        case .bullet(let id, _, let indent):
            return .bullet(id: id, text: newText, indent: indent)
        case .numbered(let id, _, let indent):
            return .numbered(id: id, text: newText, indent: indent)
        case .todo(let id, _, let done, let indent):
            return .todo(id: id, text: newText, done: done, indent: indent)
        case .quote(let id, _):
            return .quote(id: id, text: newText)
        case .toggle(let id, _, let expanded, let children):
            return .toggle(id: id, title: newText, expanded: expanded, children: children)
        case .code, .divider, .subpage:
            return self
        }
    }

    public func withIndent(_ newIndent: Int) -> Block {
        let clamped = max(0, min(5, newIndent))
        switch self {
        case .bullet(let id, let text, _):
            return .bullet(id: id, text: text, indent: clamped)
        case .numbered(let id, let text, _):
            return .numbered(id: id, text: text, indent: clamped)
        case .todo(let id, let text, let done, _):
            return .todo(id: id, text: text, done: done, indent: clamped)
        default:
            return self
        }
    }
}

extension Document {
    public func index(of blockID: BlockID) -> Int? {
        blocks.firstIndex(where: { $0.id == blockID })
    }

    @discardableResult
    public mutating func remove(blockID: BlockID) -> Block? {
        guard let i = index(of: blockID) else { return nil }
        return blocks.remove(at: i)
    }

    public mutating func replace(blockID: BlockID, with replacements: [Block]) {
        guard let i = index(of: blockID) else { return }
        blocks.replaceSubrange(i...i, with: replacements)
    }

    public mutating func insert(_ block: Block, after blockID: BlockID) {
        guard let i = index(of: blockID) else { return }
        blocks.insert(block, at: i + 1)
    }
}
