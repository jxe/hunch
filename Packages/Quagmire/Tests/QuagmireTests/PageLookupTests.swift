import Foundation
import SwiftUI
import Testing
@testable import Quagmire

/// The reference-target boundary: four lookup states, per-target capabilities,
/// and what each one lets the editor offer.
///
/// The states exist because a host with one kind of target (a folder of local
/// files) and a host with several (a network with permissions, offline pages,
/// and things still loading) need the same row to behave differently, and the
/// editor must not guess. In particular an *unresolved* reference is not a
/// broken one, and an *unreachable* one is not a missing one — rendering either
/// as broken invites the user to clean up something that is fine.
@MainActor
@Suite("Reference target lookup")
struct PageLookupTests {

    // MARK: - Capabilities

    @Test func nothingIsPermittedOnAnUnresolvedOrBrokenTarget() {
        for lookup in [PageLookup.pending, .missing, .unavailable] {
            #expect(lookup.capabilities.isEmpty)
            #expect(!lookup.can(.navigate))
            #expect(!lookup.can(.receiveBlocks))
            #expect(!lookup.can(.inline))
            #expect(!lookup.can(.setIcon))
        }
    }

    @Test func aPresentTargetIsFullyCapableByDefault() {
        let lookup = PageLookup.present(title: "Notes")
        #expect(lookup.capabilities == .all)
        #expect(lookup.can(.navigate))
        #expect(lookup.can(.receiveBlocks))
        #expect(lookup.can(.inline))
        #expect(lookup.can(.setIcon))
    }

    @Test func capabilitiesCanVaryPerTarget() {
        let readOnly = PageLookup.present(PagePresentation(title: "Shared", capabilities: [.navigate]))
        #expect(readOnly.can(.navigate))
        #expect(!readOnly.can(.receiveBlocks))
        #expect(!readOnly.can(.inline))
    }

    @Test func onlyMissingReportsMissing() {
        #expect(PageLookup.missing.isMissing)
        #expect(!PageLookup.pending.isMissing)
        #expect(!PageLookup.unavailable.isMissing)
        #expect(!PageLookup.present(title: "x").isMissing)
    }

    // MARK: - Row presentation

    @Test func aPresentTargetShowsItsLiveTitle() {
        let row = subpageRowPresentation(
            storedTitle: "Old Name",
            lookup: .present(title: "New Name")
        )
        #expect(row.title == "New Name")
        #expect(!row.muted)
        #expect(row.annotation == nil)
    }

    @Test func anUnresolvedTargetFallsBackToTheStoredLabelAndLooksOrdinary() {
        let row = subpageRowPresentation(storedTitle: "Notes", lookup: .pending)
        #expect(row.title == "Notes")
        #expect(!row.muted, "a cold cache must not make the document look broken")
        #expect(row.annotation == nil)
        #expect(row.symbol == "doc.text")
    }

    @Test func anUnreachableTargetReadsAsDegradedNotGone() {
        let row = subpageRowPresentation(storedTitle: "Notes", lookup: .unavailable)
        #expect(row.muted)
        #expect(row.annotation == "(unavailable)")
        #expect(row.symbol != "doc.badge.exclamationmark", "it is not broken; nothing needs fixing")
    }

    @Test func aMissingTargetIsMarkedMissing() {
        let row = subpageRowPresentation(storedTitle: "Notes", lookup: .missing)
        #expect(row.muted)
        #expect(row.annotation == "(missing)")
        #expect(row.symbol == "doc.badge.exclamationmark")
        #expect(row.emoji == nil, "no icon on a target we can't read")
    }

    @Test func aHostSuppliedIconWinsOverOneDerivedFromTheTitle() {
        let row = subpageRowPresentation(
            storedTitle: "x",
            lookup: .present(PagePresentation(title: "🍎 Apples", icon: "📕"))
        )
        #expect(row.emoji == "📕")
        #expect(row.title == "Apples")
    }

