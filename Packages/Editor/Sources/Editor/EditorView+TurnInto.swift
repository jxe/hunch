import SwiftUI
#if os(iOS)
import GameController
#endif

// MARK: - Turn Into menu / block action popover
//
// The 3-column grid that opens via Cmd-/ in nav mode (macOS), drag-handle tap
// (macOS), or leading row swipe (iOS). Houses Turn Into (block-type swap),
// Copy, and Indent/Outdent. The conversion methods (`convert`, `convertSingle`,
// `convertBlockToSubpage`, `convertBlockToTemplate`, `convertSubpage`,
// `expandSubpage`) live here too — they're the actions the menu fires.

enum BlockTurnInto: CaseIterable {
    // Declaration order is no longer the source of truth for menu order —
    // `BlockTurnInto.orderedGroups` defines the on-screen ordering with category
    // dividers between groups. Keep cases together by family for readability.
    case paragraph
    case page
    case bullet
    case numbered
    case todo
    case toggle
    case heading1
    case heading2
    case heading3
    case divider
    case template

    enum Category: CaseIterable {
        case basic
        case lists
        case headings
        case structural
    }

    var category: Category {
        switch self {
        case .paragraph, .page: return .basic
        case .bullet, .numbered, .todo, .toggle: return .lists
        case .heading1, .heading2, .heading3: return .headings
        case .divider, .template: return .structural
        }
    }

    /// Display order: members of each category in the order they appear inside
    /// `BlockTurnInto.allCases`. Drives the horizontal turn-into row.
    static var orderedGroups: [(Category, [BlockTurnInto])] {
        Category.allCases.map { category in
            (category, BlockTurnInto.allCases.filter { $0.category == category })
        }
    }

    var title: String {
        switch self {
        case .paragraph: return "Text"
        case .bullet: return "Bullet"
        case .numbered: return "Number"
        case .todo: return "To-do"
        case .toggle: return "Toggle"
        case .template: return "Template"
        case .heading1: return "H1"
        case .heading2: return "H2"
        case .heading3: return "H3"
        case .page: return "Page"
        case .divider: return "Divider"
        }
    }

    var systemImage: String {
        switch self {
        case .paragraph: return "text.alignleft"
        case .bullet: return "list.bullet"
        case .numbered: return "list.number"
        case .todo: return "checkmark.square"
        case .toggle: return "chevron.right"
        case .template: return "plus.square.on.square"
        case .heading1: return "h.square"
        case .heading2: return "h.square"
        case .heading3: return "h.square"
        case .page: return "doc"
        case .divider: return "minus"
        }
    }

    var keyboardShortcut: KeyEquivalent {
        switch self {
        case .paragraph: return "p"
        case .bullet: return "b"
        case .numbered: return "n"
        case .todo: return "t"
        case .toggle: return ">"
        case .template: return "m"
        case .heading1: return "1"
        case .heading2: return "2"
        case .heading3: return "3"
        case .page: return "s"
        case .divider: return "-"
        }
    }
}

struct BlockIndentAction: Hashable {
    let delta: Int
    let title: String
    let systemImage: String
    let keyboardShortcut: KeyEquivalent
}

extension EditorView {
    @discardableResult
    func convertBlockToSubpage(blockID: BlockID, preferredTitle: String?) -> KeyPress.Result {
        guard let i = document.index(of: blockID) else { return .ignored }
        let block = document.blocks[i]
        guard !isStructuralBlock(block) else { return .ignored }

        let existingLink = wholeBlockMarkdownLink(in: block.text)
        let title = cleanedTitle(preferredTitle)
            ?? existingLink?.title
            ?? cleanedTitle(String(block.text.characters))
            ?? "Untitled"
        let requestedPath = existingLink?.path

        // The block's indent-descendants (canonical via Document.sectionRange) become the
        // body of the new subpage. The host prepends a title heading + serializes; the
        // editor just hands over the body blocks (or nil when the new page is empty).
        let range = document.sectionRange(of: blockID) ?? (i..<i+1)
        let baseIndent = block.indent
        let descendants = document.blocks[(i + 1)..<range.upperBound].map {
            $0.withIndent($0.indent - (baseIndent + 1))
        }
        let initialContent: [Block]? = descendants.isEmpty ? nil : descendants

        let pageID = onCreateSubpage(title, requestedPath, initialContent)
            ?? requestedPath
            ?? defaultSubpagePath(for: title)

        mutate("Create Subpage") {
            document.blocks.replaceSubrange(range, with: [
                .subpage(id: blockID, title: title, pageID: pageID, indent: baseIndent)
            ])
        }
        DispatchQueue.main.async {
            transferFocus(to: .nav(cursor: blockID))
        }
        return .handled
    }

