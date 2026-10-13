import XCTest

/// The plan dial at the top of the plan view, as VoiceOver meets it: one
/// element that starts at now and reads the time, what the plan does, the
/// price and the battery. Its hour steps are `PlanDial.Face.step`, tested
/// in FTWShared: XCTest on iOS cannot swipe an adjustable element. And the
/// switch to the lanes, which the phone remembers.
///
///     xcodebuild test -project FTW.xcodeproj -scheme FTW \
///       -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
///       -only-testing:FTWUITests/PlanDialTests
final class PlanDialTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testVoiceOverReadsTheDialAtNow() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            // The dial whatever the phone last chose.
            "-FTWDemo", "YES", "-FTWTab", "plan", "-FTWPlanStyle", "dial",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
        ]
        app.launch()
        let dial = app.descendants(matching: .any)["plan.dial"].firstMatch
        XCTAssertTrue(dial.waitForExistence(timeout: 15), "no plan dial")
        XCTAssertEqual(dial.label, "Plan dial")
        // The demo's plan and prices arrive a moment after the view.
        let now = NSPredicate(format: "value BEGINSWITH 'now, ' AND value CONTAINS 'öre/kWh'")
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: now, evaluatedWith: dial)], timeout: 10), .completed, "the dial does not start at now: \(dial.value ?? "")")
        let start = try XCTUnwrap(dial.value as? String)
        XCTAssertTrue(start.contains("battery "), "now leaves out the battery's level: \(start)")
    }

    /// The lanes are one tap away, and the phone remembers the choice: a
    /// new launch opens on the lanes until the viewer taps the dial again.
    @MainActor
    func testTheLanesAreOneTapAwayAndStay() throws {
        func launch() -> XCUIApplication {
            let app = XCUIApplication()
            app.launchArguments = [
                "-FTWDemo", "YES", "-FTWTab", "plan",
                "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
            ]
            app.launch()
            return app
        }
        var app = launch()
        let style = app.segmentedControls["plan.style"]
        XCTAssertTrue(style.waitForExistence(timeout: 15), "no dial or lanes switch")
        if !app.descendants(matching: .any)["plan.dial"].firstMatch.exists { style.buttons["Dial"].tap() }
        XCTAssertTrue(app.descendants(matching: .any)["plan.dial"].firstMatch.waitForExistence(timeout: 5), "the dial is not the default")
        XCTAssertTrue(style.isHittable, "the switch is not in reach")

        style.buttons["Lanes"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["plan.dial"].firstMatch.waitForNonExistence(timeout: 5), "the dial stayed")
        XCTAssertTrue(style.buttons["Lanes"].isSelected)

        app.terminate()
        app = launch()
        XCTAssertTrue(app.segmentedControls["plan.style"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.segmentedControls["plan.style"].buttons["Lanes"].isSelected, "the choice was not kept")
        XCTAssertFalse(app.descendants(matching: .any)["plan.dial"].firstMatch.exists)

        // Back to the dial, as the next test expects.
        app.segmentedControls["plan.style"].buttons["Dial"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["plan.dial"].firstMatch.waitForExistence(timeout: 5))
    }
}
