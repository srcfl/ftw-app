import XCTest

/// History's price row and the days behind it, on the actual simulator:
/// the row in both looks and both languages, the price screen it opens,
/// and a finger dragging that screen back a day and coming home. Skipped
/// unless asked for:
///
///     TEST_RUNNER_FTW_PRICE_HISTORY=1 xcodebuild test … \
///       -only-testing:FTWUITests/PriceHistoryTour -resultBundlePath price.xcresult
///     xcrun xcresulttool export attachments --path price.xcresult --output-path price
///
/// `TEST_RUNNER_FTW_LANG=en` photographs the English words; `sv` is the
/// default, as the screenshot scripts have it.
final class PriceHistoryTour: XCTestCase {
    @MainActor
    private func open(_ arguments: [String]) -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        let lang = env["FTW_LANG"] ?? "sv"
        let app = XCUIApplication()
        app.launchArguments = ["-FTWDemo", "YES", "-appearance", "system"]
            + arguments + ["-AppleLanguages", "(\(lang))", "-AppleLocale", lang == "sv" ? "sv_SE" : "en_US"]
        app.launch()
        return app
    }

    /// The row sits under the nodes, on their axis, and says what the day
    /// averaged and what its cheapest slot cost.
    @MainActor
    func testTheRowTellsTheDayAndOpensIt() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FTW_PRICE_HISTORY"] == "1", "Set TEST_RUNNER_FTW_PRICE_HISTORY=1 to drive History's price row.")
        let app = open(["-FTWTab", "history"])
        let row = app.descendants(matching: .any)["history.price"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        app.swipeUp()
        Thread.sleep(forTimeInterval: 2)
        let words = try XCTUnwrap(row.value as? String)
        XCTAssertFalse(words.contains("0,0"), "a day with prices read as nothing: \(words)")
        shoot(app, "history-price-row")

        // It opens the price screen on the same day, where now still has a
        // price.
        row.tap()
        let chart = app.descendants(matching: .any)["price.chart"].firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["price.today"].exists, "the screen opened away from today")
        shoot(app, "price-today")
    }

    /// A drag moves the price screen through time: a day behind, where the
    /// hero gives that day's average, and "Today" brings it home. A hold
    /// still reads a slot.
    @MainActor
    func testADragMovesThePriceScreenBackADay() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FTW_PRICE_HISTORY"] == "1", "Set TEST_RUNNER_FTW_PRICE_HISTORY=1 to drive History's price row.")
        let app = open(["-FTWTab", "price"])
        let chart = app.descendants(matching: .any)["price.chart"].firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 15))
        let today = app.buttons["price.today"]
        XCTAssertFalse(today.exists)

        // Two drags across the chart: a day and a half behind now.
        for _ in 0..<2 {
            chart.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).press(forDuration: 0.02,
                thenDragTo: chart.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0)
        }
        XCTAssertTrue(today.waitForExistence(timeout: 4), "a drag did not move the window off today")
        Thread.sleep(forTimeInterval: 2)
        shoot(app, "price-a-day-behind")

        // A hold still reads one slot, as it always has.
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).press(forDuration: 0.4,
            thenDragTo: chart.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0.8)
        shoot(app, "price-a-day-behind-read")

        today.tap()
        XCTAssertTrue(today.waitForNonExistence(timeout: 4), "Today did not bring the window home")
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
