import CryptoKit
import Foundation
import Editor
import SQLite3

struct PageSearchResult: Sendable, Equatable {
    let relativePath: String
    let title: String
    let snippet: String?
    let modificationDate: Date
    let score: Double
}

struct SearchIndexedPage: Sendable {
    let relativePath: String
    let modificationDate: Date
    let title: String
    let body: String
}

enum PageSearchQuery {
    /// Hunch exposes terms + quoted phrases, not FTS5's full operator syntax.
    /// Quoting every component keeps punctuation literal and makes an unfinished
    /// final quote useful while the user is still typing.
    static func compile(_ input: String) -> String? {
        var components: [(text: String, phrase: Bool)] = []
        var buffer = ""
        var inPhrase = false

        func flush(_ phrase: Bool) {
            let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { components.append((text, phrase)) }
            buffer = ""
        }

        for character in input {
            if character == "\"" {
                flush(inPhrase)
                inPhrase.toggle()
            } else if character.isWhitespace, !inPhrase {
                flush(false)
            } else {
                buffer.append(character)
            }
        }
        flush(inPhrase)

        guard !components.isEmpty else { return nil }
        return components.map { component in
            let escaped = component.text.replacingOccurrences(of: "\"", with: "\"\"")
            return component.phrase ? "\"\(escaped)\"" : "\"\(escaped)\"*"
        }.joined(separator: " AND ")
    }
}

nonisolated func searchableText(in blocks: [Block]) -> String {
    var lines: [String] = []
    func append(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { lines.append(trimmed) }
    }
    func walk(_ blocks: [Block]) {
        for block in blocks {
            switch block.kind {
            case .paragraph(let text),
                 .heading(_, let text),
                 .bullet(let text),
                 .numbered(let text),
                 .todo(let text, _),
                 .quote(let text),
                 .toggle(let text):
                append(String(text.characters))
            case .code(let source, _):
                append(source)
            case .templateButton(let label):
                append(label)
            case .subpage(let title, _):
                append(title)
            case .image(_, let alt):
                append(alt)
            case .divider:
                break
            }
            walk(block.children)
        }
    }
    walk(blocks)
    return lines.joined(separator: "\n")
}

