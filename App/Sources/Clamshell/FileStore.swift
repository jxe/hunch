import Foundation
import Editor

enum FileStoreError: Error, LocalizedError {
    case readFailed(URL, underlying: Error)
    case writeFailed(URL, underlying: Error)
    case scanFailed(URL, underlying: Error)
    case moveFailed(URL, underlying: Error)
    case unavailableOffline(URL)

    var errorDescription: String? {
        switch self {
        case .readFailed(let url, let underlying):
            return "Couldn't read \(url.lastPathComponent): \(underlying.localizedDescription)"
        case .writeFailed(let url, let underlying):
            return "Couldn't write \(url.lastPathComponent): \(underlying.localizedDescription)"
        case .scanFailed(let url, let underlying):
            return "Couldn't scan \(url.lastPathComponent): \(underlying.localizedDescription)"
        case .moveFailed(let url, let underlying):
            return "Couldn't move \(url.lastPathComponent): \(underlying.localizedDescription)"
        case .unavailableOffline(let url):
            return "\(url.lastPathComponent) isn't available on this device."
        }
    }
}

struct FileStore: Sendable {
    static let trashDirectoryName = "Trash"
    static let historyDirectoryName = ".history"
    static let assetsDirectoryName = "Assets"

    init() {}

    /// Recursive scan of `root` for `*.md` files, returning entries sorted by modification date desc.
    func scan(workspaceRoot root: URL) throws -> [WorkspaceEntry] {
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
            let fileURL = url.standardizedFileURL
            let relPath = relativePath(of: fileURL, under: root)
            entries.append(WorkspaceEntry(url: fileURL, relativePath: relPath, title: title, modificationDate: mtime))
        }
        entries.sort { $0.modificationDate > $1.modificationDate }
        return entries
    }

    func read(_ url: URL) throws -> String {
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

    func isLocallyWritable(_ url: URL) -> Bool {
        (try? requireLocallyWritable(url)) != nil
    }

    func requireLocallyWritable(_ url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw FileStoreError.unavailableOffline(url)
        }
        guard fm.isWritableFile(atPath: url.path) else {
            throw FileStoreError.writeFailed(
                url,
                underlying: CocoaError(.fileWriteNoPermission)
            )
        }
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ]
        let values = try url.resourceValues(forKeys: keys)
        guard values.isRegularFile != false else {
            throw FileStoreError.unavailableOffline(url)
        }
        guard values.isUbiquitousItem == true else { return }
        switch values.ubiquitousItemDownloadingStatus {
        case .current, .downloaded:
            return
        default:
            throw FileStoreError.unavailableOffline(url)
        }
    }

    func write(_ contents: String, to url: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        var writeError: Error?
        coordinator.coordinate(writingItemAt: url, options: [.forReplacing], error: &coordError) { coordinatedURL in
            do {
                try writeAtomic(contents, to: coordinatedURL)
            } catch {
                writeError = error
            }
        }
        if let coordError {
            try writeDirectIfLocal(contents, to: url, coordinatorError: coordError)
        }
        if let writeError {
            throw FileStoreError.writeFailed(url, underlying: writeError)
        }
    }

    private func writeDirectIfLocal(_ contents: String, to url: URL, coordinatorError: Error) throws {
        do {
            try requireLocallyWritable(url)
            try writeAtomic(contents, to: url)
        } catch FileStoreError.unavailableOffline {
            throw FileStoreError.unavailableOffline(url)
        } catch {
            throw FileStoreError.writeFailed(url, underlying: coordinatorError)
        }
    }

    private func writeAtomic(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url, options: [.atomic])
    }

    /// Read + parse + title-derive — all nonisolated. The body touches only
    /// the file system and pure value types (`Block`, `String`), so callers
    /// can hop this off MainActor when the workspace lives on iCloud and the
    /// cold-cache read would otherwise stall the main thread for ~1s/file.
    func loadDocumentTitle(at url: URL) throws -> String {
        let source = try read(url)
        let blocks = ClamshellPageEnvelope.parse(source).blocks
        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        return Document.deriveTitle(from: blocks, fallback: fallbackTitle)
    }

    @discardableResult
    func moveToTrash(relativePath: String, workspaceRoot root: URL) throws -> String {
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
