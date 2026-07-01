import Foundation
import Testing
@testable import Hunch
import Editor

@MainActor
@Suite("Subpage delete trash decision")
struct SubpageTrashDecisionTests {
    @Test func promptsWhenCurrentPageWasOnlyInboundLink() {
        let graph = LinkGraph.derive(
            outbound: ["Current.md": ["Target.md"]],
            allPageIDs: ["Current.md", "Target.md"],
            home: "Current.md"
        )

        #expect(SubpageTrashDecision.shouldPromptToTrash(
            targetPageID: "Target.md",
            sourcePageID: "Current.md",
            sourceOutboundAfterDelete: [],
            graph: graph
        ))
    }

    @Test func doesNotPromptWhenAnotherInboundPageRemains() {
        let graph = LinkGraph.derive(
            outbound: [
                "Current.md": ["Target.md"],
                "Other.md": ["Target.md"]
            ],
            allPageIDs: ["Current.md", "Other.md", "Target.md"],
            home: "Current.md"
        )

        #expect(!SubpageTrashDecision.shouldPromptToTrash(
            targetPageID: "Target.md",
            sourcePageID: "Current.md",
            sourceOutboundAfterDelete: [],
            graph: graph
        ))
    }

    @Test func doesNotPromptWhenCurrentPageStillLinksToTarget() {
        let graph = LinkGraph.derive(
            outbound: ["Current.md": ["Target.md"]],
            allPageIDs: ["Current.md", "Target.md"],
            home: "Current.md"
        )

        #expect(!SubpageTrashDecision.shouldPromptToTrash(
            targetPageID: "Target.md",
            sourcePageID: "Current.md",
            sourceOutboundAfterDelete: ["Target.md"],
            graph: graph
        ))
    }

    @Test func inlineInternalLinksCountAsInboundParents() {
        let workspaceURL = URL(fileURLWithPath: "/tmp/hunch-subpage-trash-decision", isDirectory: true)
        let otherURL = workspaceURL.appendingPathComponent("Other.md")
        var inline = AttributedString("Target")
        inline.link = URL(string: "Target.md")
        let inlineTargets = outboundLinks(
            in: [.paragraph(text: inline)],
            pageURL: otherURL,
            classify: { url, base in
                guard url.relativeString == "Target.md" else { return nil }
                return base.deletingLastPathComponent().appendingPathComponent(url.relativeString).lastPathComponent
            }
        )
        let graph = LinkGraph.derive(
            outbound: [
                "Current.md": ["Target.md"],
                "Other.md": inlineTargets
            ],
            allPageIDs: ["Current.md", "Other.md", "Target.md"],
            home: "Current.md"
        )

        #expect(inlineTargets == ["Target.md"])
        #expect(!SubpageTrashDecision.shouldPromptToTrash(
            targetPageID: "Target.md",
            sourcePageID: "Current.md",
            sourceOutboundAfterDelete: [],
            graph: graph
        ))
    }
}
