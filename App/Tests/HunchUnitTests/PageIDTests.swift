import Testing
import Foundation
@testable import Hunch
import Quagmire

/// Durable page identity: the `clamshell-id` frontmatter line, the
/// `page.md#<id>` link-fragment form, and the minting rules (create-time
/// for new pages, first-commit for legacy pages).
@Suite("Page IDs")
struct PageIDTests {
    private func attr(_ s: String) -> AttributedString { AttributedString(s) }

    // MARK: - Envelope

    @Test func mintedIDsAreValid() {
        for _ in 0..<20 {
            #expect(ClamshellPageEnvelope.isValidPageID(ClamshellPageEnvelope.mintPageID()))
        }
    }

    @Test func pageIDValidation() {
        #expect(ClamshellPageEnvelope.isValidPageID("x7f3q2"))
        #expect(ClamshellPageEnvelope.isValidPageID("000000"))
        #expect(!ClamshellPageEnvelope.isValidPageID("x7f3q"), "too short")
        #expect(!ClamshellPageEnvelope.isValidPageID("x7f3q2a"), "too long")
        #expect(!ClamshellPageEnvelope.isValidPageID("X7F3Q2"), "uppercase")
        #expect(!ClamshellPageEnvelope.isValidPageID("x7-3q2"), "punctuation")
        #expect(!ClamshellPageEnvelope.isValidPageID(""))
    }

