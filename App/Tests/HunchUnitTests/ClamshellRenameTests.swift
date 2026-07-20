import Testing
import Foundation
@testable import Hunch
@testable import Editor

/// `renamePage(at:toMatchTitle:)` — the O(1) rename: file + history +
/// bookkeeping move, no link rewriting (resolution + healing own that).
@Suite("Clamshell rename")
@MainActor
struct ClamshellRenameTests {
    private func makeRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clamshell-rename-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func attr(_ s: String) -> AttributedString { AttributedString(s) }

    private func pageID(of rel: String, in clamshell: Clamshell) throws -> String {
        let text = try String(contentsOf: clamshell.url(for: rel), encoding: .utf8)
        return try #require(ClamshellPageEnvelope.parse(text).pageID)
    }

    // MARK: - Slug predicate

    @Test func filenameMatchesTitleTruthTable() {
        #expect(Clamshell.filenameMatchesTitle(relativePath: "My-Page.md", title: "My Page"))
        #expect(Clamshell.filenameMatchesTitle(relativePath: "my-page.md", title: "My Page"), "case-insensitive")
        #expect(Clamshell.filenameMatchesTitle(relativePath: "My-Page-2.md", title: "My Page"), "-N disambiguation matches")
        #expect(Clamshell.filenameMatchesTitle(relativePath: "sub/My-Page.md", title: "My Page"), "directory ignored")
        #expect(Clamshell.filenameMatchesTitle(relativePath: "Untitled.md", title: ""), "empty title slugs to Untitled")
        #expect(!Clamshell.filenameMatchesTitle(relativePath: "Old-Name.md", title: "My Page"))
        #expect(!Clamshell.filenameMatchesTitle(relativePath: "My-Page-extra.md", title: "My Page"), "non-numeric suffix is a different name")
        #expect(!Clamshell.filenameMatchesTitle(relativePath: "My-Page", title: "My Page"), "not a .md path")
    }

    @Test func slugTransliteratesEmoji() {
        #expect(Clamshell.slugStem(for: "🎉") == "party-popper")
        #expect(Clamshell.slugStem(for: "🎉 Party Time") == "party-popper-Party-Time")
        #expect(Clamshell.slugStem(for: "Notes 👍🏽") == "Notes-thumbs-up-sign", "skin-tone modifier dropped")
        #expect(Clamshell.slugStem(for: "👨‍👩‍👧") == "man-woman-girl", "ZWJ sequence expands, joiners dropped")
        #expect(Clamshell.slugStem(for: "café") == "café" || Clamshell.slugStem(for: "café") == "caf", "accented Latin is NOT transliterated")
        #expect(Clamshell.slugStem(for: "🇯🇵") == "Untitled", "flag scaffolding dropped, falls back")
        // Rename matching stays consistent with the emoji-aware slug.
        #expect(Clamshell.filenameMatchesTitle(relativePath: "party-popper.md", title: "🎉"))
    }

    // MARK: - Rename mechanics

