import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Where to place the cursor on the editor's first focus grab.
/// `.point` is what click-to-edit captures; the editor maps the point to a character
/// index via NSTextView's `characterIndexForInsertion(at:)`. `.offset` is what split /
/// programmatic-focus paths use when they already know the desired character index.
enum InitialCursorTarget: Sendable, Equatable {
    case point(CGPoint)
    case offset(Int)
}

#if os(macOS)
/// Single-slot weak handle to the currently-mounted `ContainedTextView`. Only one
/// editor mounts at a time (EditorView gates `BlockTextEditor` on `isEditing`), so
/// EditorView never needs to look up by BlockID — it just asks "is the active editor
/// for this block?" and either grabs first responder synchronously or falls through
/// to the `wantsFocus` async path on next mount.
///
/// Each EditorView owns its own holder via `@State` and publishes it through
/// `.environment(\.macActiveTextView, ...)`. ContainedTextView assigns/clears its
/// `view` slot from `viewDidMoveToWindow` / `viewWillMove(toWindow: nil)`.
@MainActor
final class MacActiveTextView {
    weak var view: ContainedTextView?

    init() {}

    /// Synchronously grab AppKit first responder for `id` if the active NSTextView
    /// is already mounted for that block. Returns true on success; false if the row
    /// hasn't mounted yet — caller relies on the NSTextView's `wantsFocus` async
    /// self-grab in `viewDidMoveToWindow` to handle the new-mount case.
    @discardableResult
    func makeFirstResponder(for id: BlockID) -> Bool {
        guard let view, view.blockID == id, let window = view.window else { return false }
        if window.firstResponder !== view {
            window.makeFirstResponder(view)
        }
        view.applyPendingCursorPositionOrSeekToEnd()
        return true
    }
}

private struct MacActiveTextViewKey: EnvironmentKey {
    static let defaultValue: MacActiveTextView? = nil
}

extension EnvironmentValues {
    /// Editor-scoped active-NSTextView handle. Set by EditorView; nil when reading
    /// outside an editor.
    var macActiveTextView: MacActiveTextView? {
        get { self[MacActiveTextViewKey.self] }
        set { self[MacActiveTextViewKey.self] = newValue }
    }
}
#endif

/// Block-level keyboard events the page-level handler reacts to.
enum BlockKey: Sendable, Equatable {
    /// Return pressed. Carries the full selection at the time of press so
    /// `splitBlock` can delete any selected range as part of the split (Return
    /// over a selection behaves like inserting `\n`: the selection is replaced).
    /// `selectionStart == selectionEnd` is the no-selection / cursor case.
    case enter(selectionStart: Int, selectionEnd: Int)
    case backspaceAtStart
    case tab
    case shiftTab
    case escape
    case cmdK(preferredTitle: String?)
    case navigateBack
    /// Up arrow pressed while the cursor is on the editor's first line. EditorView
    /// treats this as Esc + up: exit edit mode and select the previous block.
    case exitEditUp
    /// Down arrow pressed while the cursor is on the editor's last line.
    case exitEditDown
    /// Left arrow pressed at the very start of the row with no selection. EditorView
    /// hops into the previous editable block and lands the cursor at its end.
    case exitEditLeft
    /// Right arrow pressed at the very end of the row with no selection. EditorView
    /// hops into the next editable block and lands the cursor at offset 0.
    case exitEditRight
    // The mention popover (@-menu) is open over the active editor; the editor
    // forwards these unconditionally so EditorView can drive menu navigation
    // without taking focus away from the text.
    case mentionUp
    case mentionDown
    case mentionCommit
    case mentionDismiss
    /// Cmd-V / paste action received by the editor with the raw pasteboard
    /// string. EditorView decides whether the parsed result splits into
    /// multiple blocks (handled here, splice below the row) or is a single
    /// paragraph (return `.ignored` so the platform text view does its native
    /// paste, preserving cursor + undo coalescing).
    case paste(String)
    /// Pasteboard contained one or more images (or image file URLs). EditorView
    /// hands the bytes to the host via `EditorHost.saveImages(_:)`, builds image blocks, and
    /// splices them below the row — no fall-through to native paste.
    case imagesPasted([PastedImage])
}


/// A single-block text editor.
///
/// On macOS we wrap an NSTextView directly via `NSViewRepresentable`. SwiftUI's stock
/// `TextEditor` ships with `textContainerInset = (5, 0)` and `lineFragmentPadding = 5`
/// baked in — those nudge the text right by 5pt and down by ~5pt relative to a sibling
/// read-only `Text`, which breaks `.firstTextBaseline` alignment with list markers and
/// throws the typography off. Going to NSTextView lets us zero those out.
///
/// On iOS we wrap a `UITextView` directly via `UIViewRepresentable` for the same reasons
/// (insets, focus, key-event control). The iOS path also needs a real subclass so we can
/// override `deleteBackward()` — SwiftUI's `TextEditor` swallows soft-keyboard backspace
/// events on empty text, which broke "delete blank block to remove it".
struct BlockTextEditor: View {
    @Binding var text: AttributedString
#if os(iOS)
    /// Side-channel held by reference so the SwiftUI keyboard toolbar can drive
    /// mark toggles on the underlying UITextView's textStorage. Persists across
    /// re-renders; `makeUIView` / `updateUIView` keep `textView` pointed at the
    /// live view.
    @State private var iosBridge = IOSEditorBridge()
#endif
    let font: Font
    let fontSize: CGFloat
    let bold: Bool
    let lineSpacing: CGFloat
    @FocusState.Binding var focused: BlockID?
    /// True for the actively-edited block. False on iOS only, for one tick, when
    /// the row stays mounted during an inter-block focus transfer so the new
    /// row's UITextView can grab first responder while this one is still in the
    /// window (keeps the soft keyboard up across splits/merges). When false, the
    /// underlying UITextView's `wantsFocus` is `false` and it doesn't fight the
    /// new editor for first responder. See `iosTransitioningEditorID` in EditorView.
    let isActive: Bool
    let blockID: BlockID
    let onKey: (BlockKey) -> KeyPress.Result
    let onAutotransform: (BlockTransform, AttributedString) -> Void
    let onOpenLink: (URL) -> Bool
    /// Fires whenever the cursor sits after an in-progress `@query` (or transitions out
    /// of one — `nil` then). EditorView holds the popover state and decides whether to
    /// show / dismiss the menu based on this stream.
    let onMentionTriggerChange: (MentionTrigger?) -> Void
    /// When true, the editor unconditionally forwards ↑/↓/Return/Esc to `onKey` as
    /// `mentionUp/Down/Commit/Dismiss` so EditorView can drive the popover. When false,
    /// arrow keys behave normally (intra-block nav or exit-edit on boundary).
    let mentionActive: Bool
    /// Called exactly once during the underlying NSView/UIView's `make…` to fetch
    /// the cursor target for this mount. The host atomically reads-and-clears its
    /// pending-cursor channel inside the closure, so a second mount of the same
    /// block (e.g. nav-mode Enter back into it) sees nil and seeks to end.
    let consumeInitialCursor: () -> InitialCursorTarget?
    /// Document-level undo controller. NSTextView keeps its own per-instance typing-undo
    /// (used while the editor is mounted, fine-grained character-by-character). On focus
    /// loss, the Coordinator registers ONE coarse "Type" entry on this controller's shared
    /// manager — that's how typing survives editor unmount without keeping dangling
    /// pointers to a deallocated NSTextView.
    @Environment(\.documentUndoController) private var documentUndoController
    #if os(macOS)
    /// Single-slot handle to the active NSTextView. ContainedTextView assigns itself
    /// when mounted and clears on unmount, so EditorView.transferFocus can grab
    /// first-responder synchronously instead of via the async self-grab dance.
    @Environment(\.macActiveTextView) private var macActiveTextView
    #endif

