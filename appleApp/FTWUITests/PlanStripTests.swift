import XCTest

/// Now's plan strip: a finger that moves reads the quarters and opens
/// nothing; a tap opens the plan. `TEST_RUNNER_FTW_FRAMES=YES` logs the
/// overlay's draws each second (category "frames").
///
///     xcodebuild test … -only-testing:FTWUITests/PlanStripTests
final class PlanStripTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch() -> (XCUIApplication, XCUIElement) {
        let env = ProcessInfo.processInfo.environment
        let lang = env["FTW_LANG"] ?? "en"
        let app = XCUIApplication()
        app.launchArguments = ["-FTWDemo", "YES", "-FTWFrameLog", env["FTW_FRAMES"] ?? "NO", "-AppleLanguages", "(\(lang))", "-AppleLocale", lang == "sv" ? "sv_SE" : "en_US"]
        app.launch()
        let strip = app.buttons["now.plan"]
        XCTAssertTrue(strip.waitForExistence(timeout: 15))
        return (app, strip)
    }

    @MainActor
    private func sweep(_ strip: XCUIElement, from a: CGFloat, to b: CGFloat, velocity: XCUIGestureVelocity, hold: TimeInterval = 0.4) {
        let from = strip.coordinate(withNormalizedOffset: CGVector(dx: a, dy: 0.45))
        let to = strip.coordinate(withNormalizedOffset: CGVector(dx: b, dy: 0.45))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: velocity, thenHoldForDuration: hold)
    }

    /// A drag across the strip, past both edges, leaves Now where it is.
    /// The strip keeps its frame throughout.
    @MainActor
    func testADragReadsTheStripAndOpensNothing() throws {
        let (app, strip) = launch()
        let frame = strip.frame
        sweep(strip, from: 0.05, to: 1.05, velocity: .fast, hold: 0.5)
        sweep(strip, from: 0.9, to: -0.05, velocity: .default, hold: 0.5)
        sweep(strip, from: 0.3, to: 0.4, velocity: .slow, hold: 1)
        XCTAssertFalse(app.navigationBars["Plan ahead"].exists, "a drag opened the plan")
        XCTAssertTrue(app.buttons["now.node.home"].isHittable)
        XCTAssertEqual(strip.frame, frame, "the strip moved")
    }

    /// At the largest text Now is a list that scrolls; the strip sits at its
    /// foot with its sentence in full, kept as a picture in the result.
    @MainActor
    func testTheStripAtTheLargestText() throws {
        let env = ProcessInfo.processInfo.environment
        let lang = env["FTW_LANG"] ?? "sv"
        let app = XCUIApplication()
        app.launchArguments = ["-FTWDemo", "YES", "-AppleLanguages", "(\(lang))", "-AppleLocale", lang == "sv" ? "sv_SE" : "en_US",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let strip = app.buttons["now.plan"]
        XCTAssertTrue(strip.waitForExistence(timeout: 15))
        var tries = 0
        while !strip.isHittable, tries < 12 {
            app.swipeUp()
            tries += 1
        }
        XCTAssertTrue(strip.isHittable, "the strip cannot be reached at the largest text")
        Thread.sleep(forTimeInterval: 2)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "strip-ax5"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// A tap opens the plan.
    @MainActor
    func testATapOpensThePlan() throws {
        let (app, strip) = launch()
        strip.tap()
        XCTAssertTrue(app.navigationBars["Plan ahead"].waitForExistence(timeout: 5), "a tap did not open the plan")
    }
}
