import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Block-level keyboard events the page-level handler reacts to.
public enum BlockKey: Sendable, Equatable {
    case enter(cursorOffset: Int)
    case backspaceAtStart
    case tab
    case shiftTab
    case escape
    case cmdK(selectedText: String?)
    case navigateBack
    /// Up arrow pressed while the cursor is on the editor's first line. PageView
    /// treats this as Esc + up: exit edit mode and select the previous block.
    case exitEditUp
    /// Down arrow pressed while the cursor is on the editor's last line.
    case exitEditDown
    // The mention popover (@-menu) is open over the active editor; the editor
    // forwards these unconditionally so PageView can drive menu navigation
    // without taking focus away from the text.
    case mentionUp
    case mentionDown
    case mentionCommit
    case mentionDismiss
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
public struct BlockTextEditor: View {
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
    let blockID: BlockID
    let onKey: (BlockKey) -> KeyPress.Result
    let onAutotransform: (BlockTransform, AttributedString) -> Void
    /// Fires whenever the cursor sits after an in-progress `@query` (or transitions out
    /// of one — `nil` then). PageView holds the popover state and decides whether to
    /// show / dismiss the menu based on this stream.
    let onMentionTriggerChange: (MentionTrigger?) -> Void
    /// When true, the editor unconditionally forwards ↑/↓/Return/Esc to `onKey` as
    /// `mentionUp/Down/Commit/Dismiss` so PageView can drive the popover. When false,
    /// arrow keys behave normally (intra-block nav or exit-edit on boundary).
    let mentionActive: Bool
    /// Optional point (in the editor's local coordinate space) where the cursor should
    /// land on initial focus. When the user clicks on a read-only block, the click
    /// location is propagated here so the cursor lands where they clicked rather than at
    /// end-of-text. Consumed once on mount.
    let initialCursorPoint: CGPoint?
    /// Document-level undo controller. NSTextView keeps its own per-instance typing-undo
    /// (used while the editor is mounted, fine-grained character-by-character). On focus
    /// loss, the Coordinator registers ONE coarse "Type" entry on this controller's shared
    /// manager — that's how typing survives editor unmount without keeping dangling
    /// pointers to a deallocated NSTextView.
    @Environment(\.documentUndoController) private var documentUndoController

    public init(
        text: Binding<AttributedString>,
        font: Font,
        fontSize: CGFloat = 16,
        bold: Bool = false,
        lineSpacing: CGFloat,
        focused: FocusState<BlockID?>.Binding,
        blockID: BlockID,
        onKey: @escaping (BlockKey) -> KeyPress.Result,
        onAutotransform: @escaping (BlockTransform, AttributedString) -> Void = { _, _ in },
        onMentionTriggerChange: @escaping (MentionTrigger?) -> Void = { _ in },
        mentionActive: Bool = false,
        initialCursorPoint: CGPoint? = nil
    ) {
        self._text = text
        self.font = font
        self.fontSize = fontSize
        self.bold = bold
        self.lineSpacing = lineSpacing
        self._focused = focused
        self.blockID = blockID
        self.onKey = onKey
        self.onAutotransform = onAutotransform
        self.onMentionTriggerChange = onMentionTriggerChange
        self.mentionActive = mentionActive
        self.initialCursorPoint = initialCursorPoint
    }

