import Foundation

public struct WorkspaceEntry: Identifiable, Sendable, Hashable {
    public let url: URL
    public let relativePath: String
    public let title: String
    public let modificationDate: Date

    public var id: URL { url }

    public init(url: URL, relativePath: String, title: String, modificationDate: Date) {
        self.url = url
        self.relativePath = relativePath
        self.title = title
        self.modificationDate = modificationDate
    }
}

public struct Workspace: Sendable {
    public let rootURL: URL
    public var entries: [WorkspaceEntry]

    public init(rootURL: URL, entries: [WorkspaceEntry] = []) {
        self.rootURL = rootURL
        self.entries = entries
    }
}
