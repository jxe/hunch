import Testing
@testable import Editor

@Suite("Title abbreviation")
struct AbbreviateTitleTests {
    @Test func shorterThanMaxKeepsAsIs() {
        #expect(abbreviateTitle("Apple", max: 60) == "Apple")
    }

    @Test func longerWithSpaceTrimsAtWordBoundary() {
        let title = "Some really long page title that goes on and on and on"
        let result = abbreviateTitle(title, max: 30)
        #expect(result == "Some really long page title…")
        #expect(result.count <= 31)
    }

    @Test func longerWithoutSpaceFallsBackToHardCut() {
        // No whitespace inside the budget — hard-cut at max with ellipsis.
        let title = "abcdefghijklmnopqrstuvwxyz"
        let result = abbreviateTitle(title, max: 5)
        #expect(result == "abcde…")
    }

    @Test func leadingTrailingWhitespaceTrimmed() {
        #expect(abbreviateTitle("  Apple  ", max: 60) == "Apple")
    }

    @Test func defaultMaxIs60() {
        let title = String(repeating: "x", count: 80)
        let result = abbreviateTitle(title)
        #expect(result.hasSuffix("…"))
        #expect(result.count == 61) // 60 chars + ellipsis
    }
}