    public var body: some View {
        #if os(macOS)
        // The editor only mounts when its row is the active editing block (PageView gates
        // this via `isEditing`). So unconditionally request focus on mount — `@FocusState`
        // writes from PageView's `enterEditMode` are deferred and don't propagate before
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
            onMentionTriggerChange: onMentionTriggerChange,
            mentionActive: mentionActive,
            initialCursorPoint: initialCursorPoint,
            blockID: blockID,
            documentUndoController: documentUndoController
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
        // Mirrors the macOS path: the view only mounts when this row is the
        // active editor (PageView gates via `isEditing`), so request focus
        // unconditionally on mount. `onFocusChange` reflects the UITextView's
        // first-responder state back into SwiftUI's `@FocusState`.
        IOSBlockTextEditorView(
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
            blockID: blockID,
            bridge: iosBridge,
            onKey: onKey,
            onAutotransform: onAutotransform,
            onMentionTriggerChange: onMentionTriggerChange,
            mentionActive: mentionActive,
            initialCursorPoint: initialCursorPoint,
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
    let onMentionTriggerChange: (MentionTrigger?) -> Void
    let mentionActive: Bool
    let initialCursorPoint: CGPoint?
    let blockID: BlockID
    let documentUndoController: DocumentUndoController?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> ContainedTextView {
        let view = ContainedTextView()
        view.coordinator = context.coordinator
        view.delegate = context.coordinator
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
        view.wantsFocus = isFocused
        view.pendingInitialCursorPoint = initialCursorPoint
        return view
    }

    func updateNSView(_ view: ContainedTextView, context: Context) {
        context.coordinator.parent = self
        // Only re-sync textStorage from the binding when plain text drifted, or when the
        // base font props changed (e.g. paragraph → heading). Attribute changes that
        // originated inside this editor were already pushed back via textDidChange, so a
        // gratuitous reload here would clobber the cursor *and* wipe per-range bold/italic
        // (since toggleMark stores those as font symbolic traits).
        let storedPlain = view.textStorage?.string ?? ""
        let bindingPlain = String(text.characters)
        let baseFontDrift = context.coordinator.lastFontSize != fontSize
            || context.coordinator.lastBold != bold
            || context.coordinator.lastLineSpacing != lineSpacing
        if storedPlain != bindingPlain || baseFontDrift {
            loadAttributedString(into: view)
            context.coordinator.lastFontSize = fontSize
            context.coordinator.lastBold = bold
            context.coordinator.lastLineSpacing = lineSpacing
        }
        applyTypingAttributes(to: view)
        view.wantsFocus = isFocused
        if isFocused {
            if let window = view.window, window.firstResponder !== view {
                DispatchQueue.main.async {
                    window.makeFirstResponder(view)
                    view.applyPendingCursorPositionOrSeekToEnd()
                }
            }
        }
    }

    private func loadAttributedString(into view: ContainedTextView) {
        let ns = InlineMarksKit.toNS(text, baseFontSize: fontSize, baseBold: bold, lineSpacing: lineSpacing)
        view.textStorage?.setAttributedString(ns)
    }

    private func applyTypingAttributes(to view: NSTextView) {
        // NB: don't write `view.font =` here. NSTextView's font setter applies across the
        // entire text storage, which would stomp the per-range bold/italic font traits
        // that `InlineMarksKit.toggleMark` writes. The base font is already applied per-
        // range by `loadAttributedString` (via toNS).
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        let font = InlineMarksKit.interFont(size: fontSize, bold: bold, italic: false)
        view.defaultParagraphStyle = style
        view.typingAttributes = [
            .font: font,
            .paragraphStyle: style,
            .foregroundColor: NotionStyle.platformForeground
        ]
    }

    nonisolated static func resolveNSFont(size: CGFloat, bold: Bool) -> NSFont {
        InlineMarksKit.interFont(size: size, bold: bold, italic: false)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacBlockTextEditor
        var lastFontSize: CGFloat?
        var lastBold: Bool?
        var lastLineSpacing: CGFloat?
        init(_ parent: MacBlockTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let isComposing = tv.hasMarkedText()
            let plain = tv.string
            if !isComposing {
                let cursor = tv.selectedRange().location
                if let result = detectPrefixAutotransform(text: AttributedString(plain), cursor: cursor) {
                    parent.onAutotransform(result.transform, result.remainingText)
                    return
                }
            }
            // Register a text-change undo against the document-level manager BEFORE
            // mutating the binding. `parent.text` is the previous text (the binding
            // hasn't been updated yet for this keystroke). The controller's coalescing
            // folds rapid consecutive keystrokes into a single ~1s "Type" entry, while
            // the entry itself references only the model — no NSTextView in sight.
            parent.documentUndoController?
                .registerTextChange(blockID: parent.blockID, oldText: parent.text)
            // Convert NSAttributedString → model AttributedString and push to binding.
            // The BlockRow setter dedupes via `attributedStringMarksEqual` so we don't
            // chunk autosave debounces on no-op keystrokes.
            let nsAttr = tv.textStorage ?? NSTextStorage()
            parent.text = InlineMarksKit.toModel(nsAttr)
            reportMentionTrigger(in: tv, composing: isComposing)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            // Cursor moved without a text change — re-evaluate the mention trigger so
            // arrow-keying out of the @-region dismisses the popover.
            MainActor.assumeIsolated {
                reportMentionTrigger(in: tv, composing: tv.hasMarkedText())
            }
        }

        @MainActor
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
            // clicking into block B should not merge into one undo entry.
            parent.documentUndoController?.breakTextCoalescing()
            parent.onFocusChange(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.documentUndoController?.breakTextCoalescing()
            parent.onFocusChange(false)
        }
    }
}

/// NSTextView subclass that intercepts the M4 key set before NSTextView's default handling.
/// Returns YES from `performKeyEquivalent(_:)` and short-circuits `keyDown(_:)` for the
/// keys our coordinator wants to consume.
final class ContainedTextView: NSTextView {
    weak var coordinator: MacBlockTextEditor.Coordinator?
    /// Set by `updateNSView` whenever the SwiftUI focus state targets this block. Picked up
    /// in `viewDidMoveToWindow` so the second-chance focus grab works on initial mount.
    var wantsFocus: Bool = false
    /// If non-nil, the cursor is placed at this point (in the view's local coords) on
    /// initial focus. Cleared after consumption so subsequent focus grabs (e.g. coming
    /// back from another block) seek to end instead.
    var pendingInitialCursorPoint: CGPoint?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if wantsFocus, let window = window, window.firstResponder !== self {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                window.makeFirstResponder(self)
                self.applyPendingCursorPositionOrSeekToEnd()
            }
        }
    }

