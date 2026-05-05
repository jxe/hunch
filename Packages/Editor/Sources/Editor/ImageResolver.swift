import Foundation
import SwiftUI

/// A pasted image awaiting persistence. The editor hands these to
/// `onSaveImages`; the host writes bytes to disk and returns relative paths.
public struct PastedImage: Sendable, Equatable {
    /// Raw image bytes, already encoded in `format`'s extension.
    public let data: Data
    /// File extension without the leading dot (e.g. `"png"`, `"jpg"`).
    public let ext: String

    public init(data: Data, ext: String) {
        self.data = data
        self.ext = ext
    }
}

/// Host-provided synchronous resolver: turns an image block's `source` field
/// (a markdown path string like `Assets/foo.png`) into a file URL the
/// renderer can load. Returning nil means "missing — render placeholder".
///
/// Same plumbing pattern as `LinkPreviewProvider`: editor reads, host owns
/// the path arithmetic. Sync because file-URL resolution is cheap and the
/// renderer needs the URL during view body evaluation.
public typealias ImageURLResolver = @Sendable (String) -> URL?

private struct ImageURLResolverKey: EnvironmentKey {
    static let defaultValue: ImageURLResolver? = nil
}

extension EnvironmentValues {
    public var imageURLResolver: ImageURLResolver? {
        get { self[ImageURLResolverKey.self] }
        set { self[ImageURLResolverKey.self] = newValue }
    }
}
