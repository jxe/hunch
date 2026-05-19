import XCTest

/// Reproduces the iOS keyboard flicker on Return-split.
///
/// Run with:
///   xcodebuild test -project Hunch.xcodeproj -scheme Hunch \
///     -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
///     -only-testing:HunchUITests/HunchSplitKeyboardUITests
///
/// While this test runs, stream the focus log on the host:
///   xcrun simctl spawn booted log stream \
///     --predicate 'subsystem == "org.nxhx.Hunch" AND category == "focus"'
@MainActor
final class HunchSplitKeyboardUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["--hunch-ui-testing-tall-doc"]
        app.launch()
    }

    /// Tap into a row, wait for the keyboard, press Return mid-text. The bug
    /// shows up as the keyboard briefly retracting during the split — usually
    /// only ~60–150ms of animation, with no observable change to
    /// `keyboards.firstMatch.exists` (the keyboard UI tree stays "present"
    /// throughout the hide animation). Watching the keyboard's frame `minY`
    /// catches it: a flicker pushes the keyboard partially off-screen and the
    /// minY rises by tens of points before settling back.
    func testKeyboardStaysUpAcrossSplit() {
        let target = row(containing: "Row 05")
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        target.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3),
                      "Keyboard never appeared on initial tap")

        // Type a character to be sure the editor session is hot.
        app.typeText("x")

        let baselineMinY = app.keyboards.firstMatch.frame.minY
        XCTAssertGreaterThan(baselineMinY, 0, "Baseline keyboard minY zero — keyboard not actually visible")

        app.typeText("\n")

        // Sample minY frequently for ~800ms. Anything more than 20pt of
        // upward drift (= keyboard sliding down off-screen) counts as a flicker.
        var peakRise: CGFloat = 0
        let deadline = Date().addingTimeInterval(0.8)
        while Date() < deadline {
            let kb = app.keyboards.firstMatch
            if kb.exists {
                let rise = kb.frame.minY - baselineMinY
                if rise > peakRise { peakRise = rise }
            } else {
                peakRise = .greatestFiniteMagnitude
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertLessThan(peakRise, 20,
                          "Keyboard flicker: minY rose by \(peakRise)pt during split")
    }

    private func row(containing text: String) -> XCUIElement {
        app.descendants(matching: .any)["block-row-\(slug(text))"]
    }

    private func slug(_ text: String) -> String {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: "-")
    }
}