    init(
        text: Binding<AttributedString>,
        font: Font,
        fontSize: CGFloat = 16,
        bold: Bool = false,
        lineSpacing: CGFloat,
        focused: FocusState<BlockID?>.Binding,
        isActive: Bool = true,
        blockID: BlockID,
        onKey: @escaping (BlockKey) -> KeyPress.Result,
        onAutotransform: @escaping (BlockTransform, AttributedString) -> Void = { _, _ in },
        onOpenLink: @escaping (URL) -> Bool = { _ in false },
        onMentionTriggerChange: @escaping (MentionTrigger?) -> Void = { _ in },
        mentionActive: Bool = false,
        consumeInitialCursor: @escaping () -> InitialCursorTarget? = { nil }
    ) {
        self._text = text
        self.font = font
        self.fontSize = fontSize
        self.bold = bold
        self.lineSpacing = lineSpacing
        self._focused = focused
        self.isActive = isActive
        self.blockID = blockID
        self.onKey = onKey
        self.onAutotransform = onAutotransform
        self.onOpenLink = onOpenLink
        self.onMentionTriggerChange = onMentionTriggerChange
        self.mentionActive = mentionActive
        self.consumeInitialCursor = consumeInitialCursor
    }

    var body: some View {
        #if os(macOS)
        // The editor only mounts when its row is the active editing block (EditorView gates
        // this via `isEditing`). So unconditionally request focus on mount — `@FocusState`
        // writes from EditorView's `enterEditMode` are deferred and don't propagate before
        // `makeNSView`/`viewDidMoveToWindow` fire, which previously left `wantsFocus=false`
        // and the focus grab silently no-op'd.
        MacBlockTextEditor(
            text: $text,
            fontSize: fontSize,
            bold: bold,
            lineSpacing: lineSpacing,
            isFocused: true,
            onFocusChange: { newFocused in
                if newFocused {
                    focused = blockID
                } else if focused == blockID {
                    focused = nil
                }
            },
            onKey: onKey,
            onAutotransform: onAutotransform,
            onOpenLink: onOpenLink,
            onMentionTriggerChange: onMentionTriggerChange,
            mentionActive: mentionActive,
            consumeInitialCursor: consumeInitialCursor,
            blockID: blockID,
            documentUndoController: documentUndoController,
            activeView: macActiveTextView
        )
        .alignmentGuide(.firstTextBaseline) { _ in
            // NSTextView with textContainerInset=.zero, lineFragmentPadding=0 puts its first
            // baseline at `font.ascender` from the top of the view. Without this guide,
            // SwiftUI uses the view's top as the baseline, which pushes the editor visually
            // below a sibling marker in an HStack(alignment: .firstTextBaseline).
            let nsFont = MacBlockTextEditor.resolveNSFont(size: fontSize, bold: bold)
            return nsFont.ascender
        }
        .onAppear {
            focused = blockID
        }
        #else
        // Mirrors the macOS path: when this row is the active editor we request
        // focus unconditionally so the initial-mount grab in `didMoveToWindow`
        // works (the `@FocusState` write from `enterEditMode` doesn't reliably
        // propagate in time). During the one-tick inter-block transfer overlap,
        // `isActive` is false on the just-vacated row so its UITextView doesn't
        // fight the freshly-mounted one for first responder.
        IOSBlockTextEditorView(
            text: $text,
            fontSize: fontSize,
            bold: bold,
            lineSpacing: lineSpacing,
            isFocused: isActive,
            onFocusChange: { newFocused in
                if newFocused {
                    focused = blockID
                } else if focused == blockID {
                    focused = nil
                }
            },
            blockID: blockID,
            bridge: iosBridge,
            onKey: onKey,
            onAutotransform: onAutotransform,
            onOpenLink: onOpenLink,
            onMentionTriggerChange: onMentionTriggerChange,
            mentionActive: mentionActive,
            consumeInitialCursor: consumeInitialCursor,
            documentUndoController: documentUndoController
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .alignmentGuide(.firstTextBaseline) { _ in
            // UITextView with textContainerInset=.zero and lineFragmentPadding=0
            // puts its first baseline at `font.ascender` from the top of the view.
            // SwiftUI's `Text` puts its first baseline at `lineHeight - |descender|`
            // — i.e. `ascender + leading`. Using `ascender` here (what macOS does
            // with NSFont) leaves a sub-pixel gap on iOS for fonts with non-zero
            // leading (Inter ≈ 0.7pt at 16pt), which shows up as the list marker
            // hopping down ~0.5pt on focus. Match `Text`'s formula instead.
            let uiFont = IOSBlockTextEditorView.resolveUIFont(size: fontSize, bold: bold)
            return uiFont.lineHeight - abs(uiFont.descender)
        }
        .onAppear {
            focused = blockID
        }
        // The keyboard accessory bar is set as the UITextView's `inputAccessoryView`
        // inside `IOSBlockTextEditorView` — SwiftUI's `.toolbar(placement: .keyboard)`
        // doesn't reach a UIKit-hosted text view.
        #endif
    }
}

#if os(macOS)

/// NSTextView-based single-line(ish) editor. Sized to its content height; firstTextBaseline
/// alignment matches a sibling `Text` because we strip both `textContainerInset` and the
/// per-fragment padding.
struct MacBlockTextEditor: NSViewRepresentable {
    @Binding var text: AttributedString
    let fontSize: CGFloat
    let bold: Bool
    let lineSpacing: CGFloat
    let isFocused: Bool
    let onFocusChange: (Bool) -> Void
    let onKey: (BlockKey) -> KeyPress.Result
    let onAutotransform: (BlockTransform, AttributedString) -> Void
    let onOpenLink: (URL) -> Bool
    let onMentionTriggerChange: (MentionTrigger?) -> Void
    let mentionActive: Bool
    let consumeInitialCursor: () -> InitialCursorTarget?
    let blockID: BlockID
    let documentUndoController: DocumentUndoController?
    let activeView: MacActiveTextView?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> ContainedTextView {
        let view = ContainedTextView()
        view.coordinator = context.coordinator
        view.delegate = context.coordinator
        view.activeView = activeView
        view.blockID = blockID
        view.isRichText = true
        // NSTextView's native typing-undo registers actions that hold strong refs to the
        // NSTextView itself; SwiftUI's view lifecycle (one-editor-at-a-time, unmount on
        // Esc/cursor-out) frees those entries' inner state and the next Cmd-Z crashes
        // with `_undoRedoTextOperation:` on a freed pointer. We disable NSTextView's
        // local manager entirely and route everything through the document-level
        // `DocumentUndoController` (registered on first text change of each session).
        view.allowsUndo = false
        view.drawsBackground = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        loadAttributedString(into: view)
        applyTypingAttributes(to: view)
        context.coordinator.lastFontSize = fontSize
        context.coordinator.lastBold = bold
        context.coordinator.lastLineSpacing = lineSpacing
        context.coordinator.lastKnownBindingPlain = String(text.characters)
        view.wantsFocus = isFocused
        view.pendingInitialCursor = consumeInitialCursor()
        // Wire the synchronous-commit closure eagerly at mount, not in
        // `textDidBeginEditing`. NSTextView only fires the begin-editing delegate
        // when characters are inserted — programmatic attribute changes
        // (Cmd-B / Cmd-I / Cmd-E via `didChangeText()`) do NOT trigger it. Without
        // eager wiring, a Cmd-B → Esc flow leaves `flushActiveText` nil and the
        // formatting never reaches the model. `[weak coordinator, weak view]` so
        // unmounting the row cleans up.
        documentUndoController?.flushActiveText = { [weak coordinator = context.coordinator, weak view] in
            guard let coordinator, let view else { return }
            coordinator.commitLiveText(view)
        }
        return view
    }

