import Foundation
import Editor

struct WorkspaceEntry: Identifiable, Sendable, Hashable {
    let url: URL
    let relativePath: String
    let title: String
    let modificationDate: Date

    var id: URL { url }

    init(url: URL, relativePath: String, title: String, modificationDate: Date) {
        self.url = url
        self.relativePath = relativePath
        self.title = title
        self.modificationDate = modificationDate
    }
}

/// Shared workspace state — one per app instance, mounted as `@State` at the
/// `App` level. Owns the open `Clamshell` and the app-level UI surface
/// (error alert, transient banner). The page list, title cache, and
/// disk-content history live inside `Clamshell` itself. Per-window state
/// (path, openDocument, save lifecycle) lives on `WorkspaceWindow`.
@MainActor
@Observable
final class Workspace {
    var workspaceURL: URL?

    /// Page list with the live title overlay applied. Sourced from the
    /// active Clamshell, which owns the scan + title cache; nil clamshell
    /// (no workspace selected) returns an empty list.
    var entries: [WorkspaceEntry] {
        clamshell?.entries ?? []
    }

    /// Path (relative to the workspace root) of the home page, or nil if
    /// unset. Read-only passthrough to the active Clamshell — mutate via
    /// `clamshell?.setHome(relativePath:)`. The on-disk source of truth is
    /// `.clamshell.json` and travels with the folder.
    var homeRelativePath: String? {
        clamshell?.homeRelativePath
    }

    /// Surfaced in the alert in any open window. Last-write-wins across
    /// concurrent windows — acceptable; user dismisses the alert.
    var error: String?
    /// Transient non-modal notification shown by any open window. The
    /// BannerView clears it on its own dismiss timer. Last-write-wins
    /// across concurrent banners — uncommon enough to be fine.
    var banner: Banner?

    /// Transient, informational. Identity is per-instance so the view can
    /// distinguish "same message, new event" and restart its timer.
    struct Banner: Identifiable, Equatable {
        let id = UUID()
        let message: String

        /// Wording reused by every conflict-merge site (live-page presenter
        /// event AND the closed-page scan) so the message can't drift.
        static func merged(salvaged: Int, into title: String) -> Banner {
            let noun = salvaged == 1 ? "block" : "blocks"
            return Banner(message: "Merged \(salvaged) \(noun) from another device into \(title)")
        }

        static func restored(count: Int, into title: String) -> Banner {
            let noun = count == 1 ? "block" : "blocks"
            return Banner(message: "Restored \(count) \(noun) from another device into \(title)")
        }
    }

    /// URLs currently mounted as `openDocument` in any `WorkspaceWindow`.
    /// Refcounted so two windows showing the same page don't lose tracking
    /// when one closes. Used by `resolveConflictsForClosedPages` to skip
    /// pages with an active file presenter.
    private var openURLCounts: [URL: Int] = [:]

    private(set) var clamshell: Clamshell?

    /// Shared across every editor mounted in this workspace — the disk cache
    /// is a per-device asset that has nothing to do with which page is open.
    let linkPreviewService = LinkPreviewService()

    private var accessedWorkspaceURL: URL?

    /// Once-per-mount latch: the closed-page conflict sweep runs at most once
    /// per `Clamshell` instance, kicked by the first successful `openPage`
    /// (see `scheduleConflictSweepIfNeeded`). Reset whenever the clamshell is
    /// replaced (mount / switchWorkspace).
    private var hasRunConflictSweep = false

    var homeURL: URL? {
        clamshell?.homeURL
    }

    // MARK: - Lifecycle

    func tryRestore() {
        if ProcessInfo.processInfo.arguments.contains("--console-ui-testing") {
            installUITestWorkspace()
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--console-ui-testing-tall-doc") {
            installTallDocUITestWorkspace()
            return
        }
        // tryRestore is called from `.task` in every window; only the first
        // call needs to do anything.
        guard workspaceURL == nil else { return }
        // `--workspace <path>` overrides the saved bookmark for this process —
        // used by `scripts/use-fixture.sh` to point at the typography-iteration
        // fixture directory without clobbering the user's real workspace bookmark.
        let args = ProcessInfo.processInfo.arguments
        if let idx = args.firstIndex(of: "--workspace"), idx + 1 < args.count {
            installLaunchArgWorkspace(path: args[idx + 1])
            return
        }
        if let url = WorkspaceBookmark.resolve() {
            let total = perfStart()
            accessedWorkspaceURL = url
            mount(root: url)
            rescan()
            perfEnd(total, "Workspace.tryRestore")
        }
    }

