import Foundation
import Editor

/// Derived link graph over the workspace's pages: who links to whom, what's
/// reachable from the home page, and (therefore) what's orphaned. A pure value
/// snapshot — built off-main by `Clamshell.buildLinkGraph()`, cached on
/// `Clamshell`, and patched in place on save (`replacingOutbound`). Edges come
/// from both `.subpage` blocks and inline `[text](url)` links; the same
/// classifier the editor uses (`Clamshell.pagePath(for:relativeTo:)`) decides
/// what counts as an internal page reference.
struct LinkGraph: Sendable, Equatable {
    /// pageID → pages it links to (only targets that exist as live pages).
    let outbound: [String: Set<String>]
    /// pageID → pages that link to it (the inverse of `outbound`).
    let inbound: [String: Set<String>]
    /// Pages reachable from the home page by following `outbound` edges.
    let reachable: Set<String>
    /// The page vertex set this graph was built against.
    let allPageIDs: Set<String>
    /// `allPageIDs − reachable − {home}` — pages stranded off the home graph.
    let orphans: Set<String>

    static let empty = LinkGraph(
        outbound: [:], inbound: [:], reachable: [], allPageIDs: [], orphans: []
    )

    /// Pages that link to `pageID`, sorted for stable rendering.
    func backlinks(of pageID: String) -> [String] {
        (inbound[pageID] ?? []).sorted()
    }

    /// True when `pageID` can't be reached from home (the home page itself is
    /// never an orphan).
    func isOrphan(_ pageID: String) -> Bool {
        orphans.contains(pageID)
    }

    /// Return a copy with `pageID`'s outbound set replaced, re-deriving inbound,
    /// reachability, and orphans. Used for the in-memory patch on save, where
    /// the edited page's new links are known but the vertex set is unchanged.
    func replacingOutbound(of pageID: String, with targets: Set<String>, home: String?) -> LinkGraph {
        var next = outbound
        if targets.isEmpty {
            next[pageID] = nil
        } else {
            next[pageID] = targets
        }
        return LinkGraph.derive(outbound: next, allPageIDs: allPageIDs, home: home)
    }

    /// Build the full graph from a per-page outbound map. `outbound` values must
    /// already be filtered to existing pages (`∩ allPageIDs`).
    static func derive(outbound: [String: Set<String>], allPageIDs: Set<String>, home: String?) -> LinkGraph {
        var inbound: [String: Set<String>] = [:]
        for (source, targets) in outbound {
            for target in targets {
                inbound[target, default: []].insert(source)
            }
        }

        var reachable: Set<String> = []
        if let home, allPageIDs.contains(home) {
            reachable.insert(home)
            var stack = [home]
            while let current = stack.popLast() {
                for next in outbound[current] ?? [] where !reachable.contains(next) {
                    reachable.insert(next)
                    stack.append(next)
                }
            }
        }

        var orphans = allPageIDs.subtracting(reachable)
        if let home {
            orphans.remove(home)
        }

        return LinkGraph(
            outbound: outbound,
            inbound: inbound,
            reachable: reachable,
            allPageIDs: allPageIDs,
            orphans: orphans
        )
    }
}

/// Collect every internal-page target referenced by `blocks`: `.subpage`
/// pageIDs (already workspace-relative) plus inline `.link` URLs that `classify`
/// resolves to a workspace page. Pure and `nonisolated` so it runs off-main in
/// the builder and synchronously on MainActor in the save patch. Recurses into
/// `children` so links inside toggles / list nesting / heading bodies count.
nonisolated func outboundLinks(
    in blocks: [Block],
    pageURL: URL,
    classify: @Sendable (URL, URL) -> String?
) -> Set<String> {
    var targets: Set<String> = []
    func walk(_ blocks: [Block]) {
        for block in blocks {
            if case .subpage(_, let pageID) = block.kind {
                targets.insert(pageID)
            }
            for run in block.text.runs {
                if let url = run.link, let pageID = classify(url, pageURL) {
                    targets.insert(pageID)
                }
            }
            if !block.children.isEmpty {
                walk(block.children)
            }
        }
    }
    walk(blocks)
    return targets
}