    func updateNSView(_ view: ContainedTextView, context: Context) {
        context.coordinator.parent = self
        // Reload from the binding only when (a) the binding actually changed since we
        // last touched it (external mutation: undo, autotransform replacement, etc.) or
        // (b) base font props changed (paragraph → heading). The "binding lagging
        // because the user is typing" case — `tv.string` ahead of `text` — must NOT
        // trigger a reload; commit-on-blur intentionally keeps the binding stale during
        // the session, and reloading here would clobber the live text + cursor.
        let bindingPlain = String(text.characters)
        let bindingChangedExternally = context.coordinator.lastKnownBindingPlain != bindingPlain
        let baseFontDrift = context.coordinator.lastFontSize != fontSize
            || context.coordinator.lastBold != bold
            || context.coordinator.lastLineSpacing != lineSpacing
        if bindingChangedExternally || baseFontDrift {
            loadAttributedString(into: view)
            context.coordinator.lastFontSize = fontSize
            context.coordinator.lastBold = bold
            context.coordinator.lastLineSpacing = lineSpacing
            context.coordinator.lastKnownBindingPlain = bindingPlain
        }
        applyTypingAttributes(to: view)
        view.wantsFocus = isFocused
        if isFocused {
            if let window = view.window, window.firstResponder !== view {
                // Recheck inside the dispatch: the view can detach from this window
                // (or move to another) between scheduling and firing — `Esc`, switching
                // blocks, or a doc switch can unmount the row before the async runs.
                // Calling makeFirstResponder on a view that's no longer in the captured
                // window logs an AppKit error and nils out first responder.
                DispatchQueue.main.async { [weak view, weak window] in
                    guard let view, let window, view.window === window else { return }
                    if window.firstResponder !== view {
                        window.makeFirstResponder(view)
                    }
                    view.applyPendingCursorPositionOrSeekToEnd()
                }
            }
        }
    }

    private func loadAttributedString(into view: ContainedTextView) {
        let ns = InlineMarksBridge.toNS(text, baseFontSize: fontSize, baseBold: bold, lineSpacing: lineSpacing)
        view.textStorage?.setAttributedString(ns)
    }

    private func applyTypingAttributes(to view: NSTextView) {
        // NB: don't write `view.font =` here. NSTextView's font setter applies across the
        // entire text storage, which would stomp the per-range bold/italic font traits
        // that `InlineMarksBridge.toggleMark` writes. The base font is already applied per-
        // range by `loadAttributedString` (via toNS).
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        view.defaultParagraphStyle = style
        view.typingAttributes = InlineMarksBridge.baseTypingAttributes(baseFontSize: fontSize, baseBold: bold, lineSpacing: lineSpacing)
    }

