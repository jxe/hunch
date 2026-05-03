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

    private func makeDoc(url: URL, body: String) -> Document {
        Document(
            url: url,
            title: "T",
            blocks: [.paragraph(text: AttributedString(body))]
        )
    }

    @Test func singleSaveWritesContents() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let coord = DocumentSaveCoordinator()
        try await coord.save(makeDoc(url: url, body: "alpha"))
        try await coord.flush(url: url)

        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.contains("alpha"))
    }

    @Test func rapidSavesCollapseToFinalState() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let coord = DocumentSaveCoordinator()
        // Fire several saves in quick succession; the coordinator should
        // collapse intermediate snapshots and end with the last one on disk.
        for i in 0..<10 {
            try await coord.save(makeDoc(url: url, body: "v\(i)"))
        }
        try await coord.flush(url: url)

        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.contains("v9"))
    }

    @Test func concurrentSavesToDifferentURLsDontInterleave() async throws {
        let urlA = tempURL()
        let urlB = tempURL()
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }

        let coord = DocumentSaveCoordinator()
        async let a = coord.save(makeDoc(url: urlA, body: "AAA"))
        async let b = coord.save(makeDoc(url: urlB, body: "BBB"))
        _ = try await (a, b)
        try await coord.flush(url: urlA)
        try await coord.flush(url: urlB)

        let writtenA = try String(contentsOf: urlA, encoding: .utf8)
        let writtenB = try String(contentsOf: urlB, encoding: .utf8)
        #expect(writtenA.contains("AAA"))
        #expect(writtenB.contains("BBB"))
    }

    @Test func roundTripThroughCoordinator() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = Document(url: url, title: "T", blocks: [
            .heading(level: 1, text: AttributedString("Title")),
            .paragraph(text: AttributedString("Body.")),
            .bullet(text: AttributedString("one"), indent: 0),
            .bullet(text: AttributedString("two"), indent: 1)
        ])
        let coord = DocumentSaveCoordinator()
        try await coord.save(doc)
        try await coord.flush(url: url)

        let reloaded = try FileStore().loadDocument(at: url)
        #expect(reloaded.blocks.count == 4)
        if case .heading(_, _, let t, _) = reloaded.blocks[0] {
            #expect(String(t.characters) == "Title")
        } else { Issue.record("expected heading first") }
        if case .bullet(_, _, let i) = reloaded.blocks[3] {
            #expect(i == 1)
        } else { Issue.record("expected nested bullet last") }
    }
}
