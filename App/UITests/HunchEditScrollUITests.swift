import XCTest

/// Reproduction tests for the user-reported bug: on iOS, scrolling
/// "sometimes doesn't work" after typing/editing in a block. Each test
/// drives an edit flow that ends with the keyboard dismissed and the
/// editor unmounted, then asserts that a subsequent vertical drag
/// scrolls the page.
///
/// The main suspect is gesture-state leak between the iOS UITextView
/// (BlockTextEditor) and the page-level UIKit gesture bridges
/// (long-press reorder, pinch). The repeated-cycles test is the most
/// likely to surface accumulating state — the symptom the user
/// described as "happens for a spell at a time".
@MainActor
final class HunchEditScrollUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--console-ui-testing-tall-doc"]
        app.launch()
    }

    /// Baseline: multiple swipes without any editing always scroll. If this
    /// fails, the test's swipe-detection logic is broken; if it passes but
    /// `testRepeatedEditScrollCycles` fails, the bug is real.
    func testMultipleSwipesWithoutEditingAlwaysScrolls() {
        for i in 0..<5 {
            XCTAssertTrue(swipeUpDidScroll(), "Swipe \(i) (no edits) did not scroll")
        }
    }

    /// Same as above but using XCUI's high-level swipeUp() helper. Distinguishes
    /// "the gesture-recognizer state is genuinely stuck" from "manual press-drag
    /// synthesis hits a quirk in XCUI's event delivery".
    func testMultipleAppSwipeUpsAlwaysScroll() {
        for i in 0..<5 {
            guard let reference = stableMidScreenRow() else {
                XCTFail("Iter \(i): no stable row to use as reference")
                return
            }
            let yBefore = reference.frame.midY
            app.swipeUp()
            let scrolled = waitForCondition(timeout: 2) {
                if !reference.exists { return true }
                return reference.frame.midY < yBefore - 50
            }
            XCTAssertTrue(scrolled, "app.swipeUp() iter \(i) did not scroll")
        }
    }

    /// Deliberately wait between swipes to let any deceleration / scroll
    /// metrics observation settle. If this passes but the immediate-followup
    /// version fails, the bug is timing-related.
    func testSwipesWithSettleDelayAlwaysScroll() {
        for i in 0..<3 {
            XCTAssertTrue(swipeUpDidScroll(), "Settled swipe \(i) did not scroll")
            // Long delay to let everything settle.
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        }
    }

    /// Minimal repro path: tap a row, type one char, dismiss the keyboard
    /// via the accessory bar, then try to scroll.
    func testTypeThenDismissThenScroll() {
        let target = row(containing: "Row 05")
        XCTAssertTrue(target.waitForExistence(timeout: 3))
        target.tap()
        XCTAssertTrue(waitForKeyboard(), "Keyboard never appeared after tap")

        app.typeText("x")
        dismissKeyboard()
        XCTAssertTrue(waitForKeyboardGone(), "Keyboard never dismissed")

        assertSwipeUpScrolls(label: "after type+dismiss")
    }

    /// Splitting a block via Return is a structural mutation. After the split,
    /// `validateBlockReferences` may run, the editor remounts on the new block,
    /// and `setInteractionMode` runs. If any of that leaves a gesture
    /// recognizer in a stuck state, this test catches it.
    func testSplitThenDismissThenScroll() {
        let target = row(containing: "Row 05")
        XCTAssertTrue(target.waitForExistence(timeout: 3))
        target.tap()
        XCTAssertTrue(waitForKeyboard(), "Keyboard never appeared after tap")

        // Press Return to split. Whatever cursor position we landed on, the
        // block splits there — exact split point doesn't matter, only that
        // a structural mutation occurred.
        app.typeText("\n")
        dismissKeyboard()
        XCTAssertTrue(waitForKeyboardGone(), "Keyboard never dismissed")

        assertSwipeUpScrolls(label: "after split+dismiss")
    }

    /// Repeated edit-then-scroll cycles. The user described the failure as
    /// happening "for a spell at a time", suggesting state accumulates
    /// across edit cycles rather than failing on the first attempt. Most
    /// likely culprits are:
    ///  - panGestureRecognizer.require(toFail:) dependencies stacking on
    ///    each long-press recognizer reattach
    ///  - UITextView first-responder lingering across editor unmount
    func testRepeatedEditScrollCycles() {
        var failures: [String] = []
        let targets = ["Row 05", "Row 07", "Row 09", "Row 11", "Row 13"]

        for (i, label) in targets.enumerated() {
            let target = row(containing: label)
            guard scrollUntilHittable(target) else {
                XCTFail("Could not bring \(label) into view at iteration \(i)")
                return
            }
            target.tap()
            guard waitForKeyboard() else {
                failures.append("iter \(i) (\(label)): keyboard never appeared")
                continue
            }

            app.typeText("z")
            dismissKeyboard()
            guard waitForKeyboardGone() else {
                failures.append("iter \(i) (\(label)): keyboard never dismissed")
                continue
            }

            if !swipeUpDidScroll() {
                failures.append("iter \(i) (\(label)): swipe-up did not scroll page")
            }
        }

        if !failures.isEmpty {
            XCTFail("Edit-scroll cycles failed:\n  - " + failures.joined(separator: "\n  - "))
        }
    }

    /// Fast alternation with minimal delay. Real users don't wait for SwiftUI
    /// transitions to settle. If a gesture recognizer's state machine relies
    /// on per-frame cleanup that the next interaction interrupts, this test
    /// is most likely to expose it.
    func testFastEditScrollAlternation() {
        var failures: [String] = []

        for i in 0..<3 {
            let target = row(containing: "Row 0\(i + 5)")
            guard scrollUntilHittable(target) else {
                XCTFail("Could not bring Row 0\(i + 5) into view")
                return
            }
            target.tap()
            // Don't wait for keyboard — type immediately. UIKit will queue
            // the typing once the keyboard is up.
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 2)
            app.typeText("q")
            dismissKeyboard()
            // Don't wait for keyboard to fully dismiss before scrolling — that's
            // exactly the racy condition users hit.
            if !swipeUpDidScroll() {
                failures.append("iter \(i): swipe-up did not scroll")
            }
        }

        if !failures.isEmpty {
            XCTFail("Fast alternation failed:\n  - " + failures.joined(separator: "\n  - "))
        }
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

    /// Swipes up and asserts a known row in the visible region moved up by
    /// at least 50pt. Picks whichever target row is currently visible so it
    /// works regardless of scroll position.
    private func assertSwipeUpScrolls(label: String, file: StaticString = #filePath, line: UInt = #line) {
        if !swipeUpDidScroll() {
            XCTFail("Expected swipe-up to scroll the page (\(label))", file: file, line: line)
        }
    }

    /// Returns true if a vertical drag moved the page. Drags from a row
    /// element's coordinate (matching the existing passing test pattern in
    /// `HunchDragAndDropUITests.testVerticalDragOnRowScrollsThePage`).
    private func swipeUpDidScroll() -> Bool {
        guard let reference = stableMidScreenRow() else {
            XCTFail("Could not find a stable mid-screen row to use as scroll reference")
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

    /// Find a "Row NN" element whose midY sits in the middle 60% of the
    /// screen — so the test's own swipe gesture starts on real content,
    /// not on the rubber-band edge or the keyboard area.
    private func stableMidScreenRow() -> XCUIElement? {
        let screenHeight = app.frame.height
        let lower = screenHeight * 0.2
        let upper = screenHeight * 0.8
        for n in 1...30 {
            let element = row(containing: "Row \(String(format: "%02d", n))")
            guard element.exists && element.isHittable else { continue }
            let y = element.frame.midY
            if y >= lower && y <= upper { return element }
        }
        return nil
    }

    private func scrollUntilHittable(_ element: XCUIElement, attempts: Int = 8) -> Bool {
        for _ in 0..<attempts {
            if element.exists && element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists && element.isHittable
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