    nonisolated static func resolveNSFont(size: CGFloat, bold: Bool) -> NSFont {
        InlineMarksBridge.interFont(size: size, bold: bold, italic: false)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacBlockTextEditor
        var lastFontSize: CGFloat?
        var lastBold: Bool?
        var lastLineSpacing: CGFloat?
        /// Plain text we last knew the binding to hold. Updated on commit and on
        /// any external-mutation reload in `updateNSView`. While typing we don't
        /// touch the binding, so this stays equal to the binding's `String(text)`
        /// even though `tv.string` has drifted ahead. `updateNSView` uses this to
        /// distinguish "binding lagging because user typed" (skip reload) from
        /// "binding changed externally" (reload).
        var lastKnownBindingPlain: String?
        /// True once textStorage has been edited since our last commit; cleared at
        /// the end of `commitLiveText`. The "binding moved under us" guard relies
        /// on the binding's getter changing after an external mutation, but
        /// BlockRow's `textBinding` captures `block` by value and stays frozen
        /// once the row swaps to read-only Text — so the post-split unmount
        /// `textDidEndEditing` would otherwise re-write the stale textStorage
        /// through that frozen binding and clobber the truncated head.
        var textStorageDirty: Bool = false
        init(_ parent: MacBlockTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            textStorageDirty = true
            let isComposing = tv.hasMarkedText()
            if !isComposing {
                let cursor = tv.selectedRange().location
                // Build the attributed snapshot from textStorage (not `tv.string`) so
                // marks the user applied earlier in this edit — bold/italic/code etc. —
                // survive the autotransform. Same fix shape as splitBlock.
                let attrSnapshot = InlineMarksBridge.toModel(tv.textStorage ?? NSTextStorage())
                if let result = detectPrefixAutotransform(text: attrSnapshot, cursor: cursor) {
                    // Autotransform replaces the block via `mutate(...)`, which now
                    // commits the active editor first — so the pre-mutation snapshot
                    // captures the typed prefix and Cmd-Z restores it cleanly.
                    parent.onAutotransform(result.transform, result.remainingText)
                    return
                }
                if let result = detectInlineStyleAutotransform(text: attrSnapshot, cursor: cursor) {
                    applyInlineAutotransform(result, in: tv)
                    reportMentionTrigger(in: tv, composing: false)
                    return
                }
            }
            // Otherwise: live text stays in NSTextView's textStorage. We do NOT write the
            // binding per keystroke — that would force a full `EditorView.body` re-eval per
            // character. Commit happens on blur (`textDidEndEditing`) and centrally in
            // `EditorView.mutate(...)` via `flushActiveText` for any structural op.
            reportMentionTrigger(in: tv, composing: isComposing)
        }

        /// Sync NSTextView's live attributed text into the document binding, registering
        /// a coarse text-change undo entry if anything actually changed. Called from:
        /// - `textDidChange` before autotransform fires (so the snapshot has live text).
        /// - `textDidEndEditing` (blur — the normal commit point).
        /// - Pre-structural-op key paths in `ContainedTextView.keyDown` (Enter, Backspace,
        ///   Tab, Cmd-K, paste, etc.) so the model is current before `splitBlock` /
        ///   `deleteEmptyBlock` / `changeIndent` / `mutate(...)` run.
        func commitLiveText(_ tv: NSTextView) {
            // Nothing has touched textStorage since our last sync — skip. Catches
            // the unmount-driven duplicate commit after split / autotransform /
            // Cmd-K, where the frozen textBinding would otherwise re-write stale
            // textStorage back over the freshly-mutated model.
            if !textStorageDirty { return }
            let nsAttr = tv.textStorage ?? NSTextStorage()
            let newText = InlineMarksBridge.toModel(nsAttr)
            let oldText = parent.text
            let oldPlain = String(oldText.characters)
            // If the binding moved out from under us since our last sync, a structural
            // op (splitBlock, autotransform, Cmd-K, etc.) has already mutated the model
            // for this block. Our NSTextStorage still holds pre-op text and writing it
            // would clobber the new model state — the canonical case is split duplicating
            // the tail back into the head's row on the unmount-driven textDidEndEditing.
            // Reconcile our snapshot to what the model now holds and bail.
            if let last = lastKnownBindingPlain, oldPlain != last {
                lastKnownBindingPlain = oldPlain
                textStorageDirty = false
                return
            }
            let newPlain = String(newText.characters)
            let changed = oldPlain != newPlain || !attributedStringMarksEqual(oldText, newText)
            if changed {
                if let controller = parent.documentUndoController {
                    controller.transaction(name: "Type", coalesceKey: parent.blockID) {
                        parent.text = newText
                    }
                } else {
                    parent.text = newText
                }
            }
            lastKnownBindingPlain = newPlain
            textStorageDirty = false
            // No separate emit step needed: `controller.transaction(...)`
            // above already fired `Document.didCommitTransaction` with the
            // typing diff. Top-level commits — blur, explicit flush, view
            // tear-down — go through the same path.
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            // Cursor moved without a text change — re-evaluate the mention trigger so
            // arrow-keying out of the @-region dismisses the popover. Defer the
            // SwiftUI state write: this delegate also fires synchronously from
            // `updateNSView` paths that set `selectedRange`, which run inside
            // SwiftUI's view-update pass.
            let composing = tv.hasMarkedText()
            let plain = tv.string
            let cursor = tv.selectedRange().location
            Task { @MainActor [weak self] in
                guard let self else { return }
                if composing {
                    self.parent.onMentionTriggerChange(nil)
                } else {
                    self.parent.onMentionTriggerChange(detectMentionTrigger(plain: plain, cursor: cursor))
                }
            }
        }

        private func applyInlineAutotransform(_ result: InlineAutotransformResult, in tv: NSTextView) {
            let ns = InlineMarksBridge.toNS(
                result.text,
                baseFontSize: parent.fontSize,
                baseBold: parent.bold,
                lineSpacing: parent.lineSpacing
            )
            tv.textStorage?.setAttributedString(ns)
            tv.setSelectedRange(NSRange(location: result.cursor, length: 0))
            tv.typingAttributes = InlineMarksBridge.baseTypingAttributes(
                baseFontSize: parent.fontSize,
                baseBold: parent.bold,
                lineSpacing: parent.lineSpacing
            )
            textStorageDirty = true
            tv.invalidateIntrinsicContentSize()
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url: URL?
            if let value = link as? URL {
                url = value
            } else if let value = link as? String {
                url = URL(string: value)
            } else {
                url = nil
            }
            guard let url else { return false }
            return parent.onOpenLink(url)
        }

        private func reportMentionTrigger(in tv: NSTextView, composing: Bool) {
            if composing {
                parent.onMentionTriggerChange(nil)
                return
            }
            let cursor = tv.selectedRange().location
            let trigger = detectMentionTrigger(plain: tv.string, cursor: cursor)
            parent.onMentionTriggerChange(trigger)
        }

        func textDidBeginEditing(_ notification: Notification) {
            // Break coalescing across edit-session boundaries — typing in block A then
            // clicking into block B should not merge into one undo entry. Defer the
            // SwiftUI focus write: NSTextView fires this delegate synchronously from
            // `makeFirstResponder` calls that may originate inside a view-update pass.
            //
            // `flushActiveText` is wired eagerly in `makeNSView`, not here —
            // this delegate doesn't fire for programmatic attribute changes
            // (Cmd-B / Cmd-I via `didChangeText()`), so a Cmd-B-then-Esc with no
            // intervening typing would otherwise leave the commit hook nil.
            parent.documentUndoController?.breakCoalescing()
            Task { @MainActor [weak self] in
                self?.parent.onFocusChange(true)
            }
        }

        func textDidEndEditing(_ notification: Notification) {
            // Commit the in-flight text to the binding. During the session the live text
            // lived in NSTextView; this is the single coarse write that hands ownership
            // back to the model and registers the session as one undo entry.
            if let tv = notification.object as? NSTextView {
                commitLiveText(tv)
            }
            // Don't clear `flushActiveText` here. In fullscreen mode the Esc-notification
            // path (HunchApp's NSEvent monitor → `handleEscapeKey` → `transferFocus(.nav)`)
            // commits AFTER first responder resigns — clearing the closure here would
            // turn that commit into a no-op. The closure captures coordinator + view
            // weakly, so unmounting the row still cleans it up.
            parent.documentUndoController?.breakCoalescing()
            Task { @MainActor [weak self] in
                self?.parent.onFocusChange(false)
            }
        }
    }
}

/// NSTextView subclass that intercepts the M4 key set before NSTextView's default handling.
/// Returns YES from `performKeyEquivalent(_:)` and short-circuits `keyDown(_:)` for the
/// keys our coordinator wants to consume.
final class ContainedTextView: NSTextView {
    weak var coordinator: MacBlockTextEditor.Coordinator?
    /// Single-slot active-NSTextView handle on the owning EditorView. We assign
    /// `activeView.view = self` in `viewDidMoveToWindow` and clear it on tear-down so
    /// EditorView.transferFocus can grab us synchronously.
    weak var activeView: MacActiveTextView?
    /// Set in `makeNSView`; never changes during a view's lifetime (one editor mount
    /// per (BlockID, edit-session)). Used to verify "is this view for the BlockID
    /// transferFocus wants?".
    var blockID: BlockID?
    /// Set by `updateNSView` whenever the SwiftUI focus state targets this block. Picked up
    /// in `viewDidMoveToWindow` so the second-chance focus grab works on initial mount.
    var wantsFocus: Bool = false
    /// If non-nil, the cursor is placed at this target on initial focus. Cleared
    /// after consumption so subsequent focus grabs (e.g. coming back from another
    /// block) seek to end instead.
    var pendingInitialCursor: InitialCursorTarget?
    /// Idempotency latch on `applyPendingCursorPositionOrSeekToEnd`. Both
    /// `viewDidMoveToWindow` and `updateNSView` schedule a focus-grab + apply on
    /// initial mount; without this latch the second one runs after the first has
    /// already consumed `pendingInitialCursor`, falls into the seek-to-end branch
    /// and overwrites the just-set cursor position.
    private var didApplyInitialCursor = false

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // Tear-down: about to detach from the window. Drop the active-view slot so
        // a late transferFocus(to: .editor(id)) can't grab a doomed view. Only clear
        // if we still hold the slot — a remount of a different block may have
        // already overwritten it.
        if newWindow == nil, let activeView, activeView.view === self {
            activeView.view = nil
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            activeView?.view = self
        }
        if wantsFocus, let window = window, window.firstResponder !== self {
            // Same reasoning as updateNSView's async grab: the view can detach from
            // this window between scheduling and firing — bail unless we're still
            // hosted by the same window.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                if window.firstResponder !== self {
                    window.makeFirstResponder(self)
                }
                self.applyPendingCursorPositionOrSeekToEnd()
            }
        }
    }

    /// Applies `pendingInitialCursor` if set (placing the cursor at the click point or
    /// the explicit character offset), or falls back to seeking the cursor to the end
    /// of the text. Idempotent — subsequent calls during the same view's lifetime are
    /// no-ops, so a second async focus-grab can't drag the cursor back to end.
    func applyPendingCursorPositionOrSeekToEnd() {
        if didApplyInitialCursor { return }
        didApplyInitialCursor = true
        if let target = pendingInitialCursor {
            pendingInitialCursor = nil
            let len = (string as NSString).length
            let idx: Int
            switch target {
            case .point(let p): idx = characterIndexForInsertion(at: p)
            case .offset(let o): idx = max(0, min(o, len))
            }
            setSelectedRange(NSRange(location: idx, length: 0))
        } else {
            setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        }
    }

    override func keyDown(with event: NSEvent) {
        if let onKey = coordinator?.parent.onKey {
            // While the mention popover is open, intercept menu-nav keys before the
            // editor's normal handling so EditorView can drive selection / commit.
            if coordinator?.parent.mentionActive == true {
                switch event.keyCode {
                case 126: // Up
                    if onKey(.mentionUp) == .handled { return }
                case 125: // Down
                    if onKey(.mentionDown) == .handled { return }
                case 36, 76: // Return / numpad Enter
                    if onKey(.mentionCommit) == .handled { return }
                case 53: // Escape
                    if onKey(.mentionDismiss) == .handled { return }
                case 48: // Tab — accept the highlighted entry, mirroring Notion.
                    if onKey(.mentionCommit) == .handled { return }
                default:
                    break
                }
            }
            // Live-text commits are handled centrally by `EditorView.mutate(...)`
            // (which calls `flushActiveText?()` first) and by `transferFocus(...)`
            // (same hook). Every BlockKey routed below either triggers a `mutate`
            // (Enter/Backspace/Tab/Cmd-K → split/delete/indent/convert) or a
            // `transferFocus` (Up/Down/Left/Right exit), so we don't need to
            // commit explicitly here. Cmd-[ (navigateBack) is the exception —
            // it doesn't mutate the model or change focus through transferFocus,
            // so commit so the outgoing doc carries the typed text.
            switch event.keyCode {
            case 36, 76: // Return, numpad Enter
                let range = selectedRange()
                let selStart = range.location
                let selEnd = range.location + range.length
                if onKey(.enter(selectionStart: selStart, selectionEnd: selEnd)) == .handled { return }
            case 51: // Delete (backspace)
                // Fire `.backspaceAtStart` whenever the cursor is at the very start
                // of the row with no selection — the page handler decides what to do
                // based on block type and whether the row is empty (unbullet, merge,
                // delete-block).
                let range = selectedRange()
                if range.location == 0, range.length == 0 {
                    if onKey(.backspaceAtStart) == .handled { return }
                }
            case 48: // Tab
                // Reserved for indent/outdent; never insert a literal tab character.
                let shift = event.modifierFlags.contains(.shift)
                _ = onKey(shift ? .shiftTab : .tab)
                return
            case 53: // Escape
                // cancelOperation handles Esc via NSTextView's normal routing — keyDown
                // never fires for Esc on NSTextView (it's intercepted as a command).
                if onKey(.escape) == .handled { return }
            case 40: // K
                if event.modifierFlags.contains(.command) {
                    // Carry the live text through the BlockKey: when the user typed
                    // into a freshly created row and presses Cmd-K, EditorView's
                    // `document.children` snapshot is stale within this event handler
                    // (same pattern as the cmd-enter fix), so `convertBlockToSubpage`
                    // can't recover the typed text from `document.blocks[i]`. Read
                    // it directly from the live NSTextView instead.
                    let preferred: String?
                    let range = selectedRange()
                    if range.length > 0, let textRange = Range(range, in: string) {
                        preferred = String(string[textRange])
                    } else {
                        preferred = string.isEmpty ? nil : string
                    }
                    if onKey(.cmdK(preferredTitle: preferred)) == .handled { return }
                }
            case 33: // [ — Cmd-[ → navigate back
                if event.modifierFlags.contains(.command) {
                    // Navigate-back leaves the page; commit so the outgoing doc is
                    // current. This path doesn't go through `mutate` or
                    // `transferFocus`, so the central commit hook doesn't fire here.
                    coordinator?.commitLiveText(self)
                    if onKey(.navigateBack) == .handled { return }
                }
            case 11: // B — Cmd-B → bold
                if event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.shift) {
                    toggleInlineMark(.bold)
                    return
                }
            case 34: // I — Cmd-I → italic
                if event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.shift) {
                    toggleInlineMark(.italic)
                    return
                }
            case 14: // E — Cmd-E → inline code (matching Notion)
                if event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.shift) {
                    toggleInlineMark(.code)
                    return
                }
            case 1: // S — Cmd-Shift-S → strikethrough (matching Notion)
                if event.modifierFlags.contains([.command, .shift]) {
                    toggleInlineMark(.strikethrough)
                    return
                }
            case 126: // Up arrow
                if !event.modifierFlags.contains([.shift, .option]),
                   cursorIsOnFirstLine() {
                    if onKey(.exitEditUp) == .handled { return }
                }
            case 125: // Down arrow
                if !event.modifierFlags.contains([.shift, .option]),
                   cursorIsOnLastLine() {
                    if onKey(.exitEditDown) == .handled { return }
                }
            case 123: // Left arrow
                // Plain Left at offset 0 with no selection hops to the end of the
                // previous editable block. Any modifier (shift/option/cmd/ctrl)
                // means selection-extension or word/line nav — let NSTextView handle.
                if event.modifierFlags.isDisjoint(with: [.shift, .option, .command, .control]) {
                    let range = selectedRange()
                    if range.location == 0, range.length == 0 {
                        if onKey(.exitEditLeft) == .handled { return }
                    }
                }
            case 124: // Right arrow
                if event.modifierFlags.isDisjoint(with: [.shift, .option, .command, .control]) {
                    let range = selectedRange()
                    let length = textStorage?.length ?? 0
                    if range.location == length, range.length == 0 {
                        if onKey(.exitEditRight) == .handled { return }
                    }
                }
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    /// Toggles an inline mark on the current selection. No-op if the selection is empty —
    /// pre-typing toggles via `typingAttributes` aren't wired yet (M6 follow-up).
    func toggleInlineMark(_ mark: InlineMark) {
        guard let storage = textStorage,
              let parent = coordinator?.parent else { return }
        let range = selectedRange()
        guard range.length > 0 else {
            typingAttributes = InlineMarksBridge.typingAttributes(
                toggling: mark,
                current: typingAttributes,
                baseFontSize: parent.fontSize,
                baseBold: parent.bold,
                lineSpacing: parent.lineSpacing
            )
            return
        }
        InlineMarksBridge.toggleMark(mark, on: range, in: storage, baseFontSize: parent.fontSize, baseBold: parent.bold)
        didChangeText()
    }

    /// Whether the insertion point is on the first wrapped line of the editor's content.
    /// Single-line content trivially returns true. Used to gate `exitEditUp` so that an up
    /// arrow in the middle of a multi-line paragraph still moves intra-block.
    func cursorIsOnFirstLine() -> Bool {
        guard let lm = layoutManager, let tc = textContainer else { return true }
        if (textStorage?.length ?? 0) == 0 { return true }
        let cursor = selectedRange().location
        let glyphRange = lm.glyphRange(forCharacterRange: NSRange(location: cursor, length: 0), actualCharacterRange: nil)
        var firstLineRange = NSRange()
        _ = lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: &firstLineRange, withoutAdditionalLayout: false)
        _ = tc
        return NSLocationInRange(glyphRange.location, firstLineRange) || glyphRange.location == firstLineRange.location
    }

    func cursorIsOnLastLine() -> Bool {
        guard let lm = layoutManager else { return true }
        let length = textStorage?.length ?? 0
        if length == 0 { return true }
        let cursor = selectedRange().location
        let glyphRange = lm.glyphRange(forCharacterRange: NSRange(location: cursor, length: 0), actualCharacterRange: nil)
        var lastLineRange = NSRange()
        let lastGlyph = max(0, lm.numberOfGlyphs - 1)
        _ = lm.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: &lastLineRange, withoutAdditionalLayout: false)
        return NSLocationInRange(glyphRange.location, lastLineRange) || glyphRange.location >= lastLineRange.location
    }

    override var intrinsicContentSize: NSSize {
        guard let lm = layoutManager, let tc = textContainer else {
            return super.intrinsicContentSize
        }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(used.height))
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
    }

    /// NSTextView's default paste validation rejects pasteboards that carry only
    /// image data (PNG/TIFF/file URLs) — its `readablePasteboardTypes` covers
    /// strings/RTF/RTFD/HTML, not images. Without this override, Cmd-V over an
    /// image-only pasteboard beeps and our `paste(_:)` override never runs.
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(NSText.paste(_:)),
           !readPasteboardImages(NSPasteboard.general).isEmpty {
            return true
        }
        return super.validateMenuItem(menuItem)
    }

    /// Intercept Cmd-V / paste action. NSTextView routes both the menu item and the
    /// keyboard shortcut through `paste(_:)`. We hand the raw pasteboard string up to
    /// EditorView via the `.paste` BlockKey; if it splices multi-block content it
    /// returns `.handled` and we skip super. Single-paragraph pastes return `.ignored`
    /// and fall through to the native handler so cursor placement + native typing-undo
    /// coalescing both stay correct.
    override func paste(_ sender: Any?) {
        if let onKey = coordinator?.parent.onKey {
            // Image-on-pasteboard takes precedence over text. Cmd-Shift-4 puts a PNG/TIFF
            // representation alongside no string at all; copying an image from a browser
            // puts both — in both cases the user expects an image, not the URL. Live-text
            // commit happens centrally in `EditorView.mutate(...)` if the paste splices
            // blocks; single-paragraph string paste returns `.ignored` and falls through
            // to the rich-text sanitize path (no model snapshot, binding stays stale
            // until blur as usual).
            let images = readPasteboardImages(NSPasteboard.general)
            if !images.isEmpty {
                if onKey(.imagesPasted(images)) == .handled {
                    return
                }
            }
            if let str = NSPasteboard.general.string(forType: .string) {
                if onKey(.paste(str)) == .handled {
                    return
                }
            }
        }
        // Single-paragraph fallthrough. If the pasteboard carries a rich representation
        // (RTF/HTML — common for browser, Pages, Notion, Mail copies), strip every
        // attribute that doesn't round-trip to markdown and re-render in the row's
        // typography before insertion. Plain-text-only pastes go to super.paste, which
        // inserts using the row's typingAttributes.
        if let parent = coordinator?.parent,
           let rich = readPasteboardRichText(NSPasteboard.general) {
            let sanitized = InlineMarksBridge.sanitize(
                rich,
                baseFontSize: parent.fontSize,
                baseBold: parent.bold,
                lineSpacing: parent.lineSpacing)
            insertText(sanitized, replacementRange: selectedRange())
            return
        }
        super.paste(sender)
    }

    /// NSTextView routes Esc via `cancelOperation(_:)` rather than firing it through
    /// `keyDown`'s normal switch. Hook that path explicitly so our `.escape` handler
    /// (exit edit mode, return to nav mode) runs. We resign first responder to nil first
    /// so the window's first-responder slot is cleared before SwiftUI re-renders — without
    /// this, NSTextView remains nominal first responder during the unmount and SwiftUI
    /// can't successfully set the page container as the new first responder, leaving
    /// arrow-key nav unbound.
    override func cancelOperation(_ sender: Any?) {
        if coordinator?.parent.mentionActive == true,
           let onKey = coordinator?.parent.onKey,
           onKey(.mentionDismiss) == .handled {
            // Esc while the mention popover is open dismisses the menu but leaves the
            // editor focused — don't resign first responder.
            return
        }
        // Order matters: let `.escape` run while this view is still first responder
        // and `flushActiveText` is still wired. `handleEditorKey(.escape)` calls
        // `flushActiveText` to flush live text (with marks) into the binding,
        // then transitions to nav mode. Only after that do we resign — resigning
        // first would synchronously fire `textDidEndEditing` and re-renders may
        // race the commit.
        if let onKey = coordinator?.parent.onKey, onKey(.escape) == .handled {
            window?.makeFirstResponder(nil)
            return
        }
        super.cancelOperation(sender)
    }
}

