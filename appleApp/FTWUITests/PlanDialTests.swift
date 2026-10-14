import XCTest

/// The plan view opens on the dial, the lanes are one tap away and the
/// phone keeps the choice; a finger round the ring reads the plan without
/// moving the page; VoiceOver reads the dial at now.
///
///     xcodebuild test -project FTW.xcodeproj -scheme FTW \
///       -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
///       -only-testing:FTWUITests/PlanDialTests
final class PlanDialTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ more: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-FTWDemo", "YES", "-FTWTab", "plan",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
        ] + more
        app.launch()
        return app
    }

    private func dial(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["plan.dial"].firstMatch
    }

    /// One element that starts at now and reads the time, the price and
    /// what the plan does then.
    @MainActor
    func testVoiceOverReadsTheDialAtNow() throws {
        let app = launch(["-FTWPlanStyle", "dial"])
        let dial = dial(app)
        XCTAssertTrue(dial.waitForExistence(timeout: 15), "no plan dial")
        XCTAssertEqual(dial.label, "Plan dial")
        // The demo's plan and prices arrive a moment after the view.
        let priced = NSPredicate(format: "value CONTAINS 'öre' AND value CONTAINS 'Battery'")
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: priced, evaluatedWith: dial)], timeout: 10), .completed, "the dial does not read now: \(dial.value ?? "")")
    }

    /// A drag round the ring reads the plan; the page stays where it is.
    @MainActor
    func testAFingerRoundTheRingKeepsThePageStill() throws {
        let app = launch(["-FTWPlanStyle", "dial"])
        let dial = dial(app)
        XCTAssertTrue(dial.waitForExistence(timeout: 15))
        let frame = dial.frame
        // Two points on the ring, 60° apart, so the straight drag stays on it.
        func ring(_ degrees: Double) -> XCUICoordinate {
            let a = degrees * .pi / 180
            return dial.coordinate(withNormalizedOffset: CGVector(dx: 0.5 + 0.4 * sin(a), dy: 0.5 - 0.4 * cos(a)))
        }
        ring(30).press(forDuration: 0.05, thenDragTo: ring(90), withVelocity: .slow, thenHoldForDuration: 0.6)
        ring(200).press(forDuration: 0.05, thenDragTo: ring(140), withVelocity: .default, thenHoldForDuration: 0.6)
        XCTAssertEqual(dial.frame, frame, "the page moved under the finger")
        XCTAssertTrue(app.navigationBars["Plan ahead"].exists)
    }

    /// The lanes are one tap away, and the phone remembers the choice: a
    /// new launch opens on the lanes until the viewer taps the dial again.
    @MainActor
    func testTheLanesAreOneTapAwayAndStay() throws {
        var app = launch()
        let style = app.segmentedControls["plan.style"]
        XCTAssertTrue(style.waitForExistence(timeout: 15), "no dial or lanes switch")
        if !dial(app).exists { style.buttons["Dial"].tap() }
        XCTAssertTrue(dial(app).waitForExistence(timeout: 5), "the dial is not the default")
        XCTAssertTrue(style.isHittable, "the switch is not in reach")

        style.buttons["Lanes"].tap()
        XCTAssertTrue(dial(app).waitForNonExistence(timeout: 5), "the dial stayed")
        XCTAssertTrue(style.buttons["Lanes"].isSelected)

        app.terminate()
        app = launch()
        XCTAssertTrue(app.segmentedControls["plan.style"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.segmentedControls["plan.style"].buttons["Lanes"].isSelected, "the choice was not kept")
        XCTAssertFalse(dial(app).exists)

        // Back to the dial, as the next run expects.
        app.segmentedControls["plan.style"].buttons["Dial"].tap()
        XCTAssertTrue(dial(app).waitForExistence(timeout: 5))
    }
}
