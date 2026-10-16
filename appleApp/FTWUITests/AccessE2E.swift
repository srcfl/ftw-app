import XCTest

/// One assistant approved end to end against a real box and a local FTW
/// Cloud, then removed. Skipped unless the rig is up:
///
///     TEST_RUNNER_FTW_E2E_PAIR=<pairing link from the box>
///     TEST_RUNNER_FTW_E2E_LINK=<the consent page's app link>
///     TEST_RUNNER_FTW_E2E_CODE=<the consent page's code>
///     TEST_RUNNER_FTW_E2E_CLOUD=wss://127.0.0.1:18943/v1/app
///     TEST_RUNNER_FTW_E2E_CLOUD_KEY=<ftwcloudd's Noise key, base64url>
///     TEST_RUNNER_FTW_E2E_OFFER_KEYS=<kid>:<pub>
///     xcodebuild test … -only-testing:FTWUITests/AccessE2E
///
/// The simulator must trust the rig's CA (`simctl keychain add-root-cert`),
/// have Face ID enrolled, and be told to match while the test waits for it
/// (`notifyutil -p com.apple.BiometricKit_Sim.pearl.match`): the rig's
/// script does both. The box's pairing code names no home yet, so the
/// first session goes through the relay, as a newly paired phone's does.
final class AccessE2E: XCTestCase {
    @MainActor
    func testApproveThenRemove() throws {
        let env = ProcessInfo.processInfo.environment
        guard let pair = env["FTW_E2E_PAIR"], let link = env["FTW_E2E_LINK"], let code = env["FTW_E2E_CODE"],
              let cloud = env["FTW_E2E_CLOUD"], let key = env["FTW_E2E_CLOUD_KEY"], let offers = env["FTW_E2E_OFFER_KEYS"] else {
            throw XCTSkip("Set the TEST_RUNNER_FTW_E2E_* variables to run against the rig.")
        }
        let app = XCUIApplication()
        app.launchArguments = [
            "-FTWPairLink", pair, "-FTWAccessLink", link,
            "-FTWCloudURL", cloud, "-FTWCloudKey", key,
            "-FTWOfferKeys", offers, "-FTWOfferURL", "https://127.0.0.1:18943",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()

        // Pair with the box. The simulator has no passkey, so the phone
        // keeps its key on the device, as a phone without one does.
        let pairButton = app.buttons["pair.primary"]
        XCTAssertTrue(pairButton.waitForExistence(timeout: 20))
        pairButton.tap()
        // FTW Cloud's one screen at first start.
        let carryOn = app.buttons["Continue"]
        if carryOn.waitForExistence(timeout: 20) { carryOn.tap() }

        // The consent link's sheet opens over the home once the box has
        // answered: the code from the page, then the offer.
        let field = app.textFields["offer.code"]
        XCTAssertTrue(field.waitForExistence(timeout: 60))
        shoot(app, "e2e-code")
        field.typeText(code)
        app.buttons["offer.continue"].tap()
        XCTAssertTrue(app.staticTexts["offer.host"].waitForExistence(timeout: 15))
        shoot(app, "e2e-offer")
        let control = app.switches["offer.control"]
        if control.waitForExistence(timeout: 3) {
            control.switches.firstMatch.exists ? control.switches.firstMatch.tap() : control.tap()
        }
        app.buttons["offer.approve"].tap()
        // Face ID: the rig's script matches it.
        XCTAssertTrue(app.buttons["offer.done"].waitForExistence(timeout: 60))
        shoot(app, "e2e-done")
        app.buttons["offer.done"].tap()

        // The assistant in the roster, as the box lists it.
        app.buttons["now.title"].tap()
        app.buttons["menu.settings"].tap()
        let access = app.buttons["settings.access"]
        for _ in 0..<6 where !access.isHittable { app.swipeUp() }
        access.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'access.grant.'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        shoot(app, "e2e-roster")
        // Let the assistant call its home a few times.
        Thread.sleep(forTimeInterval: Double(env["FTW_E2E_HOLD_S"] ?? "") ?? 20)

        // Removed with one tap, no Face ID.
        row.swipeLeft()
        let remove = app.buttons["Remove access"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 15))
        shoot(app, "e2e-removed")
        Thread.sleep(forTimeInterval: 8)
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
