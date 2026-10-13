import XCTest

/// Now is built to be read without scrolling. On the smallest and the
/// largest iPhone that runs iOS 26, at the standard text size, its last
/// element can be tapped where it stands, and every node opens its view.
///
///     xcodebuild test -project FTW.xcodeproj -scheme FTW \
///       -destination 'platform=iOS Simulator,name=iPhone SE (3rd generation)' \
///       -only-testing:FTWUITests/NowFitsTests
final class NowFitsTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The standard text size, whatever the simulator was left at.
    static let standard = "UICTContentSizeCategoryL"
    /// The largest size that is not an accessibility size.
    static let largest = "UICTContentSizeCategoryXXXL"

    @MainActor
    private func launchDemo(text: String = NowFitsTests.standard) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-FTWDemo", "YES",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-UIPreferredContentSizeCategoryName", text,
        ]
        app.launch()
        XCTAssertTrue(app.buttons["now.node.home"].waitForExistence(timeout: 15), "Now never drew the home")
        return app
    }

    @MainActor
    func testTheFootOfNowIsTappableWithoutScrolling() throws {
        let app = launchDemo()
        let foot = app.buttons["Source & licenses"]
        XCTAssertTrue(foot.waitForExistence(timeout: 5))
        // On screen as laid out: inside the window, hittable, and with no
        // scroll view on Now that could have carried it there.
        XCTAssertTrue(app.windows.firstMatch.frame.contains(foot.frame), "\(foot.frame) is outside \(app.windows.firstMatch.frame)")
        XCTAssertTrue(foot.isHittable)
        XCTAssertEqual(app.scrollViews.count, 0, "Now scrolls at the standard text size")
        for node in ["solar", "battery", "home", "grid", "car"] {
            XCTAssertTrue(app.buttons["now.node.\(node)"].isHittable, "\(node) cannot be tapped")
        }
        XCTAssertTrue(app.buttons["now.mode"].isHittable)
        foot.tap()
        XCTAssertTrue(app.navigationBars["Source & licenses"].waitForExistence(timeout: 5))
    }

    /// Only the accessibility sizes may scroll.
    @MainActor
    func testAtTheLargestStandardTextSizeNowStillFits() throws {
        let app = launchDemo(text: Self.largest)
        let foot = app.buttons["Source & licenses"]
        XCTAssertTrue(foot.waitForExistence(timeout: 5))
        XCTAssertTrue(app.windows.firstMatch.frame.contains(foot.frame), "\(foot.frame) is outside \(app.windows.firstMatch.frame)")
        XCTAssertTrue(foot.isHittable)
        XCTAssertEqual(app.scrollViews.count, 0, "Now scrolls at the largest standard text size")
    }

    @MainActor
    func testANodeOpensItsLiveHistoryPlanAndMode() throws {
        let app = launchDemo()
        app.buttons["now.node.battery"].tap()
        XCTAssertTrue(app.navigationBars["Battery"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["LIVE · LAST 5 MIN"].exists)
        let ahead = app.segmentedControls["node.period"].buttons["Ahead"]
        XCTAssertTrue(ahead.isHittable)
        ahead.tap()
        XCTAssertTrue(app.buttons["node.mode.change"].isHittable)
        // The node's view fits too: its last control is where it stands.
        XCTAssertTrue(app.windows.firstMatch.frame.contains(app.buttons["node.mode.change"].frame))
    }

    /// The mode sheet opens tall enough for its choices, keeps the box's
    /// mode ticked while a new one waits in its own row, moves nothing under
    /// the finger, and closes once the box applied the mode.
    @MainActor
    func testTheModeSheetFitsWaitsInPlaceAndClosesOnceApplied() throws {
        let app = launchDemo()
        let button = app.buttons["now.mode"]
        // The choices rest until the stream is up.
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 3)
        button.tap()
        let plan = app.buttons["mode.choice.plan"]
        XCTAssertTrue(plan.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1.5)
        shoot(app, "mode-open")
        XCTAssertTrue(plan.isSelected, "the box's mode is not ticked")
        let idle = app.buttons["mode.choice.idle"]
        XCTAssertTrue(idle.exists)
        // Every choice the sheet opened with is on screen: the sheet fits
        // its content, or is full height and scrolls.
        let window = app.windows.firstMatch.frame
        if !window.contains(idle.frame) {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(window.contains(idle.frame), "\(idle.frame) is outside \(window)")
        let top = idle.frame.minY
        idle.tap()
        Thread.sleep(forTimeInterval: 0.3)
        shoot(app, "mode-sending")
        XCTAssertEqual(idle.frame.minY, top, accuracy: 1, "the row moved under the finger")
        XCTAssertTrue(plan.isSelected, "the box's mode lost its tick before the box answered")
        // Applied: the sheet goes, and Now names the box's new mode.
        XCTAssertTrue(plan.waitForNonExistence(timeout: 10), "the sheet stayed open after the box applied the mode")
        XCTAssertEqual(button.value as? String, "Stop batteries")
        shoot(app, "mode-applied")
    }

    /// The first screen: a large title, one prominent action in reach
    /// without scrolling, the demo as a second choice, all in Swedish on a
    /// Swedish phone.
    @MainActor
    func testPairingHasOneActionInReachInSwedish() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(sv)", "-AppleLocale", "sv_SE",
            "-UIPreferredContentSizeCategoryName", Self.standard,
        ]
        app.launch()
        let scan = app.buttons["pair.primary"]
        guard scan.waitForExistence(timeout: 10) else {
            // A phone that holds a home opens it instead; nothing to see here.
            throw XCTSkip("this simulator holds a paired home")
        }
        shoot(app, "pair")
        XCTAssertTrue(app.navigationBars["Anslut FTW"].exists, "no large Swedish title")
        XCTAssertEqual(scan.label, "Skanna QR-koden")
        XCTAssertTrue(scan.isHittable)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(scan.frame))
        XCTAssertTrue(app.buttons["pair.demo"].exists)
        XCTAssertEqual(app.buttons.matching(identifier: "pair.primary").count, 1, "more than one prominent action")
    }

    @MainActor
    private func shoot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
