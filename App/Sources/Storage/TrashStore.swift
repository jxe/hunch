import Foundation
import Editor

/// Records and restores user deletions inside `<workspace>/.Trash/`.
///
/// Two kinds of entries surface through `listEntries`:
/// - Whole-page deletions: existing `.Trash/<file>.md` produced by `FileStore.moveToTrash`.
/// - Block-level deletions: `.Trash/_blocks/<ISO>--<flatPath>.md`, a frontmatter envelope
///   over the deleted markdown so we can re-insert at the original indices on restore.
public actor TrashStore {
    public static let blockSubdirectoryName = "_blocks"

    private let workspaceRoot: URL
    private let store: FileStore

    public init(workspaceRoot: URL, store: FileStore = FileStore()) {
        self.workspaceRoot = workspaceRoot
        self.store = store
    }

    // MARK: - Recording block deletions

    public func recordBlockDeletion(
        source: String,
        indices: [Int],
        blocks: [Block],
        actionName: String,
        date: Date = Date()
    ) throws {
        guard !blocks.isEmpty else { return }

        let dir = blocksDirectoryURL()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let timestamp = TrashStore.iso8601Filename(from: date)
        let flatSource = TrashStore.flattenSourcePath(source)
        let baseName = "\(timestamp)--\(flatSource)"
        let url = uniqueURL(in: dir, baseName: baseName, ext: "md")

        let body = BlockSerializer.serialize(blocks)
        let frontmatter = TrashRecordCodec.encode(
            source: source,
            indices: indices,
            deletedAt: date,
            actionName: actionName
        )
        let contents = frontmatter + body

        try store.write(contents, to: url)
    }

    // MARK: - Listing

    public func listEntries() throws -> [TrashEntry] {
        var out: [TrashEntry] = []
        out.append(contentsOf: try listPageEntries())
        out.append(contentsOf: try listBlockEntries())
        out.sort { $0.timestamp > $1.timestamp }
        return out
    }

    private func listPageEntries() throws -> [TrashEntry] {
        let trashDir = workspaceRoot.appendingPathComponent(FileStore.trashDirectoryName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: trashDir.path) else { return [] }
        let resourceKeys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: trashDir,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var entries: [TrashEntry] = []
        for case let url as URL in enumerator {
            // Skip block-record subtree — those are handled by listBlockEntries.
            if url.pathComponents.contains(TrashStore.blockSubdirectoryName) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard url.pathExtension.lowercased() == "md" else { continue }
            let values = try url.resourceValues(forKeys: Set(resourceKeys))
            guard values.isRegularFile == true else { continue }
            let mtime = values.contentModificationDate ?? .distantPast
            let trashRel = TrashStore.relativePath(of: url, under: workspaceRoot)
            let title = url.deletingPathExtension().lastPathComponent
            entries.append(TrashEntry(
                kind: .page(trashRelativePath: trashRel),
                timestamp: mtime,
                displayTitle: title,
                sourcePath: TrashStore.sourcePathFromTrashRelative(trashRel)
            ))
        }
        return entries
    }

    private func listBlockEntries() throws -> [TrashEntry] {
        let dir = blocksDirectoryURL()
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        var entries: [TrashEntry] = []
        for url in urls where url.pathExtension.lowercased() == "md" {
            guard let contents = try? store.read(url),
                  let parsed = TrashRecordCodec.decode(contents) else { continue }
            let preview = TrashStore.previewLine(from: parsed.body)
            let title = preview.isEmpty ? parsed.actionName : preview
            entries.append(TrashEntry(
                kind: .blocks(recordURL: url, indices: parsed.indices, body: parsed.body, actionName: parsed.actionName),
                timestamp: parsed.deletedAt,
                displayTitle: title,
                sourcePath: parsed.source
            ))
        }
        return entries
    }

    // MARK: - Restore

    /// Move a page out of `.Trash/` back to its original relative path. Returns the
    /// restored URL on success.
    @discardableResult
    public func restorePage(_ entry: TrashEntry) throws -> URL {
        guard case .page(let trashRelativePath) = entry.kind else {
            throw TrashStoreError.wrongEntryKind
        }
        let source = workspaceRoot.appendingPathComponent(trashRelativePath)
        let originalRel = TrashStore.sourcePathFromTrashRelative(trashRelativePath)
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

    /// Parse the deleted-blocks markdown back into `[Block]` and return them along with
    /// the indices recorded at deletion time. Caller decides how to re-insert into the
    /// document (in-bounds → at index, out-of-bounds → append).
    public func loadDeletedBlocks(_ entry: TrashEntry) throws -> (blocks: [Block], indices: [Int], source: String) {
        guard case .blocks(_, let indices, let body, _) = entry.kind else {
            throw TrashStoreError.wrongEntryKind
        }
        let blocks = BlockParser.parse(body).map { $0.withFreshID() }
        return (blocks, indices, entry.sourcePath)
    }

    /// Permanently remove a trash record (used after successful block restore, or
    /// future "empty trash" affordance). Page entries are not deleted by this — the
    /// page itself is moved by `restorePage`.
    public func deleteRecord(_ entry: TrashEntry) throws {
        switch entry.kind {
        case .blocks(let recordURL, _, _, _):
            try? FileManager.default.removeItem(at: recordURL)
        case .page:
            break
        }
    }

    // MARK: - Helpers

    private func blocksDirectoryURL() -> URL {
        workspaceRoot
            .appendingPathComponent(FileStore.trashDirectoryName, isDirectory: true)
            .appendingPathComponent(TrashStore.blockSubdirectoryName, isDirectory: true)
    }

    private func uniqueURL(in dir: URL, baseName: String, ext: String) -> URL {
        var candidate = dir.appendingPathComponent("\(baseName).\(ext)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(baseName)-\(suffix).\(ext)")
            suffix += 1
        }
        return candidate
    }

    fileprivate static func iso8601Filename(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let raw = formatter.string(from: date)
        // Replace `:` with `-` for filename safety on case-insensitive macOS volumes.
        return raw.replacingOccurrences(of: ":", with: "-")
    }

    fileprivate static func iso8601(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    fileprivate static func date(fromISO8601 string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private static func flattenSourcePath(_ relativePath: String) -> String {
        relativePath
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".md", with: "")
    }

    private static func relativePath(of url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        if filePath.hasPrefix(rootPath + "/") {
            return String(filePath.dropFirst(rootPath.count + 1))
        }
        return url.lastPathComponent
    }

    /// Strip the leading `.Trash/` from a trash-relative path to recover the original
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

    private static func previewLine(from body: String) -> String {
        for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return String(trimmed.prefix(80)) }
        }
        return ""
    }
}

