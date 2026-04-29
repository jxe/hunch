import Foundation

public enum FileStoreError: Error {
    case readFailed(URL, underlying: Error)
    case writeFailed(URL, underlying: Error)
    case scanFailed(URL, underlying: Error)
}

public struct FileStore: Sendable {
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
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        var content = ""
        var readError: Error?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordError) { coordinatedURL in
            do {
                content = try String(contentsOf: coordinatedURL, encoding: .utf8)
            } catch {
                readError = error
            }
        }
        if let coordError { throw FileStoreError.readFailed(url, underlying: coordError) }
        if let readError { throw FileStoreError.readFailed(url, underlying: readError) }
        return content
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

    public func loadDocument(at url: URL) throws -> Document {
        let source = try read(url)
        let blocks = BlockParser.parse(source)
        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        let title = Document.deriveTitle(from: blocks, fallback: fallbackTitle)
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        return Document(url: url, title: title, blocks: blocks, modificationDate: mtime)
    }

    public func save(_ document: Document) throws {
        try write(BlockSerializer.serialize(document.blocks), to: document.url)
    }

    private func relativePath(of url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        if filePath.hasPrefix(rootPath + "/") {
            return String(filePath.dropFirst(rootPath.count + 1))
        }
        return url.lastPathComponent
    }
}
