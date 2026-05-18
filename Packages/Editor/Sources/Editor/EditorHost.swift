import Foundation

/// Existence + title resolution for a `*.md` page id. Returned by
/// `EditorHost.lookupPage(_:)`. The three states a page can be in:
///   - `.missing` — file not on disk (trashed, renamed, or never created).
///     Subpage rows render distinctly and don't navigate on tap.
///   - `.present(title: "…")` — file exists and the host has its title cached.
///   - `.present(title: nil)` — file exists but the host hasn't resolved the
///     title yet (cache miss). Render normally; call sites fall back to the
///     block-stored title.
public enum PageLookup: Equatable, Hashable, Sendable {
    case missing
    case present(title: String?)
}

/// Destination of an inline-link / subpage-row click in the editor. Subpage
/// rows arrive as `.workspacePage(pageID)` (the editor already knows the
/// id). Inline `[text](url)` clicks arrive as `.url(URL)` — the host
/// classifies them (workspace-relative `.md`, external `http`/`https`, mail
/// link, etc.) and routes accordingly.
public enum LinkTarget: Equatable, Hashable, Sendable {
    case workspacePage(pageID: String)
    case url(URL)
}

extension PageLookup {
    /// The resolved page title if known; nil for `.missing` and for
    /// `.present` whose title hasn't been cached yet.
    public var title: String? {
        if case .present(let t) = self { return t }
        return nil
    }
    public var isMissing: Bool {
        if case .missing = self { return true }
        return false
    }
}

/// Host integration for `EditorView`. The host owns the document layer (file
/// I/O, the workspace page list, persistence) and exposes the operations the
/// editor needs as method calls. Supplied by reference so its identity is
/// stable across the host's view re-renders — that lets `EditorView` and its
/// row wrapper rely on `EquatableView` gating without the closure-identity
/// churn that 17 individual @escaping callbacks previously caused.
@MainActor
public protocol EditorHost: AnyObject {
    /// `@`-mention candidates for the given query string. Editor renders up to
    /// the first 8 results; host owns filtering/ranking.
    func suggestPages(_ query: String) -> [MentionItem]

    /// User clicked an internal link or subpage row in the editor — host
    /// dispatches to its navigation stack (workspace page) or system handler
    /// (external URL). Returns true when the host fully handled the link;
    /// false lets the editor fall through to the system's default URL
    /// handler (used by SwiftUI's `OpenURLAction.systemAction`).
    @discardableResult
    func openLink(_ target: LinkTarget) -> Bool

    /// Resolve a `*.md` page id to its existence + title. Used by inline-link
    /// and subpage rows for display, and by the editor to gate navigation
    /// into broken subpage rows.
    func lookupPage(_ pageID: String) -> PageLookup

    /// Persist a new subpage. `initialContent` is the body the editor wants the
    /// new page to start with (descendants of the source block); the host
    /// serializes it and prepends a title heading. Returns the host-assigned
    /// page id, or nil if creation failed.
    func onCreateSubpage(_ title: String, _ requestedID: String?, _ initialContent: [Block]?) -> String?

    /// Read the page at `pageID` and return its blocks. Nil → couldn't load,
    /// the calling action becomes a no-op.
    func onLoadSubpage(_ pageID: String) -> [Block]?

    /// Absorb a subpage's content into its parent (Turn Into a non-page block):
    /// the editor inlines the loaded blocks at the subpage row's position and
    /// the host trashes the original file. Returns `true` if the host trashed
    /// the file. Async so the inline-then-trash sequence runs in real order
    /// (the host needs to force-save the parent before deleting the source).
    func onAbsorbSubpage(_ pageID: String) async -> Bool

    /// Append blocks to the end of the page at `pageID`. Returns `true` on
    /// success. Used by drop-on-subpage to move dragged blocks into a child page.
    /// Async so the host can sequence log-then-file durability before returning —
    /// the editor's local-block-removal only fires on success.
    func onAppendToSubpage(_ pageID: String, _ blocks: [Block]) async -> Bool

