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
    case templateButton(id: BlockID = BlockID(), label: String, indent: Int = 0)
    case subpage(id: BlockID = BlockID(), title: String, pageID: String, indent: Int = 0)
    case image(id: BlockID = BlockID(), source: String, alt: String, indent: Int = 0)

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
             .templateButton(let id, _, _),
             .subpage(let id, _, _, _),
             .image(let id, _, _, _):
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
             .templateButton(_, _, let i),
             .subpage(_, _, _, let i),
             .image(_, _, _, let i):
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
        case .templateButton(_, let label, _):
            return AttributedString(label)
        case .code, .divider, .subpage, .image:
            return AttributedString()
        }
    }

    /// Returns a copy of this block with its text replaced. No-op for blocks
    /// that don't carry an `AttributedString` body (code/divider/subpage).
    /// Toggle returns a copy with the *title* replaced.
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
        case .toggle(let id, _, let indent):
            return .toggle(id: id, title: newText, indent: indent)
        case .templateButton(let id, _, let indent):
            return .templateButton(id: id, label: String(newText.characters), indent: indent)
        case .code, .divider, .subpage, .image:
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
        case .toggle(let id, let title, _):
            return .toggle(id: id, title: title, indent: clamped)
        case .templateButton(let id, let label, _):
            return .templateButton(id: id, label: label, indent: clamped)
        case .subpage(let id, let title, let pageID, _):
            return .subpage(id: id, title: title, pageID: pageID, indent: clamped)
        case .image(let id, let source, let alt, _):
            return .image(id: id, source: source, alt: alt, indent: clamped)
        }
    }

    public func withFreshID() -> Block {
        switch self {
        case .paragraph(_, let text, let indent):
            return .paragraph(text: text, indent: indent)
        case .heading(_, let level, let text, let indent):
            return .heading(level: level, text: text, indent: indent)
        case .bullet(_, let text, let indent):
            return .bullet(text: text, indent: indent)
        case .numbered(_, let text, let indent):
            return .numbered(text: text, indent: indent)
        case .todo(_, let text, let done, let indent):
            return .todo(text: text, done: done, indent: indent)
        case .quote(_, let text, let indent):
            return .quote(text: text, indent: indent)
        case .code(_, let source, let language, let indent):
            return .code(source: source, language: language, indent: indent)
        case .divider(_, let indent):
            return .divider(indent: indent)
        case .toggle(_, let title, let indent):
            return .toggle(title: title, indent: indent)
        case .templateButton(_, let label, let indent):
            return .templateButton(label: label, indent: indent)
        case .subpage(_, let title, let pageID, let indent):
            return .subpage(title: title, pageID: pageID, indent: indent)
        case .image(_, let source, let alt, let indent):
            return .image(source: source, alt: alt, indent: indent)
        }
    }
}
