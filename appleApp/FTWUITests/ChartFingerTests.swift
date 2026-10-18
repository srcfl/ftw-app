import XCTest

/// The finger on the charts (UX pass 3, U4). A tap on a node chart opens
/// it on the whole screen and a quick drag pans; a swipe up that starts
/// on the plan dial's ring scrolls the plan, and once the ring scrubs, the
/// page holds still.
///
/// The back swipe from the screen's edge is not here: a swipe the test
/// runner makes from the edge does not go back even where no chart is, so
/// it proves nothing. That and a real thumb's timing need a device.
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

    @MainActor
    func testATapEnlargesTheTimelineAndADragOnlyPans() throws {
        for period in ["1", "24", "48"] {
            let app = launch(["-FTWNode", "battery", "-FTWTimelineHours", period])
            let chart = app.descendants(matching: .any)["node.timeline.chart"]
            XCTAssertTrue(chart.waitForExistence(timeout: 15), "no \(period) chart")
            Thread.sleep(forTimeInterval: 2)
            let close = app.buttons["node.chart.close"]
            // A drag across the chart pans and opens nothing.
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
        // A quick move along the top of the ring scrubs too, at once.
        ring(0).press(forDuration: 0.02, thenDragTo: ring(0).withOffset(CGVector(dx: 60, dy: 8)), withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertEqual(dial.frame.minY, top, accuracy: 1, "the page moved under a scrub")
        // A swipe up from the ring at nine o'clock scrolls the plan.
        ring(9).press(forDuration: 0.02, thenDragTo: ring(9).withOffset(CGVector(dx: 0, dy: -220)), withVelocity: .fast, thenHoldForDuration: 0)
        Thread.sleep(forTimeInterval: 1)
        guard dial.frame.minY >= top - 40 else { return }
        // It did not: the same swipe under the dial tells whether the page
        // scrolls at all. On a tall phone the whole plan fits.
        let below = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.maxY + 60))
        below.press(forDuration: 0.02, thenDragTo: below.withOffset(CGVector(dx: 0, dy: -220)), withVelocity: .fast, thenHoldForDuration: 0)
        Thread.sleep(forTimeInterval: 1)
        if dial.frame.minY >= top - 40 { throw XCTSkip("The whole plan fits this screen, so nothing scrolls; the ring is tried on a smaller phone.") }
        XCTFail("a swipe up on the ring did not scroll the plan, one under the dial did")
    }
}
