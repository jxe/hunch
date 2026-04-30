import XCTest

@MainActor
final class ConsoleDragAndDropUITests: XCTestCase {
    private var app: XCUIApplication!

    func testLongPressReordersRows() {
        launchApp()

        let bravo = row(containing: "Bravo")
        let delta = row(containing: "Delta")
        let echo = row(containing: "Echo")
        XCTAssertTrue(bravo.waitForExistence(timeout: 3))
        XCTAssertTrue(delta.waitForExistence(timeout: 3))
        XCTAssertTrue(echo.waitForExistence(timeout: 3))

        let start = bravo.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
        let end = echo.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
        start.press(forDuration: 0.55, thenDragTo: end)

        assertRowOrder(["Alpha", "Charlie", "Delta", "Bravo", "Echo", "Foxtrot"])
    }

    func testHorizontalSwipeDoesNotStartReorder() {
        launchApp()

        let bravo = row(containing: "Bravo")
        XCTAssertTrue(bravo.waitForExistence(timeout: 3))

        let start = bravo.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5))
        let end = bravo.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)

        assertRowOrder(["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot"])
    }

    private func launchApp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--console-ui-testing"]
        app.launch()
    }

    private func row(containing text: String) -> XCUIElement {
        app.descendants(matching: .any)["block-row-\(slug(text))"]
    }

    private func assertRowOrder(_ expected: [String], timeout: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line) {
        if !waitForRowOrder(expected, timeout: timeout) {
            XCTFail("Expected row order \(expected), got \(rowOrderDescription(expected))", file: file, line: line)
        }
    }

    private func waitForRowOrder(_ expected: [String], timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let actual = currentRowOrder(expected)
            if actual == expected {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }

    private func currentRowOrder(_ texts: [String]) -> [String] {
        texts.compactMap { text -> (String, CGFloat)? in
            let element = row(containing: text)
            guard element.exists else { return nil }
            return (text, element.frame.midY)
        }
        .sorted { $0.1 < $1.1 }
        .map(\.0)
    }

    private func rowOrderDescription(_ texts: [String]) -> String {
        texts.map { text in
            let element = row(containing: text)
            guard element.exists else { return "\(text): missing" }
            return "\(text): \(element.frame)"
        }
        .joined(separator: ", ")
    }

    private func slug(_ text: String) -> String {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: "-")
    }
}
