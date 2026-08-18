import Foundation
import SwiftUI

/// What the editor is allowed to do with a particular reference target.
///
/// Per-target, not per-host. A host may hold a mix: pages you own and pages
/// shared read-only, local files and ones behind a network that is currently
/// down. The editor hides or disables an affordance *before* its first
/// mutation rather than letting the user try and fail.
///
/// Only what the editor actually gates is listed. Deleting the *row* is always
/// allowed — it is this document's content — and whether deleting it should
/// also trash the target is the host's policy, reported through
/// `didDeleteSubpageLink`, so there is no `delete` capability here.
public struct DocumentCapabilities: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Open the target. Gates row taps, Return, and right-arrow.
    public static let navigate = DocumentCapabilities(rawValue: 1 << 0)
    /// Accept blocks moved or copied onto the row.
    public static let receiveBlocks = DocumentCapabilities(rawValue: 1 << 1)
    /// Load the target's content into this document and retire the target.
    /// Gates Turn Into on a reference row.
    public static let inline = DocumentCapabilities(rawValue: 1 << 2)
    /// Set the target's icon from the row's icon picker.
    public static let setIcon = DocumentCapabilities(rawValue: 1 << 3)

    public static let all: DocumentCapabilities = [.navigate, .receiveBlocks, .inline, .setIcon]
}

/// Everything the editor needs to draw a reference row and decide what it may
/// offer, for a target that currently exists.
public struct PagePresentation: Equatable, Hashable, Sendable {
    /// The target's current title. Nil means "exists, title not resolved yet" —
    /// the row falls back to the label stored on the block.
    public var title: String?
    /// A leading emoji or short glyph for the row. Hosts with no icon concept
    /// leave this nil; the row derives one from the title instead.
    public var icon: String?
    public var capabilities: DocumentCapabilities

    public init(title: String? = nil, icon: String? = nil, capabilities: DocumentCapabilities = .all) {
        self.title = title
        self.icon = icon
        self.capabilities = capabilities
    }
}

/// What the host knows about an opaque reference *right now*.
///
/// Returned by `EditorHost.lookupPage(_:)`, which is called while building
/// rows and must therefore be a cheap synchronous read of host-owned state.
/// See the contract note on `lookupPage` — in particular why `.pending` exists
/// and why making this async would be the wrong fix.
public enum PageLookup: Equatable, Hashable, Sendable {
    /// Not resolved yet. A host reading from a cold cache or across a network
    /// returns this immediately and resolves in the background. The row renders
    /// with its stored label and offers nothing destructive until the answer
    /// arrives — an unresolved reference is not the same as a broken one, and
    /// guessing either way is worse than saying so.
    case pending
    /// Exists and is reachable.
    case present(PagePresentation)
    /// Resolved, and the target is not there — trashed, renamed, never created.
    /// Rows render distinctly and don't navigate.
    case missing
    /// Exists, but cannot be reached right now: offline, or permission denied.
    /// Distinct from `.missing` because the target is not gone, so the row must
    /// not read as broken and nothing should offer to clean it up.
    case unavailable
}

extension PageLookup {
    /// Convenience for the common case: present, fully capable, no icon.
    public static func present(title: String?) -> PageLookup {
        .present(PagePresentation(title: title))
    }

    /// The resolved title if known; nil in every state that doesn't have one.
    public var title: String? {
        if case .present(let presentation) = self { return presentation.title }
        return nil
    }

    public var icon: String? {
        if case .present(let presentation) = self { return presentation.icon }
        return nil
    }

    /// Nothing is permitted on a target that is missing, unreachable, or not
    /// yet resolved.
    public var capabilities: DocumentCapabilities {
        if case .present(let presentation) = self { return presentation.capabilities }
        return []
    }

    public func can(_ capability: DocumentCapabilities) -> Bool {
        capabilities.contains(capability)
    }

    /// True only when the host has resolved the target and it is gone. A
    /// `.pending` or `.unavailable` reference is not missing, and rows must not
    /// render it as broken.
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

    /// Whether the host implements inlining *at all*. This is a floor, not the
    /// per-row answer: a host that returns true must still say, per target,
    /// whether that particular one can be inlined, via
    /// `DocumentCapabilities.inline` on its `PageLookup`. Hosts with a uniform
    /// answer can return true here and `.all` capabilities everywhere.
    var supportsSubpageInlining: Bool { get }

    /// Whether the host can present the asynchronous destination picker used
    /// by "Move to". When false, the editor hides that action.
    var supportsMoveDestinationPicker: Bool { get }

    /// `@`-mention candidates for the given query string. Editor renders up to
    /// the first 8 results; host owns filtering/ranking. `document` is the
    /// page the mention is being typed into — hosts typically exclude it
    /// from the candidate pool.
    ///
    /// Async because a host may have to search across a network to answer, and
    /// the mention menu is not on the row-rendering hot path, so it can simply
    /// wait. The editor drives this from a cancellable task per keystroke and
    /// discards results whose query no longer matches what is on screen, so a
    /// slow answer can never overwrite a newer one.
    func suggestPages(_ query: String, in document: Document) async -> [MentionItem]

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

    /// Resolve an opaque page id to what is currently known about it. Used by
    /// inline-link and subpage rows for display, and to gate every affordance
    /// that acts on the target.
    ///
    /// **This must be a cheap synchronous read of state the host already
    /// holds.** It is called while building rows, and its result is stored on
    /// the row and compared in `==` so `.equatable()` can skip re-rendering
    /// rows whose references did not change. Making it `async` would remove
    /// that gating and re-render the document on every resolution.
    ///
    /// A host that cannot answer synchronously — a cold cache, a network —
    /// returns `.pending`, starts resolving in the background, and publishes
    /// the answer into observation-tracked state. SwiftUI re-renders, the next
    /// call returns `.present`, and the row updates without any document
    /// mutation. Two obligations come with that:
    ///
    /// - **Dedupe the background work.** This is called from a view body, so
    ///   an un-deduped fetch per call is an infinite loop, not a cache miss.
    /// - **Be observation-tracked.** If completing the resolution doesn't
    ///   invalidate the view, the row stays `.pending` forever.
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
    func suggestPages(_ query: String, in document: Document) async -> [MentionItem] { [] }
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
            case .unsupported(let payload, _):
                // Verbatim: this codec is the fallback for hosts that supply no
                // pasteboard format of their own, and the payload is the only
                // faithful thing we can put on the pasteboard for a block whose
                // meaning we don't know.
                lines.append(payload)
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
