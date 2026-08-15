import XCTest

/// Smoke test only: catch a build that crashes or hangs on launch before it
/// reaches TestFlight testers.
///
/// Deliberately does NOT assert on specific copy. An earlier version matched
/// the welcome headline exactly and broke the moment that text was reworded —
/// a failing build for a passing app is worse than no test.
final class SnapCalUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchReachesFirstScreen() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 30),
            "App never reached the foreground"
        )

        // Any of these means we rendered something usable: the sign-in wall,
        // the dashboard, or simply a screen with content on it.
        let signIn = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Apple' OR label CONTAINS[c] 'Continue'")
        ).firstMatch
        let scan = app.buttons["Scan Food"]
        let anyText = app.staticTexts.firstMatch

        let deadline = Date().addingTimeInterval(30)
        var rendered = false
        while Date() < deadline {
            if signIn.exists || scan.exists || anyText.exists {
                rendered = true
                break
            }
            _ = signIn.waitForExistence(timeout: 1)
        }

        XCTAssertTrue(rendered, "App launched but rendered no interactive content")
        XCTAssertFalse(app.alerts.element.exists, "An alert was showing on first launch")
    }
}
