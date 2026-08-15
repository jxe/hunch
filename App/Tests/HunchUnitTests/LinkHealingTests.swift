import Testing
import Foundation
@testable import Hunch
import Quagmire

/// The lazy link-healing pass: stale destinations converge to canonical
/// form (resolved rel + page-ID fragment) with proper purge/add journal
/// ops, so healed pages never resurrect their stale-link blocks.
@Suite("Link healing")
@MainActor
struct LinkHealingTests {
    private func makeRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clamshell-heal-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func attr(_ s: String) -> AttributedString { AttributedString(s) }

    private func pageID(of rel: String, in clamshell: Clamshell) throws -> String {
        let text = try String(contentsOf: clamshell.url(for: rel), encoding: .utf8)
        return try #require(ClamshellPageEnvelope.parse(text).pageID)
    }

    /// Build page A carrying a subpage row + inline link to `dest`, committed
    /// through the normal chain so the journal has A's adds.
    private func makeLinkingPage(
        to dest: String,
        inlineTo inlineDest: String,
        in clamshell: Clamshell
    ) async throws -> Document {
        var inline = attr("see B")
        inline.link = URL(string: inlineDest)
        let blocks: [Block] = [
            .subpage(title: "B", pageID: dest),
            .paragraph(text: inline),
        ]
        let doc = Document(id: DocumentID("A"), children: blocks)
        let changes = RecoveryChangeDiff.derive(pre: [], post: blocks)
        try await clamshell.commit(
            .fromEditorChanges(changes),
            to: doc,
            at: clamshell.url(for: "A.md")
        )
        return doc
    }

