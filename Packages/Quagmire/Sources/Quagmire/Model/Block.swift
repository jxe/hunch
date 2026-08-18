import Foundation

/// All six Markdown heading levels are representable. Comparable so the
/// heading-fold parser pass can use natural `top.level >= incoming.level`
/// stack-pop comparisons.
///
/// Representable is not the same as offered: creation UI (the Turn Into menu,
/// the `#`/`##`/`###` prefix transforms) deliberately stops at H3, matching
/// Notion. H4–H6 exist so a document that already contains them survives being
/// opened and edited. Before this, `clamped` folded 4–6 down to 3 and the
/// serializer then wrote `###` back out, quietly rewriting the user's file the
/// first time they touched it.
public enum HeadingLevel: Int, Comparable, Hashable, Sendable, CaseIterable {
    case h1 = 1, h2 = 2, h3 = 3, h4 = 4, h5 = 5, h6 = 6

    public init?(level: Int) {
        self.init(rawValue: level)
    }

    /// Clamps any incoming integer to the representable range. Only for callers
    /// that genuinely have no level to preserve — a parser reading a real
    /// document should use `init?(level:)` and treat nil as "not a heading",
    /// so an out-of-range value fails loudly instead of silently becoming H1.
    public static func clamped(_ level: Int) -> HeadingLevel {
        HeadingLevel(rawValue: max(1, min(6, level))) ?? .h1
    }

    /// The levels the creation UI offers. Everything else is preserve-only.
    public static let authorable: [HeadingLevel] = [.h1, .h2, .h3]

    public var isAuthorable: Bool { Self.authorable.contains(self) }

