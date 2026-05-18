import Foundation

/// A pasted image awaiting persistence. The editor hands these to
/// `EditorHost.saveImages(_:)`; the host writes bytes to disk and returns relative paths.
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
