import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - Command and undo wiring
//
// EditorView holds two `@State`-owned reference types — `editorCommands`
// (an `EditorCommands` whose `perform` / `can` closures the menu and
// keyboard handlers call) and `undoController` (a `DocumentUndoController`
// that owns the shared `UndoManager`). Both are installed once on first appear.
//
// The hooks `installUndoApply` wires onto `Document` (preMutation,
// didCommitTransaction, didReplaceChildren) capture the View struct by value,
// so they capture the underlying `Document` and `EditorState` references.
// Reads happen at fire time, so a captured-state closure that runs after the
// user has edited still sees fresh model state.
//
// Wiring lives in this file so `EditorView.swift` doesn't carry a
// 100-line setter assignment block in `onAppear`.

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
                guard host.supportsMoveDestinationPicker else { return }
                guard let id = topSelectedBlockID() else { return }
                let targetIDs = menuTargetIDs(anchorID: id)
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

            case .toggleLinkOrSubpage:
                guard host.supportsPageCreation else { return }
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
                host.navigateBack()
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

        editorCommands.performBlockAction = { actionID in
            performBlockAction(id: actionID)
        }
        editorCommands.canPerformBlockAction = { actionID in
            guard runningBlockActionID == nil else { return false }
            let context = selectedBlockActionContext()
            return host.blockActions(in: document).contains { action in
                action.id == actionID && action.isApplicable(to: context)
            }
        }
    }

    /// Wire the editor's per-document hooks onto `Document`. After this:
    ///   - `document.undoManager` is the controller's manager (so transactions
    ///     register inverses against it).
    ///   - `document.didCommitTransaction` forwards the transaction diff to
    ///     the host once per commit.
    ///   - this view's installed editor hooks flush any in-flight NSTextView
    ///     text before a transaction snapshots, then revalidate `EditorState`
    ///     after transaction commits and bulk replacements.
    ///     Fresh parse → fresh BlockIDs, so without this `state.cursor` /
    ///     `state.selection` would silently break nav and delete.
    ///   - `undoController.document` points at this document, so the typing
    ///     path in `BlockTextEditor` can call `undoController.transaction(...)`.
    func installUndoApply() {
        document.undoManager = undoController.undoManager
        undoController.document = document

        // Single hook for every transaction — forward, undo, or redo —
        // covering both halves of "edit happened": revalidate `EditorState`
        // against the new block set (drops dangling selection/cursor refs
        // when blocks vanish), then forward the diff to the host so its
        // recovery journal + .md stay in sync. Capture by reference:
        // `document`/`state`/`host` are reachable through this struct's
        // stored bindings; reads happen at fire time so the callback sees
        // fresh state. Also drops the layout cache's structural-row
        // cache — any forward/undo/redo can shift which blocks are visible.
        let layoutCache = self.layoutCache
        document.didCommitTransaction = { changes in
            host.persistCommit(changes: changes, in: document)
        }
        document.removeEditorHooks(documentHookToken)
        documentHookToken = document.installEditorHooks(Document.EditorHooks(
            preMutation: { [weak undoController] in
                undoController?.flushActiveText?()
            },
            didCommitTransaction: { ops in
                var validIDs: Set<BlockID> = []
                document.walk { block, _, _ in validIDs.insert(block.id) }
                state.revalidate(against: validIDs, fallbackCursor: document.children.first?.id)
                layoutCache.invalidateStructure()
            },
            didReplaceChildren: {
                undoController.cancelActiveTextCheckpoint?()
                var validIDs: Set<BlockID> = []
                document.walk { block, _, _ in validIDs.insert(block.id) }
                configuration.diagnostics.mode.debug("document children replaced — revalidating state against \(validIDs.count, privacy: .public) blocks")
                state.revalidate(against: validIDs, fallbackCursor: document.children.first?.id)
                layoutCache.invalidateStructure()
            }
        ))

        // Expand/collapse changes a block's visibility — drop the cached
        // visible-row layout so the next gesture tick rebuilds it.
        state.onStructureChange = { [weak layoutCache] in
            layoutCache?.invalidateStructure()
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
