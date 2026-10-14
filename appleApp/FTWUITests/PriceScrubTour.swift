import XCTest

/// A finger on the price chart: a fast sweep past both edges and back,
/// then ten seconds of scrubbing under the hitch metric. For recordings and
/// the hitch number in a pull request. Skipped unless asked for:
///
///     TEST_RUNNER_FTW_SCRUB=1 xcodebuild test … -only-testing:FTWUITests/PriceScrubTour
///
/// The scrub log (`log stream --level debug --predicate 'category == "scrub"'`)
/// shows one slot per change while the finger is down, and "touching with
/// no slot" if the marker were ever lost. `TEST_RUNNER_FTW_FRAMES=YES`
/// logs late frames each second (category "frames"), where Instruments'
/// hitch tools cannot run.
final class PriceScrubTour: XCTestCase {
    @MainActor
    private func open() throws -> (XCUIApplication, XCUIElement) {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["FTW_SCRUB"] == "1", "Set TEST_RUNNER_FTW_SCRUB=1 to drive the price chart.")
        let lang = env["FTW_LANG"] ?? "sv"
        let app = XCUIApplication()
        app.launchArguments = ["-FTWDemo", "YES", "-FTWTab", "price", "-FTWFrameLog", env["FTW_FRAMES"] ?? "NO", "-AppleLanguages", "(\(lang))", "-AppleLocale", lang == "sv" ? "sv_SE" : "en_US"]
        app.launch()
        let chart = app.descendants(matching: .any)["price.chart"].firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 15))
        return (app, chart)
    }

    @MainActor
    private func sweep(_ chart: XCUIElement, from a: CGFloat, to b: CGFloat, velocity: XCUIGestureVelocity, hold: TimeInterval = 0.4) {
        let from = chart.coordinate(withNormalizedOffset: CGVector(dx: a, dy: 0.5))
        let to = chart.coordinate(withNormalizedOffset: CGVector(dx: b, dy: 0.5))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: velocity, thenHoldForDuration: hold)
    }

    /// Fast across the whole chart and past the right edge, then back past
    /// the left one.
    @MainActor
    func testFastSweepPastBothEdges() throws {
        let (_, chart) = try open()
        sweep(chart, from: 0.03, to: 1.08, velocity: .fast, hold: 1)
        sweep(chart, from: 0.97, to: -0.05, velocity: .fast, hold: 1)
        sweep(chart, from: 0.5, to: 0.6, velocity: .slow, hold: 1.5)
    }

    /// Ten seconds of scrubbing back and forth, at the speeds a thumb uses.
    @MainActor
    func testTenSecondsOfScrubbing() throws {
        let (app, chart) = try open()
        let options = XCTMeasureOptions()
        options.iterationCount = 1
        measure(metrics: [XCTHitchMetric(application: app)], options: options) {
            let began = Date()
            var right = true
            while Date().timeIntervalSince(began) < 10 {
                sweep(chart, from: right ? 0.02 : 0.98, to: right ? 1.05 : -0.03, velocity: right ? .fast : .default, hold: 0.2)
                right.toggle()
            }
        }
    }
}
