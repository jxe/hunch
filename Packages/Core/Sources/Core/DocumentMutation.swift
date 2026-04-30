import Foundation

extension Block {
    /// Returns a copy of this block with its text replaced. No-op for blocks
    /// that don't carry an `AttributedString` body (code/divider/subpage).
    /// Toggle returns a copy with the *title* replaced; toggle children are
    /// unchanged.
    public func withText(_ newText: AttributedString) -> Block {
        switch self {
        case .paragraph(let id, _, let indent):
            return .paragraph(id: id, text: newText, indent: indent)
        case .heading(let id, let level, _, let indent):
            return .heading(id: id, level: level, text: newText, indent: indent)
        case .bullet(let id, _, let indent):
            return .bullet(id: id, text: newText, indent: indent)
        case .numbered(let id, _, let indent):
            return .numbered(id: id, text: newText, indent: indent)
        case .todo(let id, _, let done, let indent):
            return .todo(id: id, text: newText, done: done, indent: indent)
        case .quote(let id, _, let indent):
            return .quote(id: id, text: newText, indent: indent)
        case .toggle(let id, _, let expanded, let children, let indent):
            return .toggle(id: id, title: newText, expanded: expanded, children: children, indent: indent)
        case .code, .divider, .subpage:
            return self
        }
    }

    public func withIndent(_ newIndent: Int) -> Block {
        let clamped = max(0, min(5, newIndent))
        switch self {
        case .paragraph(let id, let text, _):
            return .paragraph(id: id, text: text, indent: clamped)
        case .heading(let id, let level, let text, _):
            return .heading(id: id, level: level, text: text, indent: clamped)
        case .bullet(let id, let text, _):
            return .bullet(id: id, text: text, indent: clamped)
        case .numbered(let id, let text, _):
            return .numbered(id: id, text: text, indent: clamped)
        case .todo(let id, let text, let done, _):
            return .todo(id: id, text: text, done: done, indent: clamped)
        case .quote(let id, let text, _):
            return .quote(id: id, text: text, indent: clamped)
        case .code(let id, let source, let language, _):
            return .code(id: id, source: source, language: language, indent: clamped)
        case .divider(let id, _):
            return .divider(id: id, indent: clamped)
        case .toggle(let id, let title, let expanded, let children, _):
            return .toggle(id: id, title: title, expanded: expanded, children: children, indent: clamped)
        case .subpage(let id, let title, let path, _):
            return .subpage(id: id, title: title, path: path, indent: clamped)
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

    public func sectionRange(of blockID: BlockID) -> Range<Int>? {
        guard let start = index(of: blockID) else { return nil }
        let baseIndent = blocks[start].indent
        var end = start + 1
        while end < blocks.count, blocks[end].indent > baseIndent {
            end += 1
        }
        return start..<end
    }

    public func indicesIncludingSections(of ids: some Sequence<BlockID>) -> [Int] {
        var included = Set<Int>()
        for id in ids {
            guard let range = sectionRange(of: id) else { continue }
            included.formUnion(range)
        }
        return included.sorted()
    }
}
