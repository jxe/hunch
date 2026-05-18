import Foundation
import Editor

// MARK: - HunchEditorHost (protocol + forwarding defaults)

/// An `EditorHost` with access to `Workspace` and the currently-open
/// `Document`. The default implementations below cover every method that
/// doesn't need per-window state — page lookups, subpage create / load,
/// pasteboard serialization, image storage, link previews — by forwarding
/// to the workspace's `Clamshell` or to stateless helpers.
///
/// `WorkspaceWindow` conforms below and only has to implement the methods
/// that genuinely depend on the window: navigation, the move-to picker
/// sheet, and durability sequencing for absorb / append (which need to
/// reach the parent doc mounted in *this* window).
@MainActor
protocol HunchEditorHost: EditorHost {
    var workspace: Workspace { get }
    var openDocument: Document? { get }
}

extension HunchEditorHost {
    // — Workspace-scoped forwarders —

    func suggestPages(_ query: String) -> [MentionItem] {
        workspace.clamshell?.pages(matching: query, excluding: openDocument?.url) ?? []
    }

    func lookupPage(_ pageID: String) -> PageLookup {
        workspace.clamshell?.lookupPage(pageID) ?? .missing
    }

    func onCreateSubpage(_ title: String, _ requestedID: String?, _ initialContent: [Block]?) -> String? {
        workspace.createSubpage(title: title, requestedPath: requestedID, initialContent: initialContent)
            ?? requestedID
    }

    func onLoadSubpage(_ pageID: String) -> [Block]? {
        guard let clamshell = workspace.clamshell else { return nil }
        let target = clamshell.url(for: pageID)
        do {
            return try clamshell.loadDocument(at: target).children
        } catch {
            Diag.subpage.error("onLoadSubpage: load(\(target.path, privacy: .public)) threw: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func documentDidChange(ops: [EditorOp], on post: Document) {
        workspace.clamshell?.documentDidChange(ops: ops, in: post)
    }

    func flush(_ document: Document) async {
        guard let clamshell = workspace.clamshell else { return }
        _ = await clamshell.flush(document)
    }

    func onSaveImages(_ items: [PastedImage]) -> [String] {
        guard let clamshell = workspace.clamshell else { return [] }
        var paths: [String] = []
        paths.reserveCapacity(items.count)
        for item in items {
            do {
                paths.append(try clamshell.writeImage(item))
            } catch {
                workspace.error = "Failed to save pasted image: \(error.localizedDescription)"
            }
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
}

// MARK: - WorkspaceWindow: per-window methods only

extension WorkspaceWindow: HunchEditorHost {
    @discardableResult
    func openLink(_ target: LinkTarget) -> Bool {
        switch target {
        case .workspacePage(let pageID):
            openSubpage(relativePath: pageID)
            return true
        case .url(let url):
            // Workspace-relative `*.md` links resolve against the open doc's
            // URL (or home if we're at the root) and navigate internally.
            // Everything else falls through to the system handler.
            let currentDocURL = path.last ?? workspace.homeURL
            if let rel = workspace.workspaceRelativeMarkdownPath(for: url, currentDocURL: currentDocURL) {
                openSubpage(relativePath: rel)
                return true
            }
            return false
        }
    }

    func onAbsorbSubpage(_ pageID: String) async -> Bool {
        // The editor calls this immediately after the inline-content mutation
        // and relies on the host to durably persist the parent doc before the
        // source file is trashed. Without the flush here, the autosave is
        // still debounced — and a crash in that window would leave the source
        // gone and the inlined content unpersisted.
        guard let clamshell = workspace.clamshell, let parent = openDocument else { return false }
        let target = clamshell.url(for: pageID)
        guard FileManager.default.fileExists(atPath: target.path) else { return false }
        guard await clamshell.flush(parent) else {
            Diag.subpage.error("onAbsorbSubpage: flush failed; skipping trash of \(pageID, privacy: .public) to avoid data loss")
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

    func onAppendToSubpage(_ pageID: String, _ blocks: [Block]) async -> Bool {
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
    func onRequestMoveDestination(_ blockIDs: [BlockID], _ inDocCandidates: [InDocMoveTarget]) async -> MoveDestination? {
        await withCheckedContinuation { (continuation: CheckedContinuation<MoveDestination?, Never>) in
            moveRequest = MoveRequest(
                blockIDs: blockIDs,
                inDocCandidates: inDocCandidates,
                completion: { destination in continuation.resume(returning: destination) }
            )
        }
    }

    func onNavigateBack() {
        goBack()
    }
}