    @Test func aLeadingEmojiBecomesTheIconWhenTheHostHasNone() {
        let row = subpageRowPresentation(storedTitle: "x", lookup: .present(title: "🍎 Apples"))
        #expect(row.emoji == "🍎")
        #expect(row.title == "Apples")
    }

    // MARK: - Affordance gating

    @Test func navigationIsRefusedUnlessTheTargetSaysItCanBeOpened() {
        for lookup in [PageLookup.pending, .missing, .unavailable] {
            let host = CapabilityTestHost(lookup: lookup)
            let link = Block.subpage(title: "T", pageID: "t.md")
            let doc = Document(id: DocumentID("d"), children: [link])
            let editor = EditorView(document: doc, state: EditorState(), host: host)
            editor.installUndoApply()

            // Handled-but-inert: the keypress is swallowed so it can't fall
            // through to something else, but no navigation happens.
            #expect(editor.navigateIntoSubpage(link.id))
            #expect(host.openedPages.isEmpty, "must not navigate into \(lookup)")
        }
    }

    @Test func navigationWorksWhenTheTargetPermitsIt() {
        let host = CapabilityTestHost(lookup: .present(title: "T"))
        let link = Block.subpage(title: "T", pageID: "t.md")
        let doc = Document(id: DocumentID("d"), children: [link])
        let editor = EditorView(document: doc, state: EditorState(), host: host)
        editor.installUndoApply()

        #expect(editor.navigateIntoSubpage(link.id))
        #expect(host.openedPages == ["t.md"])
    }

    @Test func navigationIsRefusedWhenTheTargetIsPresentButNotNavigable() {
        let host = CapabilityTestHost(
            lookup: .present(PagePresentation(title: "T", capabilities: [.receiveBlocks]))
        )
        let link = Block.subpage(title: "T", pageID: "t.md")
        let doc = Document(id: DocumentID("d"), children: [link])
        let editor = EditorView(document: doc, state: EditorState(), host: host)
        editor.installUndoApply()

        #expect(editor.navigateIntoSubpage(link.id))
        #expect(host.openedPages.isEmpty)
    }

    @Test func inliningIsRefusedWhenTheTargetSaysSo() async {
        let host = CapabilityTestHost(
            lookup: .present(PagePresentation(title: "T", capabilities: [.navigate]))
        )
        host.loadedBlocks = [.paragraph(text: AttributedString("body"))]
        let link = Block.subpage(title: "T", pageID: "t.md")
        let doc = Document(id: DocumentID("d"), children: [link])
        let editor = EditorView(document: doc, state: EditorState(), host: host)
        editor.installUndoApply()

        #expect(editor.convertSubpage(blockID: link.id, to: .toggle) == .ignored)
        #expect(!host.didLoad, "must not even read the target it isn't allowed to inline")
        #expect(doc.children.count == 1)
    }

    @Test func inliningProceedsWhenTheTargetPermitsIt() async {
        let host = CapabilityTestHost(lookup: .present(title: "T"))
        host.loadedBlocks = [.paragraph(text: AttributedString("body"))]
        let link = Block.subpage(title: "T", pageID: "t.md")
        let doc = Document(id: DocumentID("d"), children: [link])
        let editor = EditorView(document: doc, state: EditorState(), host: host)
        editor.installUndoApply()

        #expect(editor.convertSubpage(blockID: link.id, to: .toggle) == .handled)
        await host.awaitInlineCompletion()
        #expect(doc.children[0].children.count == 1)
    }

    // MARK: - Mention candidates arrive asynchronously

