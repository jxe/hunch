import Foundation

public enum Block: Identifiable, Equatable, Sendable {
    case paragraph(id: BlockID = BlockID(), text: AttributedString, indent: Int = 0)
    case heading(id: BlockID = BlockID(), level: Int, text: AttributedString, indent: Int = 0)
    case bullet(id: BlockID = BlockID(), text: AttributedString, indent: Int = 0)
    case numbered(id: BlockID = BlockID(), text: AttributedString, indent: Int = 0)
    case todo(id: BlockID = BlockID(), text: AttributedString, done: Bool, indent: Int = 0)
    case quote(id: BlockID = BlockID(), text: AttributedString, indent: Int = 0)
    case code(id: BlockID = BlockID(), source: String, language: String?, indent: Int = 0)
    case divider(id: BlockID = BlockID(), indent: Int = 0)
    case toggle(id: BlockID = BlockID(), title: AttributedString, indent: Int = 0)
    case subpage(id: BlockID = BlockID(), title: String, path: String, indent: Int = 0)

    public var id: BlockID {
        switch self {
        case .paragraph(let id, _, _),
             .heading(let id, _, _, _),
             .bullet(let id, _, _),
             .numbered(let id, _, _),
             .todo(let id, _, _, _),
             .quote(let id, _, _),
             .code(let id, _, _, _),
             .divider(let id, _),
             .toggle(let id, _, _),
             .subpage(let id, _, _, _):
            return id
        }
    }

    public var indent: Int {
        switch self {
        case .paragraph(_, _, let i),
             .heading(_, _, _, let i),
             .bullet(_, _, let i),
             .numbered(_, _, let i),
             .todo(_, _, _, let i),
             .quote(_, _, let i),
             .code(_, _, _, let i),
             .divider(_, let i),
             .toggle(_, _, let i),
             .subpage(_, _, _, let i):
            return i
        }
    }

    /// The block's body text for text-bearing blocks (paragraph, heading, list items, quote,
    /// toggle title). Returns an empty `AttributedString` for code/divider/subpage. Code's
    /// `source` is intentionally not surfaced here — code editing is out of M3 scope.
    public var text: AttributedString {
        switch self {
        case .paragraph(_, let text, _),
             .heading(_, _, let text, _),
             .bullet(_, let text, _),
             .numbered(_, let text, _),
             .todo(_, let text, _, _),
             .quote(_, let text, _):
            return text
        case .toggle(_, let title, _):
            return title
        case .code, .divider, .subpage:
            return AttributedString()
        }
    }
}