    @discardableResult
    func expandSubpage(blockID: BlockID) -> KeyPress.Result {
        guard let i = document.index(of: blockID) else { return .ignored }
        guard case .subpage(_, _, let path, let indent) = document.blocks[i] else { return .ignored }
        guard let loaded = onLoadSubpage(path), !loaded.isEmpty else { return .ignored }

        // Shift all loaded blocks by the subpage row's indent so the inlined
        // content sits at the same depth as the link it's replacing.
        let shifted = loaded.map { $0.withIndent($0.indent + indent) }
        mutate("Expand Subpage") {
            document.blocks.replaceSubrange(i..<(i + 1), with: shifted)
        }
        DispatchQueue.main.async {
            if let first = shifted.first {
                setCursor(first.id)
            }
        }
        return .handled
    }

    @discardableResult
    func convert(blockID: BlockID, to target: BlockTurnInto) -> KeyPress.Result {
        convert(blockIDs: menuTargetIDs(anchorID: blockID), to: target)
    }

    @discardableResult
    func convert(blockIDs: [BlockID], to target: BlockTurnInto) -> KeyPress.Result {
        let ids = blockIDs.filter { document.index(of: $0) != nil }
        guard !ids.isEmpty else { return .ignored }
        if ids.count == 1, let id = ids.first {
            return convertSingle(blockID: id, to: target)
        }

        var handled = false
        for id in ids.reversed() {
            if convertSingle(blockID: id, to: target) == .handled {
                handled = true
            }
        }
        if let first = ids.first {
            DispatchQueue.main.async {
                setCursor(first)
            }
        }
        return handled ? .handled : .ignored
    }

    @discardableResult
    fileprivate func convertSingle(blockID: BlockID, to target: BlockTurnInto) -> KeyPress.Result {
        if target == .page {
            return convertBlockToSubpage(blockID: blockID, preferredTitle: nil)
        }
        if target == .template {
            return convertBlockToTemplate(blockID: blockID)
        }
        guard let i = document.index(of: blockID) else { return .ignored }
        let block = document.blocks[i]
        if target == .divider {
            guard canReplaceEmptyBlockWithDivider(block) else { return .ignored }
            mutate("Turn Into") {
                document.blocks[i] = .divider(id: blockID, indent: block.indent)
            }
            state.expandedToggles.remove(blockID)
            state.expandedTemplates.remove(blockID)
            return .handled
        }
        if case .subpage = block {
            return convertSubpage(blockID: blockID, to: target)
        }
        guard let text = textForBlockTypeChange(block) else { return .ignored }

        mutate("Turn Into") {
            document.blocks[i] = blockForTurnInto(target, id: blockID, text: text, indent: block.indent)
        }
        if target == .toggle {
            state.expandedToggles.insert(blockID)
        } else {
            state.expandedToggles.remove(blockID)
        }
        return .handled
    }

    @discardableResult
    fileprivate func convertBlockToTemplate(blockID: BlockID) -> KeyPress.Result {
        guard let i = document.index(of: blockID) else { return .ignored }
        let block = document.blocks[i]
        guard let text = textForBlockTypeChange(block) else { return .ignored }
        let label = cleanedTitle(String(text.characters)) ?? "Template"
        let range = document.sectionRange(of: blockID) ?? (i..<i + 1)
        let hasBody = range.upperBound > i + 1
        let replacement = Block.templateButton(id: blockID, label: label, indent: block.indent)
        let defaultBody = Block.paragraph(text: AttributedString(), indent: block.indent + 1)

        mutate("Turn Into") {
            document.blocks[i] = replacement
            if !hasBody {
                document.blocks.insert(defaultBody, at: i + 1)
            }
        }
        state.expandedToggles.remove(blockID)
        state.expandedTemplates.insert(blockID)
        return .handled
    }

