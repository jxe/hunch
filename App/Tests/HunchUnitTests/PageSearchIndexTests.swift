import Foundation
import Testing
@testable import Hunch
import Quagmire
import SQLite3

@Suite("Page full-text search")
struct PageSearchIndexTests {
    private func page(
        _ path: String,
        title: String,
        body: String,
        date: Date = Date(timeIntervalSinceReferenceDate: 1_000)
    ) -> SearchIndexedPage {
        SearchIndexedPage(
            relativePath: path,
            modificationDate: date,
            title: title,
            body: body
        )
    }

    @Test func compilesTermsQuotedPhrasesAndUnfinishedQuotes() {
        #expect(PageSearchQuery.compile("alpha beta") == "\"alpha\"* AND \"beta\"*")
        #expect(PageSearchQuery.compile("alpha \"beta gamma\"") == "\"alpha\"* AND \"beta gamma\"")
        #expect(PageSearchQuery.compile("alpha \"beta gamma") == "\"alpha\"* AND \"beta gamma\"")
        #expect(PageSearchQuery.compile("  ") == nil)
    }

    @Test func stemsFoldsDiacriticsMatchesPrefixesAndPhrases() async {
        let index = PageSearchIndex(databasePath: ":memory:")
        let pages = [
            page("Run.md", title: "Exercise", body: "A runner was running quickly through cafés."),
            page("Walk.md", title: "Walking", body: "A slow walk past a cafe."),
        ]
        await index.reconcile(pages, keeping: Set(pages.map(\.relativePath)))

        #expect(await index.search("run").map(\.relativePath) == ["Run.md"])
        #expect(Set(await index.search("cafe").map(\.relativePath)) == ["Run.md", "Walk.md"])
        #expect(await index.search("exer").map(\.relativePath) == ["Run.md"])
        #expect(await index.search("\"running quickly\"").map(\.relativePath) == ["Run.md"])
        #expect((await index.search("\"quickly running\"")).isEmpty)
    }

    @Test func requiresEveryUnquotedTerm() async {
        let index = PageSearchIndex(databasePath: ":memory:")
        let pages = [
            page("Both.md", title: "Both", body: "red green blue"),
            page("One.md", title: "One", body: "red blue"),
        ]
        await index.reconcile(pages, keeping: Set(pages.map(\.relativePath)))

        #expect(await index.search("red green").map(\.relativePath) == ["Both.md"])
    }

    @Test func titleMatchesRankAboveEquivalentBodyMatches() async {
        let index = PageSearchIndex(databasePath: ":memory:")
        let pages = [
            page("Title.md", title: "Constellation", body: "ordinary notes"),
            page("Body.md", title: "Astronomy", body: "one constellation appears"),
        ]
        await index.reconcile(pages, keeping: Set(pages.map(\.relativePath)))

        #expect(await index.search("constellation").map(\.relativePath) == ["Title.md", "Body.md"])
    }

    @Test func equalScoresUseModificationDateThenTitle() async {
        let index = PageSearchIndex(databasePath: ":memory:")
        let pages = [
            page("Alpha.md", title: "Alpha", body: "shared", date: Date(timeIntervalSinceReferenceDate: 1_000)),
            page("Beta.md", title: "Beta", body: "shared", date: Date(timeIntervalSinceReferenceDate: 2_000)),
            page("Gamma.md", title: "Gamma", body: "shared", date: Date(timeIntervalSinceReferenceDate: 2_000)),
        ]
        await index.reconcile(pages, keeping: Set(pages.map(\.relativePath)))

        #expect(await index.search("shared").map(\.relativePath) == ["Beta.md", "Gamma.md", "Alpha.md"])
    }

    @Test func bodyMatchesCarrySnippetsButTitleOnlyMatchesDoNot() async {
        let index = PageSearchIndex(databasePath: ":memory:")
        let pages = [
            page("Title.md", title: "Needle", body: "unrelated body"),
            page("Body.md", title: "Haystack", body: "the hidden needle is here"),
        ]
        await index.reconcile(pages, keeping: Set(pages.map(\.relativePath)))

        let results = await index.search("needle")
        #expect(results.first(where: { $0.relativePath == "Title.md" })?.snippet == nil)
        #expect(results.first(where: { $0.relativePath == "Body.md" })?.snippet?.contains("needle") == true)
    }

    @Test func reconcileUpdatesAndPrunesThenRenameAndRemoveStayCurrent() async {
        let index = PageSearchIndex(databasePath: ":memory:")
        await index.reconcile(
            [page("Old.md", title: "Old", body: "first term"), page("Gone.md", title: "Gone", body: "vanish")],
            keeping: ["Old.md", "Gone.md"]
        )
        await index.reconcile(
            [page("Old.md", title: "Old", body: "replacement term", date: Date(timeIntervalSinceReferenceDate: 2_000))],
            keeping: ["Old.md"]
        )

        #expect((await index.search("first")).isEmpty)
        #expect((await index.search("vanish")).isEmpty)
        #expect(await index.search("replacement").map(\.relativePath) == ["Old.md"])

        await index.rename(from: "Old.md", to: "New.md")
        #expect(await index.search("replacement").map(\.relativePath) == ["New.md"])
        await index.remove(relativePath: "New.md")
        #expect((await index.search("replacement")).isEmpty)
    }