/// Persisted per-page derivation: the page's mtime at cache time plus the title
/// and outbound link targets derived from that revision. Lets a launch skip the
/// content read for any page whose mtime is unchanged. Stored per-install in
/// `UserDefaults` (never travels with the folder — cross-device staleness).
struct LinkCacheEntry: Codable, Sendable {
    let mtime: Date
    let title: String
    let targets: [String]
}

/// One page's contribution to a graph build: its outbound link targets plus the
/// title derived from the same parse (so the build doubles as a bulk title warm
/// — the read+parse I/O is paid once, or skipped entirely on a cache hit).
private struct PageScan: Sendable {
    let rel: String
    let url: URL
    let targets: Set<String>
    let title: String
    let mtime: Date
}

extension Clamshell {
    /// Build the graph and bulk-warm titles, reusing the persistent cache for
    /// pages whose mtime is unchanged so only changed/new pages are content-read
    /// (the iCloud cold-read cost dominates). Snapshots the page set + home on
    /// MainActor up front; the per-page read+parse for the *stale* pages fans out
    /// through a bounded `TaskGroup`. Uses `readEnvelope` (the non-seeding read
    /// core) so a stray read never poisons the disk-content ring buffer that
    /// presenter-wakeup classification relies on. Rewrites the cache at the end.
    func buildLinkGraph() async -> LinkGraph {
        let pages = entries.map { (rel: $0.relativePath, url: $0.url, mtime: $0.modificationDate) }
        let allPageIDs = Set(pages.map(\.rel))
        let home = homeRelativePath
        let cached = cachedLinkEntries()
        let classify: @Sendable (URL, URL) -> String? = { [self] url, base in
            self.pagePath(for: url, relativeTo: base)
        }

        // Reuse cached title + links where the mtime matches; content-read the rest.
        var scans: [PageScan] = []
        var stale: [(rel: String, url: URL, mtime: Date)] = []
        for page in pages {
            if let hit = cached[page.rel], hit.mtime == page.mtime {
                scans.append(PageScan(rel: page.rel, url: page.url, targets: Set(hit.targets), title: hit.title, mtime: page.mtime))
            } else {
                stale.append(page)
            }
        }

        let limit = 8
        let readScans = await withTaskGroup(of: PageScan.self) { group -> [PageScan] in
            var next = 0
            func submit(_ page: (rel: String, url: URL, mtime: Date)) {
                group.addTask {
                    let blocks = (try? await self.readEnvelope(at: page.url))?.parsed.blocks ?? []
                    let title = Document.deriveTitle(
                        from: blocks,
                        fallback: page.url.deletingPathExtension().lastPathComponent
                    )
                    return PageScan(
                        rel: page.rel,
                        url: page.url,
                        targets: outboundLinks(in: blocks, pageURL: page.url, classify: classify),
                        title: title,
                        mtime: page.mtime
                    )
                }
            }
            while next < stale.count, next < limit {
                submit(stale[next]); next += 1
            }
            var results: [PageScan] = []
            while let result = await group.next() {
                results.append(result)
                if next < stale.count {
                    submit(stale[next]); next += 1
                }
            }
            return results
        }
        scans.append(contentsOf: readScans)

        applyWarmedTitles(scans.map { (url: $0.url, title: $0.title, mtime: $0.mtime) })
        storeLinkEntries(Dictionary(uniqueKeysWithValues: scans.map {
            ($0.rel, LinkCacheEntry(mtime: $0.mtime, title: $0.title, targets: Array($0.targets)))
        }))

        var outbound: [String: Set<String>] = [:]
        for scan in scans {
            let resolved = scan.targets.intersection(allPageIDs)
            if !resolved.isEmpty {
                outbound[scan.rel] = resolved
            }
        }
        return LinkGraph.derive(outbound: outbound, allPageIDs: allPageIDs, home: home)
    }
}