    @discardableResult
    fileprivate func convertSubpage(blockID: BlockID, to target: BlockTurnInto) -> KeyPress.Result {
        guard target != .page else { return .ignored }
        guard let i = document.index(of: blockID) else { return .ignored }
        guard case .subpage(_, let title, let path, let indent) = document.blocks[i] else { return .ignored }
        guard var loaded = onLoadSubpage(path) else { return .ignored }
        if case .heading(_, 1, let leadingText, _) = loaded.first,
           String(leadingText.characters).trimmingCharacters(in: .whitespacesAndNewlines) == title {
            loaded.removeFirst()
        }
        guard onAbsorbSubpage(path) else { return .ignored }

        let body = loaded.map { $0.withIndent($0.indent + indent + 1) }
        let replacement = blockForTurnInto(target, id: blockID, text: AttributedString(title), indent: indent)
        mutate("Turn Into") {
            document.blocks.replaceSubrange(i..<(i + 1), with: [replacement] + body)
        }
        if target == .toggle {
            state.expandedToggles.insert(blockID)
        } else if target == .template {
            state.expandedTemplates.insert(blockID)
        } else {
            state.expandedToggles.remove(blockID)
            state.expandedTemplates.remove(blockID)
        }
        return .handled
    }

    fileprivate func blockForTurnInto(_ target: BlockTurnInto, id: BlockID, text: AttributedString, indent: Int) -> Block {
        switch target {
        case .paragraph:
            return .paragraph(id: id, text: text, indent: indent)
        case .bullet:
            return .bullet(id: id, text: text, indent: indent)
        case .numbered:
            return .numbered(id: id, text: text, indent: indent)
        case .todo:
            return .todo(id: id, text: text, done: false, indent: indent)
        case .toggle:
            return .toggle(id: id, title: text, indent: indent)
        case .template:
            return .templateButton(id: id, label: String(text.characters), indent: indent)
        case .heading1:
            return .heading(id: id, level: 1, text: text, indent: indent)
        case .heading2:
            return .heading(id: id, level: 2, text: text, indent: indent)
        case .heading3:
            return .heading(id: id, level: 3, text: text, indent: indent)
        case .divider:
            return .divider(id: id, indent: indent)
        case .page:
            preconditionFailure("Page conversion creates a subpage file before replacing the block")
        }
    }

    /// Extracts the text/title from a block whose type can be swapped for another
    /// text-bearing type without losing content. Returns nil for blocks that don't
    /// carry user text (code/divider/subpage).
    func textForBlockTypeChange(_ block: Block) -> AttributedString? {
        switch block {
        case .paragraph(_, let t, _),
             .heading(_, _, let t, _),
             .bullet(_, let t, _),
             .numbered(_, let t, _),
             .quote(_, let t, _),
             .toggle(_, let t, _):
            return t
        case .templateButton(_, let label, _):
            return AttributedString(label)
        case .todo(_, let t, _, _):
            return t
        case .code, .divider, .subpage, .image:
            return nil
        }
    }

    fileprivate func canReplaceEmptyBlockWithDivider(_ block: Block) -> Bool {
        switch block {
        case .paragraph(_, let text, _),
             .heading(_, _, let text, _),
             .bullet(_, let text, _),
             .numbered(_, let text, _),
             .todo(_, let text, _, _),
             .quote(_, let text, _),
             .toggle(_, let text, _):
            return String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .templateButton(_, let label, _):
            return label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .code(_, let source, _, _):
            return source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .divider, .subpage, .image:
            return false
        }
    }

