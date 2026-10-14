import XCTest

/// A node from Live to Today: a finger on the live trace, then the same
/// finger on Today, the chart small, a second series added by its chip,
/// then the chart grown to the whole screen and scrubbed there. For
/// screenshots and recordings. Skipped unless asked for:
///
///     TEST_RUNNER_FTW_HISTORY=1 xcodebuild test … -only-testing:FTWUITests/HistoryTour
final class HistoryTour: XCTestCase {
    @MainActor
    func testCompactThenEnlarged() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["FTW_HISTORY"] == "1", "Set TEST_RUNNER_FTW_HISTORY=1 to drive the history.")
        let app = XCUIApplication()
        app.launchArguments = ["-FTWDemo", "YES", "-FTWNode", env["FTW_NODE"] ?? "battery", "-FTWPeriod", "live", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        // Live first, with a finger on it, then Today in the same material.
        let live = app.descendants(matching: .any)["node.live.chart"].firstMatch
        XCTAssertTrue(live.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 8)
        shoot(app, "live")
        drag(live)
        app.segmentedControls["node.period"].buttons["Today"].tap()
        let chart = app.descendants(matching: .any)["node.period.chart"].firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 2)
        shoot(app, "compact")
        drag(chart)
        // A second series, then a third, by their chips.
        let solar = app.buttons["chart.series.solar"]
        XCTAssertTrue(solar.waitForExistence(timeout: 5))
        solar.tap()
        Thread.sleep(forTimeInterval: 1.2)
        shoot(app, "compact-two")
        app.buttons["chart.series.grid"].tap()
        Thread.sleep(forTimeInterval: 1.2)
        // A finger across the small chart.
        drag(chart)
        // Grown to the whole screen out of the small one.
        app.buttons["node.chart.enlarge"].tap()
        let close = app.buttons["node.chart.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1.5)
        shoot(app, "enlarged")
        drag(app.descendants(matching: .any)["node.period.chart"].firstMatch)
        app.segmentedControls["node.chart.period"].buttons["48 h"].tap()
        Thread.sleep(forTimeInterval: 1.5)
        shoot(app, "enlarged-48h")
        // Back to one series, then shut.
        app.buttons["chart.series.grid"].firstMatch.tap()
        app.buttons["chart.series.solar"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1)
        close.tap()
        Thread.sleep(forTimeInterval: 1.5)
        shoot(app, "compact-again")
    }

    @MainActor
    private func drag(_ element: XCUIElement) {
        let from = element.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        let to = element.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        from.press(forDuration: 0.2, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 1)
        Thread.sleep(forTimeInterval: 0.8)
    }

    @MainActor
    private func shoot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
