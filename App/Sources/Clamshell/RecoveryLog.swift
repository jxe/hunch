import Foundation
import Editor

/// Per-device per-page append-only JSONL log of every atomic block content
/// this device has ever observed on a page, plus tombstones the user has
/// raised against recovered entries. Replaces the per-block content pool —
/// fewer files (one per device per page), append-only writes, zero
/// cross-device write contention (each device only ever writes its own log).
///
/// On disk:
///
///     <workspace-root>/.history/<page-rel-path>/<device-id>.jsonl
///
/// Each line is one record:
///
///     {"op":"add","h":"<full-sha256>","p":"<parent-hash>"|null,"m":"<atomic markdown>","t":<unix-seconds>,"c":<lamport-counter>}
///     {"op":"purge","h":"<full-sha256>","t":<unix-seconds>,"c":<lamport-counter>}
///
/// `add` is appended on first observation of `h` on this device. `p` is the
/// parent hash at first observation (may go stale if the block later moves).
/// `purge` is a tombstone. The union orders records by `(c, device-id)` lex
/// where both have `c` (Lamport: clock-skew-immune), falling back to `t` for
/// legacy records written before this field was added. Wall-clock `t` is
/// preserved for display and the `since:` filter on `listPurgedBlocks`.
public actor RecoveryLog {
    public static let directoryName = ".history"
    private static let logExtension = "jsonl"

    nonisolated private let workspaceRoot: URL
    nonisolated private let store: FileStore
    nonisolated private let deviceID: String

    /// Cached set of hashes our device has already recorded for each page.
    /// Hydrated on first record-attempt for that page after launch by reading
    /// our own log; subsequent calls are pure in-memory checks. Eliminates
    /// per-keystroke file I/O on the steady-state save path.
    private var ourDeviceHashes: [String: Set<String>] = [:]

    /// Per-page next-counter value to mint on the next write. Hydrated lazily
    /// from the union of every device's log so our new records' counters
    /// strictly exceed anything we've observed (modulo concurrent writes from
    /// other devices we haven't seen yet, which the latest-counter-wins union
    /// resolves on read).
    private var nextCounter: [String: UInt64] = [:]

    public init(
        workspaceRoot: URL,
        store: FileStore = FileStore(),
        deviceID: String = DeviceID.current
    ) {
        self.workspaceRoot = workspaceRoot
        self.store = store
        self.deviceID = deviceID
    }

    // MARK: - Persistence

    /// Walk the document tree (top level + descendants), collecting every
    /// (hash, parent-hash, atomic-markdown) tuple this device hasn't already
    /// recorded for this page, and append them as one batched write to our
    /// device's log. Steady-state saves with no new content perform zero file
    /// I/O — the in-memory hash cache short-circuits ahead of the append.
    ///
    /// `removing` is the set of hashes that existed in the page's prior state
    /// (typically the on-disk `.md` content being replaced) but are no longer
    /// in `blocks`. For each, a `purge` record is appended and the hash is
    /// dropped from `ourDeviceHashes` so a later re-appearance gets a fresh
    /// `add` (which wins over the older purge via latest-`t` semantics in
    /// `unionLatest`). Pass an empty set when there is no prior state to
    /// diff against (first save after launch with no cache seed, or the
    /// pre-mutation `snapshotIntoRecoveryLog` path).
    public func record(page rel: String, blocks: [Block], removing: Set<String> = []) throws {
        var known = try ensureDeviceHashesLoaded(for: rel)
        var newRecords: [Wire] = []
        let now = Date().timeIntervalSince1970
        var counter = try ensureCounterLoaded(for: rel)
        collectAdds(
            blocks: blocks,
            parentHash: nil,
            known: &known,
            now: now,
            counter: &counter,
            into: &newRecords
        )
        for hash in removing {
            newRecords.append(Wire(op: "purge", h: hash, p: nil, m: nil, t: now, c: counter))
            counter += 1
            known.remove(hash)
        }
        guard !newRecords.isEmpty else {
            ourDeviceHashes[rel] = known
            nextCounter[rel] = counter
            return
        }
        let lines = newRecords.compactMap(Self.encode).joined(separator: "\n") + "\n"
        try appendLines(lines, to: ourLogURL(for: rel))
        ourDeviceHashes[rel] = known
        nextCounter[rel] = counter
    }

    private func collectAdds(
        blocks: [Block],
        parentHash: String?,
        known: inout Set<String>,
        now: TimeInterval,
        counter: inout UInt64,
        into out: inout [Wire]
    ) {
        for block in blocks {
            let h = BlockFingerprint.atomicHash(block)
            if known.insert(h).inserted {
                out.append(Wire(
                    op: "add",
                    h: h,
                    p: parentHash,
                    m: BlockSerializer.serializeAtomic(block),
                    t: now,
                    c: counter
                ))
                counter += 1
            }
            collectAdds(
                blocks: block.children,
                parentHash: h,
                known: &known,
                now: now,
                counter: &counter,
                into: &out
            )
        }
    }

    // MARK: - Queries

    /// Lost-block entries for one page. Reads every device's log for the
    /// page, picks the latest record per hash (add or purge, latest-`t` wins
    /// across devices), keeps only hashes whose latest record is an `add`
    /// that isn't currently alive in the page's `.md`. A later `add`
    /// overrides an earlier `purge`, so deleted-then-readded content
    /// surfaces correctly.
    public func enumerate(page rel: String) -> [LostBlock] {
        guard FileManager.default.fileExists(atPath: pageDir(rel: rel).path) else { return [] }
        let byHash = unionLatestWithAdd(page: rel)
        let live = liveAtomicHashes(forPage: rel)
        return byHash.values
            .filter { $0.latest.op == "add" && !live.contains($0.latest.h) }
            .map { LostBlock(record: $0.latest, source: rel) }
            .sorted { $0.recordedAt > $1.recordedAt }
    }

    /// Lost blocks for every page that has ever produced log activity, keyed
    /// by source page rel path. Walks `.history/` once and unions per-page.
    public func enumerateAll() -> [LostBlock] {
        let historyRoot = historyRootURL()
        guard FileManager.default.fileExists(atPath: historyRoot.path) else { return [] }
        var out: [LostBlock] = []
        for rel in pageRelsUnder(historyRoot) {
            out.append(contentsOf: enumerate(page: rel))
        }
        return out.sorted { $0.recordedAt > $1.recordedAt }
    }

    /// Blocks the user (or auto-tombstone) deleted on purpose: the latest
    /// record for the hash is a `purge`, but a prior `add` for the same hash
    /// still carries the markdown + parent metadata, so we can reconstruct
    /// the block on restore. Excludes hashes that are currently alive in
    /// `.md` (a re-add already brought them back).
    ///
    /// `since` filters out purges older than the given date. nil disables
    /// the cap (returns everything). The Recover sheet defaults to a recent
    /// window to keep noise low.
    public func enumeratePurged(page rel: String, since: Date? = nil) -> [PurgedBlock] {
        guard FileManager.default.fileExists(atPath: pageDir(rel: rel).path) else { return [] }
        let byHash = unionLatestWithAdd(page: rel)
        let live = liveAtomicHashes(forPage: rel)
        let cutoff = since?.timeIntervalSince1970
        var out: [PurgedBlock] = []
        for entry in byHash.values {
            guard entry.latest.op == "purge",
                  let add = entry.latestAdd,
                  !live.contains(entry.latest.h) else { continue }
            if let cutoff, entry.latest.t < cutoff { continue }
            out.append(PurgedBlock(
                addRecord: add,
                purgedAt: Date(timeIntervalSince1970: entry.latest.t),
                source: rel
            ))
        }
        return out.sorted { $0.purgedAt > $1.purgedAt }
    }

    /// Purged blocks for every page that has ever produced log activity.
    public func enumerateAllPurged(since: Date? = nil) -> [PurgedBlock] {
        let historyRoot = historyRootURL()
        guard FileManager.default.fileExists(atPath: historyRoot.path) else { return [] }
        var out: [PurgedBlock] = []
        for rel in pageRelsUnder(historyRoot) {
            out.append(contentsOf: enumeratePurged(page: rel, since: since))
        }
        return out.sorted { $0.purgedAt > $1.purgedAt }
    }

    // MARK: - Mutation

    /// Append a tombstone for `hash` against `page`. Other devices' log
    /// reads union all tombstones across devices (any device can purge any
    /// hash; latest write wins).
    public func purge(page rel: String, hash: String) throws {
        let counter = try ensureCounterLoaded(for: rel)
        let record = Wire(
            op: "purge",
            h: hash,
            p: nil,
            m: nil,
            t: Date().timeIntervalSince1970,
            c: counter
        )
        guard let line = Self.encode(record) else { return }
        try appendLines(line + "\n", to: ourLogURL(for: rel))
        nextCounter[rel] = counter + 1
    }

    /// Recorded parent hash for `hash` on `page`, by reading every device's
    /// log and picking the latest add record (purge records don't carry
    /// parent metadata). Used by the restore flow's ancestor climb when
    /// the immediate parent of a lost block isn't itself alive in the page
    /// anymore. Returns nil for top-level (recorded `p` was null) or for
    /// hashes the log doesn't know about as an add.
    public func parentHash(page rel: String, hash: String) -> String? {
        let byHash = unionLatestWithAdd(page: rel)
        return byHash[hash]?.latestAdd?.p
    }

    /// Append a fresh `add` for `block` with the current timestamp,
    /// bypassing the in-memory hash cache. Used by the
    /// restore-from-tombstone path: a plain `record` would short-circuit
    /// (the device has already observed this hash) and the purge would
    /// remain the latest record, leaving the block tombstoned in the
    /// union. Updates the cache so subsequent normal `record` calls don't
    /// re-emit.
    public func reAdd(page rel: String, block: Block, parentHash: String?) throws {
        var known = try ensureDeviceHashesLoaded(for: rel)
        let counter = try ensureCounterLoaded(for: rel)
        let h = BlockFingerprint.atomicHash(block)
        let record = Wire(
            op: "add",
            h: h,
            p: parentHash,
            m: BlockSerializer.serializeAtomic(block),
            t: Date().timeIntervalSince1970,
            c: counter
        )
        guard let line = Self.encode(record) else { return }
        try appendLines(line + "\n", to: ourLogURL(for: rel))
        known.insert(h)
        ourDeviceHashes[rel] = known
        nextCounter[rel] = counter + 1
    }

    /// Combined view used by the iCloud conflict-merge path: tombstoned hashes
    /// (to skip blocks the user explicitly dismissed) plus a hash→parent-hash
    /// map for the climb to the nearest live ancestor when an alternate
    /// version's parent isn't itself alive in the survivor. One log-union read
    /// covers both fields.
    public struct MergeContext: Sendable {
        public let tombstones: Set<String>
        public let parentHashes: [String: String]
    }

    nonisolated public func mergeContext(page rel: String) -> MergeContext {
        let byHash = unionLatestWithAdd(page: rel)
        var tombstones: Set<String> = []
        var parentHashes: [String: String] = [:]
        for (hash, entry) in byHash {
            if entry.latest.op == "purge" {
                tombstones.insert(hash)
            }
            if let p = entry.latestAdd?.p {
                parentHashes[hash] = p
            }
        }
        return MergeContext(tombstones: tombstones, parentHashes: parentHashes)
    }

    /// Move a page's history dir. Used by trash / rename / restore so the
    /// per-device logs travel with their page.
    public func move(fromPage src: String, toPage dst: String) throws {
        let from = pageDir(rel: src)
        let to = pageDir(rel: dst)
        guard FileManager.default.fileExists(atPath: from.path) else { return }
        try FileManager.default.createDirectory(
            at: to.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: from, to: to)
        if let cached = ourDeviceHashes.removeValue(forKey: src) {
            ourDeviceHashes[dst] = cached
        }
    }

    // MARK: - Internals: hash cache

    private func ensureDeviceHashesLoaded(for rel: String) throws -> Set<String> {
        if let cached = ourDeviceHashes[rel] { return cached }
        let url = ourLogURL(for: rel)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        var out: Set<String> = []
        for record in readRecords(at: url) {
            if record.op == "add" { out.insert(record.h) }
        }
        ourDeviceHashes[rel] = out
        return out
    }

    /// Lazy hydration of the next Lamport counter for the page. On first call,
    /// scans every device's log to compute the max counter ever observed; new
    /// records get `max + 1` and the cache is bumped accordingly. nil counters
    /// in legacy records (pre-Lamport) don't affect the bump; they sort below
    /// any modern record under the union comparator.
    private func ensureCounterLoaded(for rel: String) throws -> UInt64 {
        if let cached = nextCounter[rel] { return cached }
        var maxObserved: UInt64 = 0
        for url in deviceLogURLs(for: rel) {
            for record in readRecords(at: url) {
                if let c = record.c { maxObserved = max(maxObserved, c) }
            }
        }
        let next = maxObserved + 1
        nextCounter[rel] = next
        return next
    }

    // MARK: - Internals: file I/O

    nonisolated private func ourLogURL(for rel: String) -> URL {
        pageDir(rel: rel).appendingPathComponent("\(deviceID).\(Self.logExtension)")
    }

    nonisolated private func pageDir(rel: String) -> URL {
        historyRootURL().appendingPathComponent(rel, isDirectory: true)
    }

    nonisolated private func historyRootURL() -> URL {
        workspaceRoot.appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    /// Append lines to a log file with `NSFileCoordinator` wrapping. Creates
    /// the page dir + log file as needed. The coordination is necessary
    /// because iCloud Drive may be syncing the file out concurrently with our
    /// append; without it a write race could corrupt the tail.
    private func appendLines(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        var writeError: Error?
        coordinator.coordinate(writingItemAt: url, options: [], error: &coordError) { coordinatedURL in
            do {
                if !FileManager.default.fileExists(atPath: coordinatedURL.path) {
                    FileManager.default.createFile(atPath: coordinatedURL.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: coordinatedURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(text.utf8))
            } catch {
                writeError = error
            }
        }
        if let coordError { throw coordError }
        if let writeError { throw writeError }
    }

    nonisolated private func readRecords(at url: URL) -> [Wire] {
        guard let text = try? store.read(url) else { return [] }
        var out: [Wire] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let record = Self.decode(String(raw)) {
                out.append(record)
            }
        }
        return out
    }

    /// Per-hash union across every device's log for `page`. Tracks two
    /// pieces of state side-by-side:
    /// - `latest`: the newest record overall (add or purge). Latest-`t`
    ///   wins; tells the caller whether the hash is currently tombstoned
    ///   ("delete X, save (auto-tombstone), undo, save (auto-readd)"
    ///   coherence — the readd's record is newer than the purge, so X is
    ///   alive again in the union).
    /// - `latestAdd`: the newest `add` record specifically. Carries the
    ///   block's atomic markdown `m` and recorded parent hash `p`, even
    ///   when the latest overall record is a purge. The Recover sheet
    ///   uses this to show "deleted on purpose" entries with their
    ///   original content + parent info.
    fileprivate struct HashEntry: Sendable {
        let latest: Wire
        let latestAdd: Wire?
    }

    /// True when `a` strictly succeeds `b` in the partial order. Both records
    /// with a Lamport counter compare on `(c, device)` lex; both without
    /// fall back to `t`; mixed records have the counter-bearing one win
    /// (modern records strictly dominate legacy ones — legacy records pre-date
    /// the upgrade in any realistic scenario).
    nonisolated private static func isStrictlyAfter(
        _ a: Wire, on aDevice: String,
        than b: Wire, on bDevice: String
    ) -> Bool {
        if let ac = a.c, let bc = b.c {
            if ac != bc { return ac > bc }
            return aDevice > bDevice
        }
        if a.c != nil { return true }
        if b.c != nil { return false }
        return a.t > b.t
    }

    nonisolated fileprivate func unionLatestWithAdd(page rel: String) -> [String: HashEntry] {
        var latestByHash: [String: (record: Wire, device: String)] = [:]
        var latestAddByHash: [String: (record: Wire, device: String)] = [:]
        for url in deviceLogURLs(for: rel) {
            let device = url.deletingPathExtension().lastPathComponent
            for record in readRecords(at: url) {
                guard record.op == "add" || record.op == "purge" else { continue }
                if let existing = latestByHash[record.h] {
                    if Self.isStrictlyAfter(record, on: device, than: existing.record, on: existing.device) {
                        latestByHash[record.h] = (record, device)
                    }
                } else {
                    latestByHash[record.h] = (record, device)
                }
                if record.op == "add" {
                    if let existingAdd = latestAddByHash[record.h] {
                        if Self.isStrictlyAfter(record, on: device, than: existingAdd.record, on: existingAdd.device) {
                            latestAddByHash[record.h] = (record, device)
                        }
                    } else {
                        latestAddByHash[record.h] = (record, device)
                    }
                }
            }
        }
        var out: [String: HashEntry] = [:]
        for (hash, latest) in latestByHash {
            out[hash] = HashEntry(latest: latest.record, latestAdd: latestAddByHash[hash]?.record)
        }
        return out
    }

    nonisolated private func deviceLogURLs(for rel: String) -> [URL] {
        let dir = pageDir(rel: rel)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return urls.filter { $0.pathExtension.lowercased() == Self.logExtension }
    }

    /// Walk `.history/` and yield page-rel paths (any directory whose name
    /// ends in `.md` and that contains at least one `.jsonl` log file).
    nonisolated private func pageRelsUnder(_ historyRoot: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: historyRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        var out: [String] = []
        let rootPath = historyRoot.standardizedFileURL.path
        for case let url as URL in enumerator {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir, url.lastPathComponent.hasSuffix(".md") else { continue }
            // Must actually contain logs to count.
            let logs = (try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil
            )) ?? []
            guard logs.contains(where: { $0.pathExtension.lowercased() == Self.logExtension }) else { continue }
            let path = url.standardizedFileURL.path
            if path.hasPrefix(rootPath + "/") {
                out.append(String(path.dropFirst(rootPath.count + 1)))
            }
        }
        return out
    }

    nonisolated private func liveAtomicHashes(forPage rel: String) -> Set<String> {
        let url = workspaceRoot.appendingPathComponent(rel)
        guard FileManager.default.fileExists(atPath: url.path),
              let raw = try? store.read(url) else { return [] }
        var out: Set<String> = []
        Self.collectAtomicHashes(BlockParser.parse(raw), into: &out)
        return out
    }

    nonisolated private static func collectAtomicHashes(_ blocks: [Block], into out: inout Set<String>) {
        for block in blocks {
            out.insert(BlockFingerprint.atomicHash(block))
            collectAtomicHashes(block.children, into: &out)
        }
    }

    // MARK: - Internals: codec

    fileprivate struct Wire: Codable, Sendable {
        let op: String
        let h: String
        let p: String?
        let m: String?
        let t: TimeInterval
        /// Per-page Lamport counter. nil on legacy records written before
        /// the field was added; modern reads bump local-counter past every
        /// observed `c`, so subsequent writes monotonically dominate.
        let c: UInt64?
    }

    nonisolated private static func encode(_ wire: Wire) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(wire) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated private static func decode(_ line: String) -> Wire? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return try? JSONDecoder().decode(Wire.self, from: Data(trimmed.utf8))
    }
}

