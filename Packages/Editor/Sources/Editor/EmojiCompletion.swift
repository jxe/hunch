import EmojiKit
import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// An active `:query` immediately before the caret. The range is expressed in
/// UTF-16 units so it can be replaced directly in NSTextView/UITextView text.
struct EmojiTrigger: Equatable, Sendable {
    let nsRange: NSRange
    let query: String

    init(nsRange: NSRange, query: String) {
        self.nsRange = nsRange
        self.query = query
    }
}

/// The one inline completion the native editor should currently present.
enum InlineCompletionTrigger: Equatable, Sendable {
    case mention(MentionTrigger)
    case emoji(EmojiTrigger)
}

/// Editor-owned projection of EmojiKit data. Keeping this small value at the
/// overlay boundary avoids exposing a third-party model through EditorHost.
struct EmojiSuggestion: Equatable, Identifiable, Sendable {
    var id: String { character }
    let character: String
    let name: String

    init(character: String, name: String) {
        self.character = character
        self.name = name
    }
}

/// Detect the active completion at `cursor`. Mentions keep their established
/// multi-word behavior; emoji shortcodes are a single token and therefore end
/// at whitespace.
func detectInlineCompletionTrigger(plain: String, cursor: Int) -> InlineCompletionTrigger? {
    if let emoji = detectEmojiTrigger(plain: plain, cursor: cursor) {
        return .emoji(emoji)
    }
    return detectMentionTrigger(plain: plain, cursor: cursor).map(InlineCompletionTrigger.mention)
}

func detectEmojiTrigger(plain: String, cursor: Int) -> EmojiTrigger? {
    let ns = plain as NSString
    guard cursor >= 0, cursor <= ns.length else { return nil }

    var i = cursor
    while i > 0 {
        let previous = ns.character(at: i - 1)
        guard let scalar = Unicode.Scalar(previous) else { return nil }
        if scalar == ":" {
            let colonIndex = i - 1
            if colonIndex > 0 {
                let before = ns.character(at: colonIndex - 1)
                guard let beforeScalar = Unicode.Scalar(before),
                      isEmojiTriggerBoundary(beforeScalar) else {
                    return nil
                }
            }
            let queryRange = NSRange(location: i, length: cursor - i)
            return EmojiTrigger(
                nsRange: NSRange(location: colonIndex, length: cursor - colonIndex),
                query: ns.substring(with: queryRange)
            )
        }
        if CharacterSet.whitespacesAndNewlines.contains(scalar) { return nil }
        i -= 1
    }
    return nil
}

func replacingEmojiTrigger(
    in text: AttributedString,
    trigger: EmojiTrigger,
    with character: String
) -> (text: AttributedString, cursor: Int)? {
    let plain = String(text.characters)
    let startUTF16 = trigger.nsRange.location
    let endUTF16 = startUTF16 + trigger.nsRange.length
    guard let start = characterOffset(in: plain, utf16Offset: startUTF16),
          let end = characterOffset(in: plain, utf16Offset: endUTF16),
          start <= end,
          end <= text.characters.count else { return nil }

    let prefix = attributedSlice(text, 0..<start)
    let inserted = AttributedString(character)
    let suffix = attributedSlice(text, end..<text.characters.count)
    return (prefix + inserted + suffix, (prefix + inserted).characters.count)
}

private func characterOffset(in plain: String, utf16Offset: Int) -> Int? {
    guard utf16Offset >= 0, utf16Offset <= plain.utf16.count else { return nil }
    let utf16Index = plain.utf16.index(plain.utf16.startIndex, offsetBy: utf16Offset)
    guard let index = String.Index(utf16Index, within: plain) else { return nil }
    return plain.distance(from: plain.startIndex, to: index)
}

private func attributedSlice(_ text: AttributedString, _ bounds: Range<Int>) -> AttributedString {
    let lower = text.index(text.startIndex, offsetByCharacters: bounds.lowerBound)
    let upper = text.index(text.startIndex, offsetByCharacters: bounds.upperBound)
    return AttributedString(text[lower..<upper])
}

private func isEmojiTriggerBoundary(_ scalar: Unicode.Scalar) -> Bool {
    CharacterSet.whitespacesAndNewlines.contains(scalar)
        || CharacterSet.punctuationCharacters.contains(scalar)
}

@MainActor
func emojiSuggestions(matching query: String, limit: Int = 8, locale: Locale = .current) -> [EmojiSuggestion] {
    let matches = Emoji.all.matching(query, in: locale)
    return matches.prefix(limit).map {
        EmojiSuggestion(character: $0.char, name: $0.localizedName(in: locale))
    }
}

@MainActor
func registerEmojiSelection(_ character: String) {
    let emoji = Emoji(character)
    EmojiCategory.Persisted.frequent.addEmoji(emoji)
    EmojiCategory.Persisted.recent.addEmoji(emoji)
}

