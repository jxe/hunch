import Foundation
import Editor

/// Per-page append-only log of every block-version that has ever lived in a document,
/// plus the operations to record, list, restore (anchor-based), and purge.
///
/// **On-entry model.** Every save snapshots the doc's current fingerprints into the
/// log; new fingerprints are appended once and never re-logged (dedup is by
/// fingerprint). Recovery becomes "log entries whose fingerprint isn't currently in
/// any live `.md` page" — computed at read time. The log therefore contains all
/// historical *and* current versions; the live-fingerprint filter hides current ones
/// from the Recover sheet.
///
/// Storage layout: one JSONL log per source page at
/// `<workspaceRoot>/.history/<relativePath>.jsonl`. Each line is a `LostBlockRecord`.
///
/// iCloud sync conflicts produce sibling files like `page.md 2.jsonl` or
/// `page.md.jsonl 2`. On every read we scan for these, merge their rows into the
/// canonical log (union by fingerprint), and delete the siblings.
public actor RecoveryStore {
    public static let directoryName = ".history"

    private let workspaceRoot: URL
    private let store: FileStore

    public init(workspaceRoot: URL, store: FileStore = FileStore()) {
        self.workspaceRoot = workspaceRoot
        self.store = store
    }

    public enum ListFilter: Sendable {
        case all
        case page(relativePath: String)
    }

    // MARK: - Recording

    /// Snapshot every block in `currentText` into the log, deduped by fingerprint.
    /// Idempotent — safe to call on every save.
    public func recordSnapshot(
        relativePath: String,
        currentText: String,
        date: Date = Date()
    ) async throws {
        let blocks = BlockParser.parse(currentText)
        try appendNewFingerprints(blocks: blocks, relativePath: relativePath, date: date)
    }

    /// Snapshot the about-to-be-mutated block list before a destructive UI action
    /// (typically a multi-block delete). Covers the race where blocks live briefly
    /// in the doc, get deleted, and the autosave never fires while they're present.
    /// Same dedup as `recordSnapshot` — already-known fingerprints are skipped.
    public func recordDeletion(
        relativePath: String,
        previousBlocks: [Block],
        date: Date = Date()
    ) async throws {
        try appendNewFingerprints(blocks: previousBlocks, relativePath: relativePath, date: date)
    }

    private func appendNewFingerprints(
        blocks: [Block],
        relativePath: String,
        date: Date
    ) throws {
        let logURL = self.logURL(for: relativePath)
        var existing: [LostBlockRecord] = []
        if FileManager.default.fileExists(atPath: logURL.path)
            || hasConflictSiblings(for: logURL) {
            existing = try mergeAndLoad(logURL: logURL)
        }
        let known = Set(existing.map(\.fingerprint))

        let records = computeSnapshotRecords(
            from: blocks,
            knownFingerprints: known,
            source: relativePath,
            date: date
        )
        try appendRecords(records, for: relativePath)
    }

    // MARK: - Listing

    public func list(filter: ListFilter = .all) async throws -> [LostBlock] {
        switch filter {
        case .all:
            return try listAll()
        case .page(let rel):
            return try listForPage(relativePath: rel)
        }
    }

    private func listAll() throws -> [LostBlock] {
        let dir = workspaceRoot.appendingPathComponent(Self.directoryName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        // No `.skipsHiddenFiles`: macOS marks children of a `.dotfile` parent
        // as hidden even when their own names don't start with `.` (same gotcha
        // as TrashStore/HistoryStore). The `.jsonl` filter excludes incidentals.
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }

        var canonicalLogs: Set<URL> = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            // Skip iCloud conflict siblings — they get merged on read of the canonical log.
            if isConflictSibling(url) { continue }
            canonicalLogs.insert(url.standardizedFileURL)
        }

        let liveBySource = liveFingerprintsForAllPages()
        var out: [LostBlock] = []
        for logURL in canonicalLogs {
            let records = try mergeAndLoad(logURL: logURL)
            for record in records {
                if liveBySource[record.source]?.contains(record.fingerprint) == true { continue }
                out.append(LostBlock(record: record, logURL: logURL))
            }
        }
        out.sort { $0.record.recordedAt > $1.record.recordedAt }
        return out
    }

    private func listForPage(relativePath: String) throws -> [LostBlock] {
        let logURL = self.logURL(for: relativePath)
        guard FileManager.default.fileExists(atPath: logURL.path)
                || hasConflictSiblings(for: logURL) else { return [] }
        let records = try mergeAndLoad(logURL: logURL)
        let live = liveFingerprintsForPage(relativePath: relativePath)
        return records
            .filter { !live.contains($0.fingerprint) }
            .map { LostBlock(record: $0, logURL: logURL) }
            .sorted { $0.record.recordedAt > $1.record.recordedAt }
    }

    // MARK: - Purge

    public func purge(_ entry: LostBlock) async throws {
        let url = entry.logURL
        let records = try mergeAndLoad(logURL: url)
        let filtered = records.filter {
            $0.fingerprint != entry.record.fingerprint
                || $0.recordedAt != entry.record.recordedAt
                || $0.source != entry.record.source
        }
        if filtered.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try writeAll(filtered, to: url)
        }
    }

    // MARK: - Internal: live fingerprints

    private func liveFingerprintsForPage(relativePath: String) -> Set<String> {
        let url = workspaceRoot.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path),
              let raw = try? store.read(url) else { return [] }
        return Set(BlockParser.parse(raw).map(BlockFingerprint.compute))
    }

    private func liveFingerprintsForAllPages() -> [String: Set<String>] {
        let entries = (try? store.scan(workspaceRoot: workspaceRoot)) ?? []
        var out: [String: Set<String>] = [:]
        for entry in entries {
            out[entry.relativePath] = liveFingerprintsForPage(relativePath: entry.relativePath)
        }
        return out
    }

    // MARK: - Internal: record computation

    /// Walk the tree in preorder. For each block whose fingerprint isn't in
    /// `knownFingerprints`, emit a `LostBlockRecord` with the subtree serialized
    /// as markdown — and DON'T recurse into the subtree (its descendants are
    /// covered by this record). Anchor is the preorder predecessor, giving
    /// restoration a stable reference.
    private func computeSnapshotRecords(
        from blocks: [Block],
        knownFingerprints: Set<String>,
        source: String,
        date: Date
    ) -> [LostBlockRecord] {
        var out: [LostBlockRecord] = []
        // Build the flat preorder once so we can compute originalIndex and the
        // preorder anchor lookup matches the legacy semantics.
        var flat: [Block] = []
        flatten(blocks, into: &flat)
        var consumed = Set<Int>()
        var i = 0
        while i < flat.count {
            if consumed.contains(i) { i += 1; continue }
            let block = flat[i]
            let fp = BlockFingerprint.compute(block)
            guard !knownFingerprints.contains(fp) else { i += 1; continue }

            // Skip transient autotransform residue.
            if isAutotransformResidue(block) {
                consumed.insert(i)
                i += 1
                continue
            }

            let anchor = anchorFingerprint(before: i, in: flat)
            // Serialize the entire subtree rooted at this block. The block
            // value already carries its children (because Block is a value
            // type and Block.children is part of it).
            let markdown = BlockSerializer.serialize([block])

            out.append(LostBlockRecord(
                source: source,
                recordedAt: date,
                cause: .seen,
                originalIndex: i,
                anchorFingerprint: anchor,
                fingerprint: fp,
                markdown: markdown
            ))
            // Skip the whole subtree — descendants are inside the record.
            var subtreeSize = 0
            countDescendants(block, into: &subtreeSize)
            for k in i...(i + subtreeSize) { consumed.insert(k) }
            i += 1 + subtreeSize
        }
        return out
    }

    private func flatten(_ blocks: [Block], into out: inout [Block]) {
        for block in blocks {
            out.append(block)
            flatten(block.children, into: &out)
        }
    }

    private func countDescendants(_ block: Block, into out: inout Int) {
        for child in block.children {
            out += 1
            countDescendants(child, into: &out)
        }
    }

    /// True for paragraphs whose body is empty or matches a markdown autotransform
    /// trigger (`#`, `## `, `- `, `[] `, etc.). These show up momentarily while the
    /// user is typing a heading/list/etc., and shouldn't pollute the recovery feed.
    private func isAutotransformResidue(_ block: Block) -> Bool {
        guard case .paragraph(let text) = block.kind else { return false }
        let raw = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return true }
        let triggers: Set<String> = ["#", "##", "###", "-", "*", "1.", "[]", "[ ]", ">", "▸"]
        return triggers.contains(raw)
    }

    /// Immediate predecessor in the snapshot, or nil if this is the first block.
    /// At restore time the receiving side resolves the anchor against the live
    /// doc — a missing anchor falls back to end-of-page insertion.
    private func anchorFingerprint(
        before index: Int,
        in blocks: [Block]
    ) -> String? {
        guard index > 0 else { return nil }
        return BlockFingerprint.compute(blocks[index - 1])
    }

    // MARK: - Internal: append

    private func appendRecords(_ newRecords: [LostBlockRecord], for relativePath: String) throws {
        guard !newRecords.isEmpty else { return }
        let logURL = self.logURL(for: relativePath)
        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var existing: [LostBlockRecord] = []
        if FileManager.default.fileExists(atPath: logURL.path)
            || hasConflictSiblings(for: logURL) {
            existing = try mergeAndLoad(logURL: logURL)
        }

        let existingFingerprints = Set(existing.map(\.fingerprint))
        let toAppend = newRecords.filter { !existingFingerprints.contains($0.fingerprint) }
        guard !toAppend.isEmpty else { return }

        let merged = existing + toAppend
        try writeAll(merged, to: logURL)
    }

    // MARK: - Internal: file IO

    private func logURL(for relativePath: String) -> URL {
        workspaceRoot
            .appendingPathComponent(Self.directoryName, isDirectory: true)
            .appendingPathComponent(relativePath + ".jsonl")
    }

    /// Reads the canonical log plus any iCloud conflict siblings, returns the
    /// merged record list (dedup by fingerprint, latest `recordedAt` wins on
    /// collision), and deletes the sibling files (and rewrites the canonical log
    /// if any merging happened).
    private func mergeAndLoad(logURL: URL) throws -> [LostBlockRecord] {
        var merged: [String: LostBlockRecord] = [:]   // key = fingerprint
        var didMigrate = false

        if FileManager.default.fileExists(atPath: logURL.path) {
            for record in try readLog(at: logURL) {
                let migrated = migrateFingerprintsIfNeeded(record, didMigrate: &didMigrate)
                upsert(migrated, into: &merged)
            }
        }

        let siblings = conflictSiblings(of: logURL)
        for sibling in siblings {
            if let records = try? readLog(at: sibling) {
                for record in records {
                    let migrated = migrateFingerprintsIfNeeded(record, didMigrate: &didMigrate)
                    upsert(migrated, into: &merged)
                }
            }
        }

        let result = Array(merged.values).sorted { $0.recordedAt > $1.recordedAt }
        if !siblings.isEmpty || didMigrate {
            try writeAll(result, to: logURL)
            for sibling in siblings {
                try? FileManager.default.removeItem(at: sibling)
            }
        }
        return result
    }

    /// One-shot fingerprint migration: when the algorithm changes (e.g. the
    /// indent component was dropped from the canonical string), the
    /// fingerprint stored on each record becomes mismatched. Re-parse the
    /// record's `markdown` and recompute under the current algorithm; if the
    /// result differs, rewrite the record with the new fingerprint.
    private func migrateFingerprintsIfNeeded(_ record: LostBlockRecord, didMigrate: inout Bool) -> LostBlockRecord {
        let parsed = BlockParser.parse(record.markdown)
        guard let first = parsed.first else { return record }
        let recomputed = BlockFingerprint.compute(first)
        if recomputed == record.fingerprint { return record }
        didMigrate = true
        return LostBlockRecord(
            source: record.source,
            recordedAt: record.recordedAt,
            cause: record.cause,
            originalIndex: record.originalIndex,
            anchorFingerprint: record.anchorFingerprint,
            fingerprint: recomputed,
            markdown: record.markdown
        )
    }

    private func upsert(_ record: LostBlockRecord, into merged: inout [String: LostBlockRecord]) {
        if let existing = merged[record.fingerprint] {
            // Keep whichever was recorded earliest (the "original" version is more
            // useful than a later re-disappearance with the same content).
            if record.recordedAt < existing.recordedAt {
                merged[record.fingerprint] = record
            }
        } else {
            merged[record.fingerprint] = record
        }
    }

    private func readLog(at url: URL) throws -> [LostBlockRecord] {
        let contents = try store.read(url)
        var out: [LostBlockRecord] = []
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            if let record = LostBlockRecordCodec.decode(String(line)) {
                out.append(record)
            }
        }
        return out
    }

    private func writeAll(_ records: [LostBlockRecord], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var buffer = ""
        for record in records {
            if let line = try? LostBlockRecordCodec.encode(record) {
                buffer += line
                buffer += "\n"
            }
        }
        try store.write(buffer, to: url)
    }

    // MARK: - iCloud conflict siblings

    /// Returns true if the URL's filename matches the iCloud conflict pattern:
    /// `<stem> <number>.<ext>` or `<stem>.<ext> <number>`. Used to skip them
    /// during canonical-log enumeration.
    private func isConflictSibling(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        // "page.md 2.jsonl" — number+ext at tail
        if let _ = name.range(of: #" \d+\.jsonl$"#, options: .regularExpression) {
            // Reject only if there's *more* before the " <n>.jsonl" — i.e. there's a stem.
            return name.count > " 2.jsonl".count
        }
        // "page.md.jsonl 2" — trailing space-number, no extension after number
        if let _ = name.range(of: #"\.jsonl \d+$"#, options: .regularExpression) {
            return true
        }
        return false
    }

    private func hasConflictSiblings(for logURL: URL) -> Bool {
        !conflictSiblings(of: logURL).isEmpty
    }

    private func conflictSiblings(of logURL: URL) -> [URL] {
        let dir = logURL.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        )) ?? []
        let canonicalName = logURL.lastPathComponent
        let stem = (canonicalName as NSString).deletingPathExtension   // e.g. "page.md"
        var out: [URL] = []
        for url in urls {
            let name = url.lastPathComponent
            guard name != canonicalName else { continue }
            // Match "<stem> <n>.jsonl" or "<canonicalName> <n>"
            if name.range(of: "^" + NSRegularExpression.escapedPattern(for: stem) + #" \d+\.jsonl$"#, options: .regularExpression) != nil {
                out.append(url)
                continue
            }
            if name.range(of: "^" + NSRegularExpression.escapedPattern(for: canonicalName) + #" \d+$"#, options: .regularExpression) != nil {
                out.append(url)
                continue
            }
        }
        return out
    }
}

public struct LostBlock: Sendable, Identifiable, Hashable {
    public let record: LostBlockRecord
    public let logURL: URL

    public var id: String {
        // Composite to be unique across pages and same-content re-records (impossible
        // under fingerprint dedup, but keep the date in the id for safety).
        "\(record.source)|\(record.fingerprint)|\(record.recordedAt.timeIntervalSince1970)"
    }
}
