import Foundation
import CryptoKit
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
///     {"op":"observe","h":"<full-sha256>","p":"<parent-hash>"|null,"m":"<atomic markdown>","t":<unix-seconds>,"c":<lamport-counter>}
///     {"op":"purge","h":"<full-sha256>","t":<unix-seconds>,"c":<lamport-counter>}
///
/// `add` claims authorship of `h` on this device — the block became alive
/// via a direct edit (or fresh page creation) here. `observe` notes that
/// `h` is alive in `.md` but doesn't claim authorship: typically iCloud
/// delivered a foreign device's `.md` before its `.jsonl`, so we record a
/// snapshot for Recover-sheet surfaces without making the hash eligible
/// for auto-restore if it later disappears. `p` is the parent hash at
/// record time (may go stale if the block later moves). `purge` is a
/// tombstone; only `add` and `purge` are authoritative for `alive` /
/// `tombstoned` classification.
///
/// The persistence layer is intentionally thin: it knows how to read/write
/// JSONL and the per-device hash + counter caches that keep steady-state
/// saves I/O-free, and that's it. All "what does the union mean" reasoning
/// — Lamport ordering, intent state, lost / purged classification, parent
/// chain climbs, conflict-merge context — lives in `PatchEngine`, which
/// is pure and takes a `LogJournal` produced by this actor.
actor RecoveryLog {
    static let directoryName = ".history"
    private static let logExtension = "jsonl"

    nonisolated private let workspaceRoot: URL
    nonisolated private let store: FileStore
    nonisolated private let deviceID: String

    /// Per-page next-counter value to mint on the next write. Re-validated
    /// against foreign device logs on every counter mint (see
    /// `ensureCounterLoaded`), so cross-device records that landed via
    /// iCloud after our last mint still raise our next value.
    private var nextCounter: [String: UInt64] = [:]

    /// Per-page reconcile watermarks: which device log sizes/mtimes and
    /// which `.md` mtime we last folded against. Loaded lazily from
    /// `UserDefaults` on first access, then kept in memory. The reconcile
    /// fast path stats the current files against these to decide whether
    /// any work is needed at all (skip), or only the deltas need walking
    /// (tail), or a full fold (.md changed externally / no watermark).
    private var pageWatermarks: [String: PageWatermark]?

    nonisolated private let watermarkDefaultsKey: String

    init(
        workspaceRoot: URL,
        store: FileStore = FileStore(),
        deviceID: String = DeviceID.current
    ) {
        self.workspaceRoot = workspaceRoot
        self.store = store
        self.deviceID = deviceID
        let pathHash = SHA256.hash(data: Data(workspaceRoot.standardizedFileURL.path.utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        self.watermarkDefaultsKey = "hunch.reconcileWatermarks.\(pathHash)"
    }

    // MARK: - Persistence: writes

    /// The unified write primitive. Mints sequential Lamport counters for
    /// each entry in `patch`, encodes them as JSONL, and appends to our
    /// device's log file in one batched write.
    ///
    /// No dedup: every entry emits a record. Callers that care about not
    /// re-logging known content filter upstream (the editor via
    /// `BlockTreeDiff.derive`, reconcile via `PatchEngine.unloggedObservations`).
    /// Duplicate `add` records for the same hash are harmless — intent is
    /// computed as a latest-`(counter, deviceID)`-wins fold, so the union
    /// collapses to the same intent regardless of duplicate count. The log
    /// just gets a little chattier for callers that hand in
    /// already-recorded hashes (e.g. `write(_:patch:)` after a conflict merge).
    ///
    /// Counters within a patch are sequential, so the batch reads as a
    /// coherent transaction on tail and observers see one ordered group.
    func apply(_ patch: Patch, to rel: String) throws {
        guard !patch.isEmpty else { return }
        var counter = try ensureCounterLoaded(for: rel)
        let now = Date().timeIntervalSince1970
        var wires: [Wire] = []
        wires.reserveCapacity(patch.entries.count)
        for entry in patch.entries {
            switch entry.op {
            case .add:
                wires.append(Wire(
                    op: "add",
                    h: entry.hash,
                    p: entry.parent,
                    m: entry.markdown ?? "",
                    t: now,
                    c: counter
                ))
            case .observe:
                wires.append(Wire(
                    op: "observe",
                    h: entry.hash,
                    p: entry.parent,
                    m: entry.markdown ?? "",
                    t: now,
                    c: counter
                ))
            case .purge:
                wires.append(Wire(
                    op: "purge",
                    h: entry.hash,
                    p: nil,
                    m: nil,
                    t: now,
                    c: counter
                ))
            }
            counter += 1
        }
        let lines = wires.compactMap(Self.encode).joined(separator: "\n") + "\n"
        try appendLines(lines, to: ourLogURL(for: rel))
        nextCounter[rel] = counter
    }

    /// Move a page's history dir. Used by trash / rename / restore so the
    /// per-device logs travel with their page.
    func move(fromPage src: String, toPage dst: String) throws {
        let from = pageDir(rel: src)
        let to = pageDir(rel: dst)
        guard FileManager.default.fileExists(atPath: from.path) else { return }
        try FileManager.default.createDirectory(
            at: to.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: from, to: to)
    }

    // MARK: - Persistence: reads

    /// Read every device's log for `page` and return as a `LogJournal`
    /// (engine input). No business logic — just JSONL → `LogRecord`.
    /// Slow path: reads every device file in full. Reconcile callers
    /// should prefer `reconcileAgainst(page:doc:mdMtime:)`, which uses
    /// watermarks + tail reads to skip unchanged files entirely.
    nonisolated func readJournal(page rel: String) -> LogJournal {
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

    // MARK: - Reconcile fast path (watermark + tail walk)

    /// Outcome of `reconcileAgainst`: either we determined nothing has
    /// changed since the last fold (skip — empty work), or we produced a
    /// `Reconciliation` from either a full re-fold or a delta walk over
    /// foreign-log tails. The caller (Clamshell's `runReconcile`) splices
    /// inserts into the live doc and persists `toAppend` + unrestorables
    /// to the log; both are non-empty only on the full-fold branch.
    enum ReconcileOutcome: Sendable {
        case skipped
        case folded(PatchEngine.Reconciliation, mode: Mode)

        enum Mode: Sendable {
            /// Full read of every device's log; produces inserts AND lifts
            /// unlogged doc observations AND quarantines.
            case full
            /// Delta walk over just the foreign devices whose `.jsonl`
            /// files grew since the watermark; produces inserts only. Bare-
            /// md absorption is skipped — the `.md` mtime matched the
            /// watermark, so the doc's blocks were already accounted for
            /// on the prior full fold.
            case tail
        }
    }

    /// Fold the journal for `rel` against `doc`, using watermarks to
    /// short-circuit when nothing has changed. The fast paths:
    /// 1. **Skip**: foreign log stats + our log stat + `mdMtime` all match
    ///    the watermark → no I/O beyond stat, returns `.skipped`.
    /// 2. **Tail**: `mdMtime` matches the watermark but one or more
    ///    foreign logs grew → tail-read the new bytes only, build splice
    ///    candidates, return `.folded(_, .tail)`.
    /// 3. **Full**: no watermark, or `.md` changed externally, or a log
    ///    shrunk → read everything fresh, returns `.folded(_, .full)`.
    /// On any non-skip branch, the watermark is refreshed.
    func reconcileAgainst(
        page rel: String,
        doc: [Block],
        mdMtime: Date?
    ) -> ReconcileOutcome {
        loadWatermarksIfNeeded()
        let dir = pageDir(rel: rel)
        let dirExists = FileManager.default.fileExists(atPath: dir.path)
        let watermark = pageWatermarks?[rel]
        let mdMtimeT = mdMtime?.timeIntervalSince1970

        // No journal dir AND no watermark → genuinely empty.
        if !dirExists, watermark == nil {
            return .skipped
        }

        let currentStats = currentDeviceStats(rel: rel)

        // Skip path: everything matches the watermark.
        if let w = watermark,
           w.mdMtime == mdMtimeT,
           w.devices == currentStats {
            return .skipped
        }

        // Tail path: `.md` is unchanged and we have a prior watermark.
        // Only foreign-log differences (grew, mtime moved forward) drive work.
        if let w = watermark, w.mdMtime == mdMtimeT, canTailWalk(old: w.devices, new: currentStats) {
            let recon = tailWalkFold(
                rel: rel,
                doc: doc,
                mdMtime: mdMtime,
                oldStats: w.devices,
                newStats: currentStats
            )
            pageWatermarks?[rel] = PageWatermark(mdMtime: mdMtimeT, devices: currentStats)
            saveWatermarks()
            return .folded(recon, mode: .tail)
        }

        // Full path: no watermark, or `.md` changed, or a foreign log
        // shrunk / vanished (cache invalid for that device).
        let recon = fullFold(rel: rel, doc: doc, mdMtime: mdMtime)
        pageWatermarks?[rel] = PageWatermark(mdMtime: mdMtimeT, devices: currentStats)
        saveWatermarks()
        return .folded(recon, mode: .full)
    }

    /// Update the watermark for `rel` to "I just wrote this." Called by
    /// the save path so a fresh `.md` mtime + grown own-log don't trigger
    /// a useless refold on next open. We saved the records that grew our
    /// log via `apply(_:to:)` and the engine has nothing else to do.
    ///
    /// Only our own device's stat is refreshed; foreign-device stats stay
    /// at whatever the last real fold absorbed. Stomping them with the
    /// current sizes here would claim we've absorbed records that iCloud
    /// happened to land *during* our save — silently swallowing the next
    /// foreign-driven presenter wakeup's reason to fold.
    func recordOwnSave(page rel: String, mdMtime: Date?) {
        loadWatermarksIfNeeded()
        var devices = pageWatermarks?[rel]?.devices ?? [:]
        let ourURL = ourLogURL(for: rel)
        if let values = try? ourURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
           let size = values.fileSize,
           let mtime = values.contentModificationDate {
            devices[deviceID] = DeviceWatermark(
                size: Int64(size),
                mtime: mtime.timeIntervalSince1970
            )
        }
        pageWatermarks?[rel] = PageWatermark(
            mdMtime: mdMtime?.timeIntervalSince1970,
            devices: devices
        )
        saveWatermarks()
    }

    // MARK: - Reconcile internals

    private func canTailWalk(old: [String: DeviceWatermark], new: [String: DeviceWatermark]) -> Bool {
        // Tail-walk works only when every device that existed before
        // either still exists with the same-or-larger size, or has its
        // mtime unchanged (no shrink, no rewrite). Any shrink/disappear
        // means the cached watermark is meaningless for that device →
        // fall back to full fold.
        for (id, oldW) in old {
            guard let newW = new[id] else { return false }
            if newW.size < oldW.size { return false }
        }
        // New devices are fine — they're handled in tailWalkFold by
        // reading the full file (offset 0 to current size).
        return true
    }

    /// Produce a `Reconciliation` whose `inserts` cover candidates found
    /// in the unread tails of foreign device logs. Skips
    /// `unloggedObservations` (the prior fold absorbed the doc; the `.md`
    /// is unchanged so nothing new to absorb) and quarantines.
    ///
    /// Only `add` records make a hash a restore candidate. `observe`
    /// records contribute a snapshot for completeness (so observed-only
    /// hashes don't get re-observed by `unloggedObservations` in the
    /// engine call) but don't promote a hash to `.alive`.
    private func tailWalkFold(
        rel: String,
        doc: [Block],
        mdMtime: Date?,
        oldStats: [String: DeviceWatermark],
        newStats: [String: DeviceWatermark]
    ) -> PatchEngine.Reconciliation {
        let docHashes = Self.collectAtomicHashes(doc)
        var addsByHash: [String: IntentState.AddSnapshot] = [:]
        var observesByHash: [String: IntentState.AddSnapshot] = [:]
        var purgedHashes: Set<String> = []

        for url in deviceLogURLs(for: rel) {
            let deviceID = url.deletingPathExtension().lastPathComponent
            let oldSize = oldStats[deviceID]?.size ?? 0
            let newSize = newStats[deviceID]?.size ?? 0
            guard newSize > oldSize else { continue }

            // Always offset 0 for newly-seen foreign devices; otherwise
            // pick up where we left off. Our own log: we trust our
            // self-driven watermark refresh in `recordOwnSave`, so a
            // growth here means we just wrote — fold our own new records
            // into the candidate map only if there's truly something we
            // didn't account for. Same code, same result either way.
            let offset = oldStats[deviceID] != nil ? oldSize : 0
            let wires = readWires(at: url, fromOffset: offset)
            for wire in wires {
                guard let kind = Self.wireKind(wire) else { continue }
                switch kind {
                case .add:
                    if let markdown = wire.m {
                        addsByHash[wire.h] = IntentState.AddSnapshot(
                            parent: wire.p,
                            markdown: markdown,
                            recordedAt: Date(timeIntervalSince1970: wire.t)
                        )
                        observesByHash.removeValue(forKey: wire.h)
                        purgedHashes.remove(wire.h)
                    }
                case .observe:
                    if addsByHash[wire.h] == nil, let markdown = wire.m {
                        observesByHash[wire.h] = IntentState.AddSnapshot(
                            parent: wire.p,
                            markdown: markdown,
                            recordedAt: Date(timeIntervalSince1970: wire.t)
                        )
                    }
                case .purge:
                    purgedHashes.insert(wire.h)
                    addsByHash.removeValue(forKey: wire.h)
                    observesByHash.removeValue(forKey: wire.h)
                }
            }
        }

        // Candidates: alive-in-tail (add-backed), not purged-in-tail, not
        // in doc. Observe-only hashes become `.observed` so the engine's
        // `unloggedObservations` won't re-emit them but they aren't
        // auto-restore candidates either.
        var byHash: [String: IntentState.Status] = [:]
        for (hash, add) in addsByHash where !purgedHashes.contains(hash) && !docHashes.contains(hash) {
            byHash[hash] = .alive(latestAdd: add)
        }
        for (hash, snapshot) in observesByHash where !purgedHashes.contains(hash) && byHash[hash] == nil {
            byHash[hash] = .observed(latestSnapshot: snapshot)
        }
        // Mark doc hashes as alive in the synthetic intent so
        // `unloggedObservations` doesn't try to lift them. Dummy
        // snapshots (parent: nil, empty markdown) are never read — the
        // doc-hash entries get filtered out before reaching the lost-
        // block forest.
        let dummy = IntentState.AddSnapshot(parent: nil, markdown: "", recordedAt: .distantPast)
        for hash in docHashes where byHash[hash] == nil {
            byHash[hash] = .alive(latestAdd: dummy)
        }
        let intent = IntentState(byHash: byHash)
        return PatchEngine.reconcile(intent: intent, doc: doc, mdMtime: mdMtime)
    }

    private func fullFold(rel: String, doc: [Block], mdMtime: Date?) -> PatchEngine.Reconciliation {
        let journal = readJournal(page: rel)
        let intent = PatchEngine.intent(from: journal)
        return PatchEngine.reconcile(intent: intent, doc: doc, mdMtime: mdMtime)
    }

    private func currentDeviceStats(rel: String) -> [String: DeviceWatermark] {
        var out: [String: DeviceWatermark] = [:]
        for url in deviceLogURLs(for: rel) {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize,
                  let mtime = values.contentModificationDate else { continue }
            let deviceID = url.deletingPathExtension().lastPathComponent
            out[deviceID] = DeviceWatermark(
                size: Int64(size),
                mtime: mtime.timeIntervalSince1970
            )
        }
        return out
    }

    private nonisolated static func collectAtomicHashes(_ blocks: [Block]) -> Set<String> {
        var out: Set<String> = []
        func walk(_ list: [Block]) {
            for block in list {
                out.insert(block.atomicHash)
                walk(block.children)
            }
        }
        walk(blocks)
        return out
    }

    private nonisolated static func wireKind(_ wire: Wire) -> WireKind? {
        switch wire.op {
        case "add": return .add
        case "observe": return .observe
        case "purge": return .purge
        default: return nil
        }
    }

    private enum WireKind { case add, observe, purge }

    // MARK: - Watermark persistence

    private func loadWatermarksIfNeeded() {
        guard pageWatermarks == nil else { return }
        guard let data = UserDefaults.standard.data(forKey: watermarkDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: PageWatermark].self, from: data) else {
            pageWatermarks = [:]
            return
        }
        pageWatermarks = decoded
    }

    private func saveWatermarks() {
        guard let pageWatermarks else { return }
        guard let data = try? JSONEncoder().encode(pageWatermarks) else { return }
        UserDefaults.standard.set(data, forKey: watermarkDefaultsKey)
    }

    // MARK: - Tail read

    private nonisolated func readWires(at url: URL, fromOffset offset: Int64) -> [Wire] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        do {
            if offset > 0 {
                try handle.seek(toOffset: UInt64(offset))
            }
            let data = handle.readDataToEndOfFile()
            guard !data.isEmpty else { return [] }
            let text = String(decoding: data, as: UTF8.self)
            var out: [Wire] = []
            for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
                if let record = Self.decodeWire(String(raw)) {
                    out.append(record)
                }
            }
            return out
        } catch {
            return []
        }
    }

    // MARK: - Engine-backed enumeration

    /// Lost-block entries for one page: hashes whose latest record is an
    /// `add` and aren't currently alive in the page's `.md`. Sorted by
    /// `recordedAt` descending.
    func enumerate(page rel: String) -> [LostBlock] {
        let journal = readJournal(page: rel)
        let intent = PatchEngine.intent(from: journal)
        let live = liveAtomicHashes(forPage: rel)
        return intent.lostEntries(notIn: live, source: rel)
    }

    /// Lost blocks for every page that has ever produced log activity.
    func enumerateAll() -> [LostBlock] {
        let historyRoot = historyRootURL()
        guard FileManager.default.fileExists(atPath: historyRoot.path) else { return [] }
        var out: [LostBlock] = []
        for rel in pageRelsUnder(historyRoot) {
            out.append(contentsOf: enumerate(page: rel))
        }
        return out.sorted { $0.recordedAt > $1.recordedAt }
    }

    /// Blocks deleted via the editor's op stream or a manual Recover-sheet
    /// dismiss: the latest record for the hash is a `purge`, but a prior
    /// `add` for the same hash still carries the markdown + parent metadata.
    func enumeratePurged(page rel: String, since: Date? = nil) -> [PurgedBlock] {
        let journal = readJournal(page: rel)
        let intent = PatchEngine.intent(from: journal)
        let live = liveAtomicHashes(forPage: rel)
        return intent.purgedEntries(notIn: live, source: rel, since: since)
    }

    /// Purged blocks for every page that has ever produced log activity.
    func enumerateAllPurged(since: Date? = nil) -> [PurgedBlock] {
        let historyRoot = historyRootURL()
        guard FileManager.default.fileExists(atPath: historyRoot.path) else { return [] }
        var out: [PurgedBlock] = []
        for rel in pageRelsUnder(historyRoot) {
            out.append(contentsOf: enumeratePurged(page: rel, since: since))
        }
        return out.sorted { $0.purgedAt > $1.purgedAt }
    }

    // MARK: - Internals: counter mint

    /// Compute the next Lamport counter for the page, taking the max over (a)
    /// our cached value (everything we've already minted in this process) and
    /// (b) every foreign device's log on disk. Foreign logs are re-scanned on
    /// every call so that records sync'd in via iCloud after our initial
    /// hydration still raise our counter — without this, our next mint can
    /// undershoot a foreign record that's already on disk, and the union's
    /// `(c, deviceID)` lex tiebreak silently elevates the wrong record.
    ///
    /// Cost: one stat + read per foreign device log per call. Callers reach
    /// here only when they have something to write, so steady-state saves
    /// pay zero log I/O.
    private func ensureCounterLoaded(for rel: String) throws -> UInt64 {
        let cached = nextCounter[rel]
        let ourLog = ourLogURL(for: rel)
        var maxObserved: UInt64 = 0
        for url in deviceLogURLs(for: rel) {
            // Skip our own log once it's been hydrated — `cached` already
            // reflects everything we've minted, and the initial hydration
            // (cached == nil) walked our log along with the rest.
            if cached != nil, url == ourLog { continue }
            for record in readRecords(at: url) {
                if let c = record.c { maxObserved = max(maxObserved, c) }
            }
        }
        let next = max(cached ?? 0, maxObserved + 1)
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

    // MARK: - Watermark types

    /// Per-(workspace, page) reconcile watermark, persisted in
    /// `UserDefaults` next to `DeviceID`. The journal files are the
    /// source of truth; this is just "where we last folded up to,"
    /// enough to recognise the no-change case via stat alone.
    fileprivate struct PageWatermark: Codable, Sendable {
        let mdMtime: TimeInterval?
        let devices: [String: DeviceWatermark]
    }

    fileprivate struct DeviceWatermark: Codable, Sendable, Equatable {
        let size: Int64
        let mtime: TimeInterval
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
        case "observe":
            return .observe(counter: wire.c, hash: wire.h, parent: wire.p, markdown: wire.m ?? "", t: wire.t)
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
struct LostBlock: Sendable, Identifiable {
    let markdown: String
    let hash: String
    let parentHash: String?
    let source: String
    let recordedAt: Date

    var id: String { "\(source)|\(hash)" }
}

extension LostBlock: Hashable {
    static func == (lhs: LostBlock, rhs: LostBlock) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension LostBlock {
    /// Construct a `LostBlock` from raw fields. Used by `PatchEngine` and
    /// by code paths that re-group `PurgedBlock`s through the same forest
    /// assembler.
    static func adapt(
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
struct PurgedBlock: Sendable, Identifiable {
    let markdown: String
    let hash: String
    let parentHash: String?
    let source: String
    let purgedAt: Date

    var id: String { "\(source)|\(hash)" }
}

extension PurgedBlock: Hashable {
    static func == (lhs: PurgedBlock, rhs: PurgedBlock) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension PurgedBlock {
    static func adapt(
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
