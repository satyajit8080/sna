import XCTest

/// Smoke test only — enough to catch a build that crashes on launch before it
/// reaches TestFlight testers.
final class SnapCalUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchReachesFirstScreen() {
        let app = XCUIApplication()
        app.launch()

        // Either the sign-in wall or the dashboard, depending on stored token.
        let welcome = app.staticTexts["Snap it.\nCount it.\nDone."]
        let scanButton = app.buttons["Scan Food"]

        XCTAssertTrue(
            welcome.waitForExistence(timeout: 10) || scanButton.waitForExistence(timeout: 10),
            "App did not reach a usable first screen"
        )
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
