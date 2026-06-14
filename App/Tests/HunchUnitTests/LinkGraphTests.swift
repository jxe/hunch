import Testing
import Foundation
@testable import Hunch
import Editor

@MainActor
@Suite("Link graph: extraction, reachability, orphans")
struct LinkGraphTests {
    private let workspaceURL = URL(fileURLWithPath: "/tmp/hunch-linkgraph-test", isDirectory: true).standardizedFileURL
    private let clamshell: Clamshell

    init() {
        self.clamshell = Clamshell(root: workspaceURL)
    }

    private func classify() -> @Sendable (URL, URL) -> String? {
        let clamshell = self.clamshell
        return { url, base in clamshell.pageID(for: url, relativeTo: base) }
    }

    private func linked(_ text: String, to dest: String) -> AttributedString {
        var s = AttributedString(text)
        s.link = URL(string: dest)
        return s
    }

    // MARK: - outboundLinks extraction

    @Test func extractsSubpageInlineAndNestedLinksAndSkipsExternal() {
        let blocks: [Block] = [
            .subpage(title: "B", pageID: "B.md"),
            .paragraph(text: linked("see C", to: "C.md")),
            .toggle(title: AttributedString("more"), children: [
                .paragraph(text: linked("deep", to: "sub/D.md"))
            ]),
            .paragraph(text: linked("site", to: "https://example.com/E.md")),
        ]
        let targets = outboundLinks(in: blocks, pageURL: workspaceURL.appendingPathComponent("A.md"), classify: classify())
        #expect(targets == ["B.md", "C.md", "sub/D.md"])
    }

    @Test func extractsLinkRelativeToPageDirectory() {
        let blocks: [Block] = [.paragraph(text: linked("sibling", to: "Beta.md"))]
        let targets = outboundLinks(in: blocks, pageURL: workspaceURL.appendingPathComponent("notes/Alpha.md"), classify: classify())
        #expect(targets == ["notes/Beta.md"])
    }

    // MARK: - reachability / orphans

    /// Home → A → B is reachable; Island1 → Island2 is a disconnected island.
    /// Island2 has an inbound link yet is still orphaned (unreachable from home).
    private func sampleGraph(home: String?) -> LinkGraph {
        LinkGraph.derive(
            outbound: [
                "Home.md": ["A.md"],
                "A.md": ["B.md"],
                "Island1.md": ["Island2.md"],
            ],
            allPageIDs: ["Home.md", "A.md", "B.md", "Island1.md", "Island2.md"],
            home: home
        )
    }

    @Test func reachabilityAndOrphans() {
        let g = sampleGraph(home: "Home.md")
        #expect(g.reachable == ["Home.md", "A.md", "B.md"])
        #expect(g.orphans == ["Island1.md", "Island2.md"])
        #expect(g.isOrphan("Island2.md"))
        #expect(!g.isOrphan("A.md"))
        #expect(!g.isOrphan("Home.md"))
    }

    @Test func backlinks() {
        let g = sampleGraph(home: "Home.md")
        #expect(g.backlinks(of: "B.md") == ["A.md"])
        #expect(g.backlinks(of: "Island2.md") == ["Island1.md"])
        #expect(g.backlinks(of: "Home.md").isEmpty)
    }

    @Test func noHomeMakesEveryPageOrphan() {
        let g = sampleGraph(home: nil)
        #expect(g.reachable.isEmpty)
        #expect(g.orphans == ["Home.md", "A.md", "B.md", "Island1.md", "Island2.md"])
    }

    @Test func missingHomeFileMakesEveryNonHomePageOrphan() {
        let g = sampleGraph(home: "Ghost.md")
        #expect(g.reachable.isEmpty)
        // Home subtraction only removes the named home; it isn't in the vertex set.
        #expect(g.orphans == ["Home.md", "A.md", "B.md", "Island1.md", "Island2.md"])
    }

    // MARK: - in-memory save patch

    @Test func replacingOutboundReconnectsAnIsland() {
        let g = sampleGraph(home: "Home.md")
        // Home now also links to Island1, pulling the whole island into reach.
        let patched = g.replacingOutbound(of: "Home.md", with: ["A.md", "Island1.md"], home: "Home.md")
        #expect(!patched.isOrphan("Island1.md"))
        #expect(!patched.isOrphan("Island2.md"))
        #expect(patched.orphans.isEmpty)
        #expect(patched.backlinks(of: "Island1.md") == ["Home.md"])
    }

    @Test func replacingOutboundWithEmptyOrphansFormerlyReachable() {
        let g = sampleGraph(home: "Home.md")
        // Home loses its only outbound link → A and B fall off the graph.
        let patched = g.replacingOutbound(of: "Home.md", with: [], home: "Home.md")
        #expect(patched.orphans == ["A.md", "B.md", "Island1.md", "Island2.md"])
        #expect(patched.backlinks(of: "A.md").isEmpty)
    }
}
