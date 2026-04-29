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
    @Binding var text: String
    let font: Font
    let fontSize: CGFloat
    let bold: Bool
    let lineSpacing: CGFloat
    @FocusState.Binding var focused: BlockID?
    let blockID: BlockID
    let onKey: (BlockKey) -> KeyPress.Result
    let onAutotransform: (BlockTransform, AttributedString) -> Void

    public init(
        text: Binding<String>,
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
                // iOS doesn't expose cursor offset from `.onChange`, so we approximate with
                // `count`. That's correct for the typical typing-prefix flow (cursor is at
                // the end after each keystroke). Pasted longer text won't fire the trigger
                // because cursor would not equal the trigger's length.
                if let result = detectPrefixAutotransform(text: AttributedString(newValue), cursor: newValue.count) {
                    onAutotransform(result.transform, result.remainingText)
                }
            }
            .onKeyPress(keys: [.return, .delete, .tab, .escape, KeyEquivalent("k")]) { press in
                if press.key == KeyEquivalent("k") {
                    if press.modifiers.contains(.command) { return onKey(.cmdK) }
                    return .ignored
                }
                switch press.key {
                case .return: return onKey(.enter(cursorOffset: text.count))
                case .delete: return text.isEmpty ? onKey(.backspaceAtStart) : .ignored
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
    @Binding var text: String
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
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.string = text
        // Seed wantsFocus from the initial `isFocused` so that `viewDidMoveToWindow` —
        // which can fire BEFORE `updateNSView` — has the right signal to take focus.
        view.wantsFocus = isFocused
        applyFont(to: view)
        return view
    }

    func updateNSView(_ view: ContainedTextView, context: Context) {
        // Keep coordinator's parent in sync (closures capture by value).
        context.coordinator.parent = self
        if view.string != text {
            view.string = text
        }
        applyFont(to: view)
        // Track desired focus on the view itself so `viewDidMoveToWindow` can grab focus
        // *after* the view is added to a window. Without this, a Return-to-edit transition
        // can hit `updateNSView` before the view is in the window, the dispatched
        // makeFirstResponder runs against window=nil, and focus silently fails to attach.
        view.wantsFocus = isFocused
        if isFocused {
            // First-chance attempt: if we're already in a window, take focus now.
            if let window = view.window, window.firstResponder !== view {
                DispatchQueue.main.async {
                    window.makeFirstResponder(view)
                    // Move cursor to end so typing continues from where the user left off.
                    view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
                }
            }
        }
    }

    private func applyFont(to view: NSTextView) {
        view.font = nsFont()
        // Reset paragraph style for line spacing match.
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        view.defaultParagraphStyle = style
        if !view.string.isEmpty {
            // Apply paragraph style + font over existing content (string assignment loses attrs).
            let range = NSRange(location: 0, length: (view.string as NSString).length)
            view.textStorage?.setAttributes([
                .font: nsFont(),
                .paragraphStyle: style,
                .foregroundColor: NSColor(NotionStyle.foreground)
            ], range: range)
        }
    }

    private func nsFont() -> NSFont {
        Self.resolveNSFont(size: fontSize, bold: bold)
    }

    nonisolated static func resolveNSFont(size: CGFloat, bold: Bool) -> NSFont {
        // Inter Variable is registered globally via FontRegistration; resolve by family name.
        let weight: NSFont.Weight = bold ? .bold : .regular
        if let descriptor = NSFontDescriptor(fontAttributes: [
            .family: "Inter",
            .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue]
        ]) as NSFontDescriptor?,
           let font = NSFont(descriptor: descriptor, size: size) {
            return font
        }
        return NSFont.systemFont(ofSize: size, weight: weight)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacBlockTextEditor
        init(_ parent: MacBlockTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            // IME composition fires textDidChange on every marked-text update. Skip
            // autotransform detection there — typing `# ` mid-CJK-composition must not
            // be consumed — and just propagate the current string through to the binding.
            let isComposing = tv.hasMarkedText()
            let new = tv.string
            if !isComposing {
                let cursor = tv.selectedRange().location
                if let result = detectPrefixAutotransform(text: AttributedString(new), cursor: cursor) {
                    parent.onAutotransform(result.transform, result.remainingText)
                    // Don't push the trigger characters to the binding — the row is about
                    // to be replaced wholesale by PageView's apply-transform handler.
                    return
                }
            }
            if new != parent.text {
                parent.text = new
            }
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
            default:
                break
            }
        }
        super.keyDown(with: event)
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