actor PageSearchIndex {
    private static let schemaVersion = 1
    private static let snippetStart = "\u{1F}"
    private static let snippetEnd = "\u{1E}"

    private let databasePath: String
    private var database: OpaquePointer?
    private var unavailable = false
    private var attemptedRebuild = false

    init(workspaceRoot: URL, directory: URL? = nil) {
        let base = directory ?? Self.defaultDirectory()
        let digest = SHA256.hash(data: Data(workspaceRoot.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        self.databasePath = base.appendingPathComponent("\(digest).sqlite").path
    }

    init(databasePath: String) {
        self.databasePath = databasePath
    }

    isolated deinit {
        if let database { sqlite3_close(database) }
    }

    func indexedModificationDates() -> [String: Date] {
        guard let db = openIfAvailable() else { return [:] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT relative_path, mtime FROM pages", -1, &statement, nil) == SQLITE_OK,
              let statement else { return [:] }
        defer { sqlite3_finalize(statement) }
        var result: [String: Date] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawPath = sqlite3_column_text(statement, 0) else { continue }
            result[String(cString: rawPath)] = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 1))
        }
        return result
    }

    func reconcile(_ pages: [SearchIndexedPage], keeping livePaths: Set<String>) {
        guard let db = openIfAvailable() else { return }
        do {
            try execute("BEGIN IMMEDIATE", on: db)
            let existing = indexedPaths(on: db)
            for path in existing.subtracting(livePaths) {
                try delete(path, on: db)
            }
            for page in pages {
                try upsert(page, on: db)
            }
            try execute("COMMIT", on: db)
        } catch {
            try? execute("ROLLBACK", on: db)
        }
    }

    func upsert(_ page: SearchIndexedPage) {
        guard let db = openIfAvailable() else { return }
        do {
            try execute("BEGIN IMMEDIATE", on: db)
            try upsert(page, on: db)
            try execute("COMMIT", on: db)
        } catch {
            try? execute("ROLLBACK", on: db)
        }
    }

    func remove(relativePath: String) {
        guard let db = openIfAvailable() else { return }
        try? delete(relativePath, on: db)
    }

    func rename(from oldPath: String, to newPath: String) {
        guard let db = openIfAvailable() else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE pages SET relative_path = ? WHERE relative_path = ?", -1, &statement, nil) == SQLITE_OK,
              let statement else { return }
        defer { sqlite3_finalize(statement) }
        bind(newPath, at: 1, to: statement)
        bind(oldPath, at: 2, to: statement)
        _ = sqlite3_step(statement)
    }

    func prune(keeping livePaths: Set<String>) {
        guard let db = openIfAvailable() else { return }
        do {
            try execute("BEGIN IMMEDIATE", on: db)
            for path in indexedPaths(on: db).subtracting(livePaths) {
                try delete(path, on: db)
            }
            try execute("COMMIT", on: db)
        } catch {
            try? execute("ROLLBACK", on: db)
        }
    }

    func search(_ input: String, limit: Int = 100) -> [PageSearchResult] {
        guard let query = PageSearchQuery.compile(input), let db = openIfAvailable() else { return [] }
        let sql = """
        SELECT relative_path, title, mtime,
               snippet(pages, 3, ?, ?, '…', 18),
               bm25(pages, 0.0, 0.0, 8.0, 1.0)
          FROM pages
         WHERE pages MATCH ?
         ORDER BY bm25(pages, 0.0, 0.0, 8.0, 1.0), mtime DESC,
                  title COLLATE NOCASE, relative_path COLLATE NOCASE
         LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(Self.snippetStart, at: 1, to: statement)
        bind(Self.snippetEnd, at: 2, to: statement)
        bind(query, at: 3, to: statement)
        sqlite3_bind_int(statement, 4, Int32(min(100, max(1, limit))))

        var results: [PageSearchResult] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let pathText = sqlite3_column_text(statement, 0),
                  let titleText = sqlite3_column_text(statement, 1) else { continue }
            let rawSnippet = sqlite3_column_text(statement, 3).map { String(cString: $0) }
            let snippet: String?
            if let rawSnippet, rawSnippet.contains(Self.snippetStart) {
                snippet = rawSnippet
                    .replacingOccurrences(of: Self.snippetStart, with: "")
                    .replacingOccurrences(of: Self.snippetEnd, with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                snippet = nil
            }
            results.append(PageSearchResult(
                relativePath: String(cString: pathText),
                title: String(cString: titleText),
                snippet: snippet?.isEmpty == false ? snippet : nil,
                modificationDate: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 2)),
                score: sqlite3_column_double(statement, 4)
            ))
        }
        return results
    }

    private static func defaultDirectory() -> URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("Hunch", isDirectory: true)
            .appendingPathComponent("Search", isDirectory: true)
    }

    private func openIfAvailable() -> OpaquePointer? {
        if unavailable { return nil }
        if let database { return database }
        do {
            let handle = try openDatabase()
            try configure(handle)
            return handle
        } catch {
            if let database { sqlite3_close(database) }
            database = nil
            guard databasePath != ":memory:", !attemptedRebuild else {
                unavailable = true
                return nil
            }
            attemptedRebuild = true
            removeDatabaseFiles()
            return openIfAvailable()
        }
    }

    private func openDatabase() throws -> OpaquePointer {
        let parent = URL(fileURLWithPath: databasePath).deletingLastPathComponent()
        if databasePath != ":memory:" {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            databasePath,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw SQLiteFailure.open
        }
        database = handle
        return handle
    }

    private func removeDatabaseFiles() {
        for path in [databasePath, databasePath + "-wal", databasePath + "-shm"] {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private func configure(_ db: OpaquePointer) throws {
        try execute("PRAGMA journal_mode=WAL", on: db)
        let version = try scalarInt("PRAGMA user_version", on: db)
        if version != 0, version != Self.schemaVersion {
            try execute("DROP TABLE IF EXISTS pages", on: db)
        }
        try execute("""
        CREATE VIRTUAL TABLE IF NOT EXISTS pages USING fts5(
            relative_path UNINDEXED,
            mtime UNINDEXED,
            title,
            body,
            tokenize='porter unicode61 remove_diacritics 2',
            prefix='2 3'
        )
        """, on: db)
        try execute("PRAGMA user_version = \(Self.schemaVersion)", on: db)
    }

    private func indexedPaths(on db: OpaquePointer) -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT relative_path FROM pages", -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        var paths: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) { paths.insert(String(cString: text)) }
        }
        return paths
    }

    private func upsert(_ page: SearchIndexedPage, on db: OpaquePointer) throws {
        try delete(page.relativePath, on: db)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO pages(relative_path, mtime, title, body) VALUES (?, ?, ?, ?)", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw SQLiteFailure.prepare }
        defer { sqlite3_finalize(statement) }
        bind(page.relativePath, at: 1, to: statement)
        sqlite3_bind_double(statement, 2, page.modificationDate.timeIntervalSinceReferenceDate)
        bind(page.title, at: 3, to: statement)
        bind(page.body, at: 4, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SQLiteFailure.step }
    }

    private func delete(_ path: String, on db: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM pages WHERE relative_path = ?", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw SQLiteFailure.prepare }
        defer { sqlite3_finalize(statement) }
        bind(path, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SQLiteFailure.step }
    }

    private func execute(_ sql: String, on db: OpaquePointer) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw SQLiteFailure.step }
    }

    private func scalarInt(_ sql: String, on db: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw SQLiteFailure.prepare }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw SQLiteFailure.step }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) {
        _ = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, sqliteTransient)
        }
    }
}

private enum SQLiteFailure: Error {
    case open
    case prepare
    case step
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
