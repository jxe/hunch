import Foundation
import Editor

/// Records and restores whole-page deletions inside `<workspace>/Trash/`.
/// Block-level deletions are recorded in `RecoveryLog`, not here.
actor TrashStore {
    private let workspaceRoot: URL
    private let store: FileStore

    init(workspaceRoot: URL, store: FileStore = FileStore()) {
        self.workspaceRoot = workspaceRoot
        self.store = store
    }

    // MARK: - Listing

    func listEntries() throws -> [TrashEntry] {
        let trashDir = workspaceRoot.appendingPathComponent(FileStore.trashDirectoryName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: trashDir.path) else { return [] }
        let resourceKeys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        // No `.skipsHiddenFiles`: macOS marks children of a `.dotfile` parent as
        // hidden even when their own names don't start with `.`. The `.md` filter
        // below covers incidental dotfiles like `.DS_Store`.
        guard let enumerator = FileManager.default.enumerator(
            at: trashDir,
            includingPropertiesForKeys: resourceKeys
        ) else { return [] }

        var entries: [TrashEntry] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "md" else { continue }
            let values = try url.resourceValues(forKeys: Set(resourceKeys))
            guard values.isRegularFile == true else { continue }
            let mtime = values.contentModificationDate ?? .distantPast
            let trashRel = TrashStore.relativePath(of: url, under: workspaceRoot)
            let title = url.deletingPathExtension().lastPathComponent
            entries.append(TrashEntry(
                trashRelativePath: trashRel,
                timestamp: mtime,
                displayTitle: title,
                sourcePath: TrashStore.sourcePathFromTrashRelative(trashRel)
            ))
        }
        entries.sort { $0.timestamp > $1.timestamp }
        return entries
    }

    // MARK: - Restore

    /// Move a page out of `.Trash/` back to its original relative path. Returns the
    /// restored URL on success.
    @discardableResult
    func restorePage(_ entry: TrashEntry) throws -> URL {
        let source = workspaceRoot.appendingPathComponent(entry.trashRelativePath)
        let originalRel = TrashStore.sourcePathFromTrashRelative(entry.trashRelativePath)
        let destination = TrashStore.uniqueDestination(
            originalRelativePath: originalRel,
            workspaceRoot: workspaceRoot
        )
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }

    // MARK: - Helpers

    private static func relativePath(of url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        if filePath.hasPrefix(rootPath + "/") {
            return String(filePath.dropFirst(rootPath.count + 1))
        }
        return url.lastPathComponent
    }

    /// Strip the leading `Trash/` from a trash-relative path to recover the original
    /// workspace-relative path. Returns the input unchanged if the prefix is absent.
    private static func sourcePathFromTrashRelative(_ trashRelativePath: String) -> String {
        let prefix = FileStore.trashDirectoryName + "/"
        if trashRelativePath.hasPrefix(prefix) {
            return String(trashRelativePath.dropFirst(prefix.count))
        }
        return trashRelativePath
    }

    private static func uniqueDestination(originalRelativePath: String, workspaceRoot root: URL) -> URL {
        let nsPath = originalRelativePath as NSString
        let directory = nsPath.deletingLastPathComponent
        let filename = nsPath.lastPathComponent as NSString
        let stem = filename.deletingPathExtension
        let ext = filename.pathExtension

        func candidate(suffix: String) -> URL {
            let name = ext.isEmpty ? "\(stem)\(suffix)" : "\(stem)\(suffix).\(ext)"
            if directory.isEmpty || directory == "." {
                return root.appendingPathComponent(name)
            }
            return root.appendingPathComponent(directory).appendingPathComponent(name)
        }

        var url = candidate(suffix: "")
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = candidate(suffix: "-restored-\(i)")
            i += 1
        }
        return url
    }
}

public struct TrashEntry: Sendable, Identifiable, Hashable {
    public let trashRelativePath: String
    public let timestamp: Date
    public let displayTitle: String
    public let sourcePath: String

    public var id: String { "page:\(trashRelativePath)" }
}
