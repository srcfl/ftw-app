import XCTest

/// Drags a finger across a node's charts, with the demo holding a tile of
/// history back for two seconds, for screen recordings. Skipped unless
/// asked for:
///
///     TEST_RUNNER_FTW_CHARTS=1 xcodebuild test … -only-testing:FTWUITests/ChartTour
final class ChartTour: XCTestCase {
    @MainActor
    func testScrubTheChartsAsTheGapFills() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["FTW_CHARTS"] == "1", "Set TEST_RUNNER_FTW_CHARTS=1 to drive the charts.")
        let lang = env["FTW_LANG"] ?? "sv"
        let app = XCUIApplication()
        app.launchArguments = [
            // 48 h: the held tile lies inside it, with data either side.
            "-FTWDemo", "YES", "-FTWDemoGap", "YES", "-FTWNode", env["FTW_NODE"] ?? "battery", "-FTWTimelineHours", "48", "-FTWTimelineBackHours", "7",
            "-AppleLanguages", "(\(lang))", "-AppleLocale", lang == "sv" ? "sv_SE" : "en_US",
        ]
        app.launch()
        let period = app.descendants(matching: .any)["node.timeline.chart"].firstMatch
        XCTAssertTrue(period.waitForExistence(timeout: 15))
        // The held tile stays hatched until measured data arrives.
        shoot(app, "gap-fetching")
        Thread.sleep(forTimeInterval: 2.5)
        shoot(app, "gap-filled")
        // A slow finger across today, held at the end.
        drag(period)
        Thread.sleep(forTimeInterval: 1)
    }

    @MainActor
    private func drag(_ element: XCUIElement) {
        let from = element.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5))
        let to = element.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        from.press(forDuration: 0.3, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 1)
        Thread.sleep(forTimeInterval: 1)
    }

    @MainActor
    private func shoot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
