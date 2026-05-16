import Foundation
import Editor

public struct WorkspaceEntry: Identifiable, Sendable, Hashable {
    public let url: URL
    public let relativePath: String
    public let title: String
    public let modificationDate: Date

    public var id: URL { url }

    public init(url: URL, relativePath: String, title: String, modificationDate: Date) {
        self.url = url
        self.relativePath = relativePath
        self.title = title
        self.modificationDate = modificationDate
    }
}

/// Shared workspace state — one per app instance, mounted as `@State` at the
/// `App` level. Owns the open `Clamshell`, the page list, the title cache, and
/// the disk-content history that defends in-memory edits against iCloud-Drive
/// stomps. Per-window state (path, openDocument, save lifecycle) lives on
/// `WorkspaceWindow`, which holds a reference to this.
@MainActor
@Observable
final class Workspace {
    var workspaceURL: URL?
    /// Raw scan result from `clamshell.scan()`. Titles here are
    /// filename-derived fallbacks; the title overlay lives in `titleCache`.
    /// Use `entries` for the user-facing list — it merges this with the cache.
    private(set) var scanResult: [WorkspaceEntry] = []
    /// Page list with current title overlay applied. Computed from
    /// `scanResult` + `titleCache` so the two never drift — mutating either
    /// invalidates Observation subscribers automatically.
    var entries: [WorkspaceEntry] {
        scanResult.map { entry in
            let title: String
            if let cached = titleCache[entry.url], cached.modificationDate == entry.modificationDate {
                title = cached.title
            } else {
                title = entry.title
            }
            return WorkspaceEntry(
                url: entry.url,
                relativePath: entry.relativePath,
                title: title,
                modificationDate: entry.modificationDate
            )
        }
    }
    var homeRelativePath: String?
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
    }

    /// URLs currently mounted as `openDocument` in any `WorkspaceWindow`.
    /// Refcounted so two windows showing the same page don't lose tracking
    /// when one closes. Used by `rescan()` to skip pages that have an active
    /// file presenter (which handles their conflict resolution directly).
    private var openURLCounts: [URL: Int] = [:]

    private(set) var clamshell: Clamshell?

    /// Shared across every editor mounted in this workspace — the disk cache
    /// is a per-device asset that has nothing to do with which page is open.
    let linkPreviewService = LinkPreviewService()

    /// Per-URL ring buffer of recently observed on-disk content hashes
    /// (most recent first, capped at 5). Used by
    /// `WorkspaceWindow.handlePresentedFileChange` to distinguish:
    ///  - our own write echoing back through the FS (matches head)
    ///  - an iCloud Drive revert to a state we've previously seen (matches tail)
    ///  - a genuine external edit (matches nothing)
    private(set) var diskHistory: [URL: [Int]] = [:]

    private var titleCache: [URL: CachedTitle] = [:]
    private var titleRefreshTask: Task<Void, Never>?
    private var accessedWorkspaceURL: URL?

    private struct CachedTitle {
        var title: String
        var modificationDate: Date?
    }

    var homeURL: URL? {
        guard let homeRelativePath else { return nil }
        return entries.first { $0.relativePath == homeRelativePath }?.url
    }

    func relativePath(of url: URL) -> String {
        clamshell?.relativePath(of: url) ?? url.lastPathComponent
    }

    /// Resolve an inline-link URL against a document's directory and return
    /// its workspace-relative path if it points at a markdown file inside
    /// the workspace. Returns nil for external schemes, non-`.md` targets,
    /// and anything resolving outside the workspace. Used by the
    /// `OpenURLAction` interceptor in `ContentView` to route `[text](page.md)`
    /// clicks through `WorkspaceWindow.openSubpage` instead of the system
    /// `openURL` handler.
    func workspaceRelativeMarkdownPath(for url: URL, currentDocURL: URL?) -> String? {
        guard let workspaceURL else { return nil }
        return Self.resolveWorkspaceRelativeMarkdownPath(
            for: url,
            currentDocURL: currentDocURL,
            workspaceURL: workspaceURL
        )
    }

    nonisolated static func resolveWorkspaceRelativeMarkdownPath(
        for url: URL,
        currentDocURL: URL?,
        workspaceURL: URL
    ) -> String? {
        if let scheme = url.scheme?.lowercased(), scheme != "file" { return nil }

        let resolvedURL: URL
        if url.scheme == "file" {
            resolvedURL = url.standardizedFileURL
        } else {
            let baseDir = currentDocURL?.deletingLastPathComponent() ?? workspaceURL
            guard let resolved = URL(string: url.relativeString, relativeTo: baseDir) else {
                return nil
            }
            resolvedURL = resolved.absoluteURL.standardizedFileURL
        }

        guard resolvedURL.pathExtension.lowercased() == "md" else { return nil }

        let workspaceRoot = workspaceURL.standardizedFileURL.path
        let resolvedPath = resolvedURL.path
        guard resolvedPath.hasPrefix(workspaceRoot + "/") else { return nil }
        return String(resolvedPath.dropFirst(workspaceRoot.count + 1))
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
            accessedWorkspaceURL = url
            workspaceURL = url
            let clamshell = Clamshell(root: url)
            self.clamshell = clamshell
            homeRelativePath = clamshell.homeRelativePath
            rescan()
        }
    }

    private func installLaunchArgWorkspace(path: String) {
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        workspaceURL = root
        let clamshell = Clamshell(root: root)
        // Fixture clamshells contain a single `everything.md` — open it
        // directly so snap-diff sees content immediately on launch.
        if clamshell.homeRelativePath == nil {
            clamshell.homeRelativePath = "everything.md"
        }
        self.clamshell = clamshell
        homeRelativePath = clamshell.homeRelativePath
        scanResult = (try? clamshell.scan()) ?? []
    }

    func setWorkspaceFromKeyFile(_ url: URL) {
        let root = url.deletingLastPathComponent()
        let homePath = url.lastPathComponent
        do {
            try WorkspaceBookmark.save(url: root)
            activateWorkspaceAccess(for: root)
            workspaceURL = root
            let clamshell = Clamshell(root: root)
            clamshell.homeRelativePath = homePath
            self.clamshell = clamshell
            homeRelativePath = homePath
            rescan()
        } catch {
            self.error = "Failed to save workspace bookmark: \(error.localizedDescription)"
        }
    }

    func setWorkspace(_ url: URL) {
        do {
            try WorkspaceBookmark.save(url: url)
            activateWorkspaceAccess(for: url)
            workspaceURL = url
            let clamshell = Clamshell(root: url)
            self.clamshell = clamshell
            homeRelativePath = clamshell.homeRelativePath
            rescan()
            if homeRelativePath == nil {
                autoDetectOrSeedHome(in: clamshell)
            }
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
            clamshell.homeRelativePath = detected
            homeRelativePath = detected
            return
        }

        // Empty folder — seed the welcome page and set it as home.
        guard let path = createSubpage(
            title: "Welcome to Hunch",
            requestedPath: nil,
            initialContent: welcomeContentBlocks()
        ), let entry = entries.first(where: { $0.relativePath == path }) else { return }
        setHome(entry)
    }

    /// Drop the currently bookmarked workspace. Open windows observe
    /// `workspaceURL == nil` and reset their navigation state to empty;
    /// see `WorkspaceWindow` reactions.
    func switchWorkspace() {
        WorkspaceBookmark.clear()
        releaseWorkspaceAccess()
        workspaceURL = nil
        homeRelativePath = nil
        scanResult = []
        titleCache = [:]
        diskHistory = [:]
        openURLCounts = [:]
        clamshell = nil
        titleRefreshTask?.cancel()
        titleRefreshTask = nil
    }

    func rescan() {
        guard let workspaceURL, let clamshell else { return }
        do {
            scanResult = try clamshell.scan()
            refreshTitlesInBackground(for: scanResult, workspaceURL: workspaceURL)
            resolveConflictsForClosedPages(workspaceURL: workspaceURL)
        } catch {
            self.error = "Failed to scan workspace: \(error.localizedDescription)"
        }
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

        Task { @MainActor [weak self, clamshell, candidates, workspaceURL, titleByURL] in
            var anyMerged = false
            for url in candidates {
                guard let self else { return }
                guard self.workspaceURL == workspaceURL else { return }
                let count: Int
                do {
                    count = try clamshell.resolveConflictVersions(at: url, againstLive: nil)
                } catch {
                    Diag.merge.error("scan-time resolve failed url=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                    await Task.yield()
                    continue
                }
                if count > 0 {
                    anyMerged = true
                    let title = titleByURL[url] ?? url.deletingPathExtension().lastPathComponent
                    let noun = count == 1 ? "block" : "blocks"
                    self.banner = Banner(message: "Merged \(count) \(noun) from another device into \(title)")
                }
                await Task.yield()
            }
            if anyMerged, let self, self.workspaceURL == workspaceURL {
                self.rescan()
            }
        }
    }

    func setHome(_ entry: WorkspaceEntry) {
        homeRelativePath = entry.relativePath
        clamshell?.homeRelativePath = entry.relativePath
    }

    // MARK: - Disk-history (iCloud-stomp defense)

    /// Record a hash of on-disk content for `url`. Most recent first; ring
    /// buffer of 5 entries. Consecutive duplicates are deduped.
    func recordDiskHash(_ hash: Int, for url: URL) {
        var history = diskHistory[url] ?? []
        if history.first == hash { return }
        history.insert(hash, at: 0)
        if history.count > 5 { history.removeLast(history.count - 5) }
        diskHistory[url] = history
    }

    func recordDiskText(_ text: String, for url: URL) {
        recordDiskHash(text.hashValue, for: url)
    }

    /// Load via Clamshell with disk-hash side-effects. Prefer this over
    /// `clamshell?.loadDocument(at:)` from any host call site so the history
    /// stays seeded.
    func loadDocument(at url: URL) throws -> Document {
        guard let clamshell else {
            throw NSError(domain: "Workspace", code: -1, userInfo: [NSLocalizedDescriptionKey: "No workspace"])
        }
        let (document, raw) = try clamshell.loadDocumentAndRawText(at: url)
        recordDiskText(raw, for: url)
        return document
    }

    // MARK: - Read queries

    func lookupPage(_ relativePath: String) -> PageLookup {
        guard relativePath.hasSuffix(".md"), let clamshell else { return .missing }
        let url = clamshell.url(for: relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        let mtime = modificationDate(for: url)
        let cachedTitle = (titleCache[url]?.modificationDate == mtime) ? titleCache[url]?.title : nil
        return .present(title: cachedTitle)
    }

    /// Filter + rank pages for any picker surface. `excluding` typically the
    /// currently-open document (move-to / mention / jump-to); pass nil to
    /// include everything (sidebar / page-list sheet).
    func pages(matching query: String, excluding: URL?) -> [MentionItem] {
        guard let clamshell else { return [] }
        return clamshell.searchPages(in: entries, query: query, excluding: excluding)
    }

    func saveTitleResolver() -> @Sendable (String) -> String? {
        let titlesByPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.relativePath, $0.title) })
        return { relativePath in
            titlesByPath[relativePath]
        }
    }

    func modificationDate(for url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    // MARK: - Title cache

    @discardableResult
    func refreshTitleCache(from document: Document) -> Bool {
        let previous = titleCache[document.url]
        let titleChanged = previous?.title != document.title
        if titleChanged || previous?.modificationDate != document.modificationDate {
            titleCache[document.url] = CachedTitle(title: document.title, modificationDate: document.modificationDate)
        }
        return titleChanged
    }

    private func refreshTitlesInBackground(for scanned: [WorkspaceEntry], workspaceURL: URL) {
        let stale = scanned.filter { entry in
            titleCache[entry.url]?.modificationDate != entry.modificationDate
        }
        guard !stale.isEmpty, let clamshell else { return }

        titleRefreshTask?.cancel()
        // `loadDocumentTitle` constructs a transient `Document` (MainActor)
        // before deriving the title; the lookup itself stays cheap (no parse
        // beyond the leading H1), so running it on MainActor is fine.
        titleRefreshTask = Task { @MainActor [weak self, clamshell, stale, workspaceURL] in
            var refreshed: [URL: CachedTitle] = [:]
            for entry in stale {
                guard !Task.isCancelled else { return }
                if let title = try? clamshell.loadDocumentTitle(at: entry.url) {
                    refreshed[entry.url] = CachedTitle(title: title, modificationDate: entry.modificationDate)
                }
            }
            guard !Task.isCancelled else { return }
            self?.applyRefreshedTitles(refreshed, workspaceURL: workspaceURL)
        }
    }

    private func applyRefreshedTitles(_ refreshed: [URL: CachedTitle], workspaceURL: URL) {
        guard self.workspaceURL == workspaceURL, !refreshed.isEmpty else { return }
        let truly = refreshed.filter { url, new in
            let prev = titleCache[url]
            return prev?.title != new.title || prev?.modificationDate != new.modificationDate
        }
        guard !truly.isEmpty else { return }
        titleCache.merge(truly) { _, new in new }
    }

    // MARK: - Page-level mutations

    /// Filesystem-only: move a page to trash. Caller (`WorkspaceWindow`) is
    /// responsible for any per-window cleanup (close openDocument, drop from
    /// path) before calling.
    @discardableResult
    func moveToTrash(at url: URL) -> Bool {
        guard let clamshell else { return false }
        titleCache.removeValue(forKey: url)
        diskHistory.removeValue(forKey: url)
        do {
            _ = try clamshell.moveToTrash(at: url)
            homeRelativePath = clamshell.homeRelativePath
            rescan()
            return true
        } catch {
            self.error = "Failed to move \(relativePath(of: url)) to trash: \(error.localizedDescription)"
            return false
        }
    }

    func createSubpage(title: String, requestedPath: String?, initialContent: [Block]?) -> String? {
        guard let clamshell else { return requestedPath }
        do {
            let path = try clamshell.createPage(title: title, requestedPath: requestedPath, blocks: initialContent)
            let target = clamshell.url(for: path)
            titleCache[target] = CachedTitle(title: title, modificationDate: modificationDate(for: target))
            // Seed disk history for the freshly-created file so the presenter
            // doesn't classify the create event as "external".
            if let raw = try? clamshell.readRawText(at: target) {
                recordDiskText(raw, for: target)
            }
            rescan()
            return path
        } catch {
            self.error = "Failed to create page: \(error.localizedDescription)"
            return requestedPath
        }
    }

    func loadSubpage(relativePath: String) -> [Block]? {
        guard let clamshell else { return nil }
        let target = clamshell.url(for: relativePath)
        do {
            let doc = try loadDocument(at: target)
            return doc.children
        } catch {
            Diag.subpage.error("loadSubpage: loadDocument(at: \(target.path, privacy: .public)) threw: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    @discardableResult
    func appendToSubpage(relativePath: String, blocks: [Block]) -> Document? {
        guard !blocks.isEmpty, let clamshell else { return nil }
        let target = clamshell.url(for: relativePath)
        do {
            let doc = try loadDocument(at: target)
            doc.children.append(contentsOf: blocks)
            // Re-fold so the appended blocks land inside any heading that
            // was at the end of the page, not as siblings of it.
            doc.enforceHeadingContainment()
            try clamshell.writeImmediately(doc, resolvingSubpageTitle: saveTitleResolver())
            doc.modificationDate = modificationDate(for: target)
            // Seed history with the new on-disk text.
            if let raw = try? clamshell.readRawText(at: target) {
                recordDiskText(raw, for: target)
            }
            refreshTitleCache(from: doc)
            return doc
        } catch {
            self.error = "Failed to move blocks into \(relativePath): \(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func moveSubpageToTrash(relativePath: String) -> Bool {
        guard let clamshell else { return false }
        let target = clamshell.url(for: relativePath)
        return moveToTrash(at: target)
    }

    // MARK: - Pasted images

    /// Persist a batch of pasted images, returning the relative paths the
    /// editor will write into image-block `source` fields. Skips items that
    /// fail to write so the editor still inserts blocks for the rest.
    func saveImages(_ items: [PastedImage]) -> [String] {
        guard let clamshell else { return [] }
        var paths: [String] = []
        paths.reserveCapacity(items.count)
        for item in items {
            do {
                paths.append(try clamshell.writeImage(item))
            } catch {
                self.error = "Failed to save pasted image: \(error.localizedDescription)"
            }
        }
        return paths
    }

    /// Resolve an image block's source string to an on-disk URL.
    func imageURL(for source: String) -> URL? {
        clamshell?.resolveImage(source: source)
    }

    // MARK: - Recovery

    /// Snapshot the about-to-be-mutated block tree into the recovery log
    /// before a destructive UI action. Covers the race where blocks live
    /// briefly in the doc, get deleted, and the autosave never fires while
    /// they're present — without this, those blocks would never be logged
    /// and would be unrecoverable.
    func recordBlockDeletion(sourceURL: URL, previousBlocks: [Block]) {
        guard let clamshell else { return }
        clamshell.snapshotIntoRecoveryLog(at: sourceURL, blocks: previousBlocks)
    }

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
            rescan()
            return true
        } catch {
            self.error = "Restore failed: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Workspace-scoped resource access

    private func activateWorkspaceAccess(for url: URL) {
        releaseWorkspaceAccess()
        _ = url.startAccessingSecurityScopedResource()
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
            workspaceURL = root
            let clamshell = Clamshell(root: root)
            self.clamshell = clamshell
            scanResult = (try? clamshell.scan()) ?? []
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
            workspaceURL = root
            let clamshell = Clamshell(root: root)
            clamshell.homeRelativePath = "everything.md"
            self.clamshell = clamshell
            homeRelativePath = "everything.md"
            scanResult = (try? clamshell.scan()) ?? []
        } catch {
            self.error = "Failed to install tall-doc UI test workspace: \(error.localizedDescription)"
        }
    }
}

public enum RecoveryListFilter: Sendable, Hashable, Identifiable {
    case all
    case page(relativePath: String)

    public var id: Self { self }
}

/// Tree-consolidated view of a lost block forest root. Wraps the root
/// `LostBlock` (used for restore — the `WorkspaceWindow` path reconstructs
/// the subtree from this hash) plus the set of hashes covered by the
/// assembled tree (for "+N more" affordances and post-restore purge).
public struct LostBlockGroup: Sendable, Hashable, Identifiable {
    public let root: LostBlock
    public let descendantHashes: Set<String>

    public var id: String { root.id }
    public var hash: String { root.hash }
    public var source: String { root.source }
    public var recordedAt: Date { root.recordedAt }
    public var markdown: String { root.markdown }
    public var nestedCount: Int { descendantHashes.count - 1 }

    public init(root: LostBlock, descendantHashes: Set<String>) {
        self.root = root
        self.descendantHashes = descendantHashes
    }
}

/// Same shape as `LostBlockGroup` but for intentionally-deleted blocks.
public struct PurgedBlockGroup: Sendable, Hashable, Identifiable {
    public let root: PurgedBlock
    public let descendantHashes: Set<String>

    public var id: String { root.id }
    public var hash: String { root.hash }
    public var source: String { root.source }
    public var purgedAt: Date { root.purgedAt }
    public var markdown: String { root.markdown }
    public var nestedCount: Int { descendantHashes.count - 1 }

    public init(root: PurgedBlock, descendantHashes: Set<String>) {
        self.root = root
        self.descendantHashes = descendantHashes
    }
}

public enum RecoverableEntry: Identifiable, Sendable, Hashable {
    case deletedPage(TrashEntry)
    case lostBlock(LostBlockGroup)
    case purgedBlock(PurgedBlockGroup)

    public var id: String {
        switch self {
        case .deletedPage(let e): return "page:\(e.id)"
        case .lostBlock(let g): return "lost:\(g.id)"
        case .purgedBlock(let g): return "purged:\(g.id)"
        }
    }

    public var timestamp: Date {
        switch self {
        case .deletedPage(let e): return e.timestamp
        case .lostBlock(let g): return g.recordedAt
        case .purgedBlock(let g): return g.purgedAt
        }
    }

    public var sourcePath: String {
        switch self {
        case .deletedPage(let e): return e.sourcePath
        case .lostBlock(let g): return g.source
        case .purgedBlock(let g): return g.source
        }
    }

    public var displayTitle: String {
        switch self {
        case .deletedPage(let e): return e.displayTitle
        case .lostBlock(let g): return RecoverableEntry.previewLine(from: g.markdown)
        case .purgedBlock(let g): return RecoverableEntry.previewLine(from: g.markdown)
        }
    }

    public var isPageEntry: Bool {
        if case .deletedPage = self { return true }
        return false
    }

    public var isPurged: Bool {
        if case .purgedBlock = self { return true }
        return false
    }

    /// Count of additional blocks (beyond the root) bundled in this entry.
    /// Used by `RecoveryView` to show "+N more" on tree-consolidated rows.
    public var nestedCount: Int {
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
