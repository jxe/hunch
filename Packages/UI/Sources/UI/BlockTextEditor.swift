import SwiftUI
import Core
#if canImport(AppKit)
import AppKit
#endif

/// Block-level keyboard events the page-level handler reacts to.
public enum BlockKey: Sendable, Equatable {
    case enter(cursorOffset: Int)
    case backspaceAtStart
    case tab
    case shiftTab
    case escape
    case cmdK
}

/// A single-block text editor.
///
/// On macOS we wrap an NSTextView directly via `NSViewRepresentable`. SwiftUI's stock
/// `TextEditor` ships with `textContainerInset = (5, 0)` and `lineFragmentPadding = 5`
/// baked in — those nudge the text right by 5pt and down by ~5pt relative to a sibling
/// read-only `Text`, which breaks `.firstTextBaseline` alignment with list markers and
/// throws the typography off. Going to NSTextView lets us zero those out.
///
/// On iOS we fall back to plain `TextEditor` for now (we don't have iOS verification in
/// scope for M3 and UITextView's insets are different anyway).
public struct BlockTextEditor: View {
    @Binding var text: AttributedString
    let font: Font
    let fontSize: CGFloat
    let bold: Bool
    let lineSpacing: CGFloat
    @FocusState.Binding var focused: BlockID?
    let blockID: BlockID
    let onKey: (BlockKey) -> KeyPress.Result
    let onAutotransform: (BlockTransform, AttributedString) -> Void

    public init(
        text: Binding<AttributedString>,
        font: Font,
        fontSize: CGFloat = 16,
        bold: Bool = false,
        lineSpacing: CGFloat,
        focused: FocusState<BlockID?>.Binding,
        blockID: BlockID,
        onKey: @escaping (BlockKey) -> KeyPress.Result,
        onAutotransform: @escaping (BlockTransform, AttributedString) -> Void = { _, _ in }
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
            onAutotransform: onAutotransform
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
        TextEditor(text: $text)
            .font(font)
            .lineSpacing(lineSpacing)
            .focused($focused, equals: blockID)
            .onAppear {
                focused = blockID
            }
            .onChange(of: text) { _, newValue in
                let plainCount = newValue.characters.count
                if let result = detectPrefixAutotransform(text: newValue, cursor: plainCount) {
                    onAutotransform(result.transform, result.remainingText)
                }
            }
            .onKeyPress(keys: [.return, .delete, .tab, .escape, KeyEquivalent("k")]) { press in
                if press.key == KeyEquivalent("k") {
                    if press.modifiers.contains(.command) { return onKey(.cmdK) }
                    return .ignored
                }
                let plainCount = text.characters.count
                switch press.key {
                case .return: return onKey(.enter(cursorOffset: plainCount))
                case .delete: return plainCount == 0 ? onKey(.backspaceAtStart) : .ignored
                case .tab: return onKey(press.modifiers.contains(.shift) ? .shiftTab : .tab)
                case .escape: return onKey(.escape)
                default: return .ignored
                }
            }
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

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> ContainedTextView {
        let view = ContainedTextView()
        view.coordinator = context.coordinator
        view.delegate = context.coordinator
        view.isRichText = true
        view.allowsUndo = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        loadAttributedString(into: view)
        applyTypingAttributes(to: view)
        view.wantsFocus = isFocused
        return view
    }

    func updateNSView(_ view: ContainedTextView, context: Context) {
        context.coordinator.parent = self
        // Only re-sync textStorage from the binding when its plain content has drifted
        // out of sync — attribute changes that originated inside this editor were already
        // pushed back via textDidChange, so re-loading would clobber the cursor.
        let storedPlain = view.textStorage?.string ?? ""
        let bindingPlain = String(text.characters)
        if storedPlain != bindingPlain {
            loadAttributedString(into: view)
        }
        applyTypingAttributes(to: view)
        view.wantsFocus = isFocused
        if isFocused {
            if let window = view.window, window.firstResponder !== view {
                DispatchQueue.main.async {
                    window.makeFirstResponder(view)
                    view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
                }
            }
        }
    }

    private func loadAttributedString(into view: ContainedTextView) {
        let ns = InlineMarksNSKit.toNS(text, baseFontSize: fontSize, baseBold: bold, lineSpacing: lineSpacing)
        view.textStorage?.setAttributedString(ns)
    }

    private func applyTypingAttributes(to view: NSTextView) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        view.defaultParagraphStyle = style
        view.typingAttributes = [
            .font: InlineMarksNSKit.interFont(size: fontSize, bold: bold, italic: false),
            .paragraphStyle: style,
            .foregroundColor: NSColor(NotionStyle.foreground)
        ]
    }

    nonisolated static func resolveNSFont(size: CGFloat, bold: Bool) -> NSFont {
        InlineMarksNSKit.interFont(size: size, bold: bold, italic: false)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacBlockTextEditor
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
            // Convert NSAttributedString → model AttributedString and push to binding.
            // The BlockRow setter dedupes via `attributedStringMarksEqual` so we don't
            // chunk autosave debounces on no-op keystrokes.
            let nsAttr = tv.textStorage ?? NSTextStorage()
            parent.text = InlineMarksNSKit.toModel(nsAttr)
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.onFocusChange(true)
        }

        func textDidEndEditing(_ notification: Notification) {
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if wantsFocus, let window = window, window.firstResponder !== self {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                window.makeFirstResponder(self)
                self.setSelectedRange(NSRange(location: (self.string as NSString).length, length: 0))
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        if let onKey = coordinator?.parent.onKey {
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
                    if onKey(.cmdK) == .handled { return }
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
        InlineMarksNSKit.toggleMark(mark, on: range, in: storage, baseFontSize: parent.fontSize, baseBold: parent.bold)
        didChangeText()
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
        window?.makeFirstResponder(nil)
        if let onKey = coordinator?.parent.onKey, onKey(.escape) == .handled {
            return
        }
        super.cancelOperation(sender)
    }
}

#endif
