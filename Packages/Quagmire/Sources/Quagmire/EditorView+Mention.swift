import SwiftUI

extension EditorView {
    func handleCompletionTriggerChange(_ trigger: InlineCompletionTrigger?, blockID: BlockID) {
        guard let trigger else {
            state.closeCompletionMenu(forBlockID: blockID)
            return
        }
        switch trigger {
        case .mention(let mention):
            handleMentionTriggerChange(mention, blockID: blockID)
        case .emoji(let emoji):
            handleEmojiTriggerChange(emoji, blockID: blockID)
        }
    }

    /// Open (or update) the mention menu for this trigger, then ask the host
    /// for candidates.
    ///
    /// The menu goes up synchronously so typing never waits on the host. The
    /// previous query's matches stay visible while the new query runs — a host
    /// that answers over a network would otherwise blank the list between every
    /// keystroke. Results are applied only if the menu is still open on the
    /// same block with the same query, so a slow answer cannot overwrite a
    /// newer one, and the in-flight query is cancelled when a newer one starts.
    private func handleMentionTriggerChange(_ trigger: MentionTrigger, blockID: BlockID) {
        if var existing = state.mentionMenu, existing.blockID == blockID {
            existing.trigger = trigger
            existing.isSearching = true
            state.setMentionMenu(existing)
        } else {
            state.setMentionMenu(MentionMenuState(
                blockID: blockID,
                trigger: trigger,
                selectedIndex: 0,
                isSearching: true
            ))
        }

        let query = trigger.query
        mentionSearch.run { [host, document, state] in
            let matches = Array(await host.suggestPages(query, in: document).prefix(8))
            guard !Task.isCancelled else { return }
            // The user has typed on, moved to another block, or dismissed the
            // menu while this was in flight. Applying now would show answers to
            // a question that is no longer on screen.
            guard var menu = state.mentionMenu,
                  menu.blockID == blockID,
                  menu.trigger.query == query else { return }
            menu.matches = matches
            menu.isSearching = false
            if matches.isEmpty {
                menu.selectedIndex = 0
            } else if menu.selectedIndex >= matches.count {
                menu.selectedIndex = matches.count - 1
            }
            state.setMentionMenu(menu)
        }
    }

    private func handleEmojiTriggerChange(_ trigger: EmojiTrigger, blockID: BlockID) {
        let matches = emojiSuggestions(matching: trigger.query)
        if var existing = state.emojiMenu, existing.blockID == blockID {
            let queryChanged = existing.trigger.query != trigger.query
            existing.trigger = trigger
            existing.matches = matches
            if matches.isEmpty {
                existing.selectedIndex = 0
            } else if queryChanged {
                existing.selectedIndex = 0
            } else if existing.selectedIndex >= matches.count {
                existing.selectedIndex = matches.count - 1
            }
            state.setEmojiMenu(existing)
        } else {
            state.setEmojiMenu(EmojiMenuState(blockID: blockID, trigger: trigger, selectedIndex: 0, matches: matches))
        }
    }

    func moveCompletionSelection(by delta: Int) -> KeyPress.Result {
        if state.emojiMenu != nil { return moveEmojiSelection(by: delta) }
        return moveMentionSelection(by: delta)
    }

