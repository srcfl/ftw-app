import XCTest

/// What a tester could not reach in the car view (Erik, 31 Oct 2026): the
/// goal sat under the plan, a swipe that started on the plan did not
/// scroll, and neither the level ring nor Plan opened the goal.
final class CarReachTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-FTWDemo", "YES",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
            "-FTWTab", "car", "-FTWDemoCars", "one", "-FTWDemoCar", "car",
        ]
        app.launch()
        return app
    }

    /// The plan opens under the bar at the foot, now that the goal comes
    /// first: bring it up, by a swipe that starts above it.
    @MainActor
    private func planInView(_ app: XCUIApplication) -> XCUIElement {
        let chart = app.descendants(matching: .any)["node.timeline.chart"]
        XCTAssertTrue(chart.waitForExistence(timeout: 15), "no plan on the car view")
        Thread.sleep(forTimeInterval: 2)
        let window = app.windows.firstMatch
        let top = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        top.press(forDuration: 0.02, thenDragTo: top.withOffset(CGVector(dx: 0, dy: -250)), withVelocity: .slow, thenHoldForDuration: 0.3)
        Thread.sleep(forTimeInterval: 1)
        return chart
    }

    @MainActor
    func testASwipeUpOnThePlanScrollsThePage() throws {
        let app = launch()
        let chart = planInView(app)
        let before = chart.frame.minY
        let from = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        // Held at the end, so the page does not fly on past the chart.
        from.press(forDuration: 0.02, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -200)), withVelocity: .slow, thenHoldForDuration: 0.3)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(chart.exists, "the plan left the screen")
        XCTAssertLessThan(chart.frame.minY, before - 100, "a swipe up on the plan left the page where it was")
    }

    @MainActor
    func testADragAcrossThePlanPansItAndHoldsThePage() throws {
        let app = launch()
        let chart = planInView(app)
        // The goal above the plan, which the way back to now does not move.
        let goal = app.descendants(matching: .any)["car.goal"]
        let before = goal.frame.minY
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: chart.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)), withVelocity: .default, thenHoldForDuration: 0.2)
        // The window left its opening, so the way back shows.
        XCTAssertTrue(app.buttons["car.timeline.today"].waitForExistence(timeout: 3), "a drag across the plan did not pan it")
        XCTAssertEqual(goal.frame.minY, before, accuracy: 2, "a drag across the plan moved the page")
    }

    @MainActor
    func testAPinchOnThePlanZoomsIt() throws {
        let app = launch()
        let chart = planInView(app)
        chart.pinch(withScale: 2, velocity: 1)
        XCTAssertTrue(app.buttons["car.timeline.today"].waitForExistence(timeout: 3), "a pinch on the plan did not zoom it")
        XCTAssertTrue(app.descendants(matching: .any)["car.goal"].exists, "a pinch on the plan closed the car view")
    }

    @MainActor
    func testTheGoalIsOnTheFirstScreen() throws {
        let app = launch()
        let goal = app.descendants(matching: .any)["car.goal"]
        XCTAssertTrue(goal.waitForExistence(timeout: 15), "no goal on the car view")
        XCTAssertTrue(app.windows.firstMatch.frame.contains(goal.frame), "the goal is below the first screen")
    }

    @MainActor
    func testATapOnTheRingOpensTheGoal() throws {
        let app = launch()
        let ring = app.buttons["car.ring"]
        XCTAssertTrue(ring.waitForExistence(timeout: 15), "the ring is not a button")
        ring.tap()
        XCTAssertTrue(app.descendants(matching: .any)["goal.editor"].waitForExistence(timeout: 5), "a tap on the ring did not open the goal")
    }

    @MainActor
    func testATapOnTheChosenPlanOpensTheGoal() throws {
        let app = launch()
        let plan = app.buttons["car.control.plan"]
        XCTAssertTrue(plan.waitForExistence(timeout: 15), "no Plan button")
        // The demo car charges on its plan, so Plan is the chosen one.
        XCTAssertTrue(plan.isSelected, "Plan is not chosen in the demo")
        plan.tap()
        XCTAssertTrue(app.descendants(matching: .any)["goal.editor"].waitForExistence(timeout: 5), "a tap on the chosen Plan did not open the goal")
    }
}