    public static func < (lhs: HeadingLevel, rhs: HeadingLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Per-kind data. Carries no `id`, no `indent`, and no `children` — those live
/// on `Block`. Keeping payloads in an enum gives autoderived `Equatable` /
/// `Sendable` and clean exhaustive switches at use sites.
public enum BlockKind: Equatable, Sendable {
    case paragraph(text: AttributedString)
    case heading(level: HeadingLevel, text: AttributedString)
    case bullet(text: AttributedString)
    case numbered(text: AttributedString)
    case todo(text: AttributedString, done: Bool)
    case quote(text: AttributedString)
    case code(source: String, language: String?)
    case divider
    case toggle(title: AttributedString)
    case templateButton(label: String)
    case subpage(title: String, pageID: String)
    case image(source: String, alt: String)
}

/// A node in the document tree. Identity is the immutable `BlockID`; the kind
/// and children are mutable so callers can patch in place. Value semantics —
/// shallow Array copy on snapshot is the undo path.
public struct Block: Identifiable, Equatable, Sendable {
    public let id: BlockID
    public var kind: BlockKind
    public var children: [Block]

    public init(id: BlockID = BlockID(), kind: BlockKind, children: [Block] = []) {
        self.id = id
        self.kind = kind
        self.children = children
    }

    // MARK: Convenience constructors (one per kind, no children)
    //
    // The bare-leaf form is the common case in tests, autotransforms, and
    // mid-edit splits. Container blocks (heading/toggle/templateButton/list
    // items) compose by setting `children` after construction.

    public static func paragraph(text: AttributedString = AttributedString(), id: BlockID = BlockID(), children: [Block] = []) -> Block {
        Block(id: id, kind: .paragraph(text: text), children: children)
    }

    public static func heading(level: HeadingLevel, text: AttributedString, id: BlockID = BlockID(), children: [Block] = []) -> Block {
        Block(id: id, kind: .heading(level: level, text: text), children: children)
    }

    /// Convenience that accepts a raw `Int` and clamps to `HeadingLevel`. Used
    /// by parser/test sites that read levels from cmark — every level cmark can
    /// produce (1–6) now survives the conversion unchanged.
    public static func heading(level: Int, text: AttributedString, id: BlockID = BlockID(), children: [Block] = []) -> Block {
        Block(id: id, kind: .heading(level: HeadingLevel.clamped(level), text: text), children: children)
    }

    public static func bullet(text: AttributedString, id: BlockID = BlockID(), children: [Block] = []) -> Block {
        Block(id: id, kind: .bullet(text: text), children: children)
    }

    public static func numbered(text: AttributedString, id: BlockID = BlockID(), children: [Block] = []) -> Block {
        Block(id: id, kind: .numbered(text: text), children: children)
    }

    public static func todo(text: AttributedString, done: Bool, id: BlockID = BlockID(), children: [Block] = []) -> Block {
        Block(id: id, kind: .todo(text: text, done: done), children: children)
    }

    public static func quote(text: AttributedString, id: BlockID = BlockID()) -> Block {
        Block(id: id, kind: .quote(text: text))
    }

    public static func code(source: String, language: String? = nil, id: BlockID = BlockID()) -> Block {
        Block(id: id, kind: .code(source: source, language: language))
    }

    public static func divider(id: BlockID = BlockID()) -> Block {
        Block(id: id, kind: .divider)
    }

    public static func toggle(title: AttributedString, id: BlockID = BlockID(), children: [Block] = []) -> Block {
        Block(id: id, kind: .toggle(title: title), children: children)
    }

    public static func templateButton(label: String, id: BlockID = BlockID(), children: [Block] = []) -> Block {
        Block(id: id, kind: .templateButton(label: label), children: children)
    }

    public static func subpage(title: String, pageID: String, id: BlockID = BlockID()) -> Block {
        Block(id: id, kind: .subpage(title: title, pageID: pageID))
    }

    public static func image(source: String, alt: String, id: BlockID = BlockID()) -> Block {
        Block(id: id, kind: .image(source: source, alt: alt))
    }

    // MARK: Text / mutation helpers

    /// Body text for text-bearing kinds; empty string for code/divider/subpage/image.
    /// Toggle returns its title; templateButton returns its label as a plain `AttributedString`.
    public var text: AttributedString {
        switch kind {
        case .paragraph(let t),
             .heading(_, let t),
             .bullet(let t),
             .numbered(let t),
             .todo(let t, _),
             .quote(let t):
            return t
        case .toggle(let t):
            return t
        case .templateButton(let label):
            return AttributedString(label)
        case .code, .divider, .subpage, .image:
            return AttributedString()
        }
    }

    /// Returns a copy with text replaced. No-op for kinds without an
    /// `AttributedString` body (code/divider/subpage/image). Toggle replaces
    /// its title; templateButton stringifies the label.
    public func withText(_ newText: AttributedString) -> Block {
        var copy = self
        switch kind {
        case .paragraph:
            copy.kind = .paragraph(text: newText)
        case .heading(let level, _):
            copy.kind = .heading(level: level, text: newText)
        case .bullet:
            copy.kind = .bullet(text: newText)
        case .numbered:
            copy.kind = .numbered(text: newText)
        case .todo(_, let done):
            copy.kind = .todo(text: newText, done: done)
        case .quote:
            copy.kind = .quote(text: newText)
        case .toggle:
            copy.kind = .toggle(title: newText)
        case .templateButton:
            copy.kind = .templateButton(label: String(newText.characters))
        case .code, .divider, .subpage, .image:
            return self
        }
        return copy
    }

    /// Returns a copy with replaced `children`.
    public func withChildren(_ newChildren: [Block]) -> Block {
        var copy = self
        copy.children = newChildren
        return copy
    }

    /// Recursively assigns fresh BlockIDs to this block and every descendant.
    /// Used for paste/duplicate so identity collisions don't confuse selection
    /// or focus state.
    public func withFreshIDs() -> Block {
        Block(
            id: BlockID(),
            kind: kind,
            children: children.map { $0.withFreshIDs() }
        )
    }

    // MARK: Containment rules (used by canDrop / canIndent / parser fold)

    /// Whether this block is structurally permitted to hold children. Leaves
    /// (paragraph/quote/code/divider/subpage/image) reject all children;
    /// containers accept by `canContain(_:)`.
    public var isContainer: Bool {
        switch kind {
        case .heading, .bullet, .numbered, .todo, .toggle, .templateButton:
            return true
        case .paragraph, .quote, .code, .divider, .subpage, .image:
            return false
        }
    }

    /// Whether `child.kind` is permitted as a direct child of this block.
    /// - Heading at level L can contain anything *except* a heading at level
    ///   ≤ L (such a heading would close this one's body in markdown).
    /// - Toggle, templateButton, bullet, numbered, todo accept any kind.
    /// - All others are leaves and accept nothing.
    public func canContain(_ child: Block) -> Bool {
        switch kind {
        case .heading(let myLevel, _):
            if case .heading(let childLevel, _) = child.kind {
                return childLevel > myLevel
            }
            return true
        case .toggle, .templateButton, .bullet, .numbered, .todo:
            return true
        case .paragraph, .quote, .code, .divider, .subpage, .image:
            return false
        }
    }
}

// MARK: - Pattern-match helpers
//
// Replacements for the most common `if case .heading(_, _, _, _) = block`
// patterns that infest the editor today. Avoids 4-arg destructuring at
// every call site.

public extension Block {
    var headingLevel: HeadingLevel? {
        if case .heading(let level, _) = kind { return level }
        return nil
    }

    var isToggle: Bool {
        if case .toggle = kind { return true }
        return false
    }

    var isTemplateButton: Bool {
        if case .templateButton = kind { return true }
        return false
    }

    var isListItem: Bool {
        switch kind {
        case .bullet, .numbered, .todo: return true
        default: return false
        }
    }

    var isHeading: Bool {
        if case .heading = kind { return true }
        return false
    }

    /// Container that nests structurally (toggle body, list nesting) — the
    /// kind whose children render visually indented under a parent. Headings
    /// are containers but NOT structural — their children render at the
    /// heading's depth (Notion-style flush layout) and the heading-fold
    /// invariant governs which siblings can sit next to a heading.
    var isStructuralContainer: Bool {
        switch kind {
        case .bullet, .numbered, .todo, .toggle, .templateButton:
            return true
        case .heading, .paragraph, .quote, .code, .divider, .subpage, .image:
            return false
        }
    }

    var isLeaf: Bool { !isContainer }
}
