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

    /// Commit the selected page mention. A line-leading mention becomes a
    /// `.subpage` row; a mention with sentence content before it becomes an
    /// inline link in the existing text block.
    fileprivate func commitMention(_ item: MentionItem, menu: MentionMenuState) {
        defer { state.closeMentionMenu() }
        // The popover detects from the live text storage, but `block.text` is the
        // binding state — only flushed by `commitLiveText` on blur / structural
        // keys. The mention-commit keyboard branches and the popover tap path
        // don't run that flush, so without this we'd read stale (possibly empty)
        // text and the trigger-range guard below would silently bail.
        undoController.flushActiveText?()
        guard let block = document.find(menu.blockID) else { return }
        let attr = block.text
        let plain = String(attr.characters)
        let triggerStartUTF16 = menu.trigger.nsRange.location
        let triggerEndUTF16 = triggerStartUTF16 + menu.trigger.nsRange.length
        guard let triggerStart = characterOffset(in: plain, utf16Offset: triggerStartUTF16),
              let triggerEnd = characterOffset(in: plain, utf16Offset: triggerEndUTF16),
              triggerStart <= triggerEnd,
              triggerEnd <= attr.characters.count else {
            return
        }

        if !mentionStartsSubpageBlock(plain: plain, triggerStart: triggerStart) {
            commitInlineMention(item, block: block, text: attr, triggerStart: triggerStart, triggerEnd: triggerEnd)
            return
        }

        let afterText = attributedSlice(attr, triggerEnd..<attr.characters.count)

        var replacements: [Block] = []
        replacements.append(.subpage(
            title: item.title,
            pageID: item.id,
            id: block.id
        ))
        if !afterText.characters.isEmpty {
            replacements.append(.paragraph(text: afterText))
        }

        mutate("Insert Page Link") {
            document.replaceSubtree(menu.blockID, with: replacements)
        }

        DispatchQueue.main.async {
            transferFocus(to: .nav(cursor: block.id))
        }
    }

    private func commitInlineMention(_ item: MentionItem, block: Block, text: AttributedString, triggerStart: Int, triggerEnd: Int) {
        guard let url = host.linkURL(forPageID: item.id, in: document) else { return }
        let prefix = attributedSlice(text, 0..<triggerStart)
        var linked = AttributedString(item.title)
        linked.link = url
        let suffix = attributedSlice(text, triggerEnd..<text.characters.count)
        let newText = prefix + linked + suffix
        let cursor = String((prefix + linked).characters).count

        mutate("Insert Page Link") {
            document.setText(block.id, newText)
        }

        DispatchQueue.main.async {
            transferFocus(to: .editor(block.id, initialCursor: .offset(cursor)))
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
