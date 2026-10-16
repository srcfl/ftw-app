import XCTest

/// Review the design in a real iOS process. These tests never pair a box.
final class DistributionTour: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor private func launch(_ screen: String = "now", scenario: String = "sun", large: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-FTWDistributionDemo", "YES", "-FTWDistributionScreen", screen,
                               "-FTWDistributionScenario", scenario, "-AppleLanguages", "(sv)", "-AppleLocale", "sv_SE",
                               "-UIPreferredContentSizeCategoryName", large ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"]
        app.launch()
        XCTAssertTrue(app.buttons["distribution.demo"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor private func shoot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor func testCarGoalAndControlWaitForTheSimulatedReply() {
        let app = launch()
        let car = app.buttons["distribution.field.car"]
        XCTAssertTrue(car.waitForExistence(timeout: 10)); car.tap()
        let goal = app.buttons["distribution.goal"]
        XCTAssertTrue(goal.waitForExistence(timeout: 5)); shoot(app, "car-before")
        goal.tap()
        XCTAssertTrue(app.buttons["distribution.save"].waitForExistence(timeout: 5))
        app.sliders["Laddmål"].adjust(toNormalizedSliderPosition: 0.88)
        shoot(app, "goal-editor")
        app.buttons["distribution.save"].tap()
        XCTAssertTrue(goal.waitForExistence(timeout: 8))
        let pause = app.buttons["distribution.hold.paused"]
        XCTAssertTrue(pause.isHittable); pause.tap()
        XCTAssertTrue(app.buttons["distribution.hold.plan"].waitForExistence(timeout: 8))
        shoot(app, "car-paused")
    }

    @MainActor func testEveryScreenRendersAndKeepsTheDemoControls() {
        for screen in ["now", "solar", "home", "battery", "grid", "plan", "prices", "history", "box", "connection", "access", "invite", "notifications", "recovery", "about", "licenses", "widgets", "pair", "scan", "offer"] {
            let app = launch(screen)
            shoot(app, screen)
            XCTAssertTrue(app.buttons["distribution.demo"].isHittable)
            app.terminate()
        }
    }

    @MainActor func testThePlanScrubsDirectlyAndPhasesBelongToTheGrid() {
        let app = launch("plan")
        let graph = app.descendants(matching: .any).matching(identifier: "distribution.plan.graph").firstMatch
        XCTAssertTrue(graph.waitForExistence(timeout: 8))
        XCTAssertEqual(app.sliders.count, 0, "The graph must take the finger directly")
        let start = graph.coordinate(withNormalizedOffset: CGVector(dx: 0.14, dy: 0.5))
        let end = graph.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.45))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.4)
        XCTAssertTrue(app.staticTexts["02.00 · Ladda under billigare timmar"].waitForExistence(timeout: 5))
        shoot(app, "plan-direct-scrub")
        app.terminate()
        let load = launch("home")
        XCTAssertTrue(load.staticTexts["Hemmets last"].waitForExistence(timeout: 5))
        XCTAssertFalse(load.staticTexts["Nätanslutningens faser"].exists)
        load.terminate()
        let grid = launch("grid")
        XCTAssertTrue(grid.staticTexts["Nätanslutningens faser"].waitForExistence(timeout: 5))
        for phase in ["L1", "L2", "L3"] { XCTAssertTrue(grid.staticTexts[phase].exists) }
        shoot(grid, "phases-at-grid")
    }

    @MainActor func testOldDataBlocksCommandsAndLargeTextStillOpensTheCar() {
        let app = launch("car", scenario: "offline")
        let goal = app.buttons["distribution.goal"]
        XCTAssertTrue(goal.waitForExistence(timeout: 8)); XCTAssertFalse(goal.isEnabled)
        XCTAssertFalse(app.buttons["distribution.hold.now"].isEnabled)
        shoot(app, "offline")
        app.terminate()
        let large = launch("car", large: true)
        XCTAssertTrue(large.buttons["distribution.goal"].waitForExistence(timeout: 8))
        shoot(large, "car-largest-text")
        large.terminate()
        let overview = launch(large: true)
        let accessibleCar = overview.buttons["distribution.accessible.car"]
        overview.swipeUp()
        XCTAssertTrue(accessibleCar.waitForExistence(timeout: 8))
        accessibleCar.tap()
        XCTAssertTrue(overview.buttons["distribution.goal"].waitForExistence(timeout: 5))
    }

    @MainActor func testAFieldCanBeGrabbedAndStillOpensWithATap() {
        let app = launch()
        let car = app.buttons["distribution.field.car"]
        XCTAssertTrue(car.waitForExistence(timeout: 8))
        let start = car.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: 85, dy: -45))
        start.press(forDuration: 0.15, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertTrue(car.exists)
        XCTAssertFalse(app.buttons["distribution.goal"].exists, "Dragging opened a detail view")
        shoot(app, "after-push")
        let inlet = app.buttons["distribution.field.solar"]
        let source = inlet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        source.press(forDuration: 0.15, thenDragTo: source.withOffset(CGVector(dx: 70, dy: 35)), withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertTrue(car.exists, "Grabbing the solar stream opened its detail view")
        shoot(app, "after-source-grip")
        car.tap()
        XCTAssertTrue(app.buttons["distribution.goal"].waitForExistence(timeout: 5))
    }

    @MainActor func testTheRobotCanBeDraggedAndTappedWithoutOpeningADetail() {
        let app = launch()
        let robot = app.buttons["distribution.robot"]
        XCTAssertTrue(robot.waitForExistence(timeout: 8))
        let start = robot.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.12, thenDragTo: start.withOffset(CGVector(dx: 95, dy: 110)), withVelocity: .slow, thenHoldForDuration: 0.4)
        XCTAssertTrue(robot.exists)
        XCTAssertFalse(app.buttons["distribution.goal"].exists)
        shoot(app, "robot-return")
        robot.tap()
        XCTAssertTrue(app.buttons["distribution.field.battery"].exists)
        XCTAssertTrue(app.buttons["distribution.field.grid"].exists)
        shoot(app, "robot-nudge")
        app.buttons["distribution.field.battery"].tap()
        XCTAssertTrue(app.staticTexts["HEMBATTERIET"].waitForExistence(timeout: 5))
    }

    @MainActor func testOneSiteContainsOneGridAndOneHomeBatteryInEveryState() {
        for scenario in ["sun", "mixed", "importing", "night", "surplus", "battery"] {
            let app = launch(scenario: scenario)
            for part in ["solar", "home", "car", "battery", "grid"] {
                XCTAssertEqual(app.buttons.matching(identifier: "distribution.field.\(part)").count, 1)
            }
            let grid = app.buttons["distribution.field.grid"]
            let battery = app.buttons["distribution.field.battery"]
            let solar = app.buttons["distribution.field.solar"]
            XCTAssertFalse(solar.label.contains("Till solen"))
            if scenario == "sun" || scenario == "surplus" {
                XCTAssertTrue(grid.label.contains("ut ur fastigheten"))
            }
            if scenario == "mixed" || scenario == "importing" {
                XCTAssertTrue(grid.label.contains("in i fastigheten"))
            }
            if scenario == "night" {
                XCTAssertTrue(grid.label.contains("I balans"))
                XCTAssertTrue(battery.label.contains("ger energi"))
            }
            if scenario == "sun" || scenario == "battery" {
                XCTAssertTrue(battery.label.contains("lagrar"))
            }
            if scenario == "surplus" { XCTAssertTrue(battery.label.contains("Vilar")) }
            shoot(app, "site-\(scenario)")
            if scenario == "importing" {
                grid.tap()
                XCTAssertTrue(app.staticTexts["FRÅN NÄTET"].waitForExistence(timeout: 5))
            }
            app.terminate()
        }
    }
}
