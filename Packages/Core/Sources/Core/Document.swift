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
            if case .heading(_, 1, let text) = block {
                let s = String(text.characters)
                if !s.isEmpty { return s }
            }
        }
        return fallback
    }
}
