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

    func testLongPressReorderAfterScrollTargetsTouchedRow() {
        launchTallDocApp()

        let row12 = row(containing: "Row 12")
        XCTAssertTrue(scrollUntilHittable(row12), "Expected Row 12 to be visible after scrolling")

        let row15 = row(containing: "Row 15")
        XCTAssertTrue(row15.waitForExistence(timeout: 3))
        XCTAssertTrue(row15.isHittable, "Expected Row 15 to be visible as the drop target")

        let start = row12.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
        let end = row15.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
        start.press(forDuration: 0.55, thenDragTo: end)

        assertRowOrder(["Row 13", "Row 14", "Row 12", "Row 15"])
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

    /// Mostly-vertical drags often include a bit of horizontal drift. The row
    /// swipe action must not claim those touches before the ScrollView can pan.
    func testMostlyVerticalDiagonalDragOnRowScrollsThePage() {
        launchTallDocApp()

        let row05 = row(containing: "Row 05")
        XCTAssertTrue(row05.waitForExistence(timeout: 3))
        let yBefore = row05.frame.midY

        let start = row05.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5))
        let end = start.withOffset(CGVector(dx: 64, dy: -180))
        start.press(forDuration: 0.05, thenDragTo: end)

        XCTAssertTrue(
            waitForCondition(timeout: 2) {
                row05.exists && row05.frame.midY < yBefore - 50
            },
            "Expected mostly-vertical diagonal drag to scroll — Row 05.midY started at \(yBefore), " +
            "still at \(row05.frame.midY). Row swipe is likely eating the touch."
        )
    }

    /// The active iOS editor is a UITextView inside the page ScrollView. Dragging
    /// on it should still allow the page to scroll when the editor itself is not
    /// scrollable.
    func testVerticalDragOnEditingRowScrollsThePage() {
        launchTallDocApp()

        let row05 = row(containing: "Row 05")
        XCTAssertTrue(row05.waitForExistence(timeout: 3))
        row05.tap()
        let yBefore = row05.frame.midY

        let start = row05.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: 0, dy: -180))
        start.press(forDuration: 0.05, thenDragTo: end)

        XCTAssertTrue(
            waitForCondition(timeout: 2) {
                row05.exists && row05.frame.midY < yBefore - 50
            },
            "Expected vertical drag on the active editor to scroll — Row 05.midY started at \(yBefore), " +
            "still at \(row05.frame.midY). UITextView gestures may be eating the touch."
        )
    }

    /// Slow scrolls that begin in the page padding/gutter must still scroll.
    /// The page-level reorder long-press recognizer is attached to the whole
    /// UIScrollView, so this catches it winning outside an actual row.
    func testSlowVerticalDragFromPageGutterScrollsThePage() {
        launchTallDocApp()

        let row05 = row(containing: "Row 05")
        XCTAssertTrue(row05.waitForExistence(timeout: 3))
        let yBefore = row05.frame.midY

        let appOrigin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        let start = appOrigin.withOffset(CGVector(dx: max(8, row05.frame.minX - 12), dy: row05.frame.midY))
        let end = start.withOffset(CGVector(dx: 0, dy: -140))
        start.press(forDuration: 0.5, thenDragTo: end)

        XCTAssertTrue(
            waitForCondition(timeout: 2) {
                row05.exists && row05.frame.midY < yBefore - 30
            },
            "Expected slow vertical drag from page gutter to scroll — Row 05.midY started at \(yBefore), " +
            "still at \(row05.frame.midY). Page reorder long-press may be winning outside rows."
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

    private func scrollUntilHittable(_ element: XCUIElement, attempts: Int = 8) -> Bool {
        for _ in 0..<attempts {
            if element.exists && element.isHittable {
                return true
            }
            app.swipeUp()
        }
        return element.exists && element.isHittable
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
