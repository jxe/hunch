import Foundation

/// A page candidate the host offers up when the user types `@` in the editor,
/// and the row model for every page-list surface in the host (sidebar,
/// square.stack sheet, move-to sheet, jump-to sheet).
///
/// `id` is opaque to the editor — it's whatever string the host uses to identify
/// the page (a relative path, a UUID, a database key); the editor passes it back
/// unchanged in `didActivateLink(.workspacePage(...))`, `subpageContents(of:)`, etc.
///
/// `subtitle` is shown beneath the title in the row when present — useful for
/// disambiguating pages with identical titles (e.g. show the parent path).
///
/// `isHome` flags the workspace's home page so list surfaces can render a small
/// house badge.
public struct MentionItem: Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let isHome: Bool

    public init(id: String, title: String, subtitle: String? = nil, isHome: Bool = false) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.isHome = isHome
    }
}