#endif

// MARK: - iOS

#if os(iOS)

/// SwiftUI accessory bar hosted as the UITextView's `inputAccessoryView`. The
/// closures are refreshed by `updateUIView` so each render swaps in the
/// freshest `onKey` / `bridge` references.
struct KeyboardAccessoryBar: View {
    var onShiftTab: () -> Void
    var onTab: () -> Void
    var onToggleMark: (InlineMark) -> Void
    var onCmdK: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    Button(action: onShiftTab) { Image(systemName: "decrease.indent") }
                    Button(action: onTab) { Image(systemName: "increase.indent") }
                    Divider().frame(height: 20)
                    Button { onToggleMark(.bold) } label: { Image(systemName: "bold") }
                    Button { onToggleMark(.italic) } label: { Image(systemName: "italic") }
                    Button { onToggleMark(.code) } label: { Image(systemName: "chevron.left.forwardslash.chevron.right") }
                    Button { onToggleMark(.strikethrough) } label: { Image(systemName: "strikethrough") }
                    Divider().frame(height: 20)
                    Button(action: onCmdK) { Image(systemName: "rectangle.stack.badge.plus") }
                }
                .padding(.horizontal, 12)
            }
            Button(action: onDismiss) {
                Image(systemName: "keyboard.chevron.compact.down")
            }
            .padding(.horizontal, 12)
            .accessibilityIdentifier("keyboard-dismiss")
        }
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .background(.thickMaterial)
    }
}

