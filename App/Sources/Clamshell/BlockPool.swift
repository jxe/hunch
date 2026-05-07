import Foundation
import Editor

/// Per-page write-once content-addressed block pool. For each unique block
/// content ever serialized on a page, the pool holds exactly one file at
/// `<workspace-root>/.blocks/<page-rel-path>/<full-sha256>.md`. The file body
/// is `parent: <hash | "_">\n\n<atomic-markdown>` — the header records the
/// *first* parent under which this content was stored (write-once: never
/// updated, may go stale if the block later moves between parents).
///
/// Replaces the `.history/<rel>.md.jsonl` log as the recovery source. Pool
/// entries are never overwritten — same content + repeated saves only touch
/// the file's mtime (LRU input for future GC). The pool dir mirrors the page
/// path so trash/rename/restore can move it as a unit alongside the `.md`.
public actor BlockPool {
    public static let directoryName = ".blocks"
    private static let parentSentinelTopLevel = "_"

    nonisolated private let workspaceRoot: URL
    nonisolated private let store: FileStore

    public init(workspaceRoot: URL, store: FileStore = FileStore()) {
        self.workspaceRoot = workspaceRoot
        self.store = store
    }

    // MARK: - Persistence

    /// Walk the document tree (top level + descendants) and persist each
    /// block atomically into the page's pool dir. New content gets a new
    /// file; existing content gets its mtime touched.
    public func persist(page relativePath: String, blocks: [Block]) throws {
        let pageDir = poolDir(for: relativePath)
        var touched: Set<String> = []
        try walk(blocks: blocks, parentHash: nil, pageDir: pageDir, touched: &touched)
    }

    /// Recursively persist a level of the tree. `parentHash` is the atomic
    /// hash of the immediate parent, or nil for the top level.
    private func walk(
        blocks: [Block],
        parentHash: String?,
        pageDir: URL,
        touched: inout Set<String>
    ) throws {
        for block in blocks {
            let hash = BlockFingerprint.atomicHash(block)
            // A block kind that recurs in two places under the same page (e.g.
            // an empty paragraph) only needs one save — skip duplicates.
            if touched.contains(hash) {
                try walk(blocks: block.children, parentHash: hash, pageDir: pageDir, touched: &touched)
                continue
            }
            try persistOne(
                hash: hash,
                parentHash: parentHash,
                block: block,
                pageDir: pageDir
            )
            touched.insert(hash)
            try walk(blocks: block.children, parentHash: hash, pageDir: pageDir, touched: &touched)
        }
    }

    private func persistOne(
        hash: String,
        parentHash: String?,
        block: Block,
        pageDir: URL
    ) throws {
        let url = pageDir.appendingPathComponent(hash + ".md")
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: url.path
            )
            return
        }
        try FileManager.default.createDirectory(
            at: pageDir,
            withIntermediateDirectories: true
        )
        let header = "parent: \(parentHash ?? Self.parentSentinelTopLevel)\n\n"
        let body = header + BlockSerializer.serializeAtomic(block)
        try store.write(body, to: url)
    }

    // MARK: - Queries

    public func exists(page relativePath: String, hash: String) -> Bool {
        FileManager.default.fileExists(atPath: entryURL(page: relativePath, hash: hash).path)
    }

    /// Read one pool entry. Returns `nil` if the file doesn't exist.
    public func read(page relativePath: String, hash: String) throws -> PoolEntry? {
        let url = entryURL(page: relativePath, hash: hash)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try loadEntry(url: url, source: relativePath, hash: hash)
    }

    /// All pool entries for the given page, sorted by mtime descending.
    /// Reads + header-parses every file. For the recovery list path, prefer
    /// `enumerateMetadata` + on-demand `read`.
    public func enumerate(page relativePath: String) throws -> [PoolEntry] {
        let dir = poolDir(for: relativePath)
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return try entries(in: dir, source: relativePath)
    }

    /// Metadata-only enumeration for one page: filenames + mtimes only, no
    /// file reads. Drives Pass 1 of the Recover sheet.
    public func enumerateMetadata(page relativePath: String) -> [PoolEntryMetadata] {
        let dir = poolDir(for: relativePath)
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return metadata(in: dir, source: relativePath)
    }

    /// Metadata-only enumeration across the workspace, grouped by source rel
    /// path. Pure directory scan + filename filter — no per-file reads.
    public func enumerateAllMetadata() -> [String: [PoolEntryMetadata]] {
        let root = workspaceRoot.appendingPathComponent(Self.directoryName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return [:] }
        var out: [String: [PoolEntryMetadata]] = [:]
        for pageDir in (try? pageDirs(under: root)) ?? [] {
            let rel = relativePath(of: pageDir, under: root)
            out[rel] = metadata(in: pageDir, source: rel)
        }
        return out
    }

    // MARK: - Mutation

    public func purge(page relativePath: String, hash: String) throws {
        let url = entryURL(page: relativePath, hash: hash)
        try? FileManager.default.removeItem(at: url)
    }

    /// Move a page's pool dir. Used by trash / rename / restore so the pool
    /// travels with its page.
    public func move(fromPage source: String, toPage destination: String) throws {
        let from = poolDir(for: source)
        let to = poolDir(for: destination)
        guard FileManager.default.fileExists(atPath: from.path) else { return }
        try FileManager.default.createDirectory(
            at: to.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Destination shouldn't exist (collision logic lives at the page-rename
        // layer); if it does we'd rather surface the move error than silently
        // overwrite the existing pool.
        try FileManager.default.moveItem(at: from, to: to)
    }

    // MARK: - Internals

    private func poolDir(for relativePath: String) -> URL {
        workspaceRoot
            .appendingPathComponent(Self.directoryName, isDirectory: true)
            .appendingPathComponent(relativePath, isDirectory: true)
    }

    private func entryURL(page relativePath: String, hash: String) -> URL {
        poolDir(for: relativePath).appendingPathComponent(hash + ".md")
    }

    private func entries(in dir: URL, source: String) throws -> [PoolEntry] {
        var out: [PoolEntry] = []
        for meta in metadata(in: dir, source: source) {
            if let entry = try? loadEntry(meta: meta) {
                out.append(entry)
            }
        }
        out.sort { $0.recordedAt > $1.recordedAt }
        return out
    }

    private func metadata(in dir: URL, source: String) -> [PoolEntryMetadata] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        )) ?? []
        var out: [PoolEntryMetadata] = []
        for url in urls {
            guard url.pathExtension.lowercased() == "md" else { continue }
            let hash = url.deletingPathExtension().lastPathComponent
            // Filenames are SHA-256 hex (64 chars). Skip anything else.
            guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { continue }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            out.append(PoolEntryMetadata(hash: hash, source: source, recordedAt: mtime, fileURL: url))
        }
        out.sort { $0.recordedAt > $1.recordedAt }
        return out
    }

    private func loadEntry(url: URL, source: String, hash: String) throws -> PoolEntry {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return try loadEntry(meta: PoolEntryMetadata(hash: hash, source: source, recordedAt: mtime, fileURL: url))
    }

    /// Body read + header parse for one pool file. No markdown→Block parse —
    /// the caller does that on demand at restore time. Nonisolated so callers
    /// can fan body reads out concurrently without serializing on the actor.
    nonisolated public func loadEntry(meta: PoolEntryMetadata) throws -> PoolEntry {
        let body = try store.read(meta.fileURL)
        let (parentHash, markdown) = Self.parseHeader(body)
        return PoolEntry(
            markdown: markdown,
            hash: meta.hash,
            parentHash: parentHash,
            source: meta.source,
            recordedAt: meta.recordedAt,
            fileURL: meta.fileURL
        )
    }

    /// Pool-file format is `parent: <hash | "_">\n\n<markdown>`. Tolerant of
    /// trailing newlines and of files where the header is missing (legacy /
    /// hand-edited) — those return parentHash = nil and the entire body as
    /// markdown.
    nonisolated private static func parseHeader(_ body: String) -> (parentHash: String?, markdown: String) {
        let prefix = "parent: "
        guard body.hasPrefix(prefix) else { return (nil, body) }
        guard let newline = body.firstIndex(of: "\n") else { return (nil, body) }
        let parentToken = String(body[body.index(body.startIndex, offsetBy: prefix.count)..<newline])
            .trimmingCharacters(in: .whitespaces)
        let parent: String? = parentToken == Self.parentSentinelTopLevel ? nil : parentToken
        // Drop the header line and the blank line after it.
        var remaining = body[body.index(after: newline)...]
        if remaining.first == "\n" {
            remaining = remaining[remaining.index(after: remaining.startIndex)...]
        }
        return (parent, String(remaining))
    }

    private func pageDirs(under root: URL) throws -> [URL] {
        // A page dir is any directory under `.blocks/` that directly contains
        // pool files. We walk the tree because page rel paths can be nested
        // (`Subpage/Inner.md`).
        var out: [URL] = []
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return out }
        for case let url as URL in enumerator {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            // A page dir's name ends in `.md` (mirrors the page filename) and
            // contains at least one pool file. Cheaper check: name ending.
            if url.lastPathComponent.hasSuffix(".md") {
                out.append(url)
            }
        }
        return out
    }

    private func relativePath(of dir: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let dirPath = dir.standardizedFileURL.path
        if dirPath.hasPrefix(rootPath + "/") {
            return String(dirPath.dropFirst(rootPath.count + 1))
        }
        return dir.lastPathComponent
    }
}

