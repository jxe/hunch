import Foundation

/// Persists the security-scoped URL of the user's Clamshell folder. Only the
/// URL bookmark — format-level metadata like the home page lives inside the
/// Clamshell itself (see `.clamshell.json`).
public enum WorkspaceBookmark {
    private static let defaultsKey = "console.workspace.bookmark"
    /// Legacy key — the home page used to live in UserDefaults. Read once on
    /// Clamshell init for migration into `.clamshell.json`, then cleared.
    static let legacyHomePathDefaultsKey = "console.workspace.homeRelativePath"

    public static func save(url: URL) throws {
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
    }

    /// Resolves the persisted bookmark, if any. The returned URL has security-scoped access
    /// already started — call `stopAccessingSecurityScopedResource()` on it when finished.
    public static func resolve() -> URL? {
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
                try? save(url: url)
            }
            return url
        } catch {
            return nil
        }
    }

    public static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        UserDefaults.standard.removeObject(forKey: legacyHomePathDefaultsKey)
    }
}