/// Side-channel held by reference so the SwiftUI keyboard toolbar can drive
/// mark toggles on the underlying UITextView's textStorage. The toolbar lives
/// on the SwiftUI view, but mark toggling needs to read/write the platform
/// text view's selectedRange + textStorage — pass-by-reference is the simplest
/// way to bridge.
@MainActor
final class IOSEditorBridge {
    weak var textView: ContainedTextViewIOS?
    var fontSize: CGFloat = 16
    var bold: Bool = false
    var lineSpacing: CGFloat = 0

    func toggleMark(_ mark: InlineMark) {
        guard let tv = textView else { return }
        let range = tv.selectedRange
        guard range.length > 0 else {
            tv.typingAttributes = InlineMarksBridge.typingAttributes(
                toggling: mark,
                current: tv.typingAttributes,
                baseFontSize: fontSize,
                baseBold: bold,
                lineSpacing: lineSpacing
            )
            return
        }
        let storage = tv.textStorage
        InlineMarksBridge.toggleMark(mark, on: range, in: storage, baseFontSize: fontSize, baseBold: bold)
        // Notify the delegate so the binding picks up the new attributes.
        tv.delegate?.textViewDidChange?(tv)
    }
}

/// `UITextView`-based single-block editor. Strips the default insets to match
/// the macOS editor's typography alignment with the row's read-only `Text`.
struct IOSBlockTextEditorView: UIViewRepresentable {
    @Binding var text: AttributedString
    let fontSize: CGFloat
    let bold: Bool
    let lineSpacing: CGFloat
    let isFocused: Bool
    let onFocusChange: (Bool) -> Void
    let blockID: BlockID
    let bridge: IOSEditorBridge
    let onKey: (BlockKey) -> KeyPress.Result
    let onAutotransform: (BlockTransform, AttributedString) -> Void
    let onOpenLink: (URL) -> Bool
    let onMentionTriggerChange: (MentionTrigger?) -> Void
    let mentionActive: Bool
    let consumeInitialCursor: () -> InitialCursorTarget?
    let documentUndoController: DocumentUndoController?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> ContainedTextViewIOS {
        let tv = ContainedTextViewIOS()
        tv.delegate = context.coordinator
        tv.coordinator = context.coordinator
        tv.isEditable = true
        tv.isSelectable = true
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.isScrollEnabled = false
        tv.allowsEditingTextAttributes = true
        tv.adjustsFontForContentSizeCategory = false
        tv.smartDashesType = .no
        loadAttributedString(into: tv)
        applyTypingAttributes(to: tv)
        tv.wantsFocus = isFocused
        tv.pendingInitialCursor = consumeInitialCursor()
        context.coordinator.lastKnownBindingPlain = String(text.characters)
        bridge.textView = tv
        bridge.fontSize = fontSize
        bridge.bold = bold
        bridge.lineSpacing = lineSpacing
        // See macOS twin: wire eagerly at mount, not in `textViewDidBeginEditing` —
        // formatting changes via `IOSEditorBridge` don't fire begin-editing.
        documentUndoController?.flushActiveText = { [weak coordinator = context.coordinator, weak tv] in
            guard let coordinator, let tv else { return }
            coordinator.commitLiveText(tv)
        }
        // Build the keyboard accessory bar and host it on the UITextView. UIKit
        // shows this above the keyboard. SwiftUI's `.toolbar(placement: .keyboard)`
        // doesn't reach a UIViewRepresentable, so we set it directly.
        let host = UIHostingController(rootView: makeAccessoryBar(for: tv))
        host.view.translatesAutoresizingMaskIntoConstraints = true
        host.view.autoresizingMask = [.flexibleWidth]
        // UIKit re-pins the inputAccessoryView's width to the keyboard's actual
        // width via the autoresizing mask, so the initial width just needs to be
        // generous enough to cover any device. Height (44) is the bar's intrinsic
        // height and what UIKit reserves above the keyboard.
        host.view.frame = CGRect(x: 0, y: 0, width: 1024, height: 44)
        host.view.backgroundColor = .clear
        tv.inputAccessoryView = host.view
        context.coordinator.accessoryHost = host
        return tv
    }