/// One pool entry's body — raw markdown plus its on-disk metadata. Block
/// parsing is deferred to the restore site so the recovery list isn't
/// gated on swift-markdown for every pool file.
public struct PoolEntry: Sendable {
    public let markdown: String
    public let hash: String
    public let parentHash: String?
    public let source: String
    public let recordedAt: Date
    public let fileURL: URL
}

/// Cheap descriptor for one pool file: derives entirely from the directory
/// listing (`hash` from filename, `recordedAt` from mtime), no body read.
/// Drives the metadata-first first paint of the Recover sheet.
public struct PoolEntryMetadata: Sendable, Hashable {
    public let hash: String
    public let source: String
    public let recordedAt: Date
    public let fileURL: URL
}

/// UI-facing recoverable-block descriptor. A pool entry that's no longer in
/// its source page's live set. Identity is `(source, hash)` — same content
/// re-orphaned twice on the same page collapses into one entry.
///
/// `markdown` and `parentHash` are nil while the entry is a stub (Pass 1 of
/// the Recover sheet); a background body-fill replaces the stub with a
/// populated copy.
public struct LostBlock: Sendable, Identifiable {
    public let markdown: String?
    public let hash: String
    public let parentHash: String?
    public let source: String
    public let recordedAt: Date
    public let fileURL: URL

    public var id: String { "\(source)|\(hash)" }

    /// True once the body has been read and `markdown`/`parentHash` are filled.
    public var isLoaded: Bool { markdown != nil }

    init(entry: PoolEntry) {
        self.markdown = entry.markdown
        self.hash = entry.hash
        self.parentHash = entry.parentHash
        self.source = entry.source
        self.recordedAt = entry.recordedAt
        self.fileURL = entry.fileURL
    }

    init(stub meta: PoolEntryMetadata) {
        self.markdown = nil
        self.hash = meta.hash
        self.parentHash = nil
        self.source = meta.source
        self.recordedAt = meta.recordedAt
        self.fileURL = meta.fileURL
    }
}

extension LostBlock: Hashable {
    public static func == (lhs: LostBlock, rhs: LostBlock) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

private extension Character {
    var isHexDigit: Bool {
        ("0"..."9").contains(self) || ("a"..."f").contains(self) || ("A"..."F").contains(self)
    }
}
