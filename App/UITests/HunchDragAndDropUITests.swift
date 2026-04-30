import XCTest

@MainActor
final class HunchDragAndDropUITests: XCTestCase {
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

    /// Fast vertical drag on a row body must scroll the page.
    func testVerticalDragOnRowScrollsThePage() {
        launchTallDocApp()

        let row05 = row(containing: "Row 05")
        XCTAssertTrue(row05.waitForExistence(timeout: 3))
        let yBefore = row05.frame.midY

        let start = row05.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: 0, dy: -200))
        start.press(forDuration: 0.05, thenDragTo: end)

        XCTAssertTrue(
            waitForCondition(timeout: 2) {
                row05.exists && row05.frame.midY < yBefore - 50
            },
            "Expected page to scroll up — Row 05.midY started at \(yBefore), still at \(row05.frame.midY)"
        )
    }

    /// Slow vertical drag is the case from the bug report — finger movement is
    /// hesitant enough that the press passes the 0.34s long-press threshold,
    /// which the previous implementation latched into reorder mode and ate the
    /// scroll.
    func testSlowVerticalDragOnRowStillScrolls() {
        launchTallDocApp()

        let row05 = row(containing: "Row 05")
        XCTAssertTrue(row05.waitForExistence(timeout: 3))
        let yBefore = row05.frame.midY

        let start = row05.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: 0, dy: -120))
        start.press(forDuration: 0.5, thenDragTo: end)

        XCTAssertTrue(
            waitForCondition(timeout: 2) {
                row05.exists && row05.frame.midY < yBefore - 30
            },
            "Expected slow drag to scroll — Row 05.midY started at \(yBefore), still at \(row05.frame.midY). " +
            "Row reorder gesture is likely eating the touch."
        )
        // The row must not have entered reorder-source state.
        XCTAssertNotEqual(row05.value as? String, "reorder-source")
    }

    /// A brief tap must not enter reorder mode.
    func testTapDoesNotDimRow() {
        launchApp()

        let bravo = row(containing: "Bravo")
        XCTAssertTrue(bravo.waitForExistence(timeout: 3))
        bravo.tap()

        // Give SwiftUI a moment to settle. The row should never report
        // reorder-source after a tap.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNotEqual(bravo.value as? String, "reorder-source")
    }

    /// User holds long enough to clear the long-press threshold, then lifts
    /// without dragging. The reorder state must clean up — the row must not
    /// stay dimmed and subsequent interaction must work.
    func testQuickHoldThenLiftDoesntStrandTheGesture() {
        launchApp()

        let bravo = row(containing: "Bravo")
        XCTAssertTrue(bravo.waitForExistence(timeout: 3))

        bravo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.5)

        XCTAssertTrue(
            waitForCondition(timeout: 2) {
                (bravo.value as? String) != "reorder-source"
            },
            "Row stayed in reorder-source state after press-and-lift without drag motion"
        )
    }

    /// Whatever fix we make to the reorder gesture must not regress swipe-to-delete.
    func testHorizontalSwipeStillTriggersDelete() {
        launchApp()

        let bravo = row(containing: "Bravo")
        XCTAssertTrue(bravo.waitForExistence(timeout: 3))

        let start = bravo.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
        let end = bravo.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)

        assertRowOrder(["Alpha", "Charlie", "Delta", "Echo", "Foxtrot"])
    }

    private func launchApp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--console-ui-testing"]
        app.launch()
    }

    private func launchTallDocApp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--console-ui-testing-tall-doc"]
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
        waitForCondition(timeout: timeout) {
            currentRowOrder(expected) == expected
        }
    }

    private func waitForCondition(timeout: TimeInterval, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return predicate()
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
