import SwiftUI
#if os(iOS)
import GameController
#endif

// MARK: - Turn Into menu / block action popover
//
// The 3-column grid that opens via Cmd-/ in nav mode (macOS), drag-handle tap
// (macOS), or leading row swipe (iOS). Houses Turn Into (block-type swap),
// Copy, and Indent/Outdent. The conversion methods (`convert`, `convertSingle`,
// `convertBlockToSubpage`, `convertBlockToTemplate`, `convertSubpage`) live
// here too — they're the actions the menu fires.

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
        guard let block = document.find(blockID) else { return .ignored }
        guard !isStructuralBlock(block) else { return .ignored }

        let existingLink = wholeBlockWorkspaceLink(in: block.text)
        let title = cleanedTitle(preferredTitle)
            ?? existingLink?.title
            ?? cleanedTitle(String(block.text.characters))
            ?? "Untitled"
        let requestedPath = existingLink?.pageID

        // The block's children (the subtree under it) become the body of the
        // new subpage. The host prepends a title heading + serializes; the
        // editor just hands over the body blocks (or nil when empty).
        let initialContent: [Block]? = block.children.isEmpty ? nil : block.children

        guard let pageID = host.createSubpage(title: title, requestedPath: requestedPath, initialContent: initialContent)
        else { return .ignored }

        mutate("Create Subpage") {
            document.replaceSubtree(blockID, with: [
                .subpage(title: title, pageID: pageID, id: blockID)
            ])
        }
        DispatchQueue.main.async {
            transferFocus(to: .nav(cursor: blockID))
        }
        return .handled
    }

    @discardableResult
    func convert(blockIDs: [BlockID], to target: BlockTurnInto) -> KeyPress.Result {
        let ids = blockIDs.filter { document.find($0) != nil }
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
        guard let block = document.find(blockID) else { return .ignored }
        if target == .divider {
            guard canReplaceEmptyBlockWithDivider(block) else { return .ignored }
            mutate("Turn Into") {
                document.mutate(blockID) { $0.kind = .divider }
            }
            state.expandedToggles.remove(blockID)
            state.expandedTemplates.remove(blockID)
            return .handled
        }
        if case .subpage = block.kind {
            return convertSubpage(blockID: blockID, to: target)
        }
        guard let text = textForBlockTypeChange(block) else { return .ignored }

        mutate("Turn Into") {
            let replacement = blockForTurnInto(target, id: blockID, text: text)
            // Preserve the original block's children when changing kind.
            document.mutate(blockID) { existing in
                existing.kind = replacement.kind
            }
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
        guard let block = document.find(blockID) else { return .ignored }
        guard let text = textForBlockTypeChange(block) else { return .ignored }
        let label = cleanedTitle(String(text.characters)) ?? "Template"
        let hasBody = !block.children.isEmpty
        let defaultBody = Block.paragraph(text: AttributedString())

        mutate("Turn Into") {
            document.mutate(blockID) { existing in
                existing.kind = .templateButton(label: label)
                if !hasBody {
                    existing.children = [defaultBody]
                }
            }
        }
        state.expandedToggles.remove(blockID)
        state.expandedTemplates.insert(blockID)
        return .handled
    }

    @discardableResult
    fileprivate func convertSubpage(blockID: BlockID, to target: BlockTurnInto) -> KeyPress.Result {
        guard target != .page else { return .ignored }
        guard let block = document.find(blockID),
              case .subpage(let title, let path) = block.kind else { return .ignored }
        // Load + splice + trash in a Task so the key-handler returns
        // immediately. Order inside the Task: load → mutate → state-flags
        // → trash. The host force-saves the parent doc before trashing,
        // so a crash between mutate and trash leaves only a recoverable
        // duplicate (file still in workspace, bullet on disk) rather
        // than data loss (file gone, bullet never persisted).
        Task { @MainActor in
            guard var loaded = await host.loadSubpageBlocks(path) else {
                Diag.subpage.error("convertSubpage: loadSubpageBlocks returned nil — path=\(path, privacy: .public)")
                return
            }
            // The subpage may have moved out from under us during the await.
            guard document.find(blockID) != nil else { return }
            // Heading containment means the page's body lives as children of the
            // title H1, not as siblings. Replace the title heading with its
            // children so the subpage's body survives the inline.
            if let first = loaded.first,
               case .heading(.h1, let leadingText) = first.kind,
               String(leadingText.characters).trimmingCharacters(in: .whitespacesAndNewlines) == title {
                loaded.replaceSubrange(0...0, with: first.children)
            }
            // The subpage's loaded blocks become the children of the new container
            // (toggle / templateButton / list item etc.). For non-container kinds
            // they're inlined as siblings after the converted block.
            let replacement = blockForTurnInto(target, id: blockID, text: AttributedString(title))
            mutate("Turn Into") {
                if replacement.isContainer {
                    document.replaceSubtree(blockID, with: [replacement.withChildren(loaded)])
                } else {
                    document.replaceSubtree(blockID, with: [replacement] + loaded)
                }
            }
            if target == .toggle {
                state.expandedToggles.insert(blockID)
            } else if target == .template {
                state.expandedTemplates.insert(blockID)
            } else {
                state.expandedToggles.remove(blockID)
                state.expandedTemplates.remove(blockID)
            }
            if !(await host.inlineAndTrashSubpage(path)) {
                Diag.subpage.error("convertSubpage: inlineAndTrashSubpage failed after mutation — orphan file at \(path, privacy: .public)")
            }
        }
        return .handled
    }

    fileprivate func blockForTurnInto(_ target: BlockTurnInto, id: BlockID, text: AttributedString) -> Block {
        switch target {
        case .paragraph:
            return .paragraph(text: text, id: id)
        case .bullet:
            return .bullet(text: text, id: id)
        case .numbered:
            return .numbered(text: text, id: id)
        case .todo:
            return .todo(text: text, done: false, id: id)
        case .toggle:
            return .toggle(title: text, id: id)
        case .template:
            return .templateButton(label: String(text.characters), id: id)
        case .heading1:
            return .heading(level: .h1, text: text, id: id)
        case .heading2:
            return .heading(level: .h2, text: text, id: id)
        case .heading3:
            return .heading(level: .h3, text: text, id: id)
        case .divider:
            return .divider(id: id)
        case .page:
            preconditionFailure("Page conversion creates a subpage file before replacing the block")
        }
    }

    /// Extracts the text/title from a block whose type can be swapped for another
    /// text-bearing type without losing content. Returns nil for blocks that don't
    /// carry user text (code/divider/subpage/image).
    func textForBlockTypeChange(_ block: Block) -> AttributedString? {
        switch block.kind {
        case .paragraph(let t),
             .heading(_, let t),
             .bullet(let t),
             .numbered(let t),
             .quote(let t),
             .toggle(let t):
            return t
        case .templateButton(let label):
            return AttributedString(label)
        case .todo(let t, _):
            return t
        case .code, .divider, .subpage, .image:
            return nil
        }
    }

    fileprivate func canReplaceEmptyBlockWithDivider(_ block: Block) -> Bool {
        switch block.kind {
        case .paragraph(let text),
             .heading(_, let text),
             .bullet(let text),
             .numbered(let text),
             .todo(let text, _),
             .quote(let text),
             .toggle(let text):
            return String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .templateButton(let label):
            return label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .code(let source, _):
            return source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .divider, .subpage, .image:
            return false
        }
    }

    @ViewBuilder
    func blockActionMenuContent(for blockID: BlockID) -> some View {
        let targetIDs = menuTargetIDs(anchorID: blockID)
        let targetBlocks = targetIDs.compactMap { document.find($0) }
        if !targetBlocks.isEmpty {
            let availableTargets = Set(turnIntoTargets(for: targetBlocks))
            let selectedTarget = selectedTurnIntoTarget(for: targetBlocks)
            let visibleGroups: [(BlockTurnInto.Category, [BlockTurnInto])] = BlockTurnInto.orderedGroups
                .map { ($0.0, $0.1.filter { availableTargets.contains($0) || $0 == selectedTarget }) }
                .filter { !$0.1.isEmpty }
            let indentTargets = indentActions(for: targetIDs)
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
                            let inDoc = inDocMoveCandidates(excluding: targetIDs)
                            Task { @MainActor in
                                let destination = await host.moveDestination(for: targetIDs, candidates: inDoc)
                                switch destination {
                                case .page(let pageID):
                                    await moveBlocks(ids: targetIDs, intoSubpagePath: pageID)
                                case .block(let parentID):
                                    moveBlocks(ids: targetIDs, asChildrenOf: parentID, snapshot: [], hidden: [])
                                case nil:
                                    break
                                }
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
            // Tree-aware analog of "blocks at the shallowest selected depth":
            // collapse the selection to its minimal subtree-roots so a turn-into
            // applied to a parent doesn't double-apply to its already-covered
            // descendants.
            let roots = document.selectionSubtreeRoots(state.selection)
            return roots.isEmpty ? [anchorID] : roots
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
        switch block.kind {
        case .paragraph:
            return .paragraph
        case .heading(let level, _):
            switch level {
            case .h1: return .heading1
            case .h2: return .heading2
            case .h3: return .heading3
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
            switch block.kind {
            case .paragraph, .bullet, .numbered, .todo, .quote, .heading, .toggle, .templateButton, .subpage:
                return true
            case .code, .divider, .image:
                return false
            }
        }
    }

    fileprivate func indentActions(for ids: [BlockID]) -> [BlockIndentAction] {
        var actions: [BlockIndentAction] = []
        if canChangeIndent(ids: ids, by: -1) {
            actions.append(BlockIndentAction(delta: -1, title: "Outdent", systemImage: "decrease.indent", keyboardShortcut: "["))
        }
        if canChangeIndent(ids: ids, by: +1) {
            actions.append(BlockIndentAction(delta: +1, title: "Indent", systemImage: "increase.indent", keyboardShortcut: "]"))
        }
        return actions
    }

    func isStructuralBlock(_ block: Block) -> Bool {
        switch block.kind {
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

    /// If `text` is a single inline link pointing at a workspace page (and
    /// nothing else but whitespace), return its `(linkText, pageID)`. The
    /// host classifies the URL via `resolvePageID`; the editor
    /// doesn't bake in a storage convention. Used by Cmd-K-on-link to turn
    /// a `[Hello](some-page.md)` paragraph into a subpage block pointing
    /// at `some-page.md`.
    func wholeBlockWorkspaceLink(in text: AttributedString) -> (title: String, pageID: String)? {
        var linkTitle = ""
        var linkPageID: String?
        var hasNonLinkText = false

        for run in text.runs {
            let segment = String(text[run.range].characters)
            if let link = run.link {
                guard let pageID = host.resolvePageID(from: link) else { return nil }
                if let existing = linkPageID, existing != pageID {
                    return nil
                }
                linkPageID = pageID
                linkTitle += segment
            } else if !segment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                hasNonLinkText = true
            }
        }

        guard !hasNonLinkText, let linkPageID, let title = cleanedTitle(linkTitle) else {
            return nil
        }
        return (title, linkPageID)
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
