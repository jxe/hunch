import Foundation

/// An opaque handle to some other document, as the host names it.
///
/// The editor never looks inside. A host may put a relative file path in here,
/// a UUID, a database key, a path with a fragment, a URL — whatever identifies
/// a document in its own storage. Everything the editor needs to *do* with a
/// reference goes back through `EditorHost`: resolve it for display
/// (`lookupDocument`), open it (`openDocument`), build a link URL for it
/// (`linkURL(for:in:)`).
///
/// A distinct type rather than a bare `String` so a storage identifier can't be
/// confused with a title, a path, or a block's text at a call site, and so the
/// editor can't accidentally grow code that parses one. `rawValue` is there for
/// the host that produced it; treating it as structured data anywhere in this
/// package would be a bug.
public struct DocumentReference: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

extension DocumentReference: CustomStringConvertible {
    /// For diagnostics only. Do not parse.
    public var description: String { rawValue }
}
