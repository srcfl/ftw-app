import XCTest

final class PairingTests: XCTestCase {
    @MainActor
    func testOneIPhoneHasACodeAndAPictureWithoutTheCamera() throws {
        try checkPairing(appearance: "Light", text: "UICTContentSizeCategoryL")
    }

    @MainActor
    func testPairingCodeInDarkMode() throws {
        try checkPairing(appearance: "Dark", text: "UICTContentSizeCategoryL")
    }

    @MainActor
    func testPairingCodeAtTheLargestTextSize() throws {
        try checkPairing(appearance: "Light", text: "UICTContentSizeCategoryAccessibilityXXXL")
    }

    @MainActor
    private func checkPairing(appearance: String, text: String) throws {
        let originalAppearance = XCUIDevice.shared.appearance
        XCUIDevice.shared.appearance = appearance == "Dark" ? .dark : .light
        defer { XCUIDevice.shared.appearance = originalAppearance }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(sv)", "-AppleLocale", "sv_SE",
                               "-UIPreferredContentSizeCategoryName", text]
        app.launch()
        let enter = app.buttons["pair.enterCode"]
        guard enter.waitForExistence(timeout: 10) else { throw XCTSkip("This simulator already holds a paired home.") }
        XCTAssertTrue(enter.isHittable)
        XCTAssertTrue(app.buttons["pair.picture"].exists)
        enter.tap()
        XCTAssertTrue(app.navigationBars["Ange parkod"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["pair.address"].exists)
        let code = app.textFields["pair.code"]
        XCTAssertTrue(code.exists)
        XCTAssertFalse(app.buttons["pair.primary"].isEnabled)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "pair-code-swedish-\(appearance)-\(text)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        code.tap()
        code.typeText("1234")
        app.buttons["pair.primary"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Koden har gått ut'")).firstMatch.waitForExistence(timeout: 3))
        app.buttons["Avbryt"].tap()
        XCTAssertTrue(app.navigationBars["Anslut FTW"].exists)
    }
}