    func commitCompletionSelection() -> KeyPress.Result {
        if state.emojiMenu != nil { return commitEmojiSelection() }
        return commitMentionSelection()
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

    private func moveEmojiSelection(by delta: Int) -> KeyPress.Result {
        guard var menu = state.emojiMenu else { return .ignored }
        guard !menu.matches.isEmpty else { return .handled }
        let count = menu.matches.count
        menu.selectedIndex = ((menu.selectedIndex + delta) % count + count) % count
        menu.keyboardScrollRequestID += 1
        state.setEmojiMenu(menu)
        return .handled
    }

    private func commitEmojiSelection() -> KeyPress.Result {
        guard let menu = state.emojiMenu else { return .ignored }
        guard !menu.matches.isEmpty else {
            state.closeCompletionMenu()
            return .handled
        }
        let safeIndex = max(0, min(menu.selectedIndex, menu.matches.count - 1))
        commitEmoji(menu.matches[safeIndex], menu: menu)
        return .handled
    }

    private func commitEmoji(_ suggestion: EmojiSuggestion, menu: EmojiMenuState) {
        defer { state.closeCompletionMenu() }
        undoController.flushActiveText?()
        guard let block = document.find(menu.blockID) else { return }
        guard let replacement = replacingEmojiTrigger(
            in: block.text,
            trigger: menu.trigger,
            with: suggestion.character
        ) else { return }

        mutate("Insert Emoji") {
            document.setText(block.id, replacement.text)
        }
        registerEmojiSelection(suggestion.character)

        DispatchQueue.main.async {
            transferFocus(to: .editor(block.id, initialCursor: .offset(replacement.cursor)))
        }
    }

    /// Commit the selected page mention. A line-leading mention becomes a
    /// `.subpage` row; a mention with sentence content before it becomes an
    /// inline link in the existing text block.
    func commitMention(_ item: MentionItem, menu: MentionMenuState) {
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
                // "Searching…" only while there is genuinely nothing to show.
                // Once a previous query's rows are on screen they stay there
                // until the new answer replaces them, so a slow host reads as
                // slightly stale rather than as flickering.
                Text(state.mentionMenu?.isSearching == true ? "Searching…" : "No matching pages")
                    .font(configuration.theme.body(size: 12))
                    .foregroundStyle(configuration.theme.mutedForeground)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                ForEach(Array(matches.enumerated()), id: \.element.id) { index, item in
                    MentionItemRow(
                        item: item,
                        isHighlighted: state.mentionMenu?.selectedIndex == index,
                        theme: configuration.theme
                    )
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
    func completionMenuContent() -> some View {
        if state.emojiMenu != nil {
            emojiMenuContent()
        } else {
            mentionMenuContent()
        }
    }

    private func emojiMenuContent() -> some View {
        let matches = state.emojiMenu?.matches ?? []
        return VStack(alignment: .leading, spacing: 0) {
            Group {
                Button("") { _ = commitEmojiSelection() }
                    .keyboardShortcut(.return, modifiers: [])
                Button("") { state.closeCompletionMenu() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)

            if matches.isEmpty {
                Text("No matching emoji")
                    .font(configuration.theme.body(size: 12))
                    .foregroundStyle(configuration.theme.mutedForeground)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(matches.enumerated()), id: \.element.id) { index, item in
                                HStack(spacing: 10) {
                                    Text(item.character)
                                        .font(.system(size: 20))
                                        .frame(width: 26)
                                    Text(item.name)
                                        .font(configuration.theme.body(size: 13))
                                        .foregroundStyle(configuration.theme.foreground)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    state.emojiMenu?.selectedIndex == index
                                        ? configuration.theme.selectionBackground
                                        : Color.clear
                                )
                                .contentShape(Rectangle())
                                .id(item.id)
                                .onTapGesture {
                                    guard let menu = state.emojiMenu else { return }
                                    commitEmoji(item, menu: menu)
                                }
                                .onHover { hovering in
                                    #if os(macOS)
                                    if hovering, var menu = state.emojiMenu {
                                        menu.selectedIndex = index
                                        state.setEmojiMenu(menu)
                                    }
                                    #endif
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                    .scrollIndicators(.visible)
                    .onChange(of: state.emojiMenu?.keyboardScrollRequestID) { _, _ in
                        scrollToEmojiSelection(state.emojiMenu?.selectedIndex, matches: matches, proxy: proxy)
                    }
                    .onChange(of: state.emojiMenu?.trigger.query) { _, _ in
                        guard let first = matches.first else { return }
                        proxy.scrollTo(first.id, anchor: .top)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .frame(width: 260, alignment: .leading)
    }

    private func scrollToEmojiSelection(
        _ selectedIndex: Int?,
        matches: [EmojiSuggestion],
        proxy: ScrollViewProxy
    ) {
        guard let selectedIndex, matches.indices.contains(selectedIndex) else { return }
        proxy.scrollTo(matches[selectedIndex].id, anchor: .center)
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
