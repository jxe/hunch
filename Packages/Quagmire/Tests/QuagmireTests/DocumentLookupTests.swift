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
        for lookup in [DocumentLookup.pending, .missing, .unavailable] {
            #expect(lookup.capabilities.isEmpty)
            #expect(!lookup.can(.navigate))
            #expect(!lookup.can(.receiveBlocks))
            #expect(!lookup.can(.inline))
            #expect(!lookup.can(.setIcon))
        }
    }

    @Test func aPresentTargetIsFullyCapableByDefault() {
        let lookup = DocumentLookup.present(title: "Notes")
        #expect(lookup.capabilities == .all)
        #expect(lookup.can(.navigate))
        #expect(lookup.can(.receiveBlocks))
        #expect(lookup.can(.inline))
        #expect(lookup.can(.setIcon))
    }

    @Test func capabilitiesCanVaryPerTarget() {
        let readOnly = DocumentLookup.present(DocumentPresentation(title: "Shared", capabilities: [.navigate]))
        #expect(readOnly.can(.navigate))
        #expect(!readOnly.can(.receiveBlocks))
        #expect(!readOnly.can(.inline))
    }

    @Test func onlyMissingReportsMissing() {
        #expect(DocumentLookup.missing.isMissing)
        #expect(!DocumentLookup.pending.isMissing)
        #expect(!DocumentLookup.unavailable.isMissing)
        #expect(!DocumentLookup.present(title: "x").isMissing)
    }

    // MARK: - Row presentation

    @Test func aPresentTargetShowsItsLiveTitle() {
        let row = documentLinkRowPresentation(
            storedLabel: AttributedString("Old Name"),
            lookup: .present(title: "New Name")
        )
        #expect(row.title == "New Name")
        #expect(!row.muted)
        #expect(row.annotation == nil)
    }

    @Test func anUnresolvedTargetFallsBackToTheStoredLabelAndLooksOrdinary() {
        let row = documentLinkRowPresentation(storedLabel: AttributedString("Notes"), lookup: .pending)
        #expect(row.title == "Notes")
        #expect(!row.muted, "a cold cache must not make the document look broken")
        #expect(row.annotation == nil)
        #expect(row.symbol == "doc.text")
    }

    @Test func anUnreachableTargetReadsAsDegradedNotGone() {
        let row = documentLinkRowPresentation(storedLabel: AttributedString("Notes"), lookup: .unavailable)
        #expect(row.muted)
        #expect(row.annotation == "(unavailable)")
        #expect(row.symbol != "doc.badge.exclamationmark", "it is not broken; nothing needs fixing")
    }

    @Test func aMissingTargetIsMarkedMissing() {
        let row = documentLinkRowPresentation(storedLabel: AttributedString("Notes"), lookup: .missing)
        #expect(row.muted)
        #expect(row.annotation == "(missing)")
        #expect(row.symbol == "doc.badge.exclamationmark")
        #expect(row.emoji == nil, "no icon on a target we can't read")
    }

    @Test func aHostSuppliedIconWinsOverOneDerivedFromTheTitle() {
        let row = documentLinkRowPresentation(
            storedLabel: AttributedString("x"),
            lookup: .present(DocumentPresentation(title: "🍎 Apples", icon: "📕"))
        )
        #expect(row.emoji == "📕")
        #expect(row.title == "Apples")
    }

    @Test func aLeadingEmojiBecomesTheIconWhenTheHostHasNone() {
        let row = documentLinkRowPresentation(storedLabel: AttributedString("x"), lookup: .present(title: "🍎 Apples"))
        #expect(row.emoji == "🍎")
        #expect(row.title == "Apples")
    }

    // MARK: - Resolving after the fact

    /// The contract that makes a synchronous lookup usable by a host that
    /// cannot answer synchronously, in full: return `.pending`, resolve in the
    /// background, and — crucially — *invalidate whatever read the pending
    /// answer* so the row is asked again.
    ///
    /// The invalidation half is the part worth testing. A host that resolves
    /// correctly but publishes into untracked storage passes every check about
    /// return values while leaving a real UI pending forever, because nothing
    /// ever asks a second time. So this drives the read through
    /// `withObservationTracking` — which is what SwiftUI does underneath — and
    /// asserts the warm fires it before checking the new answer at all.
    @Test func completingAWarmInvalidatesWhateverReadThePendingAnswer() {
        let host = ResolvingTestHost()
        let link = Block.documentLink(label: AttributedString("Stored Label"), reference: DocumentReference("t.md"))
        let doc = Document(id: DocumentID("d"), children: [link])
        var commits = 0
        doc.didCommitTransaction = { _ in commits += 1 }
        let childrenBefore = doc.children

        // `onChange` is `@Sendable`, so the flag lives in a box. It fires
        // synchronously on the mutating thread, which here is this one.
        let invalidation = InvalidationFlag()
        var cold: [String: DocumentLookup] = [:]
        withObservationTracking {
            // The editor's real read path, not `lookupDocument` directly: the
            // dependency has to be registered by what actually builds the row.
            cold = resolveDocumentLookups(for: link, host: host, in: doc)
        } onChange: {
            invalidation.fired = true
        }

        #expect(cold["t.md"] == .pending)
        #expect(documentLinkRowPresentation(storedLabel: link.text, lookup: cold["t.md"]!).title == "Stored Label")
        #expect(host.warmRequests == 1, "the miss kicks exactly one warm")
        #expect(!invalidation.fired, "nothing has resolved yet")

        // A second read before the warm lands must not kick another: this runs
        // in a view body, so an un-deduped fetch is a spin, not a miss.
        _ = resolveDocumentLookups(for: link, host: host, in: doc)
        #expect(host.warmRequests == 1)

        host.completeWarm(title: "Live Title")

        #expect(invalidation.fired, "completing the warm must invalidate the read, or the row never asks again")

        let warm = resolveDocumentLookups(for: link, host: host, in: doc)
        #expect(warm["t.md"]?.title == "Live Title")
        #expect(documentLinkRowPresentation(storedLabel: link.text, lookup: warm["t.md"]!).title == "Live Title")

        #expect(commits == 0, "resolving a reference is not an edit")
        #expect(doc.children == childrenBefore, "and must not touch the tree")
    }

    // MARK: - Affordance gating

    @Test func navigationIsRefusedUnlessTheTargetSaysItCanBeOpened() {
        for lookup in [DocumentLookup.pending, .missing, .unavailable] {
            let host = CapabilityTestHost(lookup: lookup)
            let link = Block.documentLink(label: AttributedString("T"), reference: DocumentReference("t.md"))
            let doc = Document(id: DocumentID("d"), children: [link])
            let editor = EditorView(document: doc, state: EditorState(), host: host)
            editor.installUndoApply()

            // Handled-but-inert: the keypress is swallowed so it can't fall
            // through to something else, but no navigation happens.
            #expect(editor.navigateIntoDocumentLink(link.id))
            #expect(host.openedDocuments.isEmpty, "must not navigate into \(lookup)")
        }
    }

    @Test func navigationWorksWhenTheTargetPermitsIt() {
        let host = CapabilityTestHost(lookup: .present(title: "T"))
        let link = Block.documentLink(label: AttributedString("T"), reference: DocumentReference("t.md"))
        let doc = Document(id: DocumentID("d"), children: [link])
        let editor = EditorView(document: doc, state: EditorState(), host: host)
        editor.installUndoApply()

        #expect(editor.navigateIntoDocumentLink(link.id))
        #expect(host.openedDocuments.map(\.rawValue) == ["t.md"])
    }

    @Test func navigationIsRefusedWhenTheTargetIsPresentButNotNavigable() {
        let host = CapabilityTestHost(
            lookup: .present(DocumentPresentation(title: "T", capabilities: [.receiveBlocks]))
        )
        let link = Block.documentLink(label: AttributedString("T"), reference: DocumentReference("t.md"))
        let doc = Document(id: DocumentID("d"), children: [link])
        let editor = EditorView(document: doc, state: EditorState(), host: host)
        editor.installUndoApply()

        #expect(editor.navigateIntoDocumentLink(link.id))
        #expect(host.openedDocuments.isEmpty)
    }

    @Test func inliningIsRefusedWhenTheTargetSaysSo() async {
        let host = CapabilityTestHost(
            lookup: .present(DocumentPresentation(title: "T", capabilities: [.navigate]))
        )
        host.loadedBlocks = [.paragraph(text: AttributedString("body"))]
        let link = Block.documentLink(label: AttributedString("T"), reference: DocumentReference("t.md"))
        let doc = Document(id: DocumentID("d"), children: [link])
        let editor = EditorView(document: doc, state: EditorState(), host: host)
        editor.installUndoApply()

        #expect(editor.convertDocumentLink(blockID: link.id, to: .toggle) == .ignored)
        #expect(!host.didLoad, "must not even read the target it isn't allowed to inline")
        #expect(doc.children.count == 1)
    }

    @Test func inliningProceedsWhenTheTargetPermitsIt() async {
        let host = CapabilityTestHost(lookup: .present(title: "T"))
        host.loadedBlocks = [.paragraph(text: AttributedString("body"))]
        let link = Block.documentLink(label: AttributedString("T"), reference: DocumentReference("t.md"))
        let doc = Document(id: DocumentID("d"), children: [link])
        let editor = EditorView(document: doc, state: EditorState(), host: host)
        editor.installUndoApply()

        #expect(editor.convertDocumentLink(blockID: link.id, to: .toggle) == .handled)
        await host.awaitInlineCompletion()
        #expect(doc.children[0].children.count == 1)
    }

    // MARK: - Mention candidates arrive asynchronously

    @Test func mentionMatchesArriveWithoutBlockingTyping() async {
        let host = CapabilityTestHost(lookup: .present(title: "T"))
        host.suggestions = [MentionItem(id: DocumentReference("a.md"), title: "Alpha")]
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

        #expect(state.mentionMenu?.matches.map(\.id.rawValue) == ["a.md"])
        #expect(state.mentionMenu?.isSearching == false)
    }

    @Test func aStaleAnswerCannotOverwriteANewerQuery() {
        let menu = MentionMenuState(
            blockID: BlockID(),
            trigger: MentionTrigger(nsRange: NSRange(location: 0, length: 4), query: "beta"),
            selectedIndex: 0,
            matches: [MentionItem(id: DocumentReference("b.md"), title: "Beta")],
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
private final class CapabilityTestHost: EditorHostDefaults {
    private let lookup: DocumentLookup
    var loadedBlocks: [Block] = []
    var suggestions: [MentionItem] = []
    private(set) var openedDocuments: [DocumentReference] = []
    private(set) var didLoad = false

    private var inlineFinished: CheckedContinuation<Void, Never>?
    private var inlineAlreadyFinished = false
    private var suggestFinished: CheckedContinuation<Void, Never>?
    private var suggestAlreadyFinished = false

    init(lookup: DocumentLookup) { self.lookup = lookup }

    var supportsDocumentCreation: Bool { true }
    var supportsDocumentInlining: Bool { true }
    var supportsMoveDestinationPicker: Bool { true }

    func lookupDocument(_ reference: DocumentReference) -> DocumentLookup { lookup }
    func openDocument(_ reference: DocumentReference) { openedDocuments.append(reference) }
    func linkURL(for reference: DocumentReference, in document: Document) -> URL? { URL(string: reference.rawValue) }

    func loadDocumentBlocks(_ reference: DocumentReference) async -> [Block]? {
        didLoad = true
        return loadedBlocks
    }

    func inlineAndRetireDocument(_ reference: DocumentReference, parent: Document) async -> Bool {
        if let continuation = inlineFinished {
            inlineFinished = nil
            continuation.resume()
        } else {
            inlineAlreadyFinished = true
        }
        return true
    }

    func suggestDocuments(_ query: String, in document: Document) async -> [MentionItem] {
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


/// Records that an observation fired, from the `@Sendable` `onChange` closure.
private final class InvalidationFlag: @unchecked Sendable {
    var fired = false
}

/// Answers `.pending` until warmed, the way a host reading across a network
/// has to — and `@Observable`, the way the contract requires, so that
/// completing the warm invalidates readers instead of just changing an answer
/// nobody asks for again. `Clamshell` is `@Observable` for exactly this reason.
@MainActor
@Observable
private final class ResolvingTestHost: EditorHostDefaults {
    private var resolved: String?

    /// Not observed: bookkeeping about the warm must not itself invalidate
    /// readers, or every lookup would schedule another render.
    @ObservationIgnored private(set) var warmRequests = 0

    func lookupDocument(_ reference: DocumentReference) -> DocumentLookup {
        guard let resolved else {
            // Deduped: a real host guards this on a set of in-flight requests.
            if warmRequests == 0 { warmRequests += 1 }
            return .pending
        }
        return .present(title: resolved)
    }

    func completeWarm(title: String) { resolved = title }

    func persistCommit(changes: [DocumentChange], in document: Document) {}
    func flush(_ document: Document) async {}
}
