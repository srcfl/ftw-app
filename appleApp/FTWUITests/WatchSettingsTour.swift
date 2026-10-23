import XCTest

/// The Apple Watch row in Settings, where an owner lets the watch work
/// without the phone. The demo with a watch that offered its key
/// (`-FTWWatchKeyOffered`). The demo has no passkey, so a tap shows the
/// sentence a phone without one gets. For pictures, not a gate.
final class WatchSettingsTour: XCTestCase {
    private func shoot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func testTheWatchRow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-FTWDemo", "YES", "-FTWSheet", "settings", "-FTWWatchKeyOffered", "YES"]
        app.launch()
        let add = app.buttons["settings.watch.add"]
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 15))
        let screen = app.windows.firstMatch.frame
        let list = app.collectionViews.firstMatch
        for _ in 0..<8 where !(add.exists && add.isHittable && screen.contains(add.frame)) {
            (list.exists ? list : app).swipeUp(velocity: .slow)
        }
        XCTAssertTrue(add.isHittable, "no Apple Watch row")
        sleep(1)
        shoot("watch-row")
        add.tap()
        sleep(3)
        shoot("watch-row-tapped")
    }
}
