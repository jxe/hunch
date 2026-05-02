import SwiftUI

extension EditorView {
    /// Candidates for the active query, capped at 8. The host owns filtering/ranking;
    /// the editor just renders whatever it gets back.
    fileprivate var mentionMatches: [MentionItem] {
        guard let menu = state.mentionMenu else { return [] }
        return Array(suggestPages(menu.trigger.query).prefix(8))
    }

    func handleMentionTriggerChange(_ trigger: MentionTrigger?, blockID: BlockID) {
        guard let trigger else {
            // The editor lost the @-region (cursor moved past whitespace, range cleared,
            // etc.). Drop the menu — even if its blockID still matches, we shouldn't
            // hold stale state.
            state.closeMentionMenu(forBlockID: blockID)
            return
        }
        if var existing = state.mentionMenu, existing.blockID == blockID {
            // Query / range changed — keep the menu open, refresh state. Reset the
            // selection if the new filter would put it out of bounds.
            existing.trigger = trigger
            state.setMentionMenu(existing)
            let count = mentionMatches.count
            if count == 0 {
                existing.selectedIndex = 0
            } else if existing.selectedIndex >= count {
                existing.selectedIndex = count - 1
            }
            state.setMentionMenu(existing)
        } else {
            state.setMentionMenu(MentionMenuState(blockID: blockID, trigger: trigger, selectedIndex: 0))
        }
    }

    func moveMentionSelection(by delta: Int) -> KeyPress.Result {
        guard var menu = state.mentionMenu else { return .ignored }
        let matches = mentionMatches
        guard !matches.isEmpty else { return .handled }
        let count = matches.count
        // Wrap around — feels right for a short list and makes ↑ on the first row a
        // shortcut to the last entry.
        menu.selectedIndex = ((menu.selectedIndex + delta) % count + count) % count
        state.setMentionMenu(menu)
        return .handled
    }

    func commitMentionSelection() -> KeyPress.Result {
        guard let menu = state.mentionMenu else { return .ignored }
        let matches = mentionMatches
        guard !matches.isEmpty else {
            // No matches — Return on an empty filter just dismisses the menu without
            // splitting the block.
            state.closeMentionMenu()
            return .handled
        }
        let safeIndex = max(0, min(menu.selectedIndex, matches.count - 1))
        commitMention(matches[safeIndex], menu: menu)
        return .handled
    }

    /// Replace the active block with a `.subpage` row pointing at `item`, then drop
    /// out of edit mode. The user typed `@` to *make a page link*, not to insert
    /// `[title]` mid-sentence — so we mirror Cmd-K's `convertBlockToSubpage` shape
    /// (whole block becomes the link). Any text before/after the `@query` span is
    /// preserved as adjacent paragraphs.
    fileprivate func commitMention(_ item: MentionItem, menu: MentionMenuState) {
        defer { state.closeMentionMenu() }
        guard let blockIndex = document.index(of: menu.blockID) else { return }
        let block = document.blocks[blockIndex]
        let plain = String(block.text.characters) as NSString

        let triggerStart = menu.trigger.nsRange.location
        let triggerEnd = triggerStart + menu.trigger.nsRange.length
        guard triggerEnd <= plain.length else { return }
        let beforeText = plain.substring(with: NSRange(location: 0, length: triggerStart))
        let afterText = plain.substring(with: NSRange(location: triggerEnd, length: plain.length - triggerEnd))

        // Reuse the original block's id when the @ consumed the whole row — keeps any
        // upstream references (selection, hover, undo) targeted at the same block.
        // When there's surrounding text, the leading paragraph keeps the id and the
        // subpage row gets a fresh one.
        let beforeIsEmpty = beforeText.isEmpty
        let subpageID = beforeIsEmpty ? block.id : BlockID()

        var replacements: [Block] = []
        if !beforeIsEmpty {
            replacements.append(block.withText(AttributedString(beforeText)))
        }
        replacements.append(.subpage(
            id: subpageID,
            title: item.title,
            pageID: item.id,
            indent: block.indent
        ))
        if !afterText.isEmpty {
            replacements.append(.paragraph(text: AttributedString(afterText), indent: block.indent))
        }

        mutate("Insert Page Link") {
            document.blocks.replaceSubrange(blockIndex..<blockIndex + 1, with: replacements)
        }

        DispatchQueue.main.async {
            focusPageNavigation(on: subpageID)
        }
    }

    @ViewBuilder
    func mentionMenuContent() -> some View {
        let matches = mentionMatches
        VStack(alignment: .leading, spacing: 0) {
            // Hidden hotkey buttons — make the menu's keyboard shortcuts work even if
            // the popover happens to take focus; the editor's keyDown intercept is the
            // primary path, but this provides a fallback when the popover content is
            // first responder (iOS / certain macOS edge cases).
            Group {
                Button("") { _ = commitMentionSelection() }
                    .keyboardShortcut(.return, modifiers: [])
                Button("") { state.closeMentionMenu() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)

            if matches.isEmpty {
                Text("No matching pages")
                    .font(NotionStyle.body(size: 12))
                    .foregroundStyle(NotionStyle.mutedForeground)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                ForEach(Array(matches.enumerated()), id: \.element.id) { index, item in
                    mentionRow(item: item, isSelected: state.mentionMenu?.selectedIndex == index)
                        .onTapGesture {
                            guard let menu = state.mentionMenu else { return }
                            commitMention(item, menu: menu)
                        }
                        .onHover { hovering in
                            #if os(macOS)
                            if hovering, var menu = state.mentionMenu {
                                menu.selectedIndex = index
                                state.setMentionMenu(menu)
                            }
                            #endif
                        }
                }
            }
        }
        .padding(.vertical, 4)
        .frame(width: 240, alignment: .leading)
    }

    @ViewBuilder
    fileprivate func mentionRow(item: MentionItem, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc")
                .font(.system(size: 13))
                .foregroundStyle(NotionStyle.mutedForeground)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(NotionStyle.body(size: 13))
                    .foregroundStyle(NotionStyle.foreground)
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(NotionStyle.body(size: 10))
                        .foregroundStyle(NotionStyle.mutedForeground)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? NotionStyle.linkForeground.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
    }
}
