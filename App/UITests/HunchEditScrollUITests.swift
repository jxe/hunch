import XCTest

/// Regression guards for edit-then-scroll on iOS, written while
/// investigating a user report of "scroll sometimes doesn't work after
/// typing/editing in a block". The investigation did not reproduce the
/// reported bug — every edit followed by a scroll-with-room-to-go works.
/// These tests stay in to catch a regression if someone wires the editor
/// or keyboard dismissal in a way that does break it.
@MainActor
final class HunchEditScrollUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--hunch-ui-testing-tall-doc"]
        app.launch()
    }

    func testTypeThenDismissThenScroll() {
        let target = row(containing: "Row 05")
        XCTAssertTrue(target.waitForExistence(timeout: 3))
        target.tap()
        XCTAssertTrue(waitForKeyboard(), "Keyboard never appeared")

        app.typeText("x")
        dismissKeyboard()
        XCTAssertTrue(waitForKeyboardGone(), "Keyboard never dismissed")

        XCTAssertTrue(swipeUpDidScroll(), "Swipe after type+dismiss did not scroll")
    }

    func testSplitThenDismissThenScroll() {
        let target = row(containing: "Row 05")
        XCTAssertTrue(target.waitForExistence(timeout: 3))
        target.tap()
        XCTAssertTrue(waitForKeyboard(), "Keyboard never appeared")

        app.typeText("\n")
        dismissKeyboard()
        XCTAssertTrue(waitForKeyboardGone(), "Keyboard never dismissed")

        XCTAssertTrue(swipeUpDidScroll(), "Swipe after split+dismiss did not scroll")
    }

    /// Regression for "scroll fails when finger lands on a row in nav mode".
    /// The page-row swipe gesture used to be a SwiftUI DragGesture that
    /// claimed the touch at 18pt of motion in any direction, blocking the
    /// UIScrollView's pan. Asserts that a vertical drag starting on a row
    /// (no edit, no dismiss) actually scrolls the page.
    func testNavModeScrollFromRow() {
        let target = row(containing: "Row 05")
        XCTAssertTrue(target.waitForExistence(timeout: 3))
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Keyboard should not be present in nav mode")

        XCTAssertTrue(swipeUpDidScroll(), "Vertical drag starting on a row did not scroll")
    }

    // MARK: - Helpers

    private func row(containing text: String) -> XCUIElement {
        app.descendants(matching: .any)["block-row-\(slug(text))"]
    }

    private func dismissKeyboard() {
        let dismiss = app.buttons["keyboard-dismiss"]
        if dismiss.waitForExistence(timeout: 1) {
            dismiss.tap()
        } else {
            XCTFail("Keyboard dismiss button not found")
        }
    }

    private func waitForKeyboard(timeout: TimeInterval = 3) -> Bool {
        app.keyboards.firstMatch.waitForExistence(timeout: timeout)
    }

    private func waitForKeyboardGone(timeout: TimeInterval = 3) -> Bool {
        waitForCondition(timeout: timeout) { !app.keyboards.firstMatch.exists }
    }

    /// Drag from a mid-screen row upward 200pt and check the row moved.
    private func swipeUpDidScroll() -> Bool {
        guard let reference = stableMidScreenRow() else {
            XCTFail("No stable mid-screen row to use as scroll reference")
            return false
        }
        let yBefore = reference.frame.midY

        let start = reference.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: 0, dy: -200))
        start.press(forDuration: 0.05, thenDragTo: end)

        return waitForCondition(timeout: 2) {
            if !reference.exists { return true }
            return reference.frame.midY < yBefore - 50
        }
    }

    private func stableMidScreenRow() -> XCUIElement? {
        let screenHeight = app.frame.height
        let lower = screenHeight * 0.2
        let upper = screenHeight * 0.8
        for n in 1...60 {
            let element = row(containing: "Row \(String(format: "%02d", n))")
            guard element.exists && element.isHittable else { continue }
            let y = element.frame.midY
            if y >= lower && y <= upper { return element }
        }
        return nil
    }

    private func waitForCondition(timeout: TimeInterval, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return predicate()
    }

    private func slug(_ text: String) -> String {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: "-")
    }
}