    @Test func splitPageFragment() {
        #expect(ClamshellPageEnvelope.splitPageFragment("p.md") == ("p.md", nil))
        #expect(ClamshellPageEnvelope.splitPageFragment("p.md#x7f3q2") == ("p.md", "x7f3q2"))
        #expect(ClamshellPageEnvelope.splitPageFragment("sub/p.md#abc123") == ("sub/p.md", "abc123"))
        #expect(ClamshellPageEnvelope.splitPageFragment("p.md#introduction") == ("p.md#introduction", nil),
                "a section anchor is not a page ID")
        #expect(ClamshellPageEnvelope.splitPageFragment("https://x.test/doc.md#abc123").path == "https://x.test/doc.md")
    }

    @Test func addingPageIDIsIdempotentAndParsedBack() {
        let lines = ClamshellPageEnvelope.addingPageID("x7f3q2", to: nil)
        #expect(ClamshellPageEnvelope.pageID(in: lines) == "x7f3q2")
        let again = ClamshellPageEnvelope.addingPageID("zzzzzz", to: lines)
        #expect(ClamshellPageEnvelope.pageID(in: again) == "x7f3q2", "existing ID wins")
    }

    @Test func pageIDSurvivesSerializeRoundTrip() {
        let blocks: [Block] = [.heading(level: .h1, text: attr("Title"))]
        let lines = ClamshellPageEnvelope.addingPageID("x7f3q2", to: nil)
        let text = ClamshellPageEnvelope.serialize(
            blocks: blocks,
            existingFrontmatterLines: lines,
            logFrontier: ["dev-A": 3]
        )
        let parsed = ClamshellPageEnvelope.parse(text)
        #expect(parsed.pageID == "x7f3q2")
        // And through a second save using the parsed frontmatter, with a
        // moved-on frontier — the ID line rides along untouched.
        let second = ClamshellPageEnvelope.serialize(
            blocks: parsed.blocks,
            existingFrontmatterLines: parsed.frontmatterLines,
            logFrontier: ["dev-A": 9]
        )
        #expect(ClamshellPageEnvelope.parse(second).pageID == "x7f3q2")
    }

    @Test func foreignFrontmatterLinesAreKeptAlongsideID() {
        let source = """
        ---
        tags: [alpha]
        clamshell-id: x7f3q2
        ---
        # Title
        """
        let parsed = ClamshellPageEnvelope.parse(source)
        #expect(parsed.pageID == "x7f3q2")
        let saved = ClamshellPageEnvelope.serialize(
            blocks: parsed.blocks,
            existingFrontmatterLines: parsed.frontmatterLines,
            logFrontier: [:]
        )
        #expect(saved.contains("tags: [alpha]"))
        #expect(saved.contains("clamshell-id: x7f3q2"))
    }

    // MARK: - Parser fragment acceptance

    @Test func subpageLinkWithFragmentParsesVerbatim() {
        let blocks = BlockParser.parse("[Some Page](Some-Page.md#x7f3q2)\n")
        guard case .documentLink(let title, let pageID) = blocks.first?.kind else {
            Issue.record("expected subpage, got \(String(describing: blocks.first?.kind))")
            return
        }
        #expect(String(title.characters) == "Some Page")
        #expect(pageID.rawValue == "Some-Page.md#x7f3q2")
    }

    @Test func plainSubpageLinkStillParses() {
        let blocks = BlockParser.parse("[Some Page](Some-Page.md)\n")
        guard case .documentLink(_, let pageID) = blocks.first?.kind else {
            Issue.record("expected subpage")
            return
        }
        #expect(pageID.rawValue == "Some-Page.md")
    }

    @Test func sectionAnchorFragmentIsNotASubpage() {
        let blocks = BlockParser.parse("[Doc](https://example.test/doc.md#introduction)\n")
        if case .documentLink = blocks.first?.kind {
            // Old behavior: any dest ending in .md was a subpage; a non-ID
            // fragment keeps the suffix from matching, so this must stay a
            // paragraph with an inline link.
            Issue.record("non-ID fragment should not produce a subpage")
        }
    }

    // MARK: - Minting on Clamshell

    private func makeRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clamshell-pageid-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test @MainActor func createPageMintsID() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)
        let rel = try clamshell.createDocument(title: "Fresh Page", requestedPath: nil, initialContent: nil)
        let text = try String(contentsOf: clamshell.url(for: rel), encoding: .utf8)
        let id = ClamshellPageEnvelope.parse(text).pageID
        #expect(id != nil)
        #expect(ClamshellPageEnvelope.isValidPageID(id ?? ""))
    }

    @Test @MainActor func legacyPageGainsStableIDOnFirstCommit() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)

        let url = clamshell.url(for: "legacy.md")
        try "# Legacy\n\nbody\n".write(to: url, atomically: true, encoding: .utf8)

        let block = Block.paragraph(text: attr("added"))
        let doc = Document(id: DocumentID("legacy"), children: [block])
        try await clamshell.commit(
            .fromEditorChanges([.inserted(block: block, parent: nil)]),
            to: doc,
            at: url
        )
        let first = ClamshellPageEnvelope.parse(try String(contentsOf: url, encoding: .utf8)).pageID
        #expect(first != nil, "legacy page should gain an ID on first save")

        let v1 = Block.paragraph(text: attr("added more"))
        doc.replaceChildrenFromSystemMutation([v1])
        try await clamshell.commit(
            .fromEditorChanges([.removed(block: block), .inserted(block: v1, parent: nil)]),
            to: doc,
            at: url
        )
        let second = ClamshellPageEnvelope.parse(try String(contentsOf: url, encoding: .utf8)).pageID
        #expect(second == first, "ID must be stable across saves")
    }

    // MARK: - Resolution

    @Test @MainActor func resolutionTruthTable() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)

        let rel = try clamshell.createDocument(title: "Target", requestedPath: nil, initialContent: nil)
        let id = try #require(ClamshellPageEnvelope.parse(
            String(contentsOf: clamshell.url(for: rel), encoding: .utf8)
        ).pageID)

        // Path hit, no fragment → syntactic result, exactly the old behavior.
        #expect(clamshell.resolveSubpageTarget(rel) == rel)
        // Fragment agreeing with the path resolves the same.
        #expect(clamshell.resolveSubpageTarget("\(rel)#\(id)") == rel)
        // Unknown ID falls back to the path.
        #expect(clamshell.resolveSubpageTarget("\(rel)#zzzzz9") == rel)
        // Non-md destination is not a subpage target.
        #expect(clamshell.resolveSubpageTarget("notes.txt") == nil)

        // Simulate a rename done under our feet: move the file, re-point
        // the index (renamePage will own this), leave stale links behind.
        let newRel = "Renamed.md"
        try FileManager.default.moveItem(at: clamshell.url(for: rel), to: clamshell.url(for: newRel))
        clamshell.registerPageID(id, forRel: newRel)
        try clamshell.rescan()

        // Stale path + fragment → ID wins.
        #expect(clamshell.resolveSubpageTarget("\(rel)#\(id)") == newRel)
        // Stale path, no fragment → stays the (missing) path; render shows broken.
        #expect(clamshell.resolveSubpageTarget(rel) == rel)

        // A new page reuses the old name: the fragment still names the
        // renamed page — ID beats path when they disagree.
        _ = try clamshell.createDocument(title: "Usurper", requestedPath: rel, initialContent: nil)
        #expect(clamshell.resolveSubpageTarget("\(rel)#\(id)") == newRel)
        #expect(clamshell.resolveSubpageTarget(rel) == rel, "fragment-less link follows the path")
    }

    @Test @MainActor func titleFallbackResolvesFragmentlessStaleLink() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)

        let rel = try clamshell.createDocument(title: "Unique Flower", requestedPath: nil, initialContent: nil)
        _ = try clamshell.createDocument(title: "Other", requestedPath: nil, initialContent: nil)

        #expect(clamshell.resolvePageTarget("stale-path.md", displayText: "Unique Flower") == rel)
        #expect(clamshell.resolvePageTarget("stale-path.md", displayText: "No Such Title") == "stale-path.md",
                "no unique title match → keep the (broken) path")

        // Duplicate titles refuse to guess.
        _ = try clamshell.createDocument(title: "Unique Flower", requestedPath: "Dup.md", initialContent: nil)
        #expect(clamshell.resolvePageTarget("stale-path.md", displayText: "Unique Flower") == "stale-path.md")
    }

    @Test @MainActor func ensurePageIDMintsForLegacyAndKeepsExisting() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)

        // Legacy page (no frontmatter): ensure mints + persists.
        let legacyURL = clamshell.url(for: "legacy.md")
        try "# Legacy\n".write(to: legacyURL, atomically: true, encoding: .utf8)
        let minted = await clamshell.ensurePageID(forRel: "legacy.md")
        #expect(minted != nil)
        #expect(ClamshellPageEnvelope.parse(try String(contentsOf: legacyURL, encoding: .utf8)).pageID == minted)

        // Page with an on-disk ID unknown to the index: ensure registers it
        // without rewriting the file.
        let seededBody = "---\nclamshell-id: seedd0\n---\n# Seeded\n"
        let seededURL = clamshell.url(for: "seeded.md")
        try seededBody.write(to: seededURL, atomically: true, encoding: .utf8)
        let before = try String(contentsOf: seededURL, encoding: .utf8)
        let found = await clamshell.ensurePageID(forRel: "seeded.md")
        #expect(found == "seedd0")
        #expect(try String(contentsOf: seededURL, encoding: .utf8) == before, "no rewrite when the ID already exists")

        // Missing page: nil, no file created.
        let missing = await clamshell.ensurePageID(forRel: "nope.md")
        #expect(missing == nil)
        #expect(!FileManager.default.fileExists(atPath: clamshell.url(for: "nope.md").path))
    }

    /// Regression: moving a block into a freshly-created page whose subpage
    /// link carries an ID fragment. The host must resolve the fragment
    /// before `page(atPath:)`, or the append fails with "Couldn't find
    /// destination page Bios.md#lobtxf".
    @Test @MainActor func appendResolvesFragmentedDestination() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)

        let rel = try clamshell.createDocument(title: "Bios", requestedPath: nil, initialContent: nil)
        let id = try #require(ClamshellPageEnvelope.parse(
            String(contentsOf: clamshell.url(for: rel), encoding: .utf8)
        ).pageID)
        let fragmented = "\(rel)#\(id)"

        // The raw fragmented path is not itself a file → append would throw.
        #expect(!FileManager.default.fileExists(atPath: clamshell.url(for: fragmented).path))
        // Resolution is what the host applies before page(atPath:).
        let resolved = try #require(clamshell.resolvePageTarget(fragmented))
        #expect(resolved == rel)

        let block = Block.paragraph(text: attr("moved block"))
        try await clamshell.page(atPath: resolved).append([block])

        let text = try String(contentsOf: clamshell.url(for: rel), encoding: .utf8)
        #expect(text.contains("moved block"))
    }

    @Test @MainActor func relativeMarkdownURLAppendsFragment() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)

        let base = root.appendingPathComponent("sub", isDirectory: true)
        let target = root.appendingPathComponent("My Page.md")
        let url = clamshell.relativeMarkdownURL(from: base, to: target, fragment: "x7f3q2")
        #expect(url?.relativeString == "../My%20Page.md#x7f3q2")
        #expect(url?.fragment == "x7f3q2")
        let bare = clamshell.relativeMarkdownURL(from: base, to: target)
        #expect(bare?.relativeString == "../My%20Page.md")
    }

    @Test @MainActor func inlineLinkFragmentResolvesThroughPagePath() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)

        let rel = try clamshell.createDocument(title: "Inline Target", requestedPath: nil, initialContent: nil)
        let id = try #require(ClamshellPageEnvelope.parse(
            String(contentsOf: clamshell.url(for: rel), encoding: .utf8)
        ).pageID)
        let docURL = clamshell.url(for: "source.md")

        let plain = try #require(URL(string: rel))
        #expect(clamshell.pagePath(for: plain, relativeTo: docURL) == rel)

        let withFragment = try #require(URL(string: "\(rel)#\(id)"))
        #expect(clamshell.pagePath(for: withFragment, relativeTo: docURL) == rel)

        // Stale path, live fragment → the ID rescues the inline link too.
        let newRel = "Inline-Renamed.md"
        try FileManager.default.moveItem(at: clamshell.url(for: rel), to: clamshell.url(for: newRel))
        clamshell.registerPageID(id, forRel: newRel)
        try clamshell.rescan()
        #expect(clamshell.pagePath(for: withFragment, relativeTo: docURL) == newRel)
    }
}