    /// Install a fresh `Clamshell` rooted at `root` and publish it on
    /// `workspaceURL`. Callers handle bookmark / security-scope / home-page
    /// setup and choose the rescan flavor (workspace-level `rescan()` triggers
    /// closed-page conflict resolution; `clamshell.rescan()` skips it).
    @discardableResult
    private func mount(root: URL) -> Clamshell {
        workspaceURL = root
        let clamshell = Clamshell(root: root)
        self.clamshell = clamshell
        hasRunConflictSweep = false
        return clamshell
    }

    private func installLaunchArgWorkspace(path: String) {
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let clamshell = mount(root: root)
        // Fixture clamshells contain a single `everything.md` — open it
        // directly so snap-diff sees content immediately on launch.
        if clamshell.homeRelativePath == nil {
            clamshell.setHome(relativePath: "everything.md")
        }
        try? clamshell.rescan()
    }

    func setWorkspace(_ url: URL) {
        let total = perfStart()
        do {
            try WorkspaceBookmark.save(url: url)
            activateWorkspaceAccess(for: url)
            let clamshell = mount(root: url)
            rescan()
            if homeRelativePath == nil {
                autoDetectOrSeedHome(in: clamshell)
            }
            perfEnd(total, "Workspace.setWorkspace")
        } catch {
            self.error = "Failed to save workspace bookmark: \(error.localizedDescription)"
        }
    }

