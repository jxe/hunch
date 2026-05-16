import Foundation
import Editor

public enum FileStoreError: Error {
    case readFailed(URL, underlying: Error)
    case writeFailed(URL, underlying: Error)
    case scanFailed(URL, underlying: Error)
    case moveFailed(URL, underlying: Error)
}

public struct FileStore: Sendable {
    public static let trashDirectoryName = "Trash"
    public static let historyDirectoryName = ".history"
    public static let assetsDirectoryName = "Assets"

    public init() {}

    /// Recursive scan of `root` for `*.md` files, returning entries sorted by modification date desc.
    public func scan(workspaceRoot root: URL) throws -> [WorkspaceEntry] {
        let fm = FileManager.default
        let resourceKeys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey, .nameKey]
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw FileStoreError.scanFailed(root, underlying: NSError(domain: "FileStore", code: -1))
        }

        var entries: [WorkspaceEntry] = []
        for case let url as URL in enumerator {
            if url.pathComponents.contains(Self.trashDirectoryName)
                || url.pathComponents.contains(Self.historyDirectoryName)
                || url.pathComponents.contains(Self.assetsDirectoryName) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard url.pathExtension.lowercased() == "md" else { continue }
            let values = try url.resourceValues(forKeys: Set(resourceKeys))
            guard values.isRegularFile == true else { continue }
            let mtime = values.contentModificationDate ?? .distantPast
            let title = url.deletingPathExtension().lastPathComponent
            let relPath = relativePath(of: url, under: root)
            entries.append(WorkspaceEntry(url: url, relativePath: relPath, title: title, modificationDate: mtime))
        }
        entries.sort { $0.modificationDate > $1.modificationDate }
        return entries
    }

    public func read(_ url: URL) throws -> String {
        // NSFileCoordinator on the main thread deadlocks for "very long" with
        // iCloud Drive workspaces — Foundation's access-claim machinery waits
        // on file-provider/presenter callbacks that ultimately need the main
        // queue. The file presenter on the currently-open document already
        // catches external edits; for these one-shot reads we trade off
        // cross-process coordination for liveness.
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw FileStoreError.readFailed(url, underlying: error)
        }
    }

    public func write(_ contents: String, to url: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        var writeError: Error?
        coordinator.coordinate(writingItemAt: url, options: [.forReplacing], error: &coordError) { coordinatedURL in
            do {
                try contents.data(using: .utf8)?.write(to: coordinatedURL, options: [.atomic])
            } catch {
                writeError = error
            }
        }
        if let coordError { throw FileStoreError.writeFailed(url, underlying: coordError) }
        if let writeError { throw FileStoreError.writeFailed(url, underlying: writeError) }
    }

    @MainActor
    public func loadDocument(at url: URL) throws -> Document {
        let source = try read(url)
        let blocks = BlockParser.parse(source)
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        return Document(url: url, children: blocks, modificationDate: mtime)
    }

    @MainActor
    public func loadDocumentTitle(at url: URL) throws -> String {
        let source = try read(url)
        let blocks = BlockParser.parse(source)
        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        return Document.deriveTitle(from: blocks, fallback: fallbackTitle)
    }

    /// Write a previously-serialized document body to its URL. Caller is
    /// responsible for serializing on the MainActor (where `Document` lives)
    /// before handing the bytes off — keeping the on-disk path nonisolated.
    public func saveSerialized(_ serialized: String, to url: URL) throws {
        try write(serialized, to: url)
    }

    @discardableResult
    public func moveToTrash(relativePath: String, workspaceRoot root: URL) throws -> String {
        let source = root.appendingPathComponent(relativePath)
        let destinationPath = uniqueTrashPath(for: relativePath, workspaceRoot: root)
        let destination = root.appendingPathComponent(destinationPath)

        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: source, to: destination)
            return destinationPath
        } catch {
            throw FileStoreError.moveFailed(source, underlying: error)
        }
    }

    private func relativePath(of url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        if filePath.hasPrefix(rootPath + "/") {
            return String(filePath.dropFirst(rootPath.count + 1))
        }
        return url.lastPathComponent
    }

    private func uniqueTrashPath(for relativePath: String, workspaceRoot root: URL) -> String {
        let nsPath = relativePath as NSString
        let directory = nsPath.deletingLastPathComponent
        let filename = nsPath.lastPathComponent as NSString
        let stem = filename.deletingPathExtension
        let ext = filename.pathExtension

        func candidatePath(suffix: String = "") -> String {
            let filename = ext.isEmpty ? "\(stem)\(suffix)" : "\(stem)\(suffix).\(ext)"
            if directory == "." || directory.isEmpty {
                return "\(Self.trashDirectoryName)/\(filename)"
            }
            return "\(Self.trashDirectoryName)/\(directory)/\(filename)"
        }

        var candidate = candidatePath()
        var suffix = 2
        while FileManager.default.fileExists(atPath: root.appendingPathComponent(candidate).path) {
            candidate = candidatePath(suffix: "-\(suffix)")
            suffix += 1
        }
        return candidate
    }
}
