import Foundation

public struct Document: Identifiable, Sendable {
    public let url: URL
    public var title: String
    public var blocks: [Block]
    public var modificationDate: Date?

    public var id: URL { url }

    public init(url: URL, title: String, blocks: [Block], modificationDate: Date? = nil) {
        self.url = url
        self.title = title
        self.blocks = blocks
        self.modificationDate = modificationDate
    }

    public static func deriveTitle(from blocks: [Block], fallback: String) -> String {
        for block in blocks {
            if case .heading(_, 1, let text, _) = block {
                let s = String(text.characters)
                if !s.isEmpty { return s }
            }
        }
        return fallback
    }

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

    @discardableResult
    public mutating func moveSections(containing ids: some Sequence<BlockID>, by delta: Int) -> Bool {
        guard delta == -1 || delta == 1 else { return false }

        let indices = indicesIncludingSections(of: ids)
        guard !indices.isEmpty, let first = indices.first, let last = indices.last else { return false }
        guard indices.count == last - first + 1 else { return false }

        let baseIndent = indices.map { blocks[$0].indent }.min() ?? blocks[first].indent
        let movingCount = last - first + 1
        let movingBlocks = Array(blocks[first...last])

        if delta < 0 {
            var previousStart = first - 1
            while previousStart >= 0, blocks[previousStart].indent > baseIndent {
                previousStart -= 1
            }
            guard previousStart >= 0, blocks[previousStart].indent == baseIndent else { return false }

            blocks.removeSubrange(first...last)
            blocks.insert(contentsOf: movingBlocks, at: previousStart)
            return true
        } else {
            let nextStart = last + 1
            guard nextStart < blocks.count, blocks[nextStart].indent == baseIndent else { return false }

            var nextEnd = nextStart + 1
            while nextEnd < blocks.count, blocks[nextEnd].indent > baseIndent {
                nextEnd += 1
            }

            blocks.removeSubrange(first...last)
            blocks.insert(contentsOf: movingBlocks, at: nextEnd - movingCount)
            return true
        }
    }
}
