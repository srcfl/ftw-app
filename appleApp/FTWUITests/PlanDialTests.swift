import XCTest

/// The plan dial at the top of the plan view, as VoiceOver meets it: one
/// element that starts at now and reads the time, what the plan does, the
/// price and the battery. Its hour steps are `PlanDial.Face.step`, tested
/// in FTWShared: XCTest on iOS cannot swipe an adjustable element.
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
            "-FTWDemo", "YES", "-FTWTab", "plan",
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
}
