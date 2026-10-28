import XCTest

/// Moving History's rows on the actual simulator: a hold lifts a row, a
/// drag carries it, and the order it is left in is still there on the next
/// launch. Skipped unless asked for:
///
///     TEST_RUNNER_FTW_HISTORY_ORDER=1 xcodebuild test … \
///       -only-testing:FTWUITests/HistoryOrderTour -resultBundlePath order.xcresult
///     xcrun xcresulttool export attachments --path order.xcresult --output-path order
///
/// `TEST_RUNNER_FTW_LANG=en` photographs the English words; `sv` is the
/// default, as the screenshot scripts have it. The look is the simulator's,
/// since the app launches with `-appearance system`.
final class HistoryOrderTour: XCTestCase {
    private let nodes = ["solar", "home", "battery", "grid", "car"]

    @MainActor
    private func open(_ arguments: [String] = []) -> XCUIApplication {
        let lang = ProcessInfo.processInfo.environment["FTW_LANG"] ?? "sv"
        let app = XCUIApplication()
        app.launchArguments = ["-FTWDemo", "YES", "-appearance", "system", "-FTWTab", "history"]
            + arguments + ["-AppleLanguages", "(\(lang))", "-AppleLocale", lang == "sv" ? "sv_SE" : "en_US"]
        app.launch()
        return app
    }

    @MainActor
    private func row(_ app: XCUIApplication, _ node: String) -> XCUIElement {
        app.descendants(matching: .any)["history.node.\(node)"].firstMatch
    }

    /// The last of the day's rows carried over the first, and still there
    /// after the app has been closed and opened again. Which row that is
    /// does not matter: the phone may be holding an order from an earlier
    /// run, and a launch argument for the order would mask what a finger
    /// writes.
    @MainActor
    func testAHeldRowMovesAndIsStillThereNextLaunch() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FTW_HISTORY_ORDER"] == "1",
                          "Set TEST_RUNNER_FTW_HISTORY_ORDER=1 to drive History's order.")
        var app = open()
        XCTAssertTrue(row(app, "grid").waitForExistence(timeout: 20))
        let shown = nodes.map { row(app, $0) }.filter(\.exists).sorted { $0.frame.minY < $1.frame.minY }
        XCTAssertGreaterThan(shown.count, 1, "a day with one row has no order to move")
        let top = try XCTUnwrap(shown.first), last = try XCTUnwrap(shown.last)
        shoot(app, "history-order-before")

        last.press(forDuration: 0.8, thenDragTo: top, withVelocity: .slow, thenHoldForDuration: 0.4)
        XCTAssertLessThan(last.frame.minY, top.frame.minY, "the carried row did not stay where it was left")
        shoot(app, "history-order-moved")

        // A moved row is still a door into its day.
        last.tap()
        XCTAssertTrue(app.descendants(matching: .any)["node.timeline.chart"].firstMatch.waitForExistence(timeout: 10))

        // The phone kept it: a cold start opens on the moved order.
        app.terminate()
        app = open()
        let moved = app.descendants(matching: .any).matching(identifier: last.identifier).firstMatch
        XCTAssertTrue(moved.waitForExistence(timeout: 20))
        let others = nodes.map { row(app, $0) }.filter { $0.exists && $0.identifier != last.identifier }
        for other in others {
            XCTAssertLessThan(moved.frame.minY, other.frame.minY, "the order was not kept on this phone")
        }
        shoot(app, "history-order-kept")
    }

    /// What the phone was left holding, drawn without a finger: the order a
    /// launch argument stands in for, for the screenshots.
    @MainActor
    func testAKeptOrderDrawsTheRowsThatWay() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FTW_HISTORY_ORDER"] == "1",
                          "Set TEST_RUNNER_FTW_HISTORY_ORDER=1 to drive History's order.")
        let app = open(["-history.order", "car,price,grid,solar,home,battery"])
        let car = row(app, "car")
        XCTAssertTrue(car.waitForExistence(timeout: 20))
        for node in ["solar", "home", "battery", "grid"] {
            XCTAssertLessThan(car.frame.minY, row(app, node).frame.minY, "the car's row is not first")
        }
        shoot(app, "history-order-car-first")
    }

    @MainActor
    private func shoot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
