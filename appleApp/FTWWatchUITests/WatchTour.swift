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

    /// Now, with how the home is run by name in its corner, to read: the
    /// mode changes in Plan on the iPhone alone.
    func testNowReadsTheMode() throws {
        let app = launch("now")
        XCTAssertTrue(app.staticTexts.firstMatch.waitForExistence(timeout: 15))
        sleep(4)
        shoot("now")
        let mode = app.descendants(matching: .any)["watch.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        XCTAssertEqual(mode.label, "Mode")
        XCTAssertFalse(app.buttons["watch.mode"].exists, "the mode is plain text")
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

    /// The watch on its own: no phone, a local FTW Cloud and box, and Charge
    /// now through the box's exchange. Runs only against that rig, which
    /// names its launch arguments in `FTW_RIG_ARGS` (`TEST_RUNNER_FTW_RIG_ARGS`
    /// for xcodebuild): `-FTWCloudURL`, `-FTWCloudKey`, `-FTWWatchKey` and
    /// `-FTWWatchLink`.
    static let rigPhoneOffS: UInt32 = 12

    func testChargeNowThroughFTWCloud() throws {
        guard let rig = ProcessInfo.processInfo.environment["FTW_RIG_ARGS"], !rig.isEmpty else {
            throw XCTSkip("needs a local FTW Cloud and box; see FTW_RIG_ARGS")
        }
        let app = launch("car", rig.split(separator: " ").map(String.init))
        let button = app.buttons["watch.car.chargeNow"]
        XCTAssertTrue(button.waitForExistence(timeout: 20))
        // Time for the rig to shut the paired phone down, which xcodebuild
        // boots with the watch.
        sleep(Self.rigPhoneOffS)
        shoot("cloud-car")
        XCTAssertTrue(button.isEnabled, "Charge now is off with the phone away")
        button.tap()
        let yes = app.buttons["watch.confirm"]
        XCTAssertTrue(yes.waitForExistence(timeout: 5))
        yes.tap()
        sleep(1)
        shoot("cloud-charge-now-sending")
        // The marks are always on the line; the sentence says what the box
        // did, and only its confirmation says Charge now is on.
        let receipt = app.descendants(matching: .any)["watch.receipt"]
        let on = NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "Charge now on", "Ladda nu på")
        let done = XCTNSPredicateExpectation(predicate: on, object: receipt)
        XCTAssertEqual(XCTWaiter().wait(for: [done], timeout: 15), .completed, "the box's result did not come back through FTW Cloud")
        sleep(1)
        shoot("cloud-charge-now-confirmed")
        // One read after the box applied it: the car shows what it does now.
        sleep(5)
        shoot("cloud-car-after")
    }
}