    @Test func unchangedPagesAreRetainedWithoutReplacement() async {
        let index = PageSearchIndex(databasePath: ":memory:")
        let original = page("Keep.md", title: "Keep", body: "cached searchable body")
        await index.reconcile([original], keeping: ["Keep.md"])
        await index.reconcile([], keeping: ["Keep.md"])

        #expect(await index.indexedModificationDates() == ["Keep.md": original.modificationDate])
        #expect(await index.search("searchable").map(\.relativePath) == ["Keep.md"])
    }

    @Test func corruptDatabaseIsRebuiltAndUnavailableDatabaseFailsClosed() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("page-search-corruption-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let corruptPath = root.appendingPathComponent("corrupt.sqlite").path
        try Data("not a sqlite database".utf8).write(to: URL(fileURLWithPath: corruptPath))
        let rebuilt = PageSearchIndex(databasePath: corruptPath)
        await rebuilt.upsert(page("Recovered.md", title: "Recovered", body: "after corruption"))
        #expect(await rebuilt.search("corruption").map(\.relativePath) == ["Recovered.md"])

        let unavailable = PageSearchIndex(databasePath: "/dev/null/search.sqlite")
        await unavailable.upsert(page("Nope.md", title: "Nope", body: "inaccessible"))
        #expect((await unavailable.search("inaccessible")).isEmpty)
    }

    @Test func schemaVersionMismatchRebuildsDisposableIndex() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("page-search-schema-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("old.sqlite").path

        var database: OpaquePointer?
        #expect(sqlite3_open(path, &database) == SQLITE_OK)
        guard let database else { return }
        #expect(sqlite3_exec(database, "CREATE TABLE pages(legacy TEXT); PRAGMA user_version = 999", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)

        let index = PageSearchIndex(databasePath: path)
        await index.upsert(page("Fresh.md", title: "Fresh", body: "new schema content"))
        #expect(await index.search("schema").map(\.relativePath) == ["Fresh.md"])
    }

    @Test func resultLimitIsEnforced() async {
        let index = PageSearchIndex(databasePath: ":memory:")
        let pages = (0..<120).map { page("\($0).md", title: "Common \($0)", body: "common") }
        await index.reconcile(pages, keeping: Set(pages.map(\.relativePath)))
        #expect((await index.search("common", limit: 3)).count == 3)
        #expect((await index.search("common", limit: 1_000)).count == 100)
    }

    @Test func searchableTextIncludesVisibleKindsAndNestedChildren() {
        let blocks: [Block] = [
            .heading(level: .h1, text: AttributedString("Heading"), children: [
                .paragraph(text: AttributedString("Nested paragraph"))
            ]),
            .bullet(text: AttributedString("Bullet")),
            .numbered(text: AttributedString("Numbered")),
            .todo(text: AttributedString("Todo"), done: true),
            .quote(text: AttributedString("Quote")),
            .toggle(title: AttributedString("Toggle")),
            .templateButton(label: "Template"),
            .code(source: "let value = 1"),
            .image(source: "Assets/image.png", alt: "Diagram alt"),
            .documentLink(label: AttributedString("Child page"), reference: DocumentReference("Child.md")),
            .divider(),
        ]

        let text = searchableText(in: blocks)
        for expected in [
            "Heading", "Nested paragraph", "Bullet", "Numbered", "Todo",
            "Quote", "Toggle", "Template", "let value = 1", "Diagram alt", "Child page"
        ] {
            #expect(text.contains(expected))
        }
        #expect(!text.contains("Assets/image.png"))
        #expect(!text.contains("Child.md"))
    }

    @Test @MainActor func pagePickerTranslationNeverExposesPath() {
        let entry = WorkspaceEntry(
            url: URL(fileURLWithPath: "/tmp/workspace/nested/Page.md"),
            relativePath: "nested/Page.md",
            title: "Page",
            modificationDate: .now
        )
        #expect(entry.asMentionItem(homeRelativePath: nil).subtitle == nil)
    }

    @Test func stalePickerQueryGenerationCannotReplaceNewerResults() {
        var generations = PickerQueryGeneration()
        let old = generations.begin()
        let newest = generations.begin()

        #expect(!generations.accepts(old))
        #expect(generations.accepts(newest))
    }

    @Test func identicalTitlesRemainDistinctByInternalPath() async {
        let index = PageSearchIndex(databasePath: ":memory:")
        let pages = [
            page("one/Same.md", title: "Same", body: "shared duplicate"),
            page("two/Same.md", title: "Same", body: "shared duplicate"),
        ]
        await index.reconcile(pages, keeping: Set(pages.map(\.relativePath)))

        #expect(Set(await index.search("same").map(\.relativePath)) == ["one/Same.md", "two/Same.md"])
    }
}