public enum TrashStoreError: Error {
    case wrongEntryKind
    case malformedRecord
}

public struct TrashEntry: Sendable, Identifiable {
    public enum Kind: Sendable {
        case page(trashRelativePath: String)
        case blocks(recordURL: URL, indices: [Int], body: String, actionName: String)
    }

    public let kind: Kind
    public let timestamp: Date
    public let displayTitle: String
    public let sourcePath: String

    public var id: String {
        switch kind {
        case .page(let p): return "page:\(p)"
        case .blocks(let url, _, _, _): return "blocks:\(url.path)"
        }
    }

    public var isPageEntry: Bool {
        if case .page = kind { return true }
        return false
    }
}

/// Lightweight YAML-ish frontmatter for block deletion records. We don't depend on a
/// YAML parser — these files are written and read only by us, and the schema is fixed.
enum TrashRecordCodec {
    struct Decoded {
        let source: String
        let indices: [Int]
        let deletedAt: Date
        let actionName: String
        let body: String
    }

    static func encode(source: String, indices: [Int], deletedAt: Date, actionName: String) -> String {
        var s = "---\n"
        s += "source: \(source)\n"
        s += "indices: \(indices.map(String.init).joined(separator: ","))\n"
        s += "deletedAt: \(TrashStore.iso8601(from: deletedAt))\n"
        s += "actionName: \(escapeSingleLine(actionName))\n"
        s += "---\n"
        return s
    }

    static func decode(_ contents: String) -> Decoded? {
        guard contents.hasPrefix("---\n") else { return nil }
        let afterOpen = contents.dropFirst(4)
        guard let closeRange = afterOpen.range(of: "\n---\n") else { return nil }
        let header = String(afterOpen[..<closeRange.lowerBound])
        let body = String(afterOpen[closeRange.upperBound...])

        var fields: [String: String] = [:]
        for line in header.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }

        guard let source = fields["source"],
              let indicesField = fields["indices"],
              let dateString = fields["deletedAt"],
              let deletedAt = TrashStore.date(fromISO8601: dateString) else { return nil }
        let actionName = fields["actionName"] ?? "Delete"
        let indices = indicesField
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }

        return Decoded(
            source: source,
            indices: indices,
            deletedAt: deletedAt,
            actionName: actionName,
            body: body
        )
    }

    private static func escapeSingleLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
    }
}
