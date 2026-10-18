import XCTest

/// Opens the battery's Today twice, then kills the app and opens it again
/// straight into the battery's live trace, then its Today, for screen
/// recordings of the second open. The demo keeps its sealed cache like a
/// paired home. `FTW_DWELL` is how many seconds Now stays up first, so the
/// live ring has more to keep. Skipped unless asked for:
///
///     TEST_RUNNER_FTW_SECOND=1 xcodebuild test … -only-testing:FTWUITests/SecondOpenTour
final class SecondOpenTour: XCTestCase {
    @MainActor
    func testOpenANodeTwiceThenAfterAKill() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["FTW_SECOND"] == "1", "Set TEST_RUNNER_FTW_SECOND=1 to open the nodes.")
        let lang = env["FTW_LANG"] ?? "sv"
        let base = ["-FTWDemo", "YES", "-FTWDemoCache", "YES", "-AppleLanguages", "(\(lang))", "-AppleLocale", lang == "sv" ? "sv_SE" : "en_US"]
        let app = XCUIApplication()
        app.launchArguments = base + ["-FTWTimelineHours", "24"]
        app.launch()
        let battery = app.descendants(matching: .any)["now.node.battery"].firstMatch
        XCTAssertTrue(battery.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: Double(env["FTW_DWELL"] ?? "") ?? 6)

        // First open, back, second open.
        for open in ["first", "second"] {
            battery.tap()
            let chart = app.descendants(matching: .any)["node.timeline.chart"].firstMatch
            XCTAssertTrue(chart.waitForExistence(timeout: 5))
            shoot(app, "\(open)-open")
            Thread.sleep(forTimeInterval: 3)
            app.navigationBars.buttons.element(boundBy: 0).tap()
            Thread.sleep(forTimeInterval: 2)
        }

        // Into the background, where the app seals what it holds; killed;
        // opened again straight into the battery.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 3)
        app.terminate()
        Thread.sleep(forTimeInterval: 2)
        app.launchArguments = base + ["-FTWNode", "battery", "-FTWTimelineHours", "1"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["node.timeline.chart"].firstMatch.waitForExistence(timeout: 5))
        shoot(app, "after-kill")
        Thread.sleep(forTimeInterval: 4)
        shoot(app, "after-kill-today")
        Thread.sleep(forTimeInterval: 3)
    }

    @MainActor
    private func shoot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
