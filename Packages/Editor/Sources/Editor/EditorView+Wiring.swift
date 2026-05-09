import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - Command and undo wiring
//
// EditorView holds two `@State`-owned reference types — `editorCommands`
// (an `EditorCommands` whose `perform` / `can` closures the menu and
// keyboard handlers call) and `undoController` (a `DocumentUndoController`
// whose `apply` / `applyTextChange` closures the undo manager calls on
// Cmd-Z / redo). Both are installed once on first appear.
//
// The closures capture the View struct by value, so they capture the
// underlying `Document` and `EditorState` references. Reads happen at
// fire time, so a captured-state closure that runs after the user has
// edited still sees fresh model state.
//
// Wiring lives in this file so `EditorView.swift` doesn't carry a
// 100-line setter assignment block in `onAppear`. Step 5 expands the
// EditorCommands surface and routes nav-mode keys through it.

extension EditorView {
    /// Install `editorCommands.perform` / `editorCommands.can`. Called once
    /// from `onAppear`. Each `EditorAction` arm dispatches to a private
    /// helper on `EditorView` (kept there so they read the View's state
    /// directly without an extra parameter pass).
    func wireEditorCommands() {
        editorCommands.perform = { action in
            switch action {
            case .openBlockActionMenu:
                guard let id = topSelectedBlockID() else { return }
                actionSheet = BlockActionSheet(id: id)

            case .openMoveTo:
                guard let id = topSelectedBlockID() else { return }
                let targetIDs = menuTargetIDs(anchorID: id)
                let inDoc = inDocMoveCandidates(excluding: targetIDs)
                host.onRequestMoveDestination(targetIDs, inDoc) { destination in
                    switch destination {
                    case .page(let pageID):
                        moveBlocks(ids: targetIDs, intoSubpagePath: pageID)
                    case .block(let parentID):
                        moveBlocks(ids: targetIDs, asChildrenOf: parentID, snapshot: [], hidden: [])
                    case nil:
                        break
                    }
                }

            case .toggleLinkOrSubpage:
                guard let id = state.cursor, state.selection.count == 1 else { return }
                // The Cmd-K menu shortcut wins over NSTextView's keyDown, so the
                // live-text capture path in BlockTextEditor's keyDown never runs.
                // Mirror it here: capture the selected substring (or full string)
                // directly from the live text view, so a freshly-typed row whose
                // binding is still empty still gets its typed text used as the
                // new page's title. The commit itself happens centrally in
                // `mutate(...)` inside `convertBlockToSubpage`.
                var preferred: String? = nil
                #if os(macOS)
                if let view = activeContainedTextView() {
                    let range = view.selectedRange()
                    let str = view.string
                    if range.length > 0, let r = Range(range, in: str) {
                        preferred = String(str[r])
                    } else if !str.isEmpty {
                        preferred = str
                    }
                }
                #endif
                _ = convertBlockToSubpage(blockID: id, preferredTitle: preferred)

            case .toggleInlineMark(let mark):
                #if os(macOS)
                if let view = activeContainedTextView() {
                    view.toggleInlineMark(mark)
                    return
                }
                #endif
                switch mark {
                case .bold: _ = toggleBoldOnSelection()
                case .italic: _ = toggleItalicOnSelection()
                case .strikethrough: _ = toggleStrikethroughOnSelection()
                case .code: break
                }

            case .indent:
                runDualMode(
                    edit: { bid in _ = changeIndent(bid, by: +1) },
                    nav: { indentSelection(by: 1) }
                )
            case .outdent:
                runDualMode(
                    edit: { bid in _ = changeIndent(bid, by: -1) },
                    nav: { indentSelection(by: -1) }
                )
            case .newBlockBelow:
                runDualMode(
                    edit: { bid in _ = insertEmptySiblingAfter(bid) },
                    nav: { _ = createEmptySiblingAndEdit() }
                )
            case .moveBlockUp:
                runDualMode(
                    edit: { bid in moveBlocksInDocument(Set([bid]), by: -1) },
                    nav: { moveSelectionInDocument(by: -1) }
                )
            case .moveBlockDown:
                runDualMode(
                    edit: { bid in moveBlocksInDocument(Set([bid]), by: +1) },
                    nav: { moveSelectionInDocument(by: +1) }
                )

            // Nav-mode keyboard actions. Fired from `handleNavKeyPress` via
            // the binding table below; not exposed in the menu bar (the
            // system equivalents handle those there).
            case .copySelection:
                _ = copySelectionToPasteboard()
            case .pasteFromPasteboard:
                _ = pasteFromPasteboard()
            case .cutSelection:
                _ = cutSelectionToPasteboard()
            case .deleteSelection:
                deleteSelection()
            case .escape:
                handleEscapeKey()
            case .navigateBack:
                host.onNavigateBack()
            case .moveCursor(let delta):
                moveCursor(by: delta)
            case .extendSelection(let delta):
                extendSelection(by: delta)
            case .enterEditOrOpenSubpage:
                if let id = state.cursor, state.selection.count == 1 {
                    if navigateIntoSubpage(id) { return }
                    transferFocus(to: .editor(id, initialCursor: nil))
                }
            case .navRightArrow:
                _ = handleNavRightArrow()
            case .navLeftArrow:
                _ = handleNavLeftArrow()
            }
        }

        editorCommands.can = { predicate in
            switch predicate {
            case .canIndent:
                if let bid = state.editingBlock {
                    return document.canIndent(bid)
                }
                let roots = document.selectionSubtreeRoots(state.selection)
                return !roots.isEmpty && roots.allSatisfy { document.canIndent($0) }
            case .canOutdent:
                if let bid = state.editingBlock {
                    return document.canOutdent(bid)
                }
                let roots = document.selectionSubtreeRoots(state.selection)
                return !roots.isEmpty && roots.allSatisfy { document.canOutdent($0) }
            }
        }
    }

