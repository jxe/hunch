import Foundation
import SwiftUI
import Testing
@testable import Quagmire

/// Ordering guarantees for the operations that move content between documents.
///
/// Every one of them has a window where a crash could lose the only copy of
/// something, and every one is written to make that window produce a
/// *duplicate* instead: create the destination before removing the source,
/// flush the parent before retiring the child. Until now those orderings were
/// asserted by comment only, and the host stubs in the other suites always
/// succeeded — so nothing checked what happens when the destination write
/// fails, which is exactly when the ordering matters.
@MainActor
@Suite("Cross-document durability")
struct CrossDocumentDurabilityTests {

    // MARK: - Create from block

    @Test func aFailedCreateLeavesTheSourceBlockIntact() async {
        let host = FailureHost()
        host.createSucceeds = false
        let block = Block.paragraph(text: AttributedString("Promote me"))
        let doc = Document(id: DocumentID("d"), children: [block])
        let editor = EditorView(document: doc, state: EditorState(), host: host)
        editor.installUndoApply()

        editor.convertBlockToDocument(blockID: block.id, preferredTitle: nil)
        await host.settle()

        #expect(doc.children.map(\.id) == [block.id], "nothing to link to, so nothing is replaced")
        #expect(String(doc.children[0].text.characters) == "Promote me")
    }

    @Test func aSuccessfulCreateReplacesTheSourceOnlyAfterTheTargetExists() async {
        let host = FailureHost()
        let block = Block.paragraph(text: AttributedString("Promote me"))
        let doc = Document(id: DocumentID("d"), children: [block])
        let editor = EditorView(document: doc, state: EditorState(), host: host)
        editor.installUndoApply()

        editor.convertBlockToDocument(blockID: block.id, preferredTitle: nil)
        await host.settle()

        #expect(host.created == ["Promote me"], "the destination is written first")
        guard case .documentLink = doc.children[0].kind else {
            Issue.record("expected the source row to become a link")
            return
        }
        #expect(doc.children[0].id == block.id, "and it replaces the row in place")
    }

    // MARK: - Turn Into on a link (load, inline, then retire the source)

    @Test func aFailedLoadLeavesTheLinkIntact() async {
        let host = FailureHost()
        host.loadedBlocks = nil
        let link = Block.documentLink(label: AttributedString("Child"), reference: DocumentReference("child.md"))
        let doc = Document(id: DocumentID("d"), children: [link])
        let editor = EditorView(document: doc, state: EditorState(), host: host)
        editor.installUndoApply()

        editor.convertDocumentLink(blockID: link.id, to: .toggle)
        await host.settle()

        guard case .documentLink = doc.children[0].kind else {
            Issue.record("a failed load must not convert the row")
            return
        }
        #expect(!host.didRetire, "and must never retire the document it could not read")
    }

    @Test func theSourceIsRetiredOnlyAfterItsContentIsInTheParent() async {
        let host = FailureHost()
        host.loadedBlocks = [.paragraph(text: AttributedString("inlined body"))]
        let link = Block.documentLink(label: AttributedString("Child"), reference: DocumentReference("child.md"))
        let doc = Document(id: DocumentID("d"), children: [link])
        let editor = EditorView(document: doc, state: EditorState(), host: host)
        editor.installUndoApply()

        editor.convertDocumentLink(blockID: link.id, to: .toggle)
        await host.settle()

        #expect(host.didRetire)
        #expect(host.documentContainedInlinedBodyAtRetireTime == true,
                "the parent must already hold the content when the source is retired")
    }

    @Test func aFailedRetireLeavesTheInlinedCopyInPlace() async {
        let host = FailureHost()
        host.loadedBlocks = [.paragraph(text: AttributedString("inlined body"))]
        host.retireSucceeds = false
        let link = Block.documentLink(label: AttributedString("Child"), reference: DocumentReference("child.md"))
        let doc = Document(id: DocumentID("d"), children: [link])
        let editor = EditorView(document: doc, state: EditorState(), host: host)
        editor.installUndoApply()

        editor.convertDocumentLink(blockID: link.id, to: .toggle)
        await host.settle()

        // A duplicate (content here *and* still in the source document) is the
        // designed failure mode. Losing the inline would be the bad one.
        #expect(doc.children[0].children.count == 1)
        #expect(String(doc.children[0].children[0].text.characters) == "inlined body")
    }

    // MARK: - Moving blocks into another document

    @Test func aFailedAppendLeavesTheSourceBlocksWhereTheyAre() async {
        let host = FailureHost()
        host.appendSucceeds = false
        let moving = Block.paragraph(text: AttributedString("moving"))
        let stay = Block.paragraph(text: AttributedString("stay"))
        let doc = Document(id: DocumentID("d"), children: [moving, stay])
        let editor = EditorView(document: doc, state: EditorState(), host: host)
        editor.installUndoApply()

        await editor.moveBlocks(ids: [moving.id], intoDocument: DocumentReference("other.md"))

        #expect(doc.children.map(\.id) == [moving.id, stay.id],
                "a move that never landed must not remove anything")
    }

    @Test func aSuccessfulAppendRemovesTheSourceBlocksAfterTheWrite() async {
        let host = FailureHost()
        let moving = Block.paragraph(text: AttributedString("moving"))
        let stay = Block.paragraph(text: AttributedString("stay"))
        let doc = Document(id: DocumentID("d"), children: [moving, stay])
        let editor = EditorView(document: doc, state: EditorState(), host: host)
        editor.installUndoApply()

        await editor.moveBlocks(ids: [moving.id], intoDocument: DocumentReference("other.md"))

        #expect(host.appendedBlocks.map { String($0.text.characters) } == ["moving"])
        #expect(doc.children.map(\.id) == [stay.id])
    }

    @Test func copyingIntoAnotherDocumentSendsFreshIDsAndKeepsTheSource() async {
        let host = FailureHost()
        let source = Block.paragraph(text: AttributedString("copy me"))
        let doc = Document(id: DocumentID("d"), children: [source])
        let editor = EditorView(document: doc, state: EditorState(), host: host)
        editor.installUndoApply()

        await editor.copyBlocks(ids: [source.id], intoDocument: DocumentReference("other.md"))

        #expect(doc.children.map(\.id) == [source.id], "a copy leaves the source alone")
        #expect(host.appendedBlocks.count == 1)
        #expect(host.appendedBlocks[0].id != source.id, "the destination gets its own identity")
    }

    // MARK: - Deleting a link

    @Test func deletingALinkRowNotifiesTheHostOnceAfterTheCommit() {
        let host = FailureHost()
        let link = Block.documentLink(label: AttributedString("Child"), reference: DocumentReference("child.md"))
        let doc = Document(id: DocumentID("d"), children: [link, .paragraph(text: AttributedString("after"))])
        let state = EditorState()
        let editor = EditorView(document: doc, state: state, host: host)
        editor.installUndoApply()

        state.setCursor(link.id)
        editor.deleteSelection()

        #expect(host.deletedLinks.map(\.rawValue) == ["child.md"])
        #expect(host.documentStillHadLinkAtCallbackTime == false,
                "the host must see the post-delete document, so it can ask whether anything still points at the target")
    }

    @Test func deletingAnInlineLinkDoesNotNotifyTheHost() {
        var text = AttributedString("see this")
        text.link = URL(string: "child.md")
        let block = Block.paragraph(text: text)
        let host = FailureHost()
        let doc = Document(id: DocumentID("d"), children: [block, .paragraph(text: AttributedString("after"))])
        let state = EditorState()
        let editor = EditorView(document: doc, state: state, host: host)
        editor.installUndoApply()

        state.setCursor(block.id)
        editor.deleteSelection()

        #expect(host.deletedLinks.isEmpty,
                "an inline link is prose, not a structural reference — deleting it is not a signal about the target")
    }
}