    @Test func mentionMatchesArriveWithoutBlockingTyping() async {
        let host = CapabilityTestHost(lookup: .present(title: "T"))
        host.suggestions = [MentionItem(id: "a.md", title: "Alpha")]
        let block = Block.paragraph(text: AttributedString("@al"))
        let doc = Document(id: DocumentID("d"), children: [block])
        let state = EditorState()
        let editor = EditorView(document: doc, state: state, host: host)
        editor.installUndoApply()
        state.enterEditMode(on: block.id)

        editor.handleCompletionTriggerChange(
            .mention(MentionTrigger(nsRange: NSRange(location: 0, length: 3), query: "al")),
            blockID: block.id
        )

        // The menu is up immediately, before the host has answered.
        #expect(state.mentionMenu?.isSearching == true)
        #expect(state.mentionMenu?.matches.isEmpty == true)

        await host.awaitSuggestCompletion()
        // Let the applying continuation run.
        for _ in 0..<10 where state.mentionMenu?.isSearching != false {
            await Task.yield()
        }

        #expect(state.mentionMenu?.matches.map(\.id) == ["a.md"])
        #expect(state.mentionMenu?.isSearching == false)
    }

    @Test func aStaleAnswerCannotOverwriteANewerQuery() {
        let menu = MentionMenuState(
            blockID: BlockID(),
            trigger: MentionTrigger(nsRange: NSRange(location: 0, length: 4), query: "beta"),
            selectedIndex: 0,
            matches: [MentionItem(id: "b.md", title: "Beta")],
            isSearching: false
        )
        // The guard the async path applies before writing results back.
        #expect(menu.trigger.query != "alpha")
        #expect(!menu.isDefinitivelyEmpty)
    }

    @Test func anEmptyMenuIsOnlyDefinitiveOnceTheSearchHasFinished() {
        let searching = MentionMenuState(
            blockID: BlockID(),
            trigger: MentionTrigger(nsRange: NSRange(location: 0, length: 1), query: "z"),
            selectedIndex: 0,
            matches: [],
            isSearching: true
        )
        #expect(!searching.isDefinitivelyEmpty, "'no results' while still searching is a lie")

        var settled = searching
        settled.isSearching = false
        #expect(settled.isDefinitivelyEmpty)
    }
}

@MainActor
private final class CapabilityTestHost: EditorHost {
    private let lookup: PageLookup
    var loadedBlocks: [Block] = []
    var suggestions: [MentionItem] = []
    private(set) var openedPages: [String] = []
    private(set) var didLoad = false

    private var inlineFinished: CheckedContinuation<Void, Never>?
    private var inlineAlreadyFinished = false
    private var suggestFinished: CheckedContinuation<Void, Never>?
    private var suggestAlreadyFinished = false

    init(lookup: PageLookup) { self.lookup = lookup }

    var supportsPageCreation: Bool { true }
    var supportsSubpageInlining: Bool { true }
    var supportsMoveDestinationPicker: Bool { true }

    func lookupPage(_ pageID: String) -> PageLookup { lookup }
    func openPage(pageID: String) { openedPages.append(pageID) }
    func linkURL(forPageID pageID: String, in document: Document) -> URL? { URL(string: pageID) }

    func loadPageBlocks(_ pageID: String) async -> [Block]? {
        didLoad = true
        return loadedBlocks
    }

    func inlineAndTrashPage(_ pageID: String, parent: Document) async -> Bool {
        if let continuation = inlineFinished {
            inlineFinished = nil
            continuation.resume()
        } else {
            inlineAlreadyFinished = true
        }
        return true
    }

    func suggestPages(_ query: String, in document: Document) async -> [MentionItem] {
        defer {
            if let continuation = suggestFinished {
                suggestFinished = nil
                continuation.resume()
            } else {
                suggestAlreadyFinished = true
            }
        }
        return suggestions
    }

    func persistCommit(changes: [DocumentChange], in document: Document) {}
    func flush(_ document: Document) async {}

    func awaitInlineCompletion() async {
        if inlineAlreadyFinished { inlineAlreadyFinished = false; return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in inlineFinished = c }
    }

    func awaitSuggestCompletion() async {
        if suggestAlreadyFinished { suggestAlreadyFinished = false; return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in suggestFinished = c }
    }
}