    /// Install the closures the undo controller calls on Cmd-Z / redo.
    /// `apply` restores the document tree (and re-registers the inverse for
    /// redo). `applyTextChange` restores a single block's text — used for
    /// the coalesced typing-burst undo entries.
    func installUndoApply() {
        undoController.apply = { newBlocks in
            let beforeRedo = document.snapshot()
            document.restore(newBlocks)

            // Validate cursor/selection/edit-mode against the new tree — drops
            // invalid IDs from the navigating selection, falls back to nav mode
            // if the editing block disappeared.
            var validIDs: Set<BlockID> = []
            document.walk { block, _, _ in validIDs.insert(block.id) }
            state.revalidate(against: validIDs, fallbackCursor: document.children.first?.id)

            // Re-register inverse — when this runs during isUndoing, UndoManager pushes
            // it to the redo stack; during isRedoing, it goes back on the undo stack.
            undoController.register(beforeRedo, name: undoController.undoManager.undoActionName)
            host.onEdited()
        }
        undoController.applyTextChange = { blockID, oldText in
            guard let block = document.find(blockID) else { return }
            let beforeRedoText = block.text
            document.setText(blockID, oldText)
            undoController.registerTextChange(blockID: blockID, oldText: beforeRedoText)
            host.onEdited()
        }
    }

    /// The active NSTextView when one's frontmost — wraps the macOS-only
    /// firstResponder probe so callers don't need their own `#if os(macOS)`.
    #if os(macOS)
    func activeContainedTextView() -> ContainedTextView? {
        NSApp.keyWindow?.firstResponder as? ContainedTextView
    }
    #endif

    /// Most editor commands have two shapes: one when an NSTextView is active
    /// (act on `state.editingBlock`), and one when no editor is mounted (act
    /// on the nav selection). The live-text commit happens centrally inside
    /// `mutate(...)`; this helper just picks which closure to call so each
    /// switch arm in `wireEditorCommands` stays a single line.
    func runDualMode(
        edit: (BlockID) -> Void,
        nav: () -> Void
    ) {
        #if os(macOS)
        if activeContainedTextView() != nil, let bid = state.editingBlock {
            edit(bid)
            return
        }
        #endif
        nav()
    }
}
