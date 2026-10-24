import XCTest

/// The continuous timeline on the actual simulator: history is present
/// before a five-minute ring fills, a pan holds while readings arrive,
/// pinch changes the window, and the same window opens on the whole screen.
final class HistoryTour: XCTestCase {
    @MainActor
    func testContinuousHistoryPanPinchAndEnlarge() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["FTW_HISTORY"] == "1", "Set TEST_RUNNER_FTW_HISTORY=1 to drive the timeline.")
        let app = XCUIApplication()
        app.launchArguments = ["-FTWDemo", "YES", "-FTWNode", "home", "-FTWTimelineHours", "1", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let chart = app.descendants(matching: .any)["node.timeline.chart"].firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 15))
        XCTAssertFalse(app.segmentedControls["node.period"].exists)
        Thread.sleep(forTimeInterval: 3)
        shoot(app, "timeline-history-on-open")
        let initial = chart.value as? String
        chart.coordinate(withNormalizedOffset: .init(dx: 0.2, dy: 0.5)).press(forDuration: 0.02,
            thenDragTo: chart.coordinate(withNormalizedOffset: .init(dx: 0.8, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0)
        // "Today" goes back to the window a node opens on.
        let now = app.buttons["timeline.today"]
        XCTAssertTrue(now.waitForExistence(timeout: 3))
        XCTAssertTrue(now.isEnabled)
        let panned = chart.value as? String
        XCTAssertNotEqual(initial, panned)
        Thread.sleep(forTimeInterval: 4)
        XCTAssertEqual(panned, chart.value as? String, "new live readings moved a panned window")
        shoot(app, "timeline-panned-held")
        chart.pinch(withScale: 0.5, velocity: -1)
        XCTAssertNotEqual(panned, chart.value as? String, "pinch did not change the window")
        shoot(app, "timeline-pinched")
        // A hold reads an interval mean rather than a manufactured live value.
        chart.coordinate(withNormalizedOffset: .init(dx: 0.2, dy: 0.5)).press(forDuration: 0.4,
            thenDragTo: chart.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0.7)
        now.tap()
        XCTAssertFalse(now.isEnabled)
        app.buttons["node.chart.enlarge"].tap()
        let close = app.buttons["node.chart.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 4))
        XCTAssertFalse(app.segmentedControls["node.chart.period"].exists)
        shoot(app, "timeline-full-screen")
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testMissingWaitingAndUnavailableHistoryStayDistinct() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FTW_HISTORY"] == "1", "Set TEST_RUNNER_FTW_HISTORY=1 to drive the timeline.")
        for (state, message) in [
            ("empty", "No recorded history in this window."),
            ("unavailable", "Your box can't send its history right now. Still trying."),
            ("waiting", "Fetching history…"),
        ] {
            let app = XCUIApplication()
            // The held tile is the previous epoch-aligned 12-hour tile.
            // Keep this window inside it at any wall-clock time.
            let back = state == "waiting" ? (Date().timeIntervalSince1970 / 3_600).truncatingRemainder(dividingBy: 12) + 3 : 7
            app.launchArguments = ["-FTWDemo", "YES", "-FTWNode", "home", "-FTWTimelineHours", "1", "-FTWTimelineBackHours", String(back), "-FTWDemoHistory", state, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            app.launch()
            let chart = app.descendants(matching: .any)["node.timeline.chart"].firstMatch
            XCTAssertTrue(chart.waitForExistence(timeout: 15))
            let hasState = NSPredicate(format: "value CONTAINS %@", message)
            expectation(for: hasState, evaluatedWith: chart)
            waitForExpectations(timeout: 8)
            shoot(app, "timeline-" + state)
            app.terminate()
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
