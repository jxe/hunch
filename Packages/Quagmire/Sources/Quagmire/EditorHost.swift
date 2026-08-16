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
    /// Whether the host can persist a page created by Turn Into → Page or
    /// Cmd-K. When false, the editor hides those creation affordances.
    var supportsPageCreation: Bool { get }

    /// Whether the host can load, inline, durably save, and trash an existing
    /// subpage. When false, a subpage row cannot be turned into another type.
    var supportsSubpageInlining: Bool { get }

    /// Whether the host can present the asynchronous destination picker used
    /// by "Move to". When false, the editor hides that action.
    var supportsMoveDestinationPicker: Bool { get }

    /// `@`-mention candidates for the given query string. Editor renders up to
    /// the first 8 results; host owns filtering/ranking. `document` is the
    /// page the mention is being typed into — hosts typically exclude it
    /// from the candidate pool.
    func suggestPages(_ query: String, in document: Document) -> [MentionItem]

    /// Navigate to the workspace page identified by `pageID`. Called from
    /// subpage-row taps and from the OpenURLAction interceptor after the
    /// editor has classified an inline `[text](url)` link as internal via
    /// `resolvePageID(from:)`. External URLs never reach this method —
    /// they fall through to the system handler at the OpenURLAction site.
    func openPage(pageID: String)

    /// Set the page-level icon for the referenced page. A host may represent
    /// the icon as the leading emoji of the page title or project
    /// this onto their own storage model.
    func setPageIcon(_ emoji: String, forPageID pageID: String) async -> Bool

    /// Resolve an opaque page id to its existence + title. Used by inline-link
    /// and subpage rows for display, and by the editor to gate navigation
    /// into broken subpage rows.
    func lookupPage(_ pageID: String) -> PageLookup

    /// A `.subpage` row was deleted from `document`. The editor has already
    /// committed the row removal when this fires; hosts can inspect the
    /// post-delete document and decide whether the now-unlinked target page
    /// should be offered for trashing.
    func didDeleteSubpageLink(pageID: String, title: String, from document: Document)

    /// Classify a URL from an inline `[text](url)` link as an internal page
    /// reference. Returns the host's pageID for that URL, or nil for
    /// external URLs (and for any URL the host doesn't consider an internal
    /// page reference). The host owns the storage convention — file paths,
    /// UUIDs, database keys — so this is the single hook the editor uses
    /// at render time (inline-link decoration) and at Cmd-K-on-link time
    /// (subpage creation from an existing link) to decide whether a URL
    /// names an internal page. Relative URLs resolve against `document` —
    /// the page whose text contains the link.
    func resolvePageID(from url: URL, in document: Document) -> String?

    /// Build the inline-link URL that should be stored for `pageID` when
    /// mentioning it from `document`. The editor treats page ids as opaque;
    /// hosts own whether persisted links are relative paths, file URLs, UUID
    /// URLs, or something else.
    func linkURL(forPageID pageID: String, in document: Document) -> URL?

    /// Persist a new page. `initialContent` is the body the editor wants the
    /// new page to start with (descendants of the source block); the host
    /// serializes it and prepends a title heading. `requestedPath` is honored
    /// as-is when non-nil (used by the editor for deterministic-id cases like
    /// redo / preserved-id mention create); pass nil to let the host derive a
    /// slug from `title`. Returns the host-assigned page id, or nil if
    /// creation failed. Async because the host does file I/O (and possibly
    /// a workspace rescan); the editor awaits inside a Task spawned from
    /// the key-handler.
    func createPage(title: String, requestedPath: String?, initialContent: [Block]?) async -> String?

    /// Load the page at `pageID` and return its blocks. Nil → couldn't load,
    /// the calling action becomes a no-op. Async because the host reads off
    /// disk; the editor awaits inside a Task spawned from the key-handler.
    /// Paired with `inlineAndTrashPage(_:)` in the Convert flow — load
    /// the blocks, inline them into the parent, then ask the host to
    /// flush+trash the source.
    func loadPageBlocks(_ pageID: String) async -> [Block]?

    /// Companion to `loadPageBlocks(_:)`: after the editor has inlined the
    /// loaded blocks into `parent`, the host flushes `parent` (so the
    /// inline is durable on disk) and then moves the source page to
    /// Trash. Returns `true` if the host trashed the file. Async so the
    /// inline-then-trash sequence runs in real order — the parent's save
    /// must land before the source goes away, or a crash window could leave
    /// the file gone and the inlined copy unpersisted. `parent` is passed
    /// explicitly (not inferred from the host's "current page") because the
    /// user may have navigated away between the splice and this call.
    func inlineAndTrashPage(_ pageID: String, parent: Document) async -> Bool

    /// Append blocks to the end of the page at `pageID`. Returns `true` on
    /// success. Used by drop-on-subpage to move or copy dragged blocks into a
    /// child page.
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
    /// `changes` carries semantic pre→post block snapshots. The editor does
    /// not expose or derive host storage identity.
    ///
    /// When `changes` is empty, the change is a pure reorder/move. The host
    /// should still persist the new tree shape.
    ///
    /// Called *synchronously* on the mutation-commit thread — the editor's
    /// typing path can't await mid-`Document.transaction`. The host
    /// translates the changes into whatever storage primitive it owns; in
    /// practice the host spawns a Task and awaits durability internally,
    /// reaching that Task through `flush(_:)`. From the editor's side
    /// this is fire-and-forget on the typing thread; the host's
    /// `flush(_:)` is the only way to await durability.
    func persistCommit(changes: [DocumentChange], in document: Document)

    /// Await durability of any writes already in flight for `document`.
    /// With the commit-time atomic save model, every `persistCommit`
    /// schedules its own log + .md write — `flush` doesn't *trigger* a
    /// save, it blocks until any in-flight one(s) for this doc complete.
    /// Editor calls this on focus-loss (so the commit that just fired is
    /// durable before the row unmounts) and the host calls it directly
    /// from scene-phase / navigation-away / close paths. The doc is
    /// passed explicitly (symmetric with `persistCommit(changes:in:)`) so
    /// the host doesn't have to infer "current doc" from its own state.
    /// Non-throwing: the host owns error surfacing (banner, retry) —
    /// the editor has nothing useful to do with a flush failure.
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

    /// Host-supplied actions for selected text-bearing blocks. Returning an
    /// empty array hides the host-action surface. Each action carries its own
    /// applicability predicate, so no parallel capability flag is needed.
    func blockActions(in document: Document) -> [EditorBlockAction]
}

