import XCTest

/// Reproduces the user-reported bug: on iOS, scrolling the page sometimes
/// doesn't work — "for a spell at a time, after navigation or modifications".
///
/// What the diagnostic exploration found (see end-of-file notes for the
/// extended trail): once XCUI fires a swipe-up that successfully scrolls
/// the page, every *subsequent* swipe — synthesized via `app.swipeUp()`,
/// the scroll view element, or manual `press(forDuration:thenDragTo:)` —
/// produces zero movement. This is reproducible without any editing,
/// navigation, gesture-bridge involvement, or focus-state churn — those
/// were all ruled out one by one. The bug appears to live below our code.
@MainActor
final class HunchEditScrollUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--console-ui-testing-tall-doc"]
        app.launch()
    }

    /// **Primary repro.** Two consecutive swipes without any editing in
    /// between. The first scrolls the page; the second is silently dropped.
    /// Captures the user's "spell at a time" symptom in its simplest form.
    func testTwoConsecutiveSwipesBothScroll() {
        XCTAssertTrue(swipeUpDidScroll(), "First swipe didn't scroll (test setup wrong)")
        XCTAssertTrue(swipeUpDidScroll(), "Second swipe didn't scroll — repro of the user's bug")
    }

    /// Sustained version of the above. Useful for confirming the bug stays
    /// reproduced after future fixes / regressions. Reports every iteration
    /// so partial improvements are visible.
    func testFiveConsecutiveSwipesAllScroll() {
        var failures: [String] = []
        for i in 0..<5 {
            if !swipeUpDidScroll() {
                failures.append("iter \(i)")
            }
        }
        if !failures.isEmpty {
            XCTFail("Swipe-up failed at: \(failures.joined(separator: ", "))")
        }
    }

    /// Edit-then-scroll flow the user originally described. Currently passes
    /// (one edit + one scroll works), but kept as a regression guard for the
    /// fix path.
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

    /// Splitting a block via Return then scrolling. Same shape as the type
    /// test — one structural mutation then one scroll. Currently passes.
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

    /// Returns true if a vertical drag moved the page. Drags from a row
    /// that's currently mid-screen so there's always room for the gesture.
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
        for n in 1...80 {
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

// MARK: - Investigation notes
//
// Diagnostic exploration verified the following are NOT the cause:
//
//  * IOSPageReorderGestureBridge — long-press recognizer with
//    `panGestureRecognizer.require(toFail:)`. Disabled the bridge entirely
//    via a `--disable-page-reorder` launch arg; subsequent swipes still
//    failed.
//  * IOSPagePinchGestureBridge — same approach; no change.
//  * IOSPageBlockDropTarget — the `.onDrop` adds UIDropInteraction's own
//    gesture recognizers. Disabled; no change.
//  * IOSScrollMetricsReader — KVO observer that fires Tasks on every
//    contentOffset change, potentially re-rendering. Disabled; no change.
//  * IOSRowSwipeActions — per-row `.highPriorityGesture` DragGesture.
//    Disabled; no change.
//  * The page-level `.focusable() .focused($pageFocused)` chain. Removed
//    for iOS; no change.
//  * Edit-mode entry/exit — single edit + single scroll passes. Multiple
//    swipes fail regardless of editing.
//  * XCUI synthesis path — same failure with `app.swipeUp()`,
//    `scrollViews.firstMatch.swipeUp()`, manual element-coordinate
//    `press(forDuration:thenDragTo:)`, and app-coordinate variants.
//  * Timing — 1.5s sleep between swipes also failed.
//
// Diagnostic frame capture confirmed the page genuinely doesn't move on
// repeat swipes (every row's midY change is exactly 0.0pt), so this isn't
// an XCUI measurement quirk.
//
// Likely remaining suspects (require deeper investigation, possibly
// instrumenting UIScrollView's pan recognizer state with NSLog or
// running on iOS 25 to see if it's an iOS 26 regression):
//
//   1. NavigationStack — the page lives inside `NavigationStack(path:)`
//      and its destination view; one of NavigationStack's internal
//      gesture recognizers may be claiming touches after the first scroll.
//   2. SwiftUI ScrollView on iOS 26 — possible scroll-edge-effect or
//      decelerator state machine issue.
//   3. Some interaction between the GeometryReader wrapper and the
//      ScrollView contentSize after the first deceleration finishes.
//
// User reports the bug as intermittent in real usage; XCUI synthesis hits
// it deterministically, suggesting XCUI's gesture cadence happens to land
// in the failing state every time while real fingers occasionally don't.