    @ViewBuilder
    func blockActionMenuContent(for blockID: BlockID) -> some View {
        let targetIDs = menuTargetIDs(anchorID: blockID)
        let targetIndices = targetIDs.compactMap { document.index(of: $0) }
        let targetBlocks = targetIndices.map { document.blocks[$0] }
        if !targetBlocks.isEmpty {
            let availableTargets = Set(turnIntoTargets(for: targetBlocks))
            let selectedTarget = selectedTurnIntoTarget(for: targetBlocks)
            let visibleGroups: [(BlockTurnInto.Category, [BlockTurnInto])] = BlockTurnInto.orderedGroups
                .map { ($0.0, $0.1.filter { availableTargets.contains($0) || $0 == selectedTarget }) }
                .filter { !$0.1.isEmpty }
            let indentTargets = indentActions(for: targetIndices)
            VStack(alignment: .leading, spacing: 8) {
                Button("Close") {
                    actionSheet = nil
                }
                .keyboardShortcut(.escape, modifiers: [])
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(visibleGroups.enumerated()), id: \.offset) { idx, group in
                            if idx > 0 {
                                blockMenuGroupDivider()
                            }
                            ForEach(group.1, id: \.self) { target in
                                compactMenuButton(
                                    title: target.title,
                                    systemImage: target.systemImage,
                                    keyboardShortcut: target.keyboardShortcut,
                                    isSelected: target == selectedTarget
                                ) {
                                    if target != selectedTarget {
                                        _ = convert(blockIDs: targetIDs, to: target)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        compactMenuButton(
                            title: "Copy",
                            systemImage: "doc.on.doc",
                            keyboardShortcut: "c",
                            keyboardShortcutModifiers: .command,
                            keyboardShortcutLabel: "⌘C"
                        ) {
                            _ = copyBlocksToPasteboard(ids: targetIDs)
                        }
                        compactMenuButton(
                            title: "Move to",
                            systemImage: "arrow.right.doc.on.clipboard",
                            keyboardShortcut: "m",
                            keyboardShortcutModifiers: [.command, .shift],
                            keyboardShortcutLabel: "⇧⌘M"
                        ) {
                            onRequestMoveDestination(targetIDs) { pickedPageID in
                                guard let pickedPageID else { return }
                                moveBlocks(ids: targetIDs, intoSubpagePath: pickedPageID)
                            }
                        }
                        ForEach(indentTargets, id: \.self) { action in
                            compactMenuButton(
                                title: action.title,
                                systemImage: action.systemImage,
                                keyboardShortcut: action.keyboardShortcut
                            ) {
                                indentMenuTargets(targetIDs, by: action.delta)
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
            .padding(12)
            .frame(width: 296, alignment: .leading)
        }
    }

    @ViewBuilder
    fileprivate func blockMenuGroupDivider() -> some View {
        Rectangle()
            .fill(NotionStyle.dividerColor)
            .frame(width: 1, height: 28)
            .padding(.horizontal, 2)
    }

    @ViewBuilder
    fileprivate func compactMenuButton(
        title: String,
        systemImage: String,
        keyboardShortcut: KeyEquivalent,
        keyboardShortcutModifiers: EventModifiers = [],
        keyboardShortcutLabel: String? = nil,
        isSelected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            actionSheet = nil
            action()
        } label: {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .semibold))
                        .frame(height: 20)
                    Text(title)
                        .font(NotionStyle.body(size: 11, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                BlockMenuShortcutChip(label: keyboardShortcutLabel ?? String(keyboardShortcut.character))
                    .padding(.top, 4)
                    .padding(.trailing, 5)
            }
            .frame(width: 60, height: 60)
        }
        .buttonStyle(BlockMenuTileStyle(isSelected: isSelected))
        .keyboardShortcut(keyboardShortcut, modifiers: keyboardShortcutModifiers)
    }

    func menuTargetIDs(anchorID: BlockID) -> [BlockID] {
        #if os(macOS)
        if state.selection.contains(anchorID), state.selection.count > 1 {
            let selectedBlocks = document.blocks.filter { state.selection.contains($0.id) }
            guard let baseIndent = selectedBlocks.map(\.indent).min() else { return [anchorID] }
            let baseIDs = selectedBlocks
                .filter { $0.indent == baseIndent }
                .map(\.id)
            return baseIDs.isEmpty ? [anchorID] : baseIDs
        }
        #endif
        return [anchorID]
    }

    fileprivate func indentMenuTargets(_ ids: [BlockID], by delta: Int) {
        for id in ids {
            _ = changeIndent(id, by: delta)
        }
    }

    fileprivate func turnIntoTargets(for blocks: [Block]) -> [BlockTurnInto] {
        BlockTurnInto.allCases.filter { target in
            if target == .template, blocks.count > 1 {
                return false
            }
            return blocks.allSatisfy { canTurn($0, into: target) }
        }
    }

    /// The single turn-into target representing what `blocks` already is. Nil for
    /// heterogeneous selections (no shared current type) and for blocks whose
    /// current type isn't a turn-into option (e.g. `.code`, `.quote`).
    fileprivate func selectedTurnIntoTarget(for blocks: [Block]) -> BlockTurnInto? {
        guard let first = blocks.first.flatMap({ currentTurnIntoTarget(for: $0) }) else { return nil }
        return blocks.allSatisfy({ currentTurnIntoTarget(for: $0) == first }) ? first : nil
    }

    fileprivate func currentTurnIntoTarget(for block: Block) -> BlockTurnInto? {
        switch block {
        case .paragraph:
            return .paragraph
        case .heading(_, let level, _, _):
            switch level {
            case 1:
                return .heading1
            case 2:
                return .heading2
            case 3:
                return .heading3
            default:
                return nil
            }
        case .bullet:
            return .bullet
        case .numbered:
            return .numbered
        case .todo:
            return .todo
        case .toggle:
            return .toggle
        case .templateButton:
            return .template
        case .subpage:
            return .page
        case .quote, .code, .divider, .image:
            return nil
        }
    }

    fileprivate func canTurn(_ block: Block, into target: BlockTurnInto) -> Bool {
        switch target {
        case .page:
            return !isStructuralBlock(block)
        case .template:
            return textForBlockTypeChange(block) != nil
        case .divider:
            return canReplaceEmptyBlockWithDivider(block)
        default:
            switch block {
            case .paragraph, .bullet, .numbered, .todo, .quote, .heading, .toggle, .templateButton, .subpage:
                return true
            case .code, .divider, .image:
                return false
            }
        }
    }

    fileprivate func indentActions(for indices: [Int]) -> [BlockIndentAction] {
        var actions: [BlockIndentAction] = []
        if canChangeIndent(at: indices, by: -1) {
            actions.append(BlockIndentAction(delta: -1, title: "Outdent", systemImage: "decrease.indent", keyboardShortcut: "["))
        }
        if canChangeIndent(at: indices, by: +1) {
            actions.append(BlockIndentAction(delta: +1, title: "Indent", systemImage: "increase.indent", keyboardShortcut: "]"))
        }
        return actions
    }

    func isStructuralBlock(_ block: Block) -> Bool {
        switch block {
        case .code, .divider, .subpage, .image:
            return true
        default:
            return false
        }
    }

    func cleanedTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    func wholeBlockMarkdownLink(in text: AttributedString) -> (title: String, path: String)? {
        var linkTitle = ""
        var linkPath: String?
        var hasNonLinkText = false

        for run in text.runs {
            let segment = String(text[run.range].characters)
            if let link = run.link {
                let destination = link.absoluteString
                guard destination.hasSuffix(".md") else { return nil }
                if let existingPath = linkPath, existingPath != destination {
                    return nil
                }
                linkPath = destination
                linkTitle += segment
            } else if !segment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                hasNonLinkText = true
            }
        }

        guard !hasNonLinkText, let linkPath, let title = cleanedTitle(linkTitle) else {
            return nil
        }
        return (title, linkPath)
    }

    fileprivate func defaultSubpagePath(for title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let chars = title.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(chars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        let stem = collapsed.isEmpty ? "Untitled" : collapsed
        return stem + ".md"
    }
}

// MARK: - Block menu styling

struct BlockMenuTileStyle: ButtonStyle {
    let isSelected: Bool
    @State private var isHovering = false

    init(isSelected: Bool = false) {
        self.isSelected = isSelected
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isSelected ? NotionStyle.linkForeground : NotionStyle.foreground)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(fillColor(isPressed: configuration.isPressed))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.08), value: isHovering)
            #if os(macOS)
            .onHover { isHovering = $0 }
            #endif
    }

    private func fillColor(isPressed: Bool) -> Color {
        if isSelected {
            if isPressed { return NotionStyle.linkForeground.opacity(0.28) }
            if isHovering { return NotionStyle.linkForeground.opacity(0.20) }
            return NotionStyle.linkForeground.opacity(0.14)
        }
        if isPressed { return NotionStyle.dividerColor }
        if isHovering { return NotionStyle.dividerColor.opacity(0.5) }
        return .clear
    }
}

struct BlockMenuShortcutChip: View {
    let label: String
    #if os(iOS)
    // On iOS the chip only makes sense when a hardware keyboard is around to
    // hit the shortcut. HardwareKeyboardObserver flips when GameController's
    // GCKeyboard reports connect/disconnect; @ObservedObject re-evaluates body
    // on change so the chip appears/disappears live.
    @ObservedObject private var keyboard = HardwareKeyboardObserver.shared
    #endif

    var body: some View {
        #if os(iOS)
        if keyboard.isConnected {
            chip
        }
        #else
        chip
        #endif
    }

    private var chip: some View {
        Text(label)
            .font(NotionStyle.mono(size: 9))
            .foregroundStyle(NotionStyle.mutedForeground)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(NotionStyle.codeBackground)
            )
    }
}

#if os(iOS)
@MainActor
final class HardwareKeyboardObserver: ObservableObject {
    static let shared = HardwareKeyboardObserver()

    @Published private(set) var isConnected: Bool = GCKeyboard.coalesced != nil

    private init() {
        NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidConnect, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.isConnected = true }
        }
        NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidDisconnect, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.isConnected = GCKeyboard.coalesced != nil }
        }
    }
}
#endif