    /// Create a new workspace folder at `url` and open it. The folder is seeded
    /// with a welcome page by `setWorkspace`'s auto-detect path (the folder is
    /// empty after creation, so the seed branch fires).
    func createNewWorkspace(at url: URL) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            self.error = "Failed to create workspace folder: \(error.localizedDescription)"
            return
        }
        setWorkspace(url)
    }

    /// After `setWorkspace` lands a folder with no `homeRelativePath`, pick or
    /// create a home page so the user doesn't get dumped into `EmptyWorkspaceView`:
    ///   - If a root-level `README.md` / `index.md` exists, use it.
    ///   - Else if any root-level `.md` exists, use the alphabetically-first.
    ///   - Else seed `Welcome to Hunch.md` from `welcomeContentBlocks()`.
    private func autoDetectOrSeedHome(in clamshell: Clamshell) {
        let rootMDs = entries
            .filter { !$0.relativePath.contains("/") }
            .sorted { $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending }
        let detected: String? = {
            if let readme = rootMDs.first(where: { $0.relativePath.lowercased() == "readme.md" }) {
                return readme.relativePath
            }
            if let index = rootMDs.first(where: { $0.relativePath.lowercased() == "index.md" }) {
                return index.relativePath
            }
            return rootMDs.first?.relativePath
        }()

        if let detected {
            clamshell.setHome(relativePath: detected)
            return
        }

        // Empty folder — seed the welcome page and set it as home.
        guard let path = createPage(
            title: "Welcome to Hunch",
            requestedPath: nil,
            initialContent: welcomeContentBlocks()
        ) else { return }
        clamshell.setHome(relativePath: path)
    }

    /// Drop the currently bookmarked workspace. Open windows observe
    /// `workspaceURL == nil` and reset their navigation state to empty;
    /// see `WorkspaceWindow` reactions.
    func switchWorkspace() {
        WorkspaceBookmark.clear()
        releaseWorkspaceAccess()
        workspaceURL = nil
        openURLCounts = [:]
        clamshell = nil
    }

    /// Reread the workspace from disk. `includeConflictSweep: false` (default)
    /// is the on-mount path — sweep is deferred to `scheduleConflictSweepIfNeeded`
    /// so it can't compete with the home-page open for MainActor. Pass `true`
    /// for user-driven reloads (Cmd-R) where surfacing alternates is the point.
    func rescan(includeConflictSweep: Bool = false) {
        guard let workspaceURL, let clamshell else { return }
        let total = perfStart()
        do {
            try clamshell.rescan()
            perfEnd(total, "Workspace.rescan", "includeSweep=\(includeConflictSweep)")
            if includeConflictSweep {
                hasRunConflictSweep = true
                resolveConflictsForClosedPages(workspaceURL: workspaceURL)
            }
        } catch {
            self.error = "Failed to scan workspace: \(error.localizedDescription)"
        }
    }

    /// Fire the closed-page conflict sweep exactly once per `Clamshell`
    /// instance. Called from `WorkspaceWindow.handlePathChange` after the
    /// first successful `openPage` so the sweep runs after the home page
    /// is visible, not racing it for MainActor. No-op on repeat calls.
    func scheduleConflictSweepIfNeeded() {
        guard let workspaceURL else { return }
        guard !hasRunConflictSweep else { return }
        hasRunConflictSweep = true
        resolveConflictsForClosedPages(workspaceURL: workspaceURL)
    }

    // MARK: - Open-URL registry

    /// Register a URL as currently mounted in some window's `openDocument`.
    /// Refcounted; safe to call repeatedly. Pair with `unregisterOpenURL`.
    func registerOpenURL(_ url: URL) {
        openURLCounts[url, default: 0] += 1
    }

    func unregisterOpenURL(_ url: URL) {
        guard let n = openURLCounts[url] else { return }
        if n <= 1 { openURLCounts.removeValue(forKey: url) }
        else { openURLCounts[url] = n - 1 }
    }

    // MARK: - iCloud conflict resolution

    /// Iterate scanned entries in the background and run
    /// `Clamshell.resolveConflictVersions` for any page that isn't currently
    /// open in a window (those are handled by their file presenter). Surfaces
    /// a banner per page that salvaged blocks; rescans once at the end if
    /// anything was merged so the page list picks up the new mtime.
    private func resolveConflictsForClosedPages(workspaceURL: URL) {
        guard let clamshell else { return }
        let candidates = entries
            .map(\.url)
            .filter { openURLCounts[$0] == nil }
        guard !candidates.isEmpty else { return }
        let titleByURL = Dictionary(uniqueKeysWithValues: entries.map { ($0.url, $0.title) })
        Diag.perf.log("sweep start candidates=\(candidates.count, privacy: .public)")

        Task { @MainActor [weak self, clamshell, candidates, workspaceURL, titleByURL] in
            let sweepTotal = perfStart()
            var anyMerged = false
            for url in candidates {
                guard let self else { return }
                guard self.workspaceURL == workspaceURL else { return }
                let resolution: Clamshell.ConflictResolution
                let iter = perfStart()
                do {
                    resolution = try await clamshell.resolveConflictVersions(at: url, againstLive: nil)
                } catch {
                    Diag.merge.error("scan-time resolve failed url=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                    perfEnd(iter, "sweep.iter", "url=\(url.lastPathComponent) error=1")
                    await Task.yield()
                    continue
                }
                perfEnd(iter, "sweep.iter", "url=\(url.lastPathComponent) salvaged=\(resolution.salvaged)")
                if resolution.salvaged > 0 {
                    anyMerged = true
                    let title = titleByURL[url] ?? url.deletingPathExtension().lastPathComponent
                    self.banner = .merged(salvaged: resolution.salvaged, into: title)
                }
                await Task.yield()
            }
            perfEnd(sweepTotal, "sweep.total", "merged=\(anyMerged)")
            if anyMerged, let self, self.workspaceURL == workspaceURL {
                self.rescan()
            }
        }
    }

    /// Convenience for new-page creation surfaces (welcome-page seed, the
    /// "New page" button in `EmptyWorkspaceView`): forwards to Clamshell
    /// and routes the throw into `self.error`. Returns the created
    /// relative path or nil on failure.
    @discardableResult
    func createPage(title: String, requestedPath: String?, initialContent: [Block]?) -> String? {
        guard let clamshell else { return nil }
        do {
            return try clamshell.createPage(title: title, requestedPath: requestedPath, initialContent: initialContent)
        } catch {
            self.error = "Failed to create page: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Recovery


    /// One-shot stream of recoverable entries (trash + lost blocks + purged
    /// blocks). Lost and purged blocks are tree-consolidated via
    /// `LostBlockForest.assemble` — a heading + child paragraphs deleted
    /// together arrive as one entry whose root carries the descendants.
    /// `purgedSince` caps purged-block surface area (default: last 30 days);
    /// pass `nil` via `showAllPurged` on the caller to disable.
    func streamRecoverableEntries(
        filter: RecoveryListFilter = .all,
        showAllPurged: Bool = false
    ) -> AsyncStream<[RecoverableEntry]> {
        AsyncStream { continuation in
            let task = Task { @MainActor [weak self] in
                guard let self, let clamshell = self.clamshell else {
                    continuation.yield([])
                    continuation.finish()
                    return
                }

                var out: [RecoverableEntry] = []
                if case .all = filter {
                    let pages = (try? await clamshell.listTrashedPages()) ?? []
                    out.append(contentsOf: pages.map { .deletedPage($0) })
                }
                let lostFilter: Clamshell.LostBlocksFilter
                switch filter {
                case .all: lostFilter = .all
                case .page(let rel): lostFilter = .page(relativePath: rel)
                }

                let lost = await clamshell.listLostBlocks(filter: lostFilter)
                out.append(contentsOf: Workspace.consolidate(lost: lost))

                let purgedSince: Date? = showAllPurged
                    ? nil
                    : Date().addingTimeInterval(-30 * 86_400)
                let purged = await clamshell.listPurgedBlocks(
                    filter: lostFilter,
                    since: purgedSince
                )
                out.append(contentsOf: Workspace.consolidate(purged: purged))

                out.sort { $0.timestamp > $1.timestamp }

                continuation.yield(out)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Group lost-block records by source page, then run each page's set
    /// through `LostBlockForest.assemble` so siblings sharing a parentHash
    /// chain emerge as one root with descendants attached. One
    /// `RecoverableEntry.lostBlock` per root.
    private static func consolidate(lost: [LostBlock]) -> [RecoverableEntry] {
        let bySource = Dictionary(grouping: lost) { $0.source }
        var out: [RecoverableEntry] = []
        for (_, entries) in bySource {
            for root in LostBlockForest.assemble(entries) {
                out.append(.lostBlock(LostBlockGroup(
                    root: root.lost,
                    descendantHashes: root.hashes
                )))
            }
        }
        return out
    }

    /// Same as `consolidate(lost:)` but for `PurgedBlock` records. Reuses
    /// the same forest assembler via a thin LostBlock-shaped shim so we
    /// have one tree-building code path.
    private static func consolidate(purged: [PurgedBlock]) -> [RecoverableEntry] {
        let bySource = Dictionary(grouping: purged) { $0.source }
        var out: [RecoverableEntry] = []
        for (_, entries) in bySource {
            // Adapter: feed purged into the same assembler via a lossless
            // mapping (LostBlock and PurgedBlock have the same recovery-
            // relevant fields). `recordedAt` carries `purgedAt` so root
            // ordering stays meaningful.
            let adapted: [LostBlock] = entries.map { p in
                LostBlock.adapt(
                    hash: p.hash,
                    parentHash: p.parentHash,
                    markdown: p.markdown,
                    source: p.source,
                    recordedAt: p.purgedAt
                )
            }
            let purgedByHash = Dictionary(uniqueKeysWithValues: entries.map { ($0.hash, $0) })
            for root in LostBlockForest.assemble(adapted) {
                guard let purgedRoot = purgedByHash[root.lost.hash] else { continue }
                out.append(.purgedBlock(PurgedBlockGroup(
                    root: purgedRoot,
                    descendantHashes: root.hashes
                )))
            }
        }
        return out
    }

    @discardableResult
    func restoreDeletedPage(_ entry: TrashEntry) async -> Bool {
        guard let clamshell else { return false }
        do {
            _ = try await clamshell.restorePage(entry)
            return true
        } catch {
            self.error = "Restore failed: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Workspace-scoped resource access

    private func activateWorkspaceAccess(for url: URL) {
        releaseWorkspaceAccess()
        let t = perfStart()
        _ = url.startAccessingSecurityScopedResource()
        perfEnd(t, "Workspace.activateWorkspaceAccess")
        accessedWorkspaceURL = url
    }

    private func releaseWorkspaceAccess() {
        accessedWorkspaceURL?.stopAccessingSecurityScopedResource()
        accessedWorkspaceURL = nil
    }

    // MARK: - UI test fixtures

    private func installUITestWorkspace() {
        do {
            let root = FileManager.default
                .temporaryDirectory
                .appendingPathComponent("console-ui-tests", isDirectory: true)
            try? FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let documentURL = root.appendingPathComponent("everything.md")
            let source = """
            # Drag Test

            Alpha

            Bravo

            Charlie

            Delta

            Echo

            Foxtrot
            """
            try source.write(to: documentURL, atomically: true, encoding: .utf8)
            try? mount(root: root).rescan()
        } catch {
            self.error = "Failed to install UI test workspace: \(error.localizedDescription)"
        }
    }

    private func installTallDocUITestWorkspace() {
        do {
            let root = FileManager.default
                .temporaryDirectory
                .appendingPathComponent("console-ui-tests", isDirectory: true)
            try? FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let documentURL = root.appendingPathComponent("everything.md")
            var lines: [String] = ["# Tall Doc"]
            for i in 1...60 {
                lines.append("Row \(String(format: "%02d", i))")
            }
            let source = lines.joined(separator: "\n\n")
            try source.write(to: documentURL, atomically: true, encoding: .utf8)
            let clamshell = mount(root: root)
            clamshell.setHome(relativePath: "everything.md")
            try? clamshell.rescan()
        } catch {
            self.error = "Failed to install tall-doc UI test workspace: \(error.localizedDescription)"
        }
    }
}

enum RecoveryListFilter: Sendable, Hashable, Identifiable {
    case all
    case page(relativePath: String)

    var id: Self { self }
}

/// Tree-consolidated view of a lost block forest root. Wraps the root
/// `LostBlock` (used for restore — the `WorkspaceWindow` path reconstructs
/// the subtree from this hash) plus the set of hashes covered by the
/// assembled tree (for "+N more" affordances and post-restore purge).
struct LostBlockGroup: Sendable, Hashable, Identifiable {
    let root: LostBlock
    let descendantHashes: Set<String>

    var id: String { root.id }
    var source: String { root.source }
    var recordedAt: Date { root.recordedAt }
    var markdown: String { root.markdown }
    var nestedCount: Int { descendantHashes.count - 1 }

    init(root: LostBlock, descendantHashes: Set<String>) {
        self.root = root
        self.descendantHashes = descendantHashes
    }
}

/// Same shape as `LostBlockGroup` but for intentionally-deleted blocks.
struct PurgedBlockGroup: Sendable, Hashable, Identifiable {
    let root: PurgedBlock
    let descendantHashes: Set<String>

    var id: String { root.id }
    var source: String { root.source }
    var purgedAt: Date { root.purgedAt }
    var markdown: String { root.markdown }
    var nestedCount: Int { descendantHashes.count - 1 }

    init(root: PurgedBlock, descendantHashes: Set<String>) {
        self.root = root
        self.descendantHashes = descendantHashes
    }
}

enum RecoverableEntry: Identifiable, Sendable, Hashable {
    case deletedPage(TrashEntry)
    case lostBlock(LostBlockGroup)
    case purgedBlock(PurgedBlockGroup)

    var id: String {
        switch self {
        case .deletedPage(let e): return "page:\(e.id)"
        case .lostBlock(let g): return "lost:\(g.id)"
        case .purgedBlock(let g): return "purged:\(g.id)"
        }
    }

    var timestamp: Date {
        switch self {
        case .deletedPage(let e): return e.timestamp
        case .lostBlock(let g): return g.recordedAt
        case .purgedBlock(let g): return g.purgedAt
        }
    }

    var sourcePath: String {
        switch self {
        case .deletedPage(let e): return e.sourcePath
        case .lostBlock(let g): return g.source
        case .purgedBlock(let g): return g.source
        }
    }

    var displayTitle: String {
        switch self {
        case .deletedPage(let e): return e.displayTitle
        case .lostBlock(let g): return RecoverableEntry.previewLine(from: g.markdown)
        case .purgedBlock(let g): return RecoverableEntry.previewLine(from: g.markdown)
        }
    }

    var isPurged: Bool {
        if case .purgedBlock = self { return true }
        return false
    }

    /// Count of additional blocks (beyond the root) bundled in this entry.
    /// Used by `RecoveryView` to show "+N more" on tree-consolidated rows.
    var nestedCount: Int {
        switch self {
        case .deletedPage: return 0
        case .lostBlock(let g): return g.nestedCount
        case .purgedBlock(let g): return g.nestedCount
        }
    }

    private static func previewLine(from body: String) -> String {
        for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return String(trimmed.prefix(80)) }
        }
        return ""
    }
}