public extension EditorHost {
    var supportsPageCreation: Bool { false }
    var supportsSubpageInlining: Bool { false }
    var supportsMoveDestinationPicker: Bool { false }
    func suggestPages(_ query: String, in document: Document) -> [MentionItem] { [] }
    func openPage(pageID: String) {}
    func didDeleteSubpageLink(pageID: String, title: String, from document: Document) {}
    func setPageIcon(_ emoji: String, forPageID pageID: String) async -> Bool { false }
    func lookupPage(_ pageID: String) -> PageLookup { .missing }
    func resolvePageID(from url: URL, in document: Document) -> String? { nil }
    func linkURL(forPageID pageID: String, in document: Document) -> URL? { nil }
    func createPage(title: String, requestedPath: String?, initialContent: [Block]?) async -> String? { nil }
    func loadPageBlocks(_ pageID: String) async -> [Block]? { nil }
    func inlineAndTrashPage(_ pageID: String, parent: Document) async -> Bool { false }
    func appendToPage(_ pageID: String, _ blocks: [Block]) async -> Bool { false }
    func moveDestination(for blockIDs: [BlockID], candidates: [InDocMoveTarget]) async -> MoveDestination? { nil }
    func navigateBack() {}
    func serializeBlocksForPasteboard(_ blocks: [Block]) -> String {
        EditorPlainTextCodec.serialize(blocks)
    }
    func parseBlocksFromPasteboard(_ string: String) -> [Block]? {
        EditorPlainTextCodec.parse(string)
    }
    func saveImages(_ items: [PastedImage]) -> [String] { [] }
    func linkPreview(for url: URL) async -> LinkPreview? { nil }
    func imageURL(for source: String) -> URL? { nil }
    func blockActions(in document: Document) -> [EditorBlockAction] { [] }
}

private enum EditorPlainTextCodec {
    static func serialize(_ blocks: [Block]) -> String {
        var lines: [String] = []
        func append(_ block: Block) {
            switch block.kind {
            case .paragraph, .heading, .bullet, .numbered, .todo, .quote,
                 .toggle, .templateButton:
                lines.append(String(block.text.characters))
            case .code(let source, _):
                lines.append(source)
            case .divider:
                lines.append("---")
            case .subpage(let title, _):
                lines.append(title)
            case .image(let source, let alt):
                lines.append(alt.isEmpty ? source : alt)
            }
            block.children.forEach(append)
        }
        blocks.forEach(append)
        return lines.joined(separator: "\n")
    }

    static func parse(_ string: String) -> [Block]? {
        let normalized = string
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        while lines.count > 1, lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines.map { .paragraph(text: AttributedString($0)) }
    }
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
