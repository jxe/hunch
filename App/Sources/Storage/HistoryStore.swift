import Foundation

/// Per-file snapshot history under `<workspace>/.history/<relativePath>/<ISO>.md`.
///
/// `snapshotIfNeeded` is invoked from the save pipeline. It debounces by checking the
/// most recent snapshot for the file: if one exists newer than `minInterval` seconds
/// ago, it no-ops. This bounds storage growth even when the autosave fires every 600ms.
public actor HistoryStore {
    public static let directoryName = ".history"
    public static let defaultMinInterval: TimeInterval = 300

    private let workspaceRoot: URL
    private let store: FileStore

    public init(workspaceRoot: URL, store: FileStore = FileStore()) {
        self.workspaceRoot = workspaceRoot
        self.store = store
    }

    /// Snapshot `contents` for `relativePath` if no snapshot exists newer than
    /// `minInterval` seconds ago. Identical-content suppression keeps consecutive
    /// `saveNow` calls without intervening edits from spamming the directory.
    public func snapshotIfNeeded(
        relativePath: String,
        contents: String,
        minInterval: TimeInterval = HistoryStore.defaultMinInterval,
        date: Date = Date()
    ) throws {
        let dir = directoryURL(for: relativePath)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if let latest = try latestSnapshotInfo(in: dir) {
            // Compare against the filename-encoded timestamp rather than the on-disk
            // mtime — the latter is affected by filesystem touches, sync, and copies,
            // and the filename is our canonical record of when the snapshot was taken.
            if date.timeIntervalSince(latest.timestamp) < minInterval { return }
            // Skip when the just-saved content matches the most recent snapshot —
            // happens during the 30s backstop when no edits have occurred.
            if let prior = try? store.read(latest.url), prior == contents { return }
        }

        let url = dir.appendingPathComponent("\(HistoryStore.iso8601Filename(from: date)).md")
        try store.write(contents, to: url)
    }

    public func listSnapshots(for relativePath: String) throws -> [HistorySnapshot] {
        let dir = directoryURL(for: relativePath)
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        // No `.skipsHiddenFiles`: macOS reports children of a `.dotfile` parent
        // as hidden even when their own names don't start with `.`, which would
        // drop every snapshot. The `.md` filter below excludes incidental dotfiles.
        let urls = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )
        var out: [HistorySnapshot] = []
        for url in urls where url.pathExtension.lowercased() == "md" {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let stem = url.deletingPathExtension().lastPathComponent
            let parsed = HistoryStore.date(fromFilename: stem) ?? mtime
            out.append(HistorySnapshot(
                relativePath: relativePath,
                url: url,
                timestamp: parsed
            ))
        }
        out.sort { $0.timestamp > $1.timestamp }
        return out
    }

    public func loadSnapshot(_ snapshot: HistorySnapshot) throws -> String {
        try store.read(snapshot.url)
    }

    // MARK: - Helpers

    private func directoryURL(for relativePath: String) -> URL {
        workspaceRoot
            .appendingPathComponent(HistoryStore.directoryName, isDirectory: true)
            .appendingPathComponent(relativePath, isDirectory: true)
    }

    private struct LatestSnapshot {
        let url: URL
        let timestamp: Date
    }

    private func latestSnapshotInfo(in dir: URL) throws -> LatestSnapshot? {
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        let urls = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        )
        var latest: LatestSnapshot?
        for url in urls where url.pathExtension.lowercased() == "md" {
            let stem = url.deletingPathExtension().lastPathComponent
            guard let timestamp = HistoryStore.date(fromFilename: stem) else { continue }
            if latest == nil || timestamp > latest!.timestamp {
                latest = LatestSnapshot(url: url, timestamp: timestamp)
            }
        }
        return latest
    }

    fileprivate static func iso8601Filename(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
    }

    fileprivate static func date(fromFilename name: String) -> Date? {
        let restored = name.replacingOccurrences(of: "-", with: ":", options: [], range: nil)
        // The full filename has dashes inside the date, so naive replace breaks the
        // date portion. Use a permissive parser: insert colons only at the right
        // positions of `YYYY-MM-DDTHH:MM:SSZ`. Fall back to `nil` on failure.
        _ = restored
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        // Reconstruct: filename uses `-` for the time separators (`HH-MM-SS`).
        // Pattern: YYYY-MM-DDTHH-MM-SS(Z|[+-]HH-MM)
        var chars = Array(name)
        // Replace the two `-` in the time portion (after T): positions of T,
        // then convert the next two `-` to `:`.
        guard let tIdx = chars.firstIndex(of: "T") else { return nil }
        var converted = 0
        var i = chars.index(after: tIdx)
        while i < chars.endIndex && converted < 2 {
            if chars[i] == "-" {
                chars[i] = ":"
                converted += 1
            }
            i = chars.index(after: i)
        }
        return formatter.date(from: String(chars))
    }
}

public struct HistorySnapshot: Sendable, Identifiable, Hashable {
    public let relativePath: String
    public let url: URL
    public let timestamp: Date

    public var id: URL { url }
}
