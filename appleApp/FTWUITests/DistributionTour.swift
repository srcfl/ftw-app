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
        car.tap()
        XCTAssertTrue(app.buttons["distribution.goal"].waitForExistence(timeout: 5))
    }
}
