import Foundation

/// A document the host offers as a candidate when the user types `@`, and the
/// row model for every document-list surface the host builds on top of it
/// (search sheet, move-to sheet, jump-to sheet).
///
/// `id` is the host's opaque `DocumentReference`; the editor passes it back
/// unchanged to `openDocument(_:)`, `lookupDocument(_:)`, and friends, and
/// stores it on the `documentLink` row it creates.
///
/// `title` is what to show *now*. Unlike the label stored on a block, this is
/// not authored and not persisted — it is the host's current answer.
///
/// `subtitle` is shown beneath the title when present — useful for
/// disambiguating documents with identical titles (e.g. show the parent path).
///
/// `isHome` flags the workspace's root document so list surfaces can badge it.
public struct MentionItem: Hashable, Sendable, Identifiable {
    public let id: DocumentReference
    public let title: String
    public let subtitle: String?
    public let isHome: Bool

    public init(id: DocumentReference, title: String, subtitle: String? = nil, isHome: Bool = false) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.isHome = isHome
    }
}
