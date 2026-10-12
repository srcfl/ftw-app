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
}
