import Quagmire
import Foundation
import Testing
@testable import Hunch

@MainActor
@Suite("Page icons")
struct PageIconTests {
    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("page-icons-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func closedPageIconPersistsAndRefreshesLookup() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)
        let relativePath = try clamshell.createPage(title: "Project", requestedPath: "project.md", initialContent: nil)
        let before = try await clamshell.page(atPath: relativePath).readBlocks()
        let oldHash = before[0].atomicHash

        try await clamshell.page(atPath: relativePath).setIcon("🚀")

        let after = try await clamshell.page(atPath: relativePath).readBlocks()
        #expect(Document.deriveTitle(from: after, fallback: "fallback") == "🚀 Project")
        #expect(clamshell.lookupPage(relativePath).title == "🚀 Project")
        #expect(FileManager.default.fileExists(atPath: clamshell.url(for: "project.md").path))

        let intent = PatchEngine.intent(from: clamshell.log.readJournal(page: relativePath))
        if case .tombstoned = intent.byHash[oldHash] {} else {
            Issue.record("the replaced title hash must be tombstoned")
        }
        if case .alive = intent.byHash[after[0].atomicHash] {} else {
            Issue.record("the emoji title hash must be alive")
        }
    }

    @Test func openPageUsesTheSameCanonicalDocument() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamshell = Clamshell(root: root)
        let relativePath = try clamshell.createPage(title: "Project", requestedPath: "project.md", initialContent: nil)
        let page = clamshell.page(atPath: relativePath)
        let session = try await page.open(onEvent: { _ in })

        try await page.setIcon("🎯")

        #expect(session.document.title == "🎯 Project")
        try await session.close()
    }

    @Test func missingH1IsWrappedWithoutLosingBody() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("notes.md")
        try "Body text".write(to: url, atomically: true, encoding: .utf8)
        let clamshell = Clamshell(root: root)

        try await clamshell.page(atPath: "notes.md").setIcon("📝")

        let blocks = try await clamshell.page(atPath: "notes.md").readBlocks()
        #expect(blocks.count == 1)
        #expect(Document.deriveTitle(from: blocks, fallback: "fallback") == "📝 notes")
        #expect(blocks[0].children.count == 1)
        #expect(String(blocks[0].children[0].text.characters) == "Body text")
    }
}