    /// SwiftUI sizes the editor by calling this with the proposed width. We
    /// hand that width to UITextView's text container, then ask UITextView
    /// what height fits — that's what `Text` does too. Without this, we'd
    /// fall back to `intrinsicContentSize`, whose height depends on whatever
    /// frame width UITextView happened to be measured with last (often zero
    /// or a single-line width), so multi-line blocks would clip.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ContainedTextViewIOS, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: fitting.height)
    }

    func updateUIView(_ tv: ContainedTextViewIOS, context: Context) {
        context.coordinator.parent = self
        // Reload only when the binding actually changed since we last touched it
        // (external mutation: undo, autotransform, etc.). The "binding lagging because
        // user is typing" case keeps `lastKnownBindingPlain == bindingPlain` while
        // `tv.textStorage.string` runs ahead — must not reload, or commit-on-blur would
        // clobber the live text.
        let bindingPlain = String(text.characters)
        if context.coordinator.lastKnownBindingPlain != bindingPlain {
            loadAttributedString(into: tv)
            context.coordinator.lastKnownBindingPlain = bindingPlain
        }
        applyTypingAttributes(to: tv)
        bridge.textView = tv
        bridge.fontSize = fontSize
        bridge.bold = bold
        bridge.lineSpacing = lineSpacing

        // Refresh the accessory bar's closures so they capture the latest
        // `onKey` / `bridge` references — both are recreated on every parent
        // re-render.
        context.coordinator.accessoryHost?.rootView = makeAccessoryBar(for: tv)

        tv.wantsFocus = isFocused
        if isFocused, tv.window != nil, !tv.isFirstResponder {
            // Defer becomeFirstResponder out of `updateUIView` — calling it
            // synchronously inside SwiftUI's view-update pass triggers
            // "AttributeGraph: cycle detected" because UIKit's first-responder
            // change cascades into delegate callbacks (selection / focus) that
            // SwiftUI sees mid-render. Initial-mount focus is handled
            // synchronously by `ContainedTextViewIOS.didMoveToWindow`, which
            // runs after view installation rather than during view-update; the
            // deferred path here only kicks in for the rarer re-grab case.
            DispatchQueue.main.async { [weak tv] in
                guard let tv, tv.window != nil, !tv.isFirstResponder else { return }
                _ = tv.becomeFirstResponder()
                tv.applyPendingCursorPositionOrSeekToEnd()
            }
        }
    }

    private func makeAccessoryBar(for tv: ContainedTextViewIOS) -> KeyboardAccessoryBar {
        // Live-text commits flow through `EditorView.mutate(...)` (for ops that
        // change the model) and `transferFocus(...)` (for Esc → nav). The
        // accessory bar's actions all hit one of those paths through `onKey`,
        // so explicit commits aren't needed here.
        KeyboardAccessoryBar(
            onShiftTab: { _ = onKey(.shiftTab) },
            onTab: { _ = onKey(.tab) },
            onToggleMark: { mark in bridge.toggleMark(mark) },
            onCmdK: {
                let range = tv.selectedRange
                let preferred: String? = {
                    let ns = tv.textStorage.string as NSString
                    if range.length > 0,
                       range.location >= 0,
                       range.location + range.length <= ns.length {
                        return ns.substring(with: range)
                    }
                    let full = ns as String
                    return full.isEmpty ? nil : full
                }()
                _ = onKey(.cmdK(preferredTitle: preferred))
            },
            onDismiss: {
                tv.resignFirstResponder()
                _ = onKey(.escape)
            }
        )
    }

    private func loadAttributedString(into tv: ContainedTextViewIOS) {
        let ns = InlineMarksBridge.toNS(text, baseFontSize: fontSize, baseBold: bold, lineSpacing: lineSpacing)
        tv.textStorage.setAttributedString(ns)
    }

    private func applyTypingAttributes(to tv: ContainedTextViewIOS) {
        let font = Self.resolveUIFont(size: fontSize, bold: bold)
        tv.font = font
        tv.typingAttributes = InlineMarksBridge.baseTypingAttributes(baseFontSize: fontSize, baseBold: bold, lineSpacing: lineSpacing)
    }

    nonisolated static func resolveUIFont(size: CGFloat, bold: Bool) -> UIFont {
        InlineMarksBridge.interFont(size: size, bold: bold, italic: false)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: IOSBlockTextEditorView
        /// Retains the SwiftUI accessory bar hosted as the UITextView's
        /// `inputAccessoryView`. UIKit retains the view itself but the
        /// hosting controller needs an owner with the right lifecycle —
        /// the Coordinator lives as long as the Representable does.
        var accessoryHost: UIHostingController<KeyboardAccessoryBar>?
        /// See `MacBlockTextEditor.Coordinator.lastKnownBindingPlain` — same role on iOS.
        var lastKnownBindingPlain: String?
        /// See `MacBlockTextEditor.Coordinator.textStorageDirty` — same role on iOS.
        var textStorageDirty: Bool = false

        init(parent: IOSBlockTextEditorView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            textStorageDirty = true
            // IME composition: skip autotransform. Live text remains in textStorage and
            // is committed on blur or centrally in `EditorView.mutate(...)`.
            let composing = (textView.markedTextRange != nil)

            if !composing {
                let cursor = textView.selectedRange.location
                // Snapshot the marked text from textStorage so any inline marks the
                // user applied earlier in this edit survive the autotransform.
                let attrSnapshot = InlineMarksBridge.toModel(textView.textStorage)
                if let result = detectPrefixAutotransform(text: attrSnapshot, cursor: cursor) {
                    // Autotransform replaces the block via `mutate(...)`, which commits
                    // the active editor first — so the pre-mutation snapshot captures
                    // the typed prefix and Cmd-Z restores it cleanly.
                    parent.onAutotransform(result.transform, result.remainingText)
                    return
                }
                if let result = detectInlineStyleAutotransform(text: attrSnapshot, cursor: cursor) {
                    applyInlineAutotransform(result, in: textView)
                    reportMentionTrigger(in: textView, composing: false)
                    return
                }
            }
            reportMentionTrigger(in: textView, composing: composing)
        }

        /// iOS twin of `MacBlockTextEditor.Coordinator.commitLiveText`. Sync live
        /// attributed text into the binding and register a coarse undo entry if
        /// anything changed. Called from `textViewDidEndEditing`, before autotransform
        /// fires, and before structural BlockKeys (Enter/backspace-at-start/Tab/etc.)
        /// in `ContainedTextViewIOS`.
        func commitLiveText(_ textView: UITextView) {
            // See macOS twin — early return when textStorage hasn't changed.
            if !textStorageDirty { return }
            let newText = InlineMarksBridge.toModel(textView.textStorage)
            let oldText = parent.text
            let oldPlain = String(oldText.characters)
            // See MacBlockTextEditor.Coordinator.commitLiveText — same teardown race:
            // a structural op (split / autotransform / Cmd-K) mutates the model after we
            // synced live text, then the unmount fires a second commit whose stale
            // textStorage would clobber the new model state.
            if let last = lastKnownBindingPlain, oldPlain != last {
                lastKnownBindingPlain = oldPlain
                textStorageDirty = false
                return
            }
            let newPlain = String(newText.characters)
            let changed = oldPlain != newPlain || !attributedStringMarksEqual(oldText, newText)
            if changed {
                if let controller = parent.documentUndoController {
                    controller.transaction(name: "Type", coalesceKey: parent.blockID) {
                        parent.text = newText
                    }
                } else {
                    parent.text = newText
                }
            }
            lastKnownBindingPlain = newPlain
            textStorageDirty = false
            // No separate emit step needed — see the macOS twin.
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            // Defer the SwiftUI write — this delegate fires synchronously from
            // both user interaction and `updateUIView`'s own
            // `applyPendingCursorPositionOrSeekToEnd`. The latter runs inside a
            // SwiftUI view-update pass; writing to `state.mentionMenu` there
            // shows up as an AttributeGraph cycle.
            let composing = (textView.markedTextRange != nil)
            let plain = textView.text ?? ""
            let cursor = textView.selectedRange.location
            Task { @MainActor [weak self] in
                guard let self else { return }
                if composing {
                    self.parent.onMentionTriggerChange(nil)
                } else {
                    self.parent.onMentionTriggerChange(detectMentionTrigger(plain: plain, cursor: cursor))
                }
            }
        }

        private func applyInlineAutotransform(_ result: InlineAutotransformResult, in textView: UITextView) {
            let ns = InlineMarksBridge.toNS(
                result.text,
                baseFontSize: parent.fontSize,
                baseBold: parent.bold,
                lineSpacing: parent.lineSpacing
            )
            textView.textStorage.setAttributedString(ns)
            textView.selectedRange = NSRange(location: result.cursor, length: 0)
            textView.typingAttributes = InlineMarksBridge.baseTypingAttributes(
                baseFontSize: parent.fontSize,
                baseBold: parent.bold,
                lineSpacing: parent.lineSpacing
            )
            textStorageDirty = true
            textView.invalidateIntrinsicContentSize()
        }

        func textView(
            _ textView: UITextView,
            primaryActionFor textItem: UITextItem,
            defaultAction: UIAction
        ) -> UIAction? {
            guard case .link(let url) = textItem.content,
                  parent.onOpenLink(url) else {
                return defaultAction
            }
            return UIAction { _ in }
        }

        private func reportMentionTrigger(in textView: UITextView, composing: Bool) {
            if composing {
                parent.onMentionTriggerChange(nil)
                return
            }
            let cursor = textView.selectedRange.location
            let trigger = detectMentionTrigger(plain: textView.text ?? "", cursor: cursor)
            parent.onMentionTriggerChange(trigger)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.documentUndoController?.breakCoalescing()
            // `flushActiveText` wired eagerly in `makeUIView` — see macOS twin.
            // Defer the @FocusState write — this delegate fires synchronously
            // from `updateUIView`'s own `becomeFirstResponder`, which runs
            // inside a SwiftUI view-update pass. A synchronous write triggers
            // an AttributeGraph cycle.
            Task { @MainActor [weak self] in
                self?.parent.onFocusChange(true)
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            // Single coarse commit on session end — see Mac twin for rationale.
            commitLiveText(textView)
            // Don't clear `flushActiveText` — keep the hook wired for late
            // commits (e.g. mode-change paths that fire after first responder
            // resigns). Weak refs in the closure clean up on unmount.
            parent.documentUndoController?.breakCoalescing()
            Task { @MainActor [weak self] in
                self?.parent.onFocusChange(false)
            }
        }
    }
}

