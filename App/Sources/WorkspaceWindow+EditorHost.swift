import Foundation
import Editor

// MARK: - WorkspaceWindow: EditorHost
//
// Most methods forward to `workspace.clamshell` or to stateless helpers.
// The ones that genuinely need per-window state — navigation, the move-to
// picker, durability sequencing for absorb / append — read `openDocument`
// and the per-window navigation primitives directly.

extension WorkspaceWindow: EditorHost {
    // — Workspace-scoped forwarders —

    func suggestPages(_ query: String) -> [MentionItem] {
        workspace.clamshell?.pages(matching: query, excluding: openDocument?.url) ?? []
    }

    func lookupPage(_ pageID: String) -> PageLookup {
        workspace.clamshell?.lookupPage(pageID) ?? .missing
    }

    func resolveWorkspacePageID(from url: URL) -> String? {
        workspace.workspaceRelativeMarkdownPath(for: url, currentDocURL: openDocument?.url)
    }

    func createSubpage(title: String, requestedID: String?, initialContent: [Block]?) -> String? {
        workspace.createSubpage(title: title, requestedPath: requestedID, initialContent: initialContent)
    }

    func subpageContents(of pageID: String) -> [Block]? {
        guard let clamshell = workspace.clamshell else { return nil }
        let target = clamshell.url(for: pageID)
        do {
            return try clamshell.loadDocument(at: target).children
        } catch {
            Diag.subpage.error("subpageContents(of:): load(\(target.path, privacy: .public)) threw: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func documentDidChange(ops: [EditorOp], in document: Document) {
        workspace.clamshell?.documentDidChange(ops: ops, in: document)
    }

    func flush(_ document: Document) async {
        guard let clamshell = workspace.clamshell else { return }
        _ = await clamshell.flush(document)
    }

    func saveImages(_ items: [PastedImage]) -> [String] {
        guard let clamshell = workspace.clamshell else { return [] }
        var paths: [String] = []
        var failures: [String] = []
        paths.reserveCapacity(items.count)
        for item in items {
            do {
                paths.append(try clamshell.writeImage(item))
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        if !failures.isEmpty {
            let summary = failures.count == 1
                ? "Failed to save pasted image: \(failures[0])"
                : "Failed to save \(failures.count) pasted images: \(failures.joined(separator: "; "))"
            workspace.error = summary
        }
        return paths
    }

    // — Stateless app conventions —

    func serializeBlocksForPasteboard(_ blocks: [Block]) -> String {
        BlockSerializer.serialize(blocks, consecutiveNumbering: true)
    }

    func parseBlocksFromPasteboard(_ string: String) -> [Block]? {
        let blocks = BlockParser.parse(string)
        return blocks.isEmpty ? nil : blocks
    }

    var linkPreviewProvider: LinkPreviewProvider? {
        workspace.linkPreviewService.provider()
    }

    var imageURLResolver: ImageURLResolver? {
        // ImageURLResolver is `@Sendable`, so the closure can't directly call
        // a MainActor method on `workspace`. The renderer always invokes the
        // resolver on the main thread (image rows render in SwiftUI body), so
        // `assumeIsolated` is sound here.
        { [workspace] source in
            MainActor.assumeIsolated { workspace.clamshell?.resolveImage(source: source) }
        }
    }

    // — Per-window navigation & durability —

    @discardableResult
    func didActivateLink(_ target: LinkTarget) -> Bool {
        switch target {
        case .workspacePage(let pageID):
            openSubpage(relativePath: pageID)
            return true
        case .url(let url):
            // Workspace-internal links resolve via the host classifier
            // (same hook used for inline-link decoration at render time);
            // everything else falls through to the system handler.
            if let pageID = resolveWorkspacePageID(from: url) {
                openSubpage(relativePath: pageID)
                return true
            }
            return false
        }
    }

    func absorbSubpage(_ pageID: String) async -> Bool {
        // The editor calls this immediately after the inline-content mutation
        // and relies on the host to durably persist the parent doc before the
        // source file is trashed. Without the flush here, the autosave is
        // still debounced — and a crash in that window would leave the source
        // gone and the inlined content unpersisted.
        guard let clamshell = workspace.clamshell, let parent = openDocument else { return false }
        let target = clamshell.url(for: pageID)
        guard FileManager.default.fileExists(atPath: target.path) else { return false }
        guard await clamshell.flush(parent) else {
            Diag.subpage.error("absorbSubpage: flush failed; skipping trash of \(pageID, privacy: .public) to avoid data loss")
            return false
        }
        do {
            _ = try clamshell.moveToTrash(at: target)
            return true
        } catch {
            workspace.error = "Failed to move \(pageID) to trash: \(error.localizedDescription)"
            return false
        }
    }

    func appendToSubpage(_ pageID: String, _ blocks: [Block]) async -> Bool {
        guard !blocks.isEmpty, let clamshell = workspace.clamshell else { return false }
        let target = clamshell.url(for: pageID)
        let doc: Document
        do {
            doc = try await clamshell.append(blocks, toPage: pageID)
        } catch {
            workspace.error = "Failed to move blocks into \(pageID): \(error.localizedDescription)"
            return false
        }
        // If this window has the subpage open (multi-window scenario), splice
        // the appended content into the live instance rather than swapping —
        // keeps the editor's state references stable.
        if let live = openDocument, live.url == target, live !== doc {
            live.replaceChildren(doc.children)
            live.modificationDate = doc.modificationDate
        }
        return true
    }

    /// Editor's async move-destination call site: store a continuation,
    /// drive the sheet via `moveRequest`, resume from `resolveMoveRequest`.
    func moveDestination(for blockIDs: [BlockID], candidates: [InDocMoveTarget]) async -> MoveDestination? {
        await withCheckedContinuation { (continuation: CheckedContinuation<MoveDestination?, Never>) in
            moveRequest = MoveRequest(
                blockIDs: blockIDs,
                inDocCandidates: candidates,
                completion: { destination in continuation.resume(returning: destination) }
            )
        }
    }

    func navigateBack() {
        goBack()
    }
}