    /// Applies `pendingInitialCursorPoint` if set (placing the cursor at the click), or
    /// falls back to seeking the cursor to the end of the text. Clears the pending point
    /// after applying.
    func applyPendingCursorPositionOrSeekToEnd() {
        if let point = pendingInitialCursorPoint {
            pendingInitialCursorPoint = nil
            let charIndex = characterIndexForInsertion(at: point)
            setSelectedRange(NSRange(location: charIndex, length: 0))
        } else {
            setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        }
    }

    override func keyDown(with event: NSEvent) {
        if let onKey = coordinator?.parent.onKey {
            // While the mention popover is open, intercept menu-nav keys before the
            // editor's normal handling so PageView can drive selection / commit.
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
            switch event.keyCode {
            case 36, 76: // Return, numpad Enter
                let cursor = (selectedRange().location)
                if onKey(.enter(cursorOffset: cursor)) == .handled { return }
            case 51: // Delete (backspace)
                if string.isEmpty {
                    if onKey(.backspaceAtStart) == .handled { return }
                }
            case 48: // Tab
                let shift = event.modifierFlags.contains(.shift)
                if onKey(shift ? .shiftTab : .tab) == .handled { return }
            case 53: // Escape
                if onKey(.escape) == .handled { return }
            case 40: // K
                if event.modifierFlags.contains(.command) {
                    let selectedText: String?
                    let range = selectedRange()
                    if range.length > 0, let textRange = Range(range, in: string) {
                        selectedText = String(string[textRange])
                    } else {
                        selectedText = nil
                    }
                    if onKey(.cmdK(selectedText: selectedText)) == .handled { return }
                }
            case 33: // [ — Cmd-[ → navigate back
                if event.modifierFlags.contains(.command) {
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
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    /// Toggles an inline mark on the current selection. No-op if the selection is empty —
    /// pre-typing toggles via `typingAttributes` aren't wired yet (M6 follow-up).
    private func toggleInlineMark(_ mark: InlineMark) {
        guard let storage = textStorage,
              let parent = coordinator?.parent else { return }
        let range = selectedRange()
        guard range.length > 0 else { return }
        InlineMarksKit.toggleMark(mark, on: range, in: storage, baseFontSize: parent.fontSize, baseBold: parent.bold)
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
        window?.makeFirstResponder(nil)
        if let onKey = coordinator?.parent.onKey, onKey(.escape) == .handled {
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

    func toggleMark(_ mark: InlineMark) {
        guard let tv = textView else { return }
        let range = tv.selectedRange
        guard range.length > 0 else {
            // Pre-typing toggles (Cmd-B with no selection biasing typingAttributes)
            // aren't wired yet — same gap as macOS, deferred to the M6 follow-up.
            return
        }
        let storage = tv.textStorage
        InlineMarksKit.toggleMark(mark, on: range, in: storage, baseFontSize: fontSize, baseBold: bold)
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
    let onMentionTriggerChange: (MentionTrigger?) -> Void
    let mentionActive: Bool
    let initialCursorPoint: CGPoint?
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
        tv.pendingInitialCursorPoint = initialCursorPoint
        bridge.textView = tv
        bridge.fontSize = fontSize
        bridge.bold = bold
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
        // Only re-sync textStorage from the binding when its plain content has drifted
        // out of sync — attribute changes that originated inside this editor were
        // already pushed back via the delegate, so re-loading would clobber the cursor.
        let storedPlain = tv.textStorage.string
        let bindingPlain = String(text.characters)
        if storedPlain != bindingPlain {
            loadAttributedString(into: tv)
        }
        applyTypingAttributes(to: tv)
        bridge.textView = tv
        bridge.fontSize = fontSize
        bridge.bold = bold

        // Refresh the accessory bar's closures so they capture the latest
        // `onKey` / `bridge` references — both are recreated on every parent
        // re-render.
        context.coordinator.accessoryHost?.rootView = makeAccessoryBar(for: tv)

        tv.wantsFocus = isFocused
        if isFocused, tv.window != nil, !tv.isFirstResponder {
            // Already in the window hierarchy — grab focus synchronously so the
            // keyboard transfer between rows doesn't dismiss/re-show. UIKit only
            // keeps the keyboard alive when a new first responder takes over
            // within the same runloop as the previous one resigning.
            _ = tv.becomeFirstResponder()
            tv.applyPendingCursorPositionOrSeekToEnd()
        }
    }

    private func makeAccessoryBar(for tv: ContainedTextViewIOS) -> KeyboardAccessoryBar {
        KeyboardAccessoryBar(
            onShiftTab: { _ = onKey(.shiftTab) },
            onTab: { _ = onKey(.tab) },
            onToggleMark: { mark in bridge.toggleMark(mark) },
            onCmdK: {
                let range = tv.selectedRange
                let selected: String? = {
                    guard range.length > 0 else { return nil }
                    let ns = tv.textStorage.string as NSString
                    guard range.location >= 0,
                          range.location + range.length <= ns.length else { return nil }
                    return ns.substring(with: range)
                }()
                _ = onKey(.cmdK(selectedText: selected))
            },
            onDismiss: {
                tv.resignFirstResponder()
                _ = onKey(.escape)
            }
        )
    }

    private func loadAttributedString(into tv: ContainedTextViewIOS) {
        let ns = InlineMarksKit.toNS(text, baseFontSize: fontSize, baseBold: bold, lineSpacing: lineSpacing)
        tv.textStorage.setAttributedString(ns)
    }

    private func applyTypingAttributes(to tv: ContainedTextViewIOS) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        let font = Self.resolveUIFont(size: fontSize, bold: bold)
        tv.font = font
        tv.typingAttributes = [
            .font: font,
            .paragraphStyle: style,
            .foregroundColor: NotionStyle.platformForeground
        ]
    }

    nonisolated static func resolveUIFont(size: CGFloat, bold: Bool) -> UIFont {
        InlineMarksKit.interFont(size: size, bold: bold, italic: false)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: IOSBlockTextEditorView
        /// Retains the SwiftUI accessory bar hosted as the UITextView's
        /// `inputAccessoryView`. UIKit retains the view itself but the
        /// hosting controller needs an owner with the right lifecycle —
        /// the Coordinator lives as long as the Representable does.
        var accessoryHost: UIHostingController<KeyboardAccessoryBar>?

        init(parent: IOSBlockTextEditorView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            // IME composition: skip autotransform but still push the binding so
            // SwiftUI redraws the in-progress text.
            let composing = (textView.markedTextRange != nil)
            let plain = textView.text ?? ""

            if !composing {
                let cursor = textView.selectedRange.location
                if let result = detectPrefixAutotransform(text: AttributedString(plain), cursor: cursor) {
                    parent.onAutotransform(result.transform, result.remainingText)
                    return
                }
            }
            // Register the BEFORE state with the document undo manager — same
            // pattern as the macOS coordinator.
            parent.documentUndoController?
                .registerTextChange(blockID: parent.blockID, oldText: parent.text)
            let model = InlineMarksKit.toModel(textView.textStorage)
            parent.text = model
            reportMentionTrigger(in: textView, composing: composing)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            reportMentionTrigger(in: textView, composing: textView.markedTextRange != nil)
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
            parent.documentUndoController?.breakTextCoalescing()
            parent.onFocusChange(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.documentUndoController?.breakTextCoalescing()
            parent.onFocusChange(false)
        }
    }
}

/// UITextView subclass that intercepts soft-keyboard delete and return so they
/// can be handled at the page level (block split / block delete-or-collapse)
/// rather than inserting characters into the row.
final class ContainedTextViewIOS: UITextView {
    weak var coordinator: IOSBlockTextEditorView.Coordinator?
    /// If non-nil, the cursor is placed at this point (in the view's local coords)
    /// on initial focus. Cleared after consumption so subsequent focus grabs
    /// fall through to seek-to-end.
    var pendingInitialCursorPoint: CGPoint?
    /// Set by `updateUIView` whenever this row should be the active editor. Picked
    /// up in `didMoveToWindow` so the second-chance focus grab works on initial
    /// mount — at the time `updateUIView` runs, `window` may still be nil and
    /// `becomeFirstResponder` would silently no-op.
    var wantsFocus: Bool = false

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
        // Empty-block backspace fires `.backspaceAtStart`. The page-level handler
        // converts the row to a paragraph (first press on a non-paragraph) or
        // removes it (second press / paragraph case).
        let isEmpty = (text ?? "").isEmpty
        if isEmpty,
           let coordinator,
           coordinator.parent.onKey(.backspaceAtStart) == .handled {
            return
        }
        super.deleteBackward()
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
            // Soft-keyboard return: split the block at the current cursor.
            let cursor = selectedRange.location
            if coordinator.parent.onKey(.enter(cursorOffset: cursor)) == .handled {
                return
            }
        }
        super.insertText(text)
    }

    /// Mirrors the macOS helper — places the cursor at a captured tap point on
    /// initial focus, or seeks to end if there's no pending point.
    func applyPendingCursorPositionOrSeekToEnd() {
        if let point = pendingInitialCursorPoint {
            pendingInitialCursorPoint = nil
            // Force layout: at didMoveToWindow / first updateUIView UITextView's
            // text container hasn't necessarily run layout, and `closestPosition`
            // returns the doc-end position when the layout is empty. Without this
            // the caret silently snaps to end on every tap-to-edit.
            layoutIfNeeded()
            layoutManager.ensureLayout(for: textContainer)
            if let position = closestPosition(to: point) {
                let offset = self.offset(from: beginningOfDocument, to: position)
                selectedRange = NSRange(location: offset, length: 0)
                return
            }
        }
        let end = (text as NSString?)?.length ?? 0
        selectedRange = NSRange(location: end, length: 0)
    }
}

#endif
