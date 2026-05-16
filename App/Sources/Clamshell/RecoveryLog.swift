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
/// `purge` is a tombstone.
///
/// The persistence layer is intentionally thin: it knows how to read/write
/// JSONL and the per-device hash + counter caches that keep steady-state
/// saves I/O-free, and that's it. All "what does the union mean" reasoning
/// — Lamport ordering, intent state, lost / purged classification, parent
/// chain climbs, conflict-merge context — lives in `PatchEngine`, which
/// is pure and takes a `LogJournal` produced by this actor.
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

    // MARK: - Persistence: writes

    /// Walk the document tree (top level + descendants), collecting every
    /// (hash, parent-hash, atomic-markdown) tuple this device hasn't already
    /// recorded for this page, and append them as one batched write to our
    /// device's log. Steady-state saves with no new content perform zero file
    /// I/O — the in-memory hash cache short-circuits ahead of the append.
    public func record(page rel: String, blocks: [Block]) throws {
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
            let h = block.atomicHash
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

    /// Append a tombstone for `hash` against `page`. Other devices' log
    /// reads union all tombstones across devices (any device can purge any
    /// hash; latest write wins).
    ///
    /// Drops `hash` from `ourDeviceHashes` after the append. Without this,
    /// retyping the identical content (same hash) on this device after a
    /// purge would short-circuit in `record()` — the cache would say
    /// "already observed" — and no fresh `add` would land. The log would
    /// then lie that the content is dead while the live `.md` shows it
    /// alive. With the cache reset, the next `record()` emits a new `add`
    /// whose counter strictly succeeds the purge, restoring intent to alive.
    public func purge(page rel: String, hash: String) throws {
        var known = try ensureDeviceHashesLoaded(for: rel)
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
        known.remove(hash)
        ourDeviceHashes[rel] = known
    }

    /// Append a batch of engine-supplied observations as fresh `add`
    /// records, skipping anything our device has already logged (cache
    /// short-circuit). Used by the reconcile path to lift bare-md and
    /// external-edit content into the journal — the engine computed
    /// "these hashes aren't in any device's log"; this method writes them
    /// as ours. Counters are minted at write time; the engine doesn't see
    /// or care about counter state.
    public func append(observations: [PatchEngine.Observation], to rel: String) throws {
        guard !observations.isEmpty else { return }
        var known = try ensureDeviceHashesLoaded(for: rel)
        var counter = try ensureCounterLoaded(for: rel)
        let now = Date().timeIntervalSince1970
        var wires: [Wire] = []
        for obs in observations {
            guard known.insert(obs.hash).inserted else { continue }
            wires.append(Wire(
                op: "add",
                h: obs.hash,
                p: obs.parent,
                m: obs.markdown,
                t: now,
                c: counter
            ))
            counter += 1
        }
        guard !wires.isEmpty else {
            ourDeviceHashes[rel] = known
            nextCounter[rel] = counter
            return
        }
        let lines = wires.compactMap(Self.encode).joined(separator: "\n") + "\n"
        try appendLines(lines, to: ourLogURL(for: rel))
        ourDeviceHashes[rel] = known
        nextCounter[rel] = counter
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
        let h = block.atomicHash
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

    // MARK: - Persistence: reads

    /// Read every device's log for `page` and return as a `LogJournal`
    /// (engine input). No business logic — just JSONL → `LogRecord`.
    nonisolated public func readJournal(page rel: String) -> LogJournal {
        let dir = pageDir(rel: rel)
        guard FileManager.default.fileExists(atPath: dir.path) else {
            return LogJournal.empty
        }
        let devices = deviceLogURLs(for: rel).map { url -> DeviceLog in
            let deviceID = url.deletingPathExtension().lastPathComponent
            let records = readRecords(at: url).compactMap(Self.decode)
            return DeviceLog(deviceID: deviceID, records: records)
        }
        return LogJournal(devices: devices)
    }

    // MARK: - Engine-backed enumeration

    /// Lost-block entries for one page: hashes whose latest record is an
    /// `add` and aren't currently alive in the page's `.md`. Sorted by
    /// `recordedAt` descending.
    public func enumerate(page rel: String) -> [LostBlock] {
        let journal = readJournal(page: rel)
        let intent = PatchEngine.intent(from: journal)
        let live = liveAtomicHashes(forPage: rel)
        return intent.lostEntries(notIn: live, source: rel)
    }

    /// Lost blocks for every page that has ever produced log activity.
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
    /// still carries the markdown + parent metadata.
    public func enumeratePurged(page rel: String, since: Date? = nil) -> [PurgedBlock] {
        let journal = readJournal(page: rel)
        let intent = PatchEngine.intent(from: journal)
        let live = liveAtomicHashes(forPage: rel)
        return intent.purgedEntries(notIn: live, source: rel, since: since)
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

    // MARK: - Internals: hash cache

    /// Replay our device's log to compute "hashes we currently consider
    /// alive on this page." Apply `add` and `purge` records in file order
    /// (which is the device's local Lamport order, monotonic per device):
    /// `add` inserts, `purge` removes. The result reflects what the next
    /// `record()` call should treat as "already observed" — re-typing a
    /// purged hash must produce a fresh `add`, not a silent skip.
    private func ensureDeviceHashesLoaded(for rel: String) throws -> Set<String> {
        if let cached = ourDeviceHashes[rel] { return cached }
        let url = ourLogURL(for: rel)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        var out: Set<String> = []
        for record in readRecords(at: url) {
            switch record.op {
            case "add": out.insert(record.h)
            case "purge": out.remove(record.h)
            default: break
            }
        }
        ourDeviceHashes[rel] = out
        return out
    }

    /// Lazy hydration of the next Lamport counter for the page. On first call,
    /// scans every device's log to compute the max counter ever observed; new
    /// records get `max + 1` and the cache is bumped accordingly. nil counters
    /// in legacy records (pre-Lamport) don't affect the bump.
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
    /// the page dir + log file as needed.
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
            if let record = Self.decodeWire(String(raw)) {
                out.append(record)
            }
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
    /// ends in `.md` and contains at least one `.jsonl` log file).
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
            out.insert(block.atomicHash)
            collectAtomicHashes(block.children, into: &out)
        }
    }

    // MARK: - Internals: wire format

    /// On-disk JSONL record. Internal — callers consume the engine-facing
    /// `LogRecord` enum via `readJournal(page:)`.
    fileprivate struct Wire: Codable, Sendable {
        let op: String
        let h: String
        let p: String?
        let m: String?
        let t: TimeInterval
        /// Per-page Lamport counter. nil on legacy records.
        let c: UInt64?
    }

    nonisolated private static func encode(_ wire: Wire) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(wire) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated private static func decodeWire(_ line: String) -> Wire? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return try? JSONDecoder().decode(Wire.self, from: Data(trimmed.utf8))
    }

    /// Convert an on-disk `Wire` to an engine-facing `LogRecord`. Skips
    /// unknown ops (forward-compat).
    nonisolated fileprivate static func decode(_ wire: Wire) -> LogRecord? {
        switch wire.op {
        case "add":
            return .add(counter: wire.c, hash: wire.h, parent: wire.p, markdown: wire.m ?? "", t: wire.t)
        case "purge":
            return .purge(counter: wire.c, hash: wire.h, t: wire.t)
        default:
            return nil
        }
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
}

extension LostBlock: Hashable {
    public static func == (lhs: LostBlock, rhs: LostBlock) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension LostBlock {
    /// Construct a `LostBlock` from raw fields. Used by `PatchEngine` and
    /// by code paths that re-group `PurgedBlock`s through the same forest
    /// assembler.
    public static func adapt(
        hash: String,
        parentHash: String?,
        markdown: String,
        source: String,
        recordedAt: Date
    ) -> LostBlock {
        LostBlock(
            markdown: markdown,
            hash: hash,
            parentHash: parentHash,
            source: source,
            recordedAt: recordedAt
        )
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
}

extension PurgedBlock: Hashable {
    public static func == (lhs: PurgedBlock, rhs: PurgedBlock) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension PurgedBlock {
    public static func adapt(
        hash: String,
        parentHash: String?,
        markdown: String,
        source: String,
        purgedAt: Date
    ) -> PurgedBlock {
        PurgedBlock(
            markdown: markdown,
            hash: hash,
            parentHash: parentHash,
            source: source,
            purgedAt: purgedAt
        )
    }
}
