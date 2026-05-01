import Foundation

/// A page candidate the host offers up when the user types `@` in the editor.
/// `id` is opaque to the editor — it's whatever string the host uses to identify
/// the page (a relative path, a UUID, a database key); the editor passes it back
/// unchanged in `onSubpageTap`, `onLoadSubpage`, etc.
///
/// `subtitle` is shown beneath the title in the popover when present — useful for
/// disambiguating pages with identical titles (e.g. show the parent path).
public struct MentionItem: Hashable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String?

    public init(id: String, title: String, subtitle: String? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
    }
}
