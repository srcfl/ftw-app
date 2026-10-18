import XCTest

/// Removing several assistants in a row, as a tester did on 17 October
/// 2026 after Grok took four tries: the app crashed in the list's batch
/// update. The demo box holds Claude, with a request waiting, and the four
/// Grok grants. Each removal is one swipe and takes the row away at once;
/// the box answers late, so the next swipe comes before it has answered
/// the last. The app must still be running with the rows gone.
///
///     xcodebuild test … -only-testing:FTWUITests/AccessRemoveTests -resultBundlePath remove.xcresult
///     xcrun xcresulttool export attachments --path remove.xcresult --output-path remove
///
/// `TEST_RUNNER_FTW_ACCESS_DELAY_MS` sets how late the box answers: 2500 ms
/// by default, so removals overlap; 600 ms is closer to a box behind FTW
/// Cloud.
final class AccessRemoveTests: XCTestCase {
    /// The demo's Grok grants, ids as the box makes them from each key.
    static let grok = [0x31, 0x32, 0x33, 0x34].map { byte in
        String(Data(repeating: UInt8(byte), count: 32).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").prefix(8))
    }
    static let claude = "q7Xn2vKd"

    /// Full swipes, one after another: each removes at once.
    @MainActor
    func testFullSwipesInARow() throws {
        try removeAll(style: "full") { app, row in
            let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5))
            let end = row.coordinate(withNormalizedOffset: CGVector(dx: -0.3, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
        }
    }

    /// Swipe, tap Remove access, and on to the next.
    @MainActor
    func testSwipeAndTapInARow() throws {
        try removeAll(style: "tap") { app, row in
            row.swipeLeft(velocity: .fast)
            let remove = app.buttons["Remove access"]
            if remove.waitForExistence(timeout: 2) { remove.tap() }
        }
    }

    @MainActor
    private func removeAll(style: String, _ swipe: @MainActor (XCUIApplication, XCUIElement) -> Void) throws {
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchArguments = [
            "-FTWDemo", "YES", "-FTWSheet", "settings", "-FTWDemoAccess", "grok",
            "-FTWDemoAccessDelayMs", env["FTW_ACCESS_DELAY_MS"] ?? "2500",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()

        XCTAssertTrue(app.buttons["mode.close"].waitForExistence(timeout: 15))
        let access = reveal(app, app.buttons["settings.access"])
        XCTAssertTrue(access.waitForExistence(timeout: 5))
        access.tap()
        let rows = (Self.grok + [Self.claude]).map { app.buttons["access.grant.\($0)"] }
        for row in rows { XCTAssertTrue(row.waitForExistence(timeout: 10), "\(row) never showed") }
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'access.request.'")).firstMatch.exists)
        Thread.sleep(forTimeInterval: 1)
        shoot(app, "\(style)-before")

        // Each row goes with its swipe, before the box has answered; the
        // next swipe waits for that, so it finds the rows where they are now.
        for row in rows {
            XCTAssertTrue(row.exists, "\(row) went before its swipe")
            swipe(app, row)
            XCTAssertTrue(row.waitForNonExistence(timeout: 2), "\(row) is still there after its swipe")
        }
        shoot(app, "\(style)-during")

        // Every answer and the read after the last are in by now.
        Thread.sleep(forTimeInterval: 8)
        XCTAssertEqual(app.state, .runningForeground, "the app is gone")
        for row in rows { XCTAssertFalse(row.exists, "\(row) is still there") }
        // Claude's request went with Claude, and the list says no one is left.
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'access.request.'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["No assistant can reach your home."].exists)
        shoot(app, "\(style)-after")
    }

    /// A row a lazy list has not made yet: scroll until it is there.
    @MainActor @discardableResult
    private func reveal(_ app: XCUIApplication, _ element: XCUIElement) -> XCUIElement {
        let screen = app.windows.firstMatch.frame
        let list = app.collectionViews.firstMatch
        for _ in 0..<8 where !(element.exists && element.isHittable && screen.contains(element.frame)) {
            (list.exists ? list : app).swipeUp(velocity: .slow)
        }
        return element
    }

    @MainActor
    private func shoot(_ app: XCUIApplication, _ name: String) {
        guard app.state == .runningForeground else { return }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