/// A host whose every cross-document operation can be made to fail.
@MainActor
private final class FailureHost: EditorHostDefaults {
    var createSucceeds = true
    var retireSucceeds = true
    var appendSucceeds = true
    var loadedBlocks: [Block]? = []

    private(set) var created: [String] = []
    private(set) var appendedBlocks: [Block] = []
    private(set) var didRetire = false
    private(set) var deletedLinks: [DocumentReference] = []
    private(set) var documentContainedInlinedBodyAtRetireTime: Bool?
    private(set) var documentStillHadLinkAtCallbackTime: Bool?

    private var pending = 0
    private var idle: CheckedContinuation<Void, Never>?

    var supportsDocumentCreation: Bool { true }
    var supportsDocumentInlining: Bool { true }
    var supportsMoveDestinationPicker: Bool { true }

    func lookupDocument(_ reference: DocumentReference) -> DocumentLookup { .present(title: nil) }
    func linkURL(for reference: DocumentReference, in document: Document) -> URL? { URL(string: reference.rawValue) }
    func resolveReference(from url: URL, in document: Document) -> DocumentReference? {
        url.absoluteString.hasSuffix(".md") ? DocumentReference(url.absoluteString) : nil
    }

    func createDocument(
        title: String,
        requestedReference: DocumentReference?,
        initialContent: [Block]?
    ) async -> DocumentReference? {
        enter()
        defer { leave() }
        guard createSucceeds else { return nil }
        created.append(title)
        return DocumentReference("\(title).md")
    }

    func loadDocumentBlocks(_ reference: DocumentReference) async -> [Block]? {
        enter()
        defer { if loadedBlocks == nil { leave() } }
        return loadedBlocks
    }

    func inlineAndRetireDocument(_ reference: DocumentReference, parent: Document) async -> Bool {
        defer { leave() }
        didRetire = true
        documentContainedInlinedBodyAtRetireTime = parent.children.contains { block in
            block.children.contains { String($0.text.characters) == "inlined body" }
        }
        return retireSucceeds
    }

    func appendToDocument(_ reference: DocumentReference, _ blocks: [Block]) async -> Bool {
        guard appendSucceeds else { return false }
        appendedBlocks = blocks
        return true
    }

    func didDeleteDocumentLink(reference: DocumentReference, label: String, from document: Document) {
        deletedLinks.append(reference)
        var found = false
        document.walk { block, _, _ in
            if case .documentLink(_, let r) = block.kind, r == reference { found = true }
        }
        documentStillHadLinkAtCallbackTime = found
    }

    func persistCommit(changes: [DocumentChange], in document: Document) {}
    func flush(_ document: Document) async {}

    // The editor drives these flows from detached tasks. Rather than yielding a
    // guessed number of times, wait for the host to see its last call.
    private func enter() { pending += 1 }
    private func leave() {
        pending -= 1
        if pending <= 0, let continuation = idle {
            idle = nil
            continuation.resume()
        }
    }

    func settle() async {
        // Give the spawned task a chance to reach its first host call.
        for _ in 0..<5 where pending == 0 { await Task.yield() }
        guard pending > 0 else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in idle = c }
        // Let the continuation after the final await run.
        for _ in 0..<5 { await Task.yield() }
    }
}
