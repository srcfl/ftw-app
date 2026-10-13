import XCTest

/// Photographs Now and every node's view of the demo, for review. Skipped
/// unless asked for, because it waits for the live curves to fill:
///
///     TEST_RUNNER_FTW_SHOTS=1 TEST_RUNNER_FTW_LANG=sv xcodebuild test … \
///       -only-testing:FTWUITests/ScreenshotTour -resultBundlePath shots.xcresult
///     xcrun xcresulttool export attachments --path shots.xcresult --output-path shots
///
/// `FTW_TEXT` takes a content size such as `UICTContentSizeCategoryXXXL`;
/// `FTW_TOUR=now` takes Now and the plan only; light or dark is the
/// simulator's own setting.
final class ScreenshotTour: XCTestCase {
    @MainActor
    func testTour() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["FTW_SHOTS"] == "1", "Set TEST_RUNNER_FTW_SHOTS=1 to photograph the demo.")
        let lang = env["FTW_LANG"] ?? "en"
        let text = env["FTW_TEXT"] ?? "UICTContentSizeCategoryL"
        let settle = Double(env["FTW_SETTLE"] ?? "") ?? 75
        let app = XCUIApplication()
        app.launchArguments = [
            "-FTWDemo", "YES",
            "-AppleLanguages", "(\(lang))", "-AppleLocale", lang == "sv" ? "sv_SE" : "en_US",
            "-UIPreferredContentSizeCategoryName", text,
        ]
        app.launch()
        XCTAssertTrue(app.buttons["now.node.home"].waitForExistence(timeout: 15))
        // Let the stream fill the live curves, as minutes of looking would.
        Thread.sleep(forTimeInterval: settle)
        shoot(app, "now")
        // At another text size, Now is the picture that matters.
        guard text == "UICTContentSizeCategoryL" else { return }

        let plan = app.buttons["now.plan"]
        if plan.waitForExistence(timeout: 5) {
            plan.tap()
            Thread.sleep(forTimeInterval: 3)
            shoot(app, "plan")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            Thread.sleep(forTimeInterval: 1.5)
        }
        // `FTW_TOUR=now` stops at Now and the plan.
        guard env["FTW_TOUR"] != "now" else { return }

        for node in ["solar", "battery", "home", "grid", "car"] {
            let door = app.buttons["now.node.\(node)"]
            guard door.waitForExistence(timeout: 5) else { continue }
            door.tap()
            Thread.sleep(forTimeInterval: 3)
            shoot(app, node)
            let ahead = app.segmentedControls["node.period"].buttons.element(boundBy: 2)
            if ahead.exists {
                ahead.tap()
                Thread.sleep(forTimeInterval: 2)
                shoot(app, "\(node)-ahead")
            }
            if node == "battery", app.buttons["node.mode.change"].exists {
                app.buttons["node.mode.change"].tap()
                Thread.sleep(forTimeInterval: 2)
                shoot(app, "mode")
                app.swipeDown(velocity: .fast)
                Thread.sleep(forTimeInterval: 1)
            }
            app.navigationBars.buttons.element(boundBy: 0).tap()
            Thread.sleep(forTimeInterval: 1.5)
        }
    }

    @MainActor
    private func shoot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
