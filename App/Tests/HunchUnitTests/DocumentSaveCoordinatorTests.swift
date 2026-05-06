import Testing
import Foundation
@testable import Hunch
import Editor

@Suite("DocumentSaveCoordinator")
struct DocumentSaveCoordinatorTests {
    private func tempURL(suffix: String = "md") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("save-coord-\(UUID().uuidString).\(suffix)")
    }

    @MainActor
    private func makeDoc(url: URL, body: String) -> Document {
        Document(
            url: url,
            title: "T",
            children: [.paragraph(text: AttributedString(body))]
        )
    }

    @MainActor
    private func serialize(_ doc: Document) -> String {
        BlockSerializer.serialize(doc.children)
    }

    @Test @MainActor func singleSaveWritesContents() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let coord = DocumentSaveCoordinator()
        let doc = makeDoc(url: url, body: "alpha")
        try await coord.save(url: url, contents: serialize(doc))
        try await coord.flush(url: url)

        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.contains("alpha"))
    }

    @Test @MainActor func rapidSavesCollapseToFinalState() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let coord = DocumentSaveCoordinator()
        for i in 0..<10 {
            let doc = makeDoc(url: url, body: "v\(i)")
            try await coord.save(url: url, contents: serialize(doc))
        }
        try await coord.flush(url: url)

        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.contains("v9"))
    }

    @Test @MainActor func concurrentSavesToDifferentURLsDontInterleave() async throws {
        let urlA = tempURL()
        let urlB = tempURL()
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }

        let coord = DocumentSaveCoordinator()
        let aContents = serialize(makeDoc(url: urlA, body: "AAA"))
        let bContents = serialize(makeDoc(url: urlB, body: "BBB"))
        async let a: Void = coord.save(url: urlA, contents: aContents)
        async let b: Void = coord.save(url: urlB, contents: bContents)
        _ = try await (a, b)
        try await coord.flush(url: urlA)
        try await coord.flush(url: urlB)

        let writtenA = try String(contentsOf: urlA, encoding: .utf8)
        let writtenB = try String(contentsOf: urlB, encoding: .utf8)
        #expect(writtenA.contains("AAA"))
        #expect(writtenB.contains("BBB"))
    }

    @Test @MainActor func roundTripThroughCoordinator() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = Document(url: url, title: "T", children: [
            .heading(level: .h1, text: AttributedString("Title"), children: [
                .paragraph(text: AttributedString("Body.")),
                .bullet(text: AttributedString("one"), children: [
                    .bullet(text: AttributedString("two"))
                ])
            ])
        ])
        let coord = DocumentSaveCoordinator()
        try await coord.save(url: url, contents: serialize(doc))
        try await coord.flush(url: url)

        let reloaded = try FileStore().loadDocument(at: url)
        // After round-trip the H1 owns its body via heading-fold.
        #expect(reloaded.children.count == 1)
        guard case .heading(.h1, let title) = reloaded.children[0].kind else {
            Issue.record("expected heading H1")
            return
        }
        #expect(String(title.characters) == "Title")
        // H1's children: paragraph + bullet (with nested bullet inside).
        #expect(reloaded.children[0].children.count == 2)
    }
}
