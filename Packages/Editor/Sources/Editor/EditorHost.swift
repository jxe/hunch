import Foundation

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

    /// User tapped an inline subpage row — host pushes the page onto its nav stack.
    func onSubpageTap(_ pageID: String)

    /// Resolve a `*.md` page id to its current title. Used by inline-link and
    /// subpage rows; nil means "page missing or not yet loaded".
    func pageTitle(_ pageID: String) -> String?

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
    /// the host trashes the original file. Returns `true` if the host trashed it.
    func onAbsorbSubpage(_ pageID: String) -> Bool

    /// Append blocks to the end of the page at `pageID`. Returns `true` on
    /// success. Used by drop-on-subpage to move dragged blocks into a child page.
    func onAppendToSubpage(_ pageID: String, _ blocks: [Block]) -> Bool

    /// Ask the host to present its picker for a "Move to" action. The editor
    /// passes the moving block ids plus a list of in-document destinations
    /// (already filtered to legal drop targets); the host merges those with the
    /// workspace page list, presents the picker, and calls back via `pick` with
    /// a `MoveDestination` — `.page(...)` for cross-page, `.block(...)` for
    /// in-doc — or `nil` if the user cancelled.
    func onRequestMoveDestination(_ blockIDs: [BlockID], _ inDocCandidates: [InDocMoveTarget], _ pick: @escaping (MoveDestination?) -> Void)

    /// User pressed Cmd-[ / swipe-back / etc. — host pops its navigation stack.
    func onNavigateBack()

    /// Document was mutated. Host kicks off its debounced save.
    func onEdited()

    /// Editor lost focus (focus left an active text editor). Host force-saves so
    /// user input doesn't sit in memory until app suspension.
    func onBlur()

    /// Capture a block-level deletion before mutation so it can be restored
    /// from the recently-deleted view. Editor supplies indices/blocks/action
    /// name; host knows the document's relative path.
    func onRecordBlockDeletion(_ indices: [Int], _ blocks: [Block], _ actionName: String)

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
