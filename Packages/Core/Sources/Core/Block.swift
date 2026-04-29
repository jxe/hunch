import Foundation

public enum Block: Identifiable, Equatable, Sendable {
    case paragraph(id: BlockID = BlockID(), text: AttributedString)
    case heading(id: BlockID = BlockID(), level: Int, text: AttributedString)
    case bullet(id: BlockID = BlockID(), text: AttributedString, indent: Int = 0)
    case numbered(id: BlockID = BlockID(), text: AttributedString, indent: Int = 0)
    case todo(id: BlockID = BlockID(), text: AttributedString, done: Bool, indent: Int = 0)
    case quote(id: BlockID = BlockID(), text: AttributedString)
    case code(id: BlockID = BlockID(), source: String, language: String?)
    case divider(id: BlockID = BlockID())
    case toggle(id: BlockID = BlockID(), title: AttributedString, expanded: Bool, children: [Block])
    case subpage(id: BlockID = BlockID(), title: String, path: String)

    public var id: BlockID {
        switch self {
        case .paragraph(let id, _),
             .heading(let id, _, _),
             .bullet(let id, _, _),
             .numbered(let id, _, _),
             .todo(let id, _, _, _),
             .quote(let id, _),
             .code(let id, _, _),
             .divider(let id),
             .toggle(let id, _, _, _),
             .subpage(let id, _, _):
            return id
        }
    }

    public var indent: Int {
        switch self {
        case .bullet(_, _, let i), .numbered(_, _, let i), .todo(_, _, _, let i):
            return i
        default:
            return 0
        }
    }

    /// The block's body text for text-bearing blocks (paragraph, heading, list items, quote,
    /// toggle title). Returns an empty `AttributedString` for code/divider/subpage. Code's
    /// `source` is intentionally not surfaced here — code editing is out of M3 scope.
    public var text: AttributedString {
        switch self {
        case .paragraph(_, let text),
             .heading(_, _, let text),
             .bullet(_, let text, _),
             .numbered(_, let text, _),
             .todo(_, let text, _, _),
             .quote(_, let text):
            return text
        case .toggle(_, let title, _, _):
            return title
        case .code, .divider, .subpage:
            return AttributedString()
        }
    }
}
