import XCTest

/// The car as its own entity against the demo box (docs/cars.md in
/// srcfl/ftw): one tap names the car on a charger that asks. The tour that
/// photographs each case is skipped unless asked for:
///
///     TEST_RUNNER_FTW_SHOTS=1 xcodebuild test … \
///       -only-testing:FTWUITests/CarsTour -resultBundlePath cars.xcresult
///     xcrun xcresulttool export attachments --path cars.xcresult --output-path cars
final class CarsTour: XCTestCase {
    static let zoe = "0a1b2c3d4e5f60718293a4b5c6d7e8f9"

    private func launch(_ more: [String], lang: String = "en") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-FTWDemo", "YES", "-AppleLanguages", "(\(lang))", "-AppleLocale", lang == "sv" ? "sv_SE" : "en_US"] + more
        app.launch()
        return app
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func text(_ app: XCUIApplication, _ part: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", part)).firstMatch
    }

    /// Two cars and no answer: the car view asks, one tap names Zoe, and
    /// the view becomes Zoe's with the box's receipt under the charger.
    @MainActor
    func testOneTapNamesTheCar() throws {
        let app = launch(["-FTWTab", "car", "-FTWDemoCars", "asking"])
        let zoe = app.buttons["car.which.\(Self.zoe)"]
        XCTAssertTrue(zoe.waitForExistence(timeout: 15), "the car view never asked which car")
        shoot(app, "asking")
        zoe.tap()
        XCTAssertTrue(text(app, "FTW now plans for Zoe.").waitForExistence(timeout: 10), "the box's answer never showed")
        XCTAssertFalse(app.buttons["car.which.\(Self.zoe)"].exists)
        shoot(app, "asking-answered")
    }

    /// Each case for review: one car with the cable out, one plugged in,
    /// two with no answer, two in the car's node view, the cars in
    /// Settings, and a box from before cars.
    @MainActor
    func testShots() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["FTW_SHOTS"] == "1", "Set TEST_RUNNER_FTW_SHOTS=1 to photograph the cars.")
        let lang = env["FTW_LANG"] ?? "en"
        let cases: [(String, [String])] = [
            ("away-car", ["-FTWTab", "car", "-FTWDemoCars", "away"]),
            ("away-node", ["-FTWNode", "car", "-FTWDemoCars", "away"]),
            ("plugged-car", ["-FTWTab", "car", "-FTWDemoCars", "one", "-FTWDemoCar", "car"]),
            ("two-node", ["-FTWNode", "car", "-FTWDemoCars", "two", "-FTWDemoCar", "car"]),
            ("asking-node", ["-FTWNode", "car", "-FTWDemoCars", "asking"]),
            ("old-box-car", ["-FTWTab", "car", "-FTWDemoCars", "old"]),
        ]
        for (name, args) in cases {
            let app = launch(args, lang: lang)
            Thread.sleep(forTimeInterval: 6)
            shoot(app, name)
            app.terminate()
        }
        let app = launch(["-FTWSheet", "settings", "-FTWDemoCars", "two", "-FTWDemoCar", "car"], lang: lang)
        let cars = app.buttons["settings.cars"]
        // The sheet fits its height to the plan's rows; the cars sit under
        // them once the box has said it keeps cars.
        Thread.sleep(forTimeInterval: 4)
        for _ in 0..<4 where !cars.isHittable { app.swipeUp() }
        XCTAssertTrue(cars.waitForExistence(timeout: 5))
        cars.tap()
        Thread.sleep(forTimeInterval: 2)
        shoot(app, "settings-cars")
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'settings.car.'")).firstMatch
        if first.waitForExistence(timeout: 5) {
            first.tap()
            Thread.sleep(forTimeInterval: 2)
            shoot(app, "settings-car")
        }
    }
}