// MARK: - LostBlock

/// UI-facing recoverable-block descriptor. One pool/log entry that is no
/// longer in its source page's live set and isn't tombstoned. Identity is
/// `(source, hash)` — same content re-orphaned twice on the same page
/// collapses into one entry.
public struct LostBlock: Sendable, Identifiable {
    public let markdown: String
    public let hash: String
    public let parentHash: String?
    public let source: String
    public let recordedAt: Date

    public var id: String { "\(source)|\(hash)" }

    fileprivate init(record: RecoveryLog.Wire, source: String) {
        self.markdown = record.m ?? ""
        self.hash = record.h
        self.parentHash = record.p
        self.source = source
        self.recordedAt = Date(timeIntervalSince1970: record.t)
    }
}

extension LostBlock: Hashable {
    public static func == (lhs: LostBlock, rhs: LostBlock) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension LostBlock {
    /// Construct a `LostBlock`-shaped record for inputs that didn't come
    /// straight out of the log union (e.g. `PurgedBlock` re-grouped through
    /// the same forest assembler in the host). Internal-style escape hatch
    /// for code in the same module that needs the same fields without
    /// fabricating a `Wire`.
    public static func adapt(
        hash: String,
        parentHash: String?,
        markdown: String,
        source: String,
        recordedAt: Date
    ) -> LostBlock {
        LostBlock(
            adaptedHash: hash,
            parentHash: parentHash,
            markdown: markdown,
            source: source,
            recordedAt: recordedAt
        )
    }

    fileprivate init(
        adaptedHash: String,
        parentHash: String?,
        markdown: String,
        source: String,
        recordedAt: Date
    ) {
        self.markdown = markdown
        self.hash = adaptedHash
        self.parentHash = parentHash
        self.source = source
        self.recordedAt = recordedAt
    }
}

// MARK: - PurgedBlock

/// A block whose latest log record across all devices is a `purge`, but
/// whose markdown + parent metadata we still have from a prior `add`.
/// Surfaces in the Recover sheet's "deleted on purpose" section so the
/// user can bring back intentional deletions when needed.
public struct PurgedBlock: Sendable, Identifiable {
    public let markdown: String
    public let hash: String
    public let parentHash: String?
    public let source: String
    public let purgedAt: Date

    public var id: String { "\(source)|\(hash)" }

    fileprivate init(addRecord: RecoveryLog.Wire, purgedAt: Date, source: String) {
        self.markdown = addRecord.m ?? ""
        self.hash = addRecord.h
        self.parentHash = addRecord.p
        self.source = source
        self.purgedAt = purgedAt
    }
}

extension PurgedBlock: Hashable {
    public static func == (lhs: PurgedBlock, rhs: PurgedBlock) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
