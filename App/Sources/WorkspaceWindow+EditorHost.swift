import Foundation
import Editor

/// `WorkspaceWindow` is the `EditorHost` for the editor mounted in this
/// window. The save lifecycle (debounce + backstop + flush-and-close) lives
/// on the window itself; these methods route the rest of the editor's
/// integration surface — link dispatch, subpage lifecycle, mention queries,
/// pasteboard codec, image persistence — through `Workspace` and the
/// per-window navigation/file-presenter state.
extension WorkspaceWindow: EditorHost {
    func suggestPages(_ query: String) -> [MentionItem] {
        workspace.pages(matching: query, excluding: openDocument?.url)
    }

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

    func lookupPage(_ pageID: String) -> PageLookup {
        workspace.lookupPage(pageID)
    }

    func onCreateSubpage(_ title: String, _ requestedID: String?, _ initialContent: [Block]?) -> String? {
        workspace.createSubpage(title: title, requestedPath: requestedID, initialContent: initialContent)
    }

    func onLoadSubpage(_ pageID: String) -> [Block]? {
        workspace.loadSubpage(relativePath: pageID)
    }

    func onAbsorbSubpage(_ pageID: String) async -> Bool {
        // The editor calls this immediately after the inline-content mutation
        // and relies on the host to durably persist the parent doc before the
        // source file is trashed. Without the force-save here, the autosave is
        // still debounced — and a crash in that window would leave the source
        // gone and the inlined content unpersisted.
        guard let clamshell = workspace.clamshell else { return false }
        let target = clamshell.url(for: pageID)
        guard FileManager.default.fileExists(atPath: target.path) else { return false }
        guard await saveNow(force: true) else {
            Diag.subpage.error("onAbsorbSubpage: force-save failed; skipping trash of \(pageID, privacy: .public) to avoid data loss")
            return false
        }
        return workspace.moveSubpageToTrash(relativePath: pageID)
    }

    func onAppendToSubpage(_ pageID: String, _ blocks: [Block]) -> Bool {
        appendToSubpage(relativePath: pageID, blocks: blocks)
    }

    func onRequestMoveDestination(_ blockIDs: [BlockID], _ inDocCandidates: [InDocMoveTarget], _ pick: @escaping (MoveDestination?) -> Void) {
        requestMoveDestination(blockIDs: blockIDs, inDocCandidates: inDocCandidates, completion: pick)
    }

    func onNavigateBack() {
        goBack()
    }

    func markDocumentDirty() {
        markEdited()
    }

    func didMutate(pre: [Block], post: Document, name: String) {
        guard let clamshell = workspace.clamshell else { return }
        let rel = clamshell.relativePath(of: post.url)
        // Snapshot pre into recovery log to catch any blocks the device hasn't
        // seen — including transient blocks that appeared in an earlier
        // mutation, were never saved (debounce window), and are about to
        // change here. Cheap when nothing's new (RecoveryLog dedupes by
        // device-known hash set).
        clamshell.snapshotIntoRecoveryLog(at: post.url, blocks: pre)
        // Snapshot post too: blocks added by *this* mutation aren't in `pre`,
        // so without this path they'd only land in the log via the next
        // mutation's pre snapshot — and never at all if no further mutation
        // happens. The dedup cache makes a second walk effectively free.
        clamshell.snapshotIntoRecoveryLog(at: post.url, blocks: post.children)
        // Tombstone any block whose id was in pre but isn't in post.
        let preByID = BlockTreeDiff.idToAtomicHash(pre)
        for hash in BlockTreeDiff.removedHashes(preByID: preByID, post: post.children) {
            Task { [clamshell, rel, hash] in
                do {
                    try await clamshell.purgeHash(hash, in: rel)
                } catch {
                    Diag.merge.error("purgeHash failed page=\(rel, privacy: .public) hash=\(hash, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    func onBlur() async {
        await saveNow(force: true)
    }

    func serializeBlocksForPasteboard(_ blocks: [Block]) -> String {
        BlockSerializer.serialize(blocks, consecutiveNumbering: true)
    }

    func parseBlocksFromPasteboard(_ string: String) -> [Block]? {
        let blocks = BlockParser.parse(string)
        return blocks.isEmpty ? nil : blocks
    }

    func onSaveImages(_ items: [PastedImage]) -> [String] {
        workspace.saveImages(items)
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
            MainActor.assumeIsolated { workspace.imageURL(for: source) }
        }
    }
}