    @Test func basicRenameMovesFileHistoryAndBookkeeping() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)

        let rel = try clamshell.createPage(title: "Old Title", requestedPath: nil, initialContent: nil)
        #expect(rel == "Old-Title.md")
        let id = try pageID(of: rel, in: clamshell)

        // Give the page a journal so the history dir exists.
        let block = Block.paragraph(text: attr("body"))
        let doc = Document(url: clamshell.url(for: rel), children: [block])
        try await clamshell.commit(.fromEditorOps([.insert(hash: block.atomicHash, parent: nil, block: block)]), to: doc)

        let result = try await clamshell.renamePage(at: clamshell.url(for: rel), toMatchTitle: "New Title")
        #expect(result.oldRelativePath == "Old-Title.md")
        #expect(result.newRelativePath == "New-Title.md")

        #expect(!FileManager.default.fileExists(atPath: clamshell.url(for: rel).path))
        #expect(FileManager.default.fileExists(atPath: clamshell.url(for: "New-Title.md").path))
        #expect(clamshell.entry(at: "New-Title.md") != nil)
        #expect(clamshell.entry(at: "Old-Title.md") == nil)

        // History dir traveled.
        let historyRoot = root.appendingPathComponent(RecoveryLog.directoryName, isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: historyRoot.appendingPathComponent("Old-Title.md").path))
        #expect(FileManager.default.fileExists(atPath: historyRoot.appendingPathComponent("New-Title.md").path))

        // ID index re-keyed: the fragment resolves to the new path.
        #expect(clamshell.resolveSubpageTarget("Old-Title.md#\(id)") == "New-Title.md")
        // The ID survives inside the moved file.
        #expect(try pageID(of: "New-Title.md", in: clamshell) == id)
    }

    @Test func renameCollisionDisambiguates() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)

        _ = try clamshell.createPage(title: "Target", requestedPath: nil, initialContent: nil)
        let rel = try clamshell.createPage(title: "Something", requestedPath: nil, initialContent: nil)

        let result = try await clamshell.renamePage(at: clamshell.url(for: rel), toMatchTitle: "Target")
        #expect(result.newRelativePath == "Target-2.md")
    }

    @Test func renameToOwnNameIsNoOp() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)

        let rel = try clamshell.createPage(title: "Stable", requestedPath: nil, initialContent: nil)
        let before = try String(contentsOf: clamshell.url(for: rel), encoding: .utf8)
        let result = try await clamshell.renamePage(at: clamshell.url(for: rel), toMatchTitle: "Stable")
        #expect(result.newRelativePath == rel)
        #expect(try String(contentsOf: clamshell.url(for: rel), encoding: .utf8) == before)
    }

    @Test func renameKeepsDisambiguatedNameWhenBaseIsTaken() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)

        _ = try clamshell.createPage(title: "Title", requestedPath: "Title.md", initialContent: nil)
        _ = try clamshell.createPage(title: "Title", requestedPath: "Title-2.md", initialContent: nil)

        let result = try await clamshell.renamePage(at: clamshell.url(for: "Title-2.md"), toMatchTitle: "Title")
        #expect(result.newRelativePath == "Title-2.md", "own -N name is not a collision")
    }

    @Test func caseOnlyRenameWorks() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)

        _ = try clamshell.createPage(title: "hello world", requestedPath: nil, initialContent: nil)
        let result = try await clamshell.renamePage(at: clamshell.url(for: "hello-world.md"), toMatchTitle: "Hello World")
        #expect(result.newRelativePath == "Hello-World.md")

        let listed = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".md") }
        #expect(listed == ["Hello-World.md"], "on-disk case must actually change, got \(listed)")
    }

    @Test func renameKeepsDirectory() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)

        _ = try clamshell.createPage(title: "Nested", requestedPath: "sub/Nested.md", initialContent: nil)
        let result = try await clamshell.renamePage(at: clamshell.url(for: "sub/Nested.md"), toMatchTitle: "Renamed Deep")
        #expect(result.newRelativePath == "sub/Renamed-Deep.md")
        #expect(FileManager.default.fileExists(atPath: clamshell.url(for: "sub/Renamed-Deep.md").path))
    }

    @Test func renameFollowsHomePointer() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)

        let rel = try clamshell.createPage(title: "Home", requestedPath: nil, initialContent: nil)
        clamshell.setHome(relativePath: rel)
        _ = try await clamshell.renamePage(at: clamshell.url(for: rel), toMatchTitle: "Sweet Home")
        #expect(clamshell.homeRelativePath == "Sweet-Home.md")
    }

    @Test func renameRefusesWhenEditorAttached() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)

        let rel = try clamshell.createPage(title: "Busy", requestedPath: nil, initialContent: nil)
        let session = try await clamshell.page(atPath: rel).open(onEvent: { _ in })
        await #expect(throws: Clamshell.RenameError.pageOpenElsewhere) {
            try await clamshell.renamePage(at: clamshell.url(for: rel), toMatchTitle: "Other")
        }
        try await session.close()
    }

    // MARK: - Rename + resolution + healing, end to end

    @Test func renamedTargetResolvesImmediatelyAndHealsLazily() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)

        _ = try clamshell.createPage(title: "B", requestedPath: "B.md", initialContent: nil)
        let id = try pageID(of: "B.md", in: clamshell)

        // A links to B; a heal pass enriches the links with B's fragment.
        var inline = attr("see B")
        inline.link = URL(string: "B.md")
        let blocks: [Block] = [.subpage(title: "B", pageID: "B.md"), .paragraph(text: inline)]
        let doc = Document(url: clamshell.url(for: "A.md"), children: blocks)
        try await clamshell.commit(.fromEditorOps(BlockTreeDiff.derive(pre: [], post: blocks)), to: doc)
        #expect(await clamshell.healLinks(in: doc) == 2)

        // Rename B. A's bytes still carry the old path + fragment.
        _ = try await clamshell.renamePage(at: clamshell.url(for: "B.md"), toMatchTitle: "Better Name")

        // Resolution is correct instantly, before any healing of A.
        guard case .subpage(_, let staleDest) = doc.children[0].kind else {
            Issue.record("expected subpage")
            return
        }
        #expect(staleDest == "B.md#\(id)")
        #expect(clamshell.resolveSubpageTarget(staleDest) == "Better-Name.md")
        if case .missing = clamshell.lookupPage(staleDest) {
            Issue.record("stale dest should still resolve to a present page")
        }

        // A's next quiet moment heals the bytes.
        #expect(await clamshell.healLinks(in: doc) == 2)
        guard case .subpage(_, let healedDest) = doc.children[0].kind else { return }
        #expect(healedDest == "Better-Name.md#\(id)")
        let diskText = try String(contentsOf: doc.url, encoding: .utf8)
        #expect(diskText.contains("Better-Name.md#\(id)"))
    }
}