/// Replace a leading page-icon emoji, or prepend one to an ordinary title.
/// The result always has exactly one separator between icon and visible title.
public func pageTitle(_ title: String, settingEmoji emoji: String) -> String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return emoji }
    if let first = trimmed.first, isEmojiCharacter(first) {
        let rest = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? emoji : "\(emoji) \(rest)"
    }
    return "\(emoji) \(trimmed)"
}

func isEmojiCharacter(_ character: Character) -> Bool {
    character.unicodeScalars.contains {
        $0.properties.isEmojiPresentation || ($0.properties.isEmoji && !$0.isASCII)
    }
}

/// Pure hit-test for the subpage marker column. Coordinates and row frame are
/// in the same page space; indentation moves the marker column right by 24pt.
func hitsSubpageIconColumn(point: CGPoint, rowFrame: CGRect, depth: Int, theme: EditorTheme = .default) -> Bool {
    let localX = point.x - rowFrame.minX
    return hitsSubpageIconColumn(localX: localX, depth: depth, theme: theme)
        && point.y >= rowFrame.minY && point.y <= rowFrame.maxY
}

func hitsSubpageIconColumn(localX: CGFloat, depth: Int, theme: EditorTheme = .default) -> Bool {
    let minX = CGFloat(depth) * theme.indentStep
    return localX >= minX && localX <= minX + theme.bulletMarkerColumnWidth
}

/// Searchable EmojiKit surface shared by page-icon picking.
struct EditorEmojiPicker: View {
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var category: EmojiCategory?
    @State private var query = ""
    @State private var selection: Emoji.GridSelection?
    @FocusState private var focus: FocusTarget?

    private enum FocusTarget: Hashable {
        case search
        case grid
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search emoji", text: $query)
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .search)
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear emoji search")
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .padding(10)

                Divider()

                EmojiGridScrollView(
                    axis: .vertical,
                    category: $category,
                    selection: $selection,
                    query: query,
                    action: { onSelect($0.char) },
                    sectionTitle: { $0.view },
                    gridItem: { $0.view }
                )
                .focused($focus, equals: .grid)
            }
            .navigationTitle("Emoji")
        }
        .emojiGridStyle(.medium)
        .frame(idealWidth: 340, idealHeight: 420)
        #if os(macOS)
        .background {
            PopoverVisibilityReader {
                focus = .search
            }
        }
        #endif
        .onChange(of: query) { _, _ in
            selectFirstVisibleEmoji()
        }
        .onKeyPress(keys: [.upArrow, .downArrow, .return, .escape]) { press in
            handleSearchKeyPress(press)
        }
        .task {
            selectFirstVisibleEmoji()
            #if !os(macOS)
            focus = .search
            #endif
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    private func handleSearchKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard press.phase == .down, focus == .search else { return .ignored }
        switch press.key {
        case .upArrow, .downArrow:
            if selection?.emoji == nil { selectFirstVisibleEmoji() }
            focus = .grid
            return .handled
        case .return:
            guard let emoji = selection?.emoji ?? firstVisibleSelection()?.emoji else {
                return .handled
            }
            registerEmojiSelection(emoji.char)
            onSelect(emoji.char)
            return .handled
        case .escape:
            dismiss()
            return .handled
        default:
            return .ignored
        }
    }

    private func selectFirstVisibleEmoji() {
        selection = firstVisibleSelection()
        category = selection?.category
    }

    private func firstVisibleSelection() -> Emoji.GridSelection? {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let search = EmojiCategory.search(query: query)
            guard let emoji = search.emojis.first else { return nil }
            return .init(emoji: emoji, category: search)
        }
        guard let firstCategory = [EmojiCategory].standardGrid.first(where: { !$0.emojis.isEmpty }),
              let emoji = firstCategory.emojis.first else { return nil }
        return .init(emoji: emoji, category: firstCategory)
    }
}

#if os(macOS)
/// Reports only after the containing NSPopover window is actually visible.
/// Moving focus any earlier can make AppKit's remote completion-list view key
/// the not-yet-visible popover window and crash in NSRemoteView.
private struct PopoverVisibilityReader: NSViewRepresentable {
    let onVisible: @MainActor () -> Void

    func makeNSView(context: Context) -> VisibilityView {
        VisibilityView(onVisible: onVisible)
    }

    func updateNSView(_ view: VisibilityView, context: Context) {
        view.onVisible = onVisible
        view.waitUntilVisible()
    }

    @MainActor
    final class VisibilityView: NSView {
        var onVisible: @MainActor () -> Void
        private var didReportVisible = false

        init(onVisible: @escaping @MainActor () -> Void) {
            self.onVisible = onVisible
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            didReportVisible = false
            waitUntilVisible()
        }

        func waitUntilVisible() {
            guard !didReportVisible, window != nil else { return }
            guard window?.isVisible == true else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                    self?.waitUntilVisible()
                }
                return
            }
            didReportVisible = true
            // Run after the order-on-screen transaction that flipped isVisible.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window?.isVisible == true else { return }
                self.onVisible()
            }
        }
    }
}
#endif