    @Test func healRewritesStaleLinksAndJournalFollows() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)

        _ = try clamshell.createPage(title: "B", requestedPath: "B.md", initialContent: nil)
        let id = try pageID(of: "B.md", in: clamshell)
        // Links carry the fragment already (the steady state a prior heal
        // pass produces) — that's what lets the rename below be rescued.
        let doc = try await makeLinkingPage(to: "B.md#\(id)", inlineTo: "B.md#\(id)", in: clamshell)
        let staleSubpageHash = doc.children[0].atomicHash
        let inlineHash = doc.children[1].atomicHash

        // Rename B under A's feet (what renamePage will do): move the file,
        // re-point the index.
        try FileManager.default.moveItem(at: clamshell.url(for: "B.md"), to: clamshell.url(for: "B-New.md"))
        clamshell.registerPageID(id, forRel: "B-New.md")
        try clamshell.rescan()

        let healed = await clamshell.healLinks(in: doc, at: clamshell.url(for: "A.md"))
        #expect(healed == 2, "subpage row + inline link should both rewrite")

        // Live doc and disk both carry the canonical destinations.
        guard case .subpage(_, let newDest) = doc.children[0].kind else {
            Issue.record("expected subpage row")
            return
        }
        #expect(newDest == "B-New.md#\(id)")
        let inlineLink = try #require(doc.children[1].text.runs.compactMap(\.link).first)
        #expect(inlineLink.relativeString == "B-New.md#\(id)")
        let diskText = try String(contentsOf: clamshell.url(for: "A.md"), encoding: .utf8)
        #expect(diskText.contains("B-New.md#\(id)"))
        #expect(!diskText.contains("(B.md#\(id))"), "stale destination must be gone from disk")

        // Journal semantics differ by block flavor. The subpage's pageID is
        // part of its content identity, so the heal must tombstone the old
        // hash and add the new — an empty-log commit would leave the old
        // hash add-backed-and-missing and reconcile would resurrect it.
        // Inline link URLs are intentionally excluded from block identity
        // (like bold/italic), so the paragraph's hash is stable across the
        // rewrite: no ops, still alive, still live in the doc.
        let journal = clamshell.log.readJournal(page: "A.md")
        let intent = PatchEngine.intent(from: journal)
        guard case .tombstoned = intent.byHash[staleSubpageHash] else {
            Issue.record("stale subpage hash should be tombstoned")
            return
        }
        #expect(doc.children[1].atomicHash == inlineHash,
                "inline rewrite is hash-invisible by design")
        guard case .alive = intent.byHash[doc.children[0].atomicHash] else {
            Issue.record("healed subpage hash should be alive")
            return
        }

        // The regression that matters: reconcile restores NOTHING.
        let recon = PatchEngine.reconcile(intent: intent, doc: doc.children)
        #expect(recon.inserts.isEmpty, "reconcile must not resurrect stale-link blocks")
        #expect(recon.restoredHashes.isEmpty)
    }

    @Test func healAddsFragmentsToLegacyLinks() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)

        // Legacy target without an ID on disk.
        try "# B\n".write(to: clamshell.url(for: "B.md"), atomically: true, encoding: .utf8)
        try clamshell.rescan()
        let doc = try await makeLinkingPage(to: "B.md", inlineTo: "B.md", in: clamshell)

        let healed = await clamshell.healLinks(in: doc, at: clamshell.url(for: "A.md"))
        #expect(healed == 2)

        // The heal minted B's ID and enriched both links with it.
        let mintedID = try pageID(of: "B.md", in: clamshell)
        guard case .subpage(_, let dest) = doc.children[0].kind else {
            Issue.record("expected subpage row")
            return
        }
        #expect(dest == "B.md#\(mintedID)")

        // Idempotent: a second pass rewrites nothing.
        let again = await clamshell.healLinks(in: doc, at: clamshell.url(for: "A.md"))
        #expect(again == 0)
    }

    @Test func healLeavesExternalAndBrokenLinksAlone() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)

        var external = attr("site")
        external.link = URL(string: "https://example.test/doc.md")
        let blocks: [Block] = [
            .subpage(title: "Gone", pageID: "Gone.md"),
            .paragraph(text: external),
        ]
        let doc = Document(id: DocumentID("A"), children: blocks)
        try await clamshell.commit(
            .fromEditorChanges(RecoveryChangeDiff.derive(pre: [], post: blocks)),
            to: doc,
            at: clamshell.url(for: "A.md")
        )

        let healed = await clamshell.healLinks(in: doc, at: clamshell.url(for: "A.md"))
        #expect(healed == 0)
        guard case .subpage(_, let dest) = doc.children[0].kind else { return }
        #expect(dest == "Gone.md", "a broken link stays verbatim until its target reappears")
    }

    @Test func healResolvesFragmentlessStaleLinkByTitle() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)

        // Target created under one name, then renamed externally with NO
        // fragment recorded anywhere — only the title matches.
        _ = try clamshell.createPage(title: "Unique Peony", requestedPath: "Old-Name.md", initialContent: nil)
        let id = try pageID(of: "Old-Name.md", in: clamshell)
        try FileManager.default.moveItem(at: clamshell.url(for: "Old-Name.md"), to: clamshell.url(for: "Peony.md"))
        clamshell.unregisterPageIDs(forRel: "Old-Name.md")
        try clamshell.rescan()
        clamshell.registerPageID(id, forRel: "Peony.md")
        // The fallback matches against live titles — warm the cache the way
        // a real session does (graph build doubles as a bulk title warm).
        _ = await clamshell.buildLinkGraph()

        let blocks: [Block] = [.subpage(title: "Unique Peony", pageID: "Old-Name.md")]
        let doc = Document(id: DocumentID("A"), children: blocks)
        try await clamshell.commit(
            .fromEditorChanges(RecoveryChangeDiff.derive(pre: [], post: blocks)),
            to: doc,
            at: clamshell.url(for: "A.md")
        )

        let healed = await clamshell.healLinks(in: doc, at: clamshell.url(for: "A.md"))
        #expect(healed == 1)
        guard case .subpage(_, let dest) = doc.children[0].kind else { return }
        #expect(dest == "Peony.md#\(id)")
    }
}
