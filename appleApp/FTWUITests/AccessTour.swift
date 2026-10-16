import XCTest

/// Photographs Access in the demo: Settings, the list, a request, one
/// grant, the activity, Get help and an assistant's offer from code to
/// done. Skipped unless asked for:
///
///     TEST_RUNNER_FTW_ACCESS_SHOTS=1 TEST_RUNNER_FTW_LANG=sv xcodebuild test … \
///       -only-testing:FTWUITests/AccessTour -resultBundlePath access.xcresult
///     xcrun xcresulttool export attachments --path access.xcresult --output-path shots
///
/// Light or dark is the simulator's own setting.
final class AccessTour: XCTestCase {
    @MainActor
    func testTour() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["FTW_ACCESS_SHOTS"] == "1", "Set TEST_RUNNER_FTW_ACCESS_SHOTS=1 to photograph Access.")
        let lang = env["FTW_LANG"] ?? "en"
        let app = XCUIApplication()
        app.launchArguments = [
            "-FTWDemo", "YES", "-FTWSheet", "settings",
            "-AppleLanguages", "(\(lang))", "-AppleLocale", lang == "sv" ? "sv_SE" : "en_US",
        ]
        app.launch()

        XCTAssertTrue(app.buttons["mode.close"].waitForExistence(timeout: 15))
        let access = reveal(app, app.buttons["settings.access"])
        XCTAssertTrue(access.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        shoot(app, "settings")

        access.tap()
        XCTAssertTrue(app.buttons["access.add"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1.5)
        shoot(app, "access")

        // What waits for the owner.
        let request = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'access.request.'")).firstMatch
        XCTAssertTrue(request.waitForExistence(timeout: 5))
        request.tap()
        XCTAssertTrue(app.buttons["request.approve"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        shoot(app, "request")
        back(app)
        Thread.sleep(forTimeInterval: 1)

        // One grant.
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'access.grant.'")).firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["grant.ends"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        shoot(app, "grant")
        back(app)
        Thread.sleep(forTimeInterval: 1)

        // The activity.
        reveal(app, app.buttons["access.activity"]).tap()
        Thread.sleep(forTimeInterval: 1.5)
        shoot(app, "activity")
        back(app)
        Thread.sleep(forTimeInterval: 1)

        // Get help.
        reveal(app, app.buttons["access.help"]).tap()
        let problem = app.textFields["help.problem"]
        XCTAssertTrue(problem.waitForExistence(timeout: 5))
        problem.tap()
        problem.typeText(lang == "sv" ? "Batteriet slutar ladda vid 80 % sedan i tisdags." : "The battery stops charging at 80 % since Tuesday.")
        let written = app.buttons["help.written"]
        if written.waitForExistence(timeout: 3) { written.tap() }
        Thread.sleep(forTimeInterval: 1)
        shoot(app, "help")
        app.buttons["help.look"].tap()
        XCTAssertTrue(app.buttons["offer.done"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        shoot(app, "help-done")
        back(app)
        Thread.sleep(forTimeInterval: 1)

        // An assistant's offer: the code, the offer, control, done.
        reveal(app, app.buttons["access.add"], down: true).tap()
        let code = app.textFields["offer.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        shoot(app, "offer-code")
        code.typeText("K7QF-2MXD")
        app.buttons["offer.continue"].tap()
        XCTAssertTrue(app.staticTexts["offer.host"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        shoot(app, "offer")
        let control = app.switches["offer.control"]
        if control.waitForExistence(timeout: 3) {
            control.switches.firstMatch.exists ? control.switches.firstMatch.tap() : control.tap()
            Thread.sleep(forTimeInterval: 1)
            shoot(app, "offer-control")
        }
        app.buttons["offer.approve"].tap()
        XCTAssertTrue(app.buttons["offer.done"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        shoot(app, "offer-done")
        app.buttons["offer.done"].tap()
        Thread.sleep(forTimeInterval: 1.5)
        shoot(app, "access-after")
    }

    /// A row a lazy list has not made yet: scroll until it is there.
    @discardableResult
    private func reveal(_ app: XCUIApplication, _ element: XCUIElement, down: Bool = false) -> XCUIElement {
        let screen = app.windows.firstMatch.frame
        let list = app.collectionViews.firstMatch
        for _ in 0..<8 where !(element.exists && element.isHittable && screen.contains(element.frame)) {
            let surface = list.exists ? list : app
            if down { surface.swipeDown(velocity: .slow) } else { surface.swipeUp(velocity: .slow) }
        }
        return element
    }

    /// iOS 26 draws the back button as glass, outside a navigation bar.
    private func back(_ app: XCUIApplication) {
        let button = app.buttons["BackButton"]
        if button.exists { button.tap() } else { app.navigationBars.buttons.element(boundBy: 0).tap() }
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
