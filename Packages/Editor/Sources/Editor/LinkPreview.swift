import Foundation
import SwiftUI

/// Metadata the host returns for an external URL so the editor can decorate
/// inline links with a favicon + page title. The editor doesn't know how the
/// host fetches or caches this — it just consumes the data.
public struct LinkPreview: Sendable, Equatable {
    public let url: URL
    public let title: String?
    /// PNG-encoded favicon bytes. The editor decodes into a platform `Image`
    /// at render time. Kept as `Data` so this struct stays `Sendable` across
    /// actor hops.
    public let iconPNG: Data?

    public init(url: URL, title: String?, iconPNG: Data?) {
        self.url = url
        self.title = title
        self.iconPNG = iconPNG
    }
}

/// Host-provided async callback. Returns nil when fetch failed, was cancelled,
/// or the URL is in a known-failed state. Same shape as `suggestPages` for
/// `@`-mentions: editor calls, host owns the I/O.
public typealias LinkPreviewProvider = @Sendable (URL) async -> LinkPreview?

private struct LinkPreviewProviderKey: EnvironmentKey {
    static let defaultValue: LinkPreviewProvider? = nil
}

extension EnvironmentValues {
    public var linkPreviewProvider: LinkPreviewProvider? {
        get { self[LinkPreviewProviderKey.self] }
        set { self[LinkPreviewProviderKey.self] = newValue }
    }
}

/// Trim a page title to roughly `max` characters, breaking at the last
/// whitespace boundary inside the budget so we don't slice mid-word. Adds an
/// ellipsis when truncation happened.
func abbreviateTitle(_ title: String, max: Int = 60) -> String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.count <= max { return trimmed }
    let budget = trimmed.prefix(max)
    if let lastSpace = budget.lastIndex(where: { $0.isWhitespace }) {
        let cut = budget[..<lastSpace]
        let stripped = cut.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stripped.isEmpty { return stripped + "…" }
    }
    return String(budget) + "…"
}
