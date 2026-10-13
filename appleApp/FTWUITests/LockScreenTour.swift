import XCTest

/// Puts the plan widget on the lock screen and photographs it, for review.
/// Skipped unless asked for: it drives SpringBoard, whose labels follow the
/// simulator's language (Swedish here), and it changes the lock screen.
///
///     TEST_RUNNER_FTW_LOCK=1 xcodebuild test … -only-testing:FTWUITests/LockScreenTour
@MainActor
final class LockScreenTour: XCTestCase {
    var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    func testPlanOnTheLockScreen() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FTW_LOCK"] == "1", "Set TEST_RUNNER_FTW_LOCK=1 to place the widget.")
        lock()
        wake()
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)).press(forDuration: 2)
        Thread.sleep(forTimeInterval: 3)
        guard tap(springboard.buttons["posterboard-customize-button"].firstMatch) else { return note("no Customize") }
        Thread.sleep(forTimeInterval: 2)
        guard tap(springboard.buttons["grouped-widgets-reticle-view"].firstMatch) else { return note("no widget slot") }
        Thread.sleep(forTimeInterval: 3)
        shoot("lock-gallery")
        // The gallery lists apps by name; FTW's entry opens its widgets.
        let ftw = springboard.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'FTW'")).firstMatch
        if !ftw.waitForExistence(timeout: 3) {
            springboard.swipeUp()
        }
        guard tap(ftw) else { return note("no FTW in the gallery") }
        Thread.sleep(forTimeInterval: 2)
        shoot("lock-ftw")
        // FTW's widgets are pages: the price first, the plan second. A tap
        // on the preview adds it.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.72)).press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.72)))
        Thread.sleep(forTimeInterval: 1.5)
        shoot("lock-ftw-plan")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72)).tap()
        Thread.sleep(forTimeInterval: 2)
        shoot("lock-added")
        // Close the gallery with its cross, then save with Done, top right.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.896, dy: 0.493)).tap()
        Thread.sleep(forTimeInterval: 2)
        // The cross leads back to the list of apps; that sheet is dragged away.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.46)).press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        Thread.sleep(forTimeInterval: 2)
        shoot("lock-closed")
        let done = springboard.buttons["editing-done"].firstMatch
        if done.waitForExistence(timeout: 2) {
            done.tap()
        } else {
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.035)).tap()
        }
        Thread.sleep(forTimeInterval: 3)
        lock()
        wake()
        Thread.sleep(forTimeInterval: 3)
        shoot("lock-plan")
    }

    /// The lock screen as it is, for a widget placed before.
    /// `TEST_RUNNER_FTW_LOCK=shot`.
    func testShowTheLockScreen() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FTW_LOCK"] == "shot", "Set TEST_RUNNER_FTW_LOCK=shot to photograph the lock screen.")
        lock()
        wake()
        Thread.sleep(forTimeInterval: 3)
        shoot("lock-plan")
    }

    private func tap(_ element: XCUIElement) -> Bool {
        guard element.waitForExistence(timeout: 5) else { return false }
        element.tap()
        return true
    }

    /// Says where it stopped, without failing: a failure makes Xcode collect
    /// a simulator diagnosis that takes minutes.
    private func note(_ text: String) {
        print("LockScreenTour stopped: \(text)")
        shoot("lock-stopped")
    }

    private func lock() {
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        Thread.sleep(forTimeInterval: 1.5)
    }

    private func wake() {
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        Thread.sleep(forTimeInterval: 2)
    }

    private func shoot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
