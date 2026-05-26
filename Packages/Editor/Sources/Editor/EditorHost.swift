import Foundation
import SwiftUI

/// Existence + title resolution for an opaque host-defined page id.
/// Returned by `EditorHost.lookupPage(_:)`. The three states a page can be in:
///   - `.missing` — page not on disk (trashed, renamed, or never created).
///     Subpage rows render distinctly and don't navigate on tap.
///   - `.present(title: "…")` — page exists and the host has its title cached.
///   - `.present(title: nil)` — page exists but the host hasn't resolved the
///     title yet (cache miss). Render normally; call sites fall back to the
///     block-stored title.
public enum PageLookup: Equatable, Hashable, Sendable {
    case missing
    case present(title: String?)
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

    /// Navigate to the workspace page identified by `pageID`. Called from
    /// subpage-row taps and from the OpenURLAction interceptor after the
    /// editor has classified an inline `[text](url)` link as internal via
    /// `resolvePageID(from:)`. External URLs never reach this method —
    /// they fall through to the system handler at the OpenURLAction site.
    func openPage(pageID: String)

    /// Resolve an opaque page id to its existence + title. Used by inline-link
    /// and subpage rows for display, and by the editor to gate navigation
    /// into broken subpage rows.
    func lookupPage(_ pageID: String) -> PageLookup

    /// Classify a URL from an inline `[text](url)` link as an internal page
    /// reference. Returns the host's pageID for that URL, or nil for
    /// external URLs (and for any URL the host doesn't consider an internal
    /// page reference). The host owns the storage convention — file paths,
    /// UUIDs, database keys — so this is the single hook the editor uses
    /// at render time (inline-link decoration) and at Cmd-K-on-link time
    /// (subpage creation from an existing link) to decide whether a URL
    /// names an internal page. Resolves relative URLs against whichever
    /// page is currently mounted in this host.
    func resolvePageID(from url: URL) -> String?

    /// Persist a new page. `initialContent` is the body the editor wants the
    /// new page to start with (descendants of the source block); the host
    /// serializes it and prepends a title heading. `requestedPath` is honored
    /// as-is when non-nil (used by the editor for deterministic-id cases like
    /// redo / preserved-id mention create); pass nil to let the host derive a
    /// slug from `title`. Returns the host-assigned page id, or nil if
    /// creation failed.
    func createPage(title: String, requestedPath: String?, initialContent: [Block]?) -> String?

    /// Load the page at `pageID` and return its blocks. Nil → couldn't load,
    /// the calling action becomes a no-op. Async because the host reads off
    /// disk; the editor awaits inside a Task spawned from the key-handler.
    /// Paired with `inlineAndTrashPage(_:)` in the Convert flow — load
    /// the blocks, inline them into the parent, then ask the host to
    /// flush+trash the source.
    func loadPageBlocks(_ pageID: String) async -> [Block]?

    /// Companion to `loadPageBlocks(_:)`: after the editor has inlined the
    /// loaded blocks into the parent document, the host flushes the parent
    /// (so the inline is durable on disk) and then moves the source page to
    /// Trash. Returns `true` if the host trashed the file. Async so the
    /// inline-then-trash sequence runs in real order — the parent's save
    /// must land before the source goes away, or a crash window could leave
    /// the file gone and the inlined copy unpersisted.
    func inlineAndTrashPage(_ pageID: String) async -> Bool

    /// Append blocks to the end of the page at `pageID`. Returns `true` on
    /// success. Used by drop-on-subpage to move dragged blocks into a child page.
    /// Async so the host can sequence log-then-file durability before returning —
    /// the editor's local-block-removal only fires on success.
    func appendToPage(_ pageID: String, _ blocks: [Block]) async -> Bool

    /// Ask the host to present its picker for a "Move to" action. The editor
    /// passes the moving block ids plus a list of in-document destinations
    /// (already filtered to legal drop targets); the host merges those with the
    /// workspace page list, presents the picker, and resumes with the user's
    /// pick (`.page(...)` for cross-page, `.block(...)` for in-doc) or `nil` if
    /// the user cancelled. Async so the editor's "Move to" call site reads as
    /// a single linear sequence instead of a callback bounced through host
    /// state.
    func moveDestination(for blockIDs: [BlockID], candidates: [InDocMoveTarget]) async -> MoveDestination?

    /// User pressed Cmd-[ / swipe-back / etc. — host pops its navigation stack.
    func navigateBack()

    /// Document was just committed via `Document.transaction` — structural
    /// mutation via `EditorView.mutate(_:_:)`, typing commit via
    /// `BlockTextEditor.Coordinator.commitLiveText`, autotransform, paste,
    /// move-to, or undo/redo of any of the above. The editor fires this
    /// from a single emission point (`Document.didCommitTransaction`).
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
    /// Called *synchronously* on the mutation-commit thread — the editor's
    /// typing path can't await mid-`Document.transaction`. The host
    /// translates the ops into whatever storage primitive it owns; in
    /// practice the host spawns a Task and awaits durability internally,
    /// reaching that Task through `flush(_:)`. From the editor's side
    /// this is fire-and-forget on the typing thread; the host's
    /// `flush(_:)` is the only way to await durability.
    func persistCommit(ops: [EditorOp], in document: Document)

    /// Await durability of any writes already in flight for `document`.
    /// With the commit-time atomic save model, every `persistCommit`
    /// schedules its own log + .md write — `flush` doesn't *trigger* a
    /// save, it blocks until any in-flight one(s) for this doc complete.
    /// Editor calls this on focus-loss (so the commit that just fired is
    /// durable before the row unmounts) and the host calls it directly
    /// from scene-phase / navigation-away / close paths. The doc is
    /// passed explicitly (symmetric with `persistCommit(ops:in:)`) so
    /// the host doesn't have to infer "current doc" from its own state.
    func flush(_ document: Document) async throws

    /// Serialize blocks into a string the editor will write to the system
    /// pasteboard on copy/cut. Host chooses the format (markdown, plain text).
    func serializeBlocksForPasteboard(_ blocks: [Block]) -> String

    /// Parse a string from the system pasteboard back into blocks the editor
    /// will insert on paste. Returning nil cancels the paste.
    func parseBlocksFromPasteboard(_ string: String) -> [Block]?

    /// Persist pasted image bytes. Returns relative paths suitable for
    /// `Block.image.source` (one per input, in order). Empty / shorter
    /// returned array cancels the paste.
    func saveImages(_ items: [PastedImage]) -> [String]

    /// Fetch external-URL preview metadata (favicon + page title) for an
    /// inline link. Editor calls this for every external `http`/`https` link
    /// in a rendered (read-only) row. Returns nil when fetch failed, was
    /// cancelled, or the URL is in a known-failed state.
    func linkPreview(for url: URL) async -> LinkPreview?

    /// Resolve an image block's `source` (a markdown path like
    /// `Assets/foo.png`) to a file URL the renderer can load. Nil →
    /// renderer shows a missing-image placeholder.
    func imageURL(for source: String) -> URL?
}

private struct EditorHostKey: @preconcurrency EnvironmentKey {
    @MainActor static let defaultValue: EditorHost? = nil
}

extension EnvironmentValues {
    /// The active `EditorHost` for the current `EditorView`. Set once by
    /// `EditorView` at the top of its body so deep renderers (image rows,
    /// link-preview tasks) can reach the host without threading it through
    /// every init.
    public var editorHost: EditorHost? {
        get { self[EditorHostKey.self] }
        set { self[EditorHostKey.self] = newValue }
    }
}
