import XCTest

/// The watch app on a watch simulator paired with an iPhone simulator that
/// runs the demo (`-FTWDemo YES`). Everything comes through the phone, as
/// on a wrist: the records, Now's frames and the box's answers to a
/// command. For pictures and recordings, not a gate: without the phone
/// the watch shows its cache and says the phone is out of reach.
final class WatchTour: XCTestCase {
    private func launch(_ page: String, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-FTWWatchPage", page] + extra
        app.launch()
        return app
    }

    private func shoot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// The Crown steps the hand a quarter at a time, forward through the
    /// evening and back to now.
    func testCrownScrub() throws {
        let app = launch("plan")
        XCTAssertTrue(app.otherElements["watch.plan.dial"].waitForExistence(timeout: 15))
        sleep(2)
        for _ in 0..<36 {
            XCUIDevice.shared.rotateDigitalCrown(delta: 0.06)
            usleep(200_000)
        }
        sleep(1)
        shoot("plan-scrubbed")
        for _ in 0..<36 {
            XCUIDevice.shared.rotateDigitalCrown(delta: -0.06)
            usleep(120_000)
        }
        sleep(1)
    }

    /// Charge now from the car page: the question, then the receipt as the
    /// box answers through the phone.
    func testChargeNowReceipt() throws {
        let app = launch("car")
        let button = app.buttons["watch.car.chargeNow"]
        XCTAssertTrue(button.waitForExistence(timeout: 15))
        sleep(2)
        button.tap()
        let yes = app.buttons["watch.confirm"]
        XCTAssertTrue(yes.waitForExistence(timeout: 5))
        sleep(1)
        shoot("charge-now-ask")
        yes.tap()
        XCTAssertTrue(app.otherElements["watch.receipt"].waitForExistence(timeout: 10) || app.staticTexts["watch.receipt"].exists)
        sleep(8)
        shoot("charge-now-receipt")
    }

    /// Now, the modes behind its toolbar button, and a change of mode with
    /// its receipt.
    func testNowAndMode() throws {
        let app = launch("now")
        XCTAssertTrue(app.staticTexts.firstMatch.waitForExistence(timeout: 15))
        sleep(4)
        shoot("now")
        let mode = app.buttons["watch.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        mode.tap()
        sleep(2)
        shoot("modes")
        let idle = app.buttons["watch.mode.idle"]
        if !idle.isHittable { app.swipeUp() }
        XCTAssertTrue(idle.waitForExistence(timeout: 5))
        idle.tap()
        let yes = app.buttons["watch.confirm"]
        XCTAssertTrue(yes.waitForExistence(timeout: 5))
        shoot("mode-ask")
        yes.tap()
        sleep(6)
        app.swipeUp()
        sleep(1)
        shoot("mode-receipt")
    }

    /// The four pages one after another, as a wrist moves through them,
    /// with a picture of each: Now after its trace has filled a little,
    /// the plan, the car, the price, and back.
    func testPaging() throws {
        let app = launch("now")
        XCTAssertTrue(app.staticTexts.firstMatch.waitForExistence(timeout: 30))
        // Live once the phone's frames arrive: the demo's status line says so.
        let live = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'DEMO'")).firstMatch
        _ = live.waitForExistence(timeout: 60)
        sleep(25)
        shoot("page-now")
        for name in ["page-plan", "page-car", "page-price"] {
            app.swipeUp()
            sleep(4)
            shoot(name)
        }
        for _ in 0..<3 {
            app.swipeDown()
            sleep(2)
        }
    }

    func testPriceAndPlan() throws {
        var app = launch("price")
        sleep(5)
        shoot("price")
        app.terminate()
        app = launch("plan")
        sleep(5)
        shoot("plan")
    }

    /// A change of mode from the toolbar's button returns to Now, whose
    /// status line carries the box's receipt for its time.
    func testModeReceiptOnNow() throws {
        let app = launch("now")
        let mode = app.buttons["watch.mode"].firstMatch
        XCTAssertTrue(mode.waitForExistence(timeout: 30))
        sleep(4)
        shoot("mode-before")
        mode.tap()
        let idle = app.buttons["watch.mode.idle"]
        XCTAssertTrue(idle.waitForExistence(timeout: 5))
        if !idle.isHittable { app.swipeUp() }
        idle.tap()
        let yes = app.buttons["watch.confirm"]
        XCTAssertTrue(yes.waitForExistence(timeout: 5))
        yes.tap()
        // Back on Now, with no tap of the person's own.
        let line = app.descendants(matching: .any)["watch.status"]
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        shoot("mode-receipt-now")
        sleep(2)
        shoot("mode-receipt-later")
        // Put the home back on the plan for the next test.
        mode.tap()
        let plan = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'watch.mode.planner_'")).firstMatch
        if plan.waitForExistence(timeout: 5) {
            if !plan.isHittable { app.swipeDown() }
            plan.tap()
            if yes.waitForExistence(timeout: 5) { yes.tap() }
        }
        sleep(6)
    }

    /// A drag across the trace reads it and leaves the page where it is; a
    /// drag up the screen still turns the page. On the simulator, with
    /// XCUITest's synthesised touches; a real wrist is another check.
    func testDragAcrossTheTraceKeepsThePage() throws {
        let app = launch("now")
        let line = app.descendants(matching: .any)["watch.status"]
        XCTAssertTrue(line.waitForExistence(timeout: 30))
        sleep(6)
        let window = app.windows.firstMatch
        let from = window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.55))
        let to = window.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.56))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 2.5)
        sleep(1)
        // Still on Now: the status line and the hero are on screen.
        XCTAssertTrue(line.isHittable, "a drag across the trace turned the page")
        XCTAssertTrue(app.descendants(matching: .any)["watch.now.hero"].exists)
        shoot("drag-across-after")
        // A swipe up from the middle of the screen, which is the trace on
        // 40 and 46 mm, still turns the page after a read.
        app.swipeUp()
        XCTAssertTrue(app.otherElements["watch.plan.dial"].waitForExistence(timeout: 5), "a swipe up from the trace did not turn the page")
        shoot("drag-up-pages")
    }
}