/// UITextView subclass that intercepts soft-keyboard delete and return so they
/// can be handled at the page level (block split / block delete-or-collapse)
/// rather than inserting characters into the row.
final class ContainedTextViewIOS: UITextView {
    weak var coordinator: IOSBlockTextEditorView.Coordinator?
    /// If non-nil, the cursor is placed at this target on initial focus. Cleared
    /// after consumption so subsequent focus grabs fall through to seek-to-end.
    var pendingInitialCursor: InitialCursorTarget?
    /// Set by `updateUIView` whenever this row should be the active editor. Picked
    /// up in `didMoveToWindow` so the second-chance focus grab works on initial
    /// mount — at the time `updateUIView` runs, `window` may still be nil and
    /// `becomeFirstResponder` would silently no-op.
    var wantsFocus: Bool = false
    /// Idempotency latch on `applyPendingCursorPositionOrSeekToEnd`. Mirrors the
    /// macOS path — both `didMoveToWindow` and `updateUIView` schedule a focus-grab
    /// + apply on initial mount; without this latch the second one runs after the
    /// first has consumed `pendingInitialCursor` and seeks back to end.
    private var didApplyInitialCursor = false

    /// With `isScrollEnabled = false` (required so SwiftUI sizes us to content
    /// height), UITextView's default intrinsicContentSize reports the width
    /// needed to fit all text on a single line. SwiftUI's VStack picks that up
    /// and expands the entire content column to match — which means tapping
    /// into one block reflows EVERY sibling read-only Text to the new wider
    /// column. Returning `noIntrinsicMetric` for width tells SwiftUI we have
    /// no horizontal preference; the parent's offered width wins, the
    /// textContainer wraps to it, and our height is computed from that
    /// wrapped layout. Width-flex, height-fixed — same shape as the read-only
    /// `Text` we're replacing.
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: UIView.noIntrinsicMetric, height: s.height)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Grab focus synchronously inside the same runloop the previous editor
        // resigned in — UIKit only keeps the keyboard alive when first-responder
        // transfer is synchronous. Async dispatch (the obvious-looking choice)
        // makes the keyboard dismiss + re-show every time the user taps a
        // different row.
        if wantsFocus, window != nil, !isFirstResponder {
            _ = becomeFirstResponder()
            applyPendingCursorPositionOrSeekToEnd()
        }
    }

    override func deleteBackward() {
        // Backspace at the very start of the row (cursor at offset 0, no selection)
        // fires `.backspaceAtStart`. Live-text commit happens centrally in
        // `EditorView.mutate(...)` if the page-level handler ends up mutating.
        if selectedRange.location == 0, selectedRange.length == 0,
           let coordinator {
            if coordinator.parent.onKey(.backspaceAtStart) == .handled {
                return
            }
        }
        super.deleteBackward()
    }

    /// Intercept the system paste action. Hand the raw pasteboard string up to
    /// EditorView via `.paste`; if it splices multi-block content it returns
    /// `.handled` and we skip super. Single-paragraph pastes return `.ignored`
    /// and fall through to UITextView's native paste so cursor placement and
    /// native undo behavior stay correct.
    override func paste(_ sender: Any?) {
        if let coordinator {
            // Live-text commit happens centrally in `EditorView.mutate(...)` for
            // multi-block paste. Single-paragraph paste returns `.ignored` and
            // falls through to the rich-text sanitize path; binding stays stale
            // until blur, as usual.
            let images = readPasteboardImages(UIPasteboard.general)
            if !images.isEmpty {
                if coordinator.parent.onKey(.imagesPasted(images)) == .handled {
                    return
                }
            }
            if let str = UIPasteboard.general.string {
                if coordinator.parent.onKey(.paste(str)) == .handled {
                    return
                }
            }
        }
        // Single-paragraph fallthrough — see the macOS twin in ContainedTextView.paste.
        if let coordinator,
           let rich = readPasteboardRichText(UIPasteboard.general) {
            let parent = coordinator.parent
            let sanitized = InlineMarksBridge.sanitize(
                rich,
                baseFontSize: parent.fontSize,
                baseBold: parent.bold,
                lineSpacing: parent.lineSpacing)
            let target = selectedRange
            textStorage.beginEditing()
            textStorage.replaceCharacters(in: target, with: sanitized)
            textStorage.endEditing()
            selectedRange = NSRange(location: target.location + sanitized.length, length: 0)
            // Direct textStorage edits don't fire textViewDidChange; nudge it so the
            // coordinator marks textStorageDirty (commit-on-blur picks up the new text)
            // and the autotransform/mention pipeline re-evaluates.
            delegate?.textViewDidChange?(self)
            return
        }
        super.paste(sender)
    }

    override func insertText(_ text: String) {
        if text == "\n",
           let coordinator {
            // While the mention popover is open, soft- or hardware-keyboard return
            // commits the highlighted entry instead of splitting the block.
            if coordinator.parent.mentionActive,
               coordinator.parent.onKey(.mentionCommit) == .handled {
                return
            }
            // Soft-keyboard return: split the block at the current selection. Live-text
            // commit happens centrally in `EditorView.mutate(...)` inside `splitBlock`.
            // When the selection is non-empty, the split deletes its contents
            // (Return-over-selection mirrors typing a `\n`).
            let range = selectedRange
            let selStart = range.location
            let selEnd = range.location + range.length
            if coordinator.parent.onKey(.enter(selectionStart: selStart, selectionEnd: selEnd)) == .handled {
                return
            }
        }
        super.insertText(text)
    }

    /// Mirrors the macOS helper — places the cursor at a captured tap point or an
    /// explicit character offset on initial focus, or seeks to end if no target is
    /// pending. Idempotent — subsequent calls during the same view's lifetime are
    /// no-ops, so a second async focus-grab can't drag the cursor back to end.
    func applyPendingCursorPositionOrSeekToEnd() {
        if didApplyInitialCursor { return }
        didApplyInitialCursor = true
        let len = (text as NSString?)?.length ?? 0
        if let target = pendingInitialCursor {
            pendingInitialCursor = nil
            switch target {
            case .point(let point):
                // Force layout: at didMoveToWindow / first updateUIView UITextView's
                // text container hasn't necessarily run layout, and `closestPosition`
                // returns the doc-end position when the layout is empty. Without this
                // the caret silently snaps to end on every tap-to-edit. `layoutIfNeeded`
                // alone is enough on TextKit 2 — touching `.layoutManager` here would
                // silently downgrade the view to TextKit 1 compatibility mode.
                layoutIfNeeded()
                if let position = closestPosition(to: point) {
                    let offset = self.offset(from: beginningOfDocument, to: position)
                    selectedRange = NSRange(location: offset, length: 0)
                    return
                }
            case .offset(let o):
                selectedRange = NSRange(location: max(0, min(o, len)), length: 0)
                return
            }
        }
        selectedRange = NSRange(location: len, length: 0)
    }
}

#endif