    /// Ask the host to present its picker for a "Move to" action. The editor
    /// passes the moving block ids plus a list of in-document destinations
    /// (already filtered to legal drop targets); the host merges those with the
    /// workspace page list, presents the picker, and resumes with the user's
    /// pick (`.page(...)` for cross-page, `.block(...)` for in-doc) or `nil` if
    /// the user cancelled. Async so the editor's "Move to" call site reads as
    /// a single linear sequence instead of a callback bounced through host
    /// state.
    func onRequestMoveDestination(_ blockIDs: [BlockID], _ inDocCandidates: [InDocMoveTarget]) async -> MoveDestination?

    /// User pressed Cmd-[ / swipe-back / etc. — host pops its navigation stack.
    func onNavigateBack()

    /// Document was just committed at an edit-session boundary — structural
    /// mutation via `EditorView.mutate(_:_:)`, typing commit
    /// (`commitLiveText` → `DocumentUndoController.afterCommit`), autotransform,
    /// undo, paste, move-to, etc.
    ///
    /// When the change came through `mutate`, `ops` carries the pre→post diff
    /// from `BlockTreeDiff.derive(pre:post:)`: `.insert(hash, parent, block)`
    /// for new (or content-changed) blocks and `.remove(hash)` for hashes
    /// that are no longer the live hash of any post id. When the change came
    /// from a typing commit, `ops` is `[.remove(preHash), .insert(nowHash, …)]`
    /// for the single active block.
    ///
    /// When `ops` is empty, the change is a pure reorder/move (same id, same
    /// hash) — nothing to log, but the host should still persist the new tree
    /// shape. The host writes log records (when non-empty) and the rendered
    /// document as one ordered unit per call.
    ///
    /// Called *synchronously* on the mutation-commit thread so the host's
    /// dirty flag is readable in immediate flush-on-close paths — a fast
    /// "type-then-navigate" sequence relies on this to not drop the last
    /// keystroke. Persistence (log append, disk write) is fire-and-forget
    /// from the host's side.
    func documentDidChange(ops: [EditorOp], on post: Document)

    /// Await durability of any writes already in flight for `document`. With
    /// the commit-time atomic save model, every `documentDidChange` schedules
    /// its own log + .md write — `flush` doesn't *trigger* a save, it blocks
    /// until pending ones complete. Editor calls this on focus-loss (so the
    /// commit that just fired is durable before the row unmounts) and the
    /// host calls it directly from scene-phase / navigation-away / close
    /// paths. The doc is passed explicitly (symmetric with
    /// `documentDidChange(ops:on:)`) so the host doesn't have to infer
    /// "current doc" from its own state.
    func flush(_ document: Document) async

    /// Serialize blocks into a string the editor will write to the system
    /// pasteboard on copy/cut. Host chooses the format (markdown, plain text).
    func serializeBlocksForPasteboard(_ blocks: [Block]) -> String

    /// Parse a string from the system pasteboard back into blocks the editor
    /// will insert on paste. Returning nil cancels the paste.
    func parseBlocksFromPasteboard(_ string: String) -> [Block]?

    /// Persist pasted image bytes. Returns relative paths suitable for
    /// `Block.image.source` (one per input, in order). Empty / shorter
    /// returned array cancels the paste.
    func onSaveImages(_ items: [PastedImage]) -> [String]

    /// Async fetcher for external-URL preview metadata (favicon + page title).
    /// Editor calls this for every external `http`/`https` link in a rendered
    /// (read-only) row. Nil → no fetching, links render undecorated.
    var linkPreviewProvider: LinkPreviewProvider? { get }

    /// Resolve an image block's `source` to a file URL the renderer can load.
    /// Nil → renderer shows a missing-image placeholder.
    var imageURLResolver: ImageURLResolver? { get }
}
