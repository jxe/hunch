import Foundation

public struct PersistedWorkspace: Sendable {
    public let url: URL
    public let homeRelativePath: String?
}

public enum WorkspaceBookmark {
    private static let defaultsKey = "console.workspace.bookmark"
    private static let homePathDefaultsKey = "console.workspace.homeRelativePath"

    public static func save(url: URL, homeRelativePath: String?) throws {
        #if os(macOS)
        let options: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkCreationOptions = []
        #endif
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let data = try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: defaultsKey)
        setHomeRelativePath(homeRelativePath)
    }

    public static func setHomeRelativePath(_ relativePath: String?) {
        if let relativePath {
            UserDefaults.standard.set(relativePath, forKey: homePathDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: homePathDefaultsKey)
        }
    }

    /// Resolves the persisted bookmark, if any. The returned URL has security-scoped access
    /// already started — call `stopAccessingSecurityScopedResource()` on it when finished.
    public static func resolve() -> PersistedWorkspace? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        var stale = false
        do {
            #if os(macOS)
            let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
            #else
            let options: URL.BookmarkResolutionOptions = []
            #endif
            let url = try URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
            _ = url.startAccessingSecurityScopedResource()
            if stale {
                try? save(url: url, homeRelativePath: UserDefaults.standard.string(forKey: homePathDefaultsKey))
            }
            return PersistedWorkspace(
                url: url,
                homeRelativePath: UserDefaults.standard.string(forKey: homePathDefaultsKey)
            )
        } catch {
            return nil
        }
    }

    public static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        UserDefaults.standard.removeObject(forKey: homePathDefaultsKey)
    }
}
