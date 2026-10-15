import XCTest

/// The finger on the charts (UX pass 3, U4). A tap on a node chart opens
/// it on the whole screen and a drag only scrubs; a swipe from the screen's
/// leading edge goes back, also over a chart, the price and the style
/// scale; a swipe up that starts on the plan dial's ring scrolls the plan,
/// and once the ring scrubs, the page holds still.
///
/// The simulator's touches are synthesized: the back swipe and the timing
/// of a real thumb still need a device.
final class ChartFingerTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ more: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-FTWDemo", "YES",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
        ] + more
        app.launch()
        return app
    }

    /// From `x` points in from the window's leading edge to most of the way
    /// across, at the height `y`, as a thumb sweeps back.
    @MainActor
    private func sweep(_ app: XCUIApplication, fromX x: CGFloat, y: CGFloat) {
        let window = app.windows.firstMatch
        let origin = window.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: x, dy: y))
            .press(forDuration: 0.02, thenDragTo: origin.withOffset(CGVector(dx: window.frame.width * 0.85, dy: y)), withVelocity: .fast, thenHoldForDuration: 0)
    }

    @MainActor
    func testATapOnEachChartEnlargesItAndADragOnlyScrubs() throws {
        for period in ["live", "today", "ahead"] {
            let app = launch(["-FTWNode", "battery", "-FTWPeriod", period])
            let chart = app.descendants(matching: .any)[period == "live" ? "node.live.chart" : "node.period.chart"]
            XCTAssertTrue(chart.waitForExistence(timeout: 15), "no \(period) chart")
            Thread.sleep(forTimeInterval: 2)
            let close = app.buttons["node.chart.close"]
            // A drag across the chart scrubs and opens nothing.
            chart.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.55))
                .press(forDuration: 0.05, thenDragTo: chart.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.55)), withVelocity: .default, thenHoldForDuration: 0.2)
            XCTAssertFalse(close.waitForExistence(timeout: 1.5), "a drag on \(period) opened the chart")
            // A tap opens it.
            chart.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)).tap()
            XCTAssertTrue(close.waitForExistence(timeout: 3), "a tap on \(period) did not open the chart")
            close.tap()
            XCTAssertTrue(close.waitForNonExistence(timeout: 3))
            app.terminate()
        }
    }

    @MainActor
    func testASwipeFromTheEdgeOverTheNodeChartGoesBack() throws {
        let app = launch(["-FTWNode", "battery", "-FTWPeriod", "today"])
        let chart = app.descendants(matching: .any)["node.period.chart"]
        XCTAssertTrue(chart.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 2)
        sweep(app, fromX: 2, y: chart.frame.midY)
        XCTAssertTrue(app.buttons["now.node.home"].waitForExistence(timeout: 3), "the swipe over the chart did not go back")
    }

    @MainActor
    func testASwipeFromTheEdgeOverThePriceGoesBack() throws {
        let app = launch(["-FTWTab", "price"])
        let chart = app.descendants(matching: .any)["price.chart"]
        XCTAssertTrue(chart.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 2)
        sweep(app, fromX: 2, y: chart.frame.midY)
        XCTAssertTrue(chart.waitForNonExistence(timeout: 3), "the swipe over the price did not go back")
    }

    @MainActor
    func testASwipeFromTheEdgeOverTheStyleScaleGoesBack() throws {
        let app = launch(["-FTWTab", "plan", "-FTWPlanStyle", "dial"])
        let scale = app.descendants(matching: .any)["style.scale"]
        XCTAssertTrue(app.descendants(matching: .any)["plan.dial"].waitForExistence(timeout: 15))
        for _ in 0..<4 where !scale.isHittable { app.swipeUp() }
        XCTAssertTrue(scale.isHittable)
        Thread.sleep(forTimeInterval: 1)
        sweep(app, fromX: 2, y: scale.frame.midY)
        XCTAssertTrue(app.buttons["now.node.home"].waitForExistence(timeout: 3), "the swipe over the style scale did not go back")
    }

    @MainActor
    func testTheDialRingScrollsUpAndDownAndHoldsThePageWhileItScrubs() throws {
        let app = launch(["-FTWTab", "plan", "-FTWPlanStyle", "dial"])
        let dial = app.descendants(matching: .any)["plan.dial"]
        XCTAssertTrue(dial.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 2)
        let frame = dial.frame
        let side = min(frame.width, frame.height)
        // Points on the ring, by the clock, in the dial's frame.
        func ring(_ hour: Double) -> XCUICoordinate {
            let a = hour / 12 * 2 * .pi
            let r = side * 0.4
            return dial.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.width / 2 + r * sin(a), dy: frame.height / 2 - r * cos(a)))
        }
        // A finger that rests on the ring, then sweeps round to three
        // o'clock and down: the dial scrubs and the page holds still.
        let top = dial.frame.minY
        ring(1).press(forDuration: 0.3, thenDragTo: ring(4), withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertEqual(dial.frame.minY, top, accuracy: 1, "the page moved under a scrub")
        // A swipe up from the ring at nine o'clock scrolls the plan.
        ring(9).press(forDuration: 0.02, thenDragTo: ring(9).withOffset(CGVector(dx: 0, dy: -220)), withVelocity: .fast, thenHoldForDuration: 0)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertLessThan(dial.frame.minY, top - 40, "a swipe up on the ring did not scroll the plan")
    }
}
