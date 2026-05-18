import Testing
import Foundation
@testable import Hunch

@Suite("Workspace relative-link resolution")
struct WorkspaceRelativeLinkTests {
    private let workspaceURL = URL(fileURLWithPath: "/tmp/hunch-test-workspace", isDirectory: true).standardizedFileURL

    private func resolve(_ link: String, from doc: String?) -> String? {
        let url = URL(string: link)!
        let docURL = doc.map { workspaceURL.appendingPathComponent($0).standardizedFileURL }
        return Clamshell.resolvePageID(
            for: url, currentDocURL: docURL, workspaceRoot: workspaceURL
        )
    }

    @Test func resolvesSiblingPage() {
        #expect(resolve("Other.md", from: "Index.md") == "Other.md")
    }

    @Test func resolvesNestedPath() {
        #expect(resolve("sub/Page.md", from: "Index.md") == "sub/Page.md")
    }

    @Test func resolvesPathRelativeToCurrentDocDirectory() {
        // A link from `notes/Alpha.md` to `Beta.md` lands at `notes/Beta.md`,
        // not at `Beta.md` at the workspace root.
        #expect(resolve("Beta.md", from: "notes/Alpha.md") == "notes/Beta.md")
    }

    @Test func resolvesParentReference() {
        #expect(resolve("../Sibling.md", from: "notes/Alpha.md") == "Sibling.md")
    }

    @Test func decodesPercentEncoding() {
        #expect(resolve("Foo%20Bar.md", from: "Index.md") == "Foo Bar.md")
    }

    @Test func rejectsUpwardEscape() {
        #expect(resolve("../../Outside.md", from: "notes/Alpha.md") == nil)
    }

    @Test func rejectsNonMarkdown() {
        #expect(resolve("image.png", from: "Index.md") == nil)
    }

    @Test func rejectsExternalURL() {
        #expect(resolve("https://example.com/Page.md", from: "Index.md") == nil)
        #expect(resolve("mailto:joe@example.com", from: "Index.md") == nil)
    }

    @Test func resolvesAgainstWorkspaceRootWhenNoCurrentDoc() {
        #expect(resolve("Home.md", from: nil) == "Home.md")
    }

    @Test func acceptsFileSchemeInsideWorkspace() {
        let url = workspaceURL.appendingPathComponent("nested/Page.md")
        let result = Clamshell.resolvePageID(
            for: url, currentDocURL: nil, workspaceRoot: workspaceURL
        )
        #expect(result == "nested/Page.md")
    }

    @Test func rejectsFileSchemeOutsideWorkspace() {
        let url = URL(fileURLWithPath: "/tmp/elsewhere/Page.md")
        let result = Clamshell.resolvePageID(
            for: url, currentDocURL: nil, workspaceRoot: workspaceURL
        )
        #expect(result == nil)
    }
}
