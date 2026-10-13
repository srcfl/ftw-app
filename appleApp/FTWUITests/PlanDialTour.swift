import XCTest

/// Drags a finger round the plan dial, for screen recordings and
/// Instruments: this evening, across midnight into tomorrow, then on round
/// tomorrow. Each drag is one touch, slow, and held at its end. Skipped
/// unless asked for:
///
///     TEST_RUNNER_FTW_DIAL=1 xcodebuild test … -only-testing:FTWUITests/PlanDialTour
///
/// With `TEST_RUNNER_FTW_DIAL_ATTACH=1` it takes over an app already
/// running, as one `xctrace record --launch` started.
final class PlanDialTour: XCTestCase {
    @MainActor
    func testScrubRoundTheDial() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["FTW_DIAL"] == "1", "Set TEST_RUNNER_FTW_DIAL=1 to drive the plan dial.")
        let lang = env["FTW_LANG"] ?? "sv"
        let app = XCUIApplication()
        if env["FTW_DIAL_ATTACH"] == "1" {
            // Instruments started the app (`-FTWDemo YES -FTWTab plan`), so
            // it can trace SwiftUI: take it over as it runs.
            app.activate()
        } else {
            app.launchArguments = [
                "-FTWDemo", "YES", "-FTWTab", "plan", "-FTWPlanStyle", "dial",
                "-AppleLanguages", "(\(lang))", "-AppleLocale", lang == "sv" ? "sv_SE" : "en_US",
            ]
            app.launch()
        }
        let dial = app.descendants(matching: .any)["plan.dial"].firstMatch
        XCTAssertTrue(dial.waitForExistence(timeout: 15))
        // The bars grow in round the spiral; let them settle.
        Thread.sleep(forTimeInterval: 2)
        shoot(app, "dial")
        let r = dial.frame.height / 2 / 1.14
        // This evening on today's turn, then across midnight onto
        // tomorrow's, then round tomorrow.
        drag(dial, r, from: (0.70, 0.60), to: (0.95, 0.64))
        drag(dial, r, from: (0.90, 0.62), to: (0.16, 0.62))
        drag(dial, r, from: (0.18, 0.78), to: (0.45, 0.80))
        drag(dial, r, from: (0.45, 0.80), to: (0.72, 0.78))
        Thread.sleep(forTimeInterval: 1)
        shoot(app, "after")
    }

    /// One touch from a time of day at a radius to another, as shares of
    /// the day and of the dial's radius: midnight at the bottom, noon at
    /// the top, up on the left.
    @MainActor
    private func drag(_ dial: XCUIElement, _ r: CGFloat, from a: (Double, Double), to b: (Double, Double)) {
        let centre = dial.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        func at(_ p: (Double, Double)) -> XCUICoordinate {
            let angle = p.0 * 2 * .pi
            return centre.withOffset(CGVector(dx: -sin(angle) * p.1 * r, dy: cos(angle) * p.1 * r))
        }
        at(a).press(forDuration: 0.25, thenDragTo: at(b), withVelocity: XCUIGestureVelocity(110), thenHoldForDuration: 1.2)
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
