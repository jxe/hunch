import Foundation
import Testing
@testable import Hunch
import Editor

@MainActor
@Suite("Hunch transcript block action")
struct TranscriptPolisherTests {
    final class StubPolisher: TranscriptPolishing {
        let isAvailable: Bool
        var results: [Result<String, StubError>]
        private(set) var inputs: [String] = []

        init(isAvailable: Bool, results: [Result<String, StubError>] = []) {
            self.isAvailable = isAvailable
            self.results = results
        }

        func polish(_ transcript: String) async throws -> String {
            inputs.append(transcript)
            guard !results.isEmpty else { throw StubError.failed }
            return try results.removeFirst().get()
        }
    }

    enum StubError: LocalizedError {
        case failed

        var errorDescription: String? { "Polishing failed." }
    }

    @Test func unavailableModelHidesTheAction() {
        let polisher = StubPolisher(isAvailable: false)
        #expect(HunchEditorActions.actions(polisher: polisher).isEmpty)
    }

    @Test func successPreservesOrderAndProposesTextReplacements() async throws {
        let polisher = StubPolisher(
            isAvailable: true,
            results: [.success("First."), .success("Second.")]
        )
        let first = Block.paragraph(text: AttributedString(" um first "))
        let second = Block.quote(text: AttributedString("uh second"))
        let context = BlockActionContext(blocks: [
            BlockActionSnapshot(id: first.id, kind: first.kind),
            BlockActionSnapshot(id: second.id, kind: second.kind)
        ])
        let action = try #require(HunchEditorActions.actions(polisher: polisher).first)

        let replacements = try await action.perform(in: context)

        #expect(polisher.inputs == ["um first", "uh second"])
        #expect(replacements.map(\.blockID) == [first.id, second.id])
        #expect(replacements.map { replacement in
            String(Block(id: replacement.blockID, kind: replacement.kind).text.characters)
        } == ["First.", "Second."])
    }

    @Test func modelErrorsPropagateToTheEditorPresentationLayer() async throws {
        let polisher = StubPolisher(isAvailable: true, results: [.failure(.failed)])
        let block = Block.paragraph(text: AttributedString("um hello"))
        let context = BlockActionContext(blocks: [
            BlockActionSnapshot(id: block.id, kind: block.kind)
        ])
        let action = try #require(HunchEditorActions.actions(polisher: polisher).first)

        await #expect(throws: StubError.self) {
            try await action.perform(in: context)
        }
    }
}
