import SwiftUI

extension EditorView {
    func handleMentionTriggerChange(_ trigger: MentionTrigger?, blockID: BlockID) {
        guard let trigger else {
            // The editor lost the @-region (cursor moved past whitespace, range cleared,
            // etc.). Drop the menu — even if its blockID still matches, we shouldn't
            // hold stale state.
            state.closeMentionMenu(forBlockID: blockID)
            return
        }
        // Snapshot match candidates once per trigger change. Body renders and
        // keyboard handlers read from `menu.matches` instead of re-querying
        // the host on every pass.
        let matches = Array(host.suggestPages(trigger.query, in: document).prefix(8))
        if var existing = state.mentionMenu, existing.blockID == blockID {
            existing.trigger = trigger
            existing.matches = matches
            if matches.isEmpty {
                existing.selectedIndex = 0
            } else if existing.selectedIndex >= matches.count {
                existing.selectedIndex = matches.count - 1
            }
            state.setMentionMenu(existing)
        } else {
            state.setMentionMenu(MentionMenuState(blockID: blockID, trigger: trigger, selectedIndex: 0, matches: matches))
        }
    }

    func moveMentionSelection(by delta: Int) -> KeyPress.Result {
        guard var menu = state.mentionMenu else { return .ignored }
        guard !menu.matches.isEmpty else { return .handled }
        let count = menu.matches.count
        // Wrap around — feels right for a short list and makes ↑ on the first row a
        // shortcut to the last entry.
        menu.selectedIndex = ((menu.selectedIndex + delta) % count + count) % count
        state.setMentionMenu(menu)
        return .handled
    }

    func commitMentionSelection() -> KeyPress.Result {
        guard let menu = state.mentionMenu else { return .ignored }
        guard !menu.matches.isEmpty else {
            // No matches — Return on an empty filter just dismisses the menu without
            // splitting the block.
            state.closeMentionMenu()
            return .handled
        }
        let safeIndex = max(0, min(menu.selectedIndex, menu.matches.count - 1))
        commitMention(menu.matches[safeIndex], menu: menu)
        return .handled
    }

    /// Replace the active block with a `.subpage` row pointing at `item`, then drop
    /// out of edit mode. The user typed `@` to *make a page link*, not to insert
    /// `[title]` mid-sentence — so we mirror Cmd-K's `convertBlockToSubpage` shape
    /// (whole block becomes the link). Any text before/after the `@query` span is
    /// preserved as adjacent paragraphs.
    fileprivate func commitMention(_ item: MentionItem, menu: MentionMenuState) {
        defer { state.closeMentionMenu() }
        // The popover detects from the live text storage, but `block.text` is the
        // binding state — only flushed by `commitLiveText` on blur / structural
        // keys. The mention-commit keyboard branches and the popover tap path
        // don't run that flush, so without this we'd read stale (possibly empty)
        // text and the trigger-range guard below would silently bail.
        undoController.flushActiveText?()
        guard let block = document.find(menu.blockID) else { return }
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
            title: item.title,
            pageID: item.id,
            id: subpageID
        ))
        if !afterText.isEmpty {
            replacements.append(.paragraph(text: AttributedString(afterText)))
        }

        mutate("Insert Page Link") {
            document.replaceSubtree(menu.blockID, with: replacements)
        }

        DispatchQueue.main.async {
            transferFocus(to: .nav(cursor: subpageID))
        }
    }

    @ViewBuilder
    func mentionMenuContent() -> some View {
        let matches = state.mentionMenu?.matches ?? []
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
                    MentionItemRow(item: item, isHighlighted: state.mentionMenu?.selectedIndex == index)
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
}
