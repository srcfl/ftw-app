import XCTest

/// Photographs the grid widget for review: on the home screen in each of
/// iOS 26's icon styles, and on the lock screen. Skipped unless asked for.
/// It drives SpringBoard, whose labels follow the simulator's language
/// (Swedish here), and it changes the home and lock screens.
///
/// Place the widgets first (`IconState.plist`, before boot) and launch the
/// app once with `-FTWDemo YES -FTWDemoWidgets YES`, so the demo leaves its
/// records. Then:
///
///     TEST_RUNNER_FTW_GRID=Tonat xcodebuild test … -only-testing:FTWUITests/GridWidgetTour/testHomeScreenStyle
///     TEST_RUNNER_FTW_GRID=lock  xcodebuild test … -only-testing:FTWUITests/GridWidgetTour/testLockScreen
///
/// The style is the button's label: Förval, Mörkt, Klart or Tonat.
@MainActor
final class GridWidgetTour: XCTestCase {
    var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }
    var asked: String { ProcessInfo.processInfo.environment["FTW_GRID"] ?? "" }

    func testHomeScreenStyle() throws {
        try XCTSkipIf(asked.isEmpty || asked == "lock", "Set TEST_RUNNER_FTW_GRID to Förval, Mörkt, Klart or Tonat.")
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72)).press(forDuration: 2)
        Thread.sleep(forTimeInterval: 1.5)
        guard tap(springboard.buttons["Ändra"].firstMatch) else { return note("no Ändra") }
        Thread.sleep(forTimeInterval: 1)
        guard tap(labelled("Anpassa")) else { return note("no Anpassa") }
        Thread.sleep(forTimeInterval: 1.5)
        guard tap(labelled(asked)) else { return note("no \(asked)") }
        Thread.sleep(forTimeInterval: 2)
        shoot("style-\(asked)-sheet")
        // The sheet is dragged away by its title; Klar leaves editing.
        let title = labelled("Anpassa")
        if title.waitForExistence(timeout: 2) {
            title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99)))
        }
        Thread.sleep(forTimeInterval: 1.5)
        let done = springboard.buttons["Klar"].firstMatch
        if done.waitForExistence(timeout: 2) { done.tap() }
        Thread.sleep(forTimeInterval: 3)
        shoot("home-\(asked)")
    }

    /// The grid widget into the lock screen's widget row. FTW's widgets are
    /// pages in the gallery, in the bundle's order: price, plan, grid.
    func testLockScreen() throws {
        try XCTSkipUnless(asked == "lock", "Set TEST_RUNNER_FTW_GRID=lock to place the widget.")
        let pages = Int(ProcessInfo.processInfo.environment["FTW_GRID_PAGE"] ?? "") ?? 2
        lockButton()
        lockButton()
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)).press(forDuration: 2)
        Thread.sleep(forTimeInterval: 3)
        guard tap(springboard.buttons["posterboard-customize-button"].firstMatch) else { return note("no Customize") }
        Thread.sleep(forTimeInterval: 2)
        guard tap(springboard.buttons["grouped-widgets-reticle-view"].firstMatch) else { return note("no widget slot") }
        Thread.sleep(forTimeInterval: 3)
        let ftw = springboard.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'FTW'")).firstMatch
        if !ftw.waitForExistence(timeout: 3) { springboard.swipeUp() }
        guard tap(ftw) else { return note("no FTW in the gallery") }
        Thread.sleep(forTimeInterval: 2)
        for _ in 0..<pages {
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.71))
                .press(forDuration: 0.05, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.71)), withVelocity: .fast, thenHoldForDuration: 0)
            Thread.sleep(forTimeInterval: 1.5)
        }
        shoot("lock-gallery")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72)).tap()
        Thread.sleep(forTimeInterval: 2)
        shoot("lock-added")
        // The gallery's cross, the sheet of apps dragged away, then Done.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.896, dy: 0.493)).tap()
        Thread.sleep(forTimeInterval: 2)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.46))
            .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        Thread.sleep(forTimeInterval: 2)
        let done = springboard.buttons["editing-done"].firstMatch
        if done.waitForExistence(timeout: 2) {
            done.tap()
        } else {
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.035)).tap()
        }
        Thread.sleep(forTimeInterval: 3)
        lockButton()
        lockButton()
        Thread.sleep(forTimeInterval: 3)
        shoot("lock")
    }

    /// The first page of the home screen as it is.
    /// `TEST_RUNNER_FTW_GRID=home`.
    func testShowTheHomeScreen() throws {
        try XCTSkipUnless(asked == "home", "Set TEST_RUNNER_FTW_GRID=home to photograph the home screen.")
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 3)
        shoot("home")
    }

    /// The lock screen as it is, for a widget placed before.
    func testShowTheLockScreen() throws {
        try XCTSkipUnless(asked == "lockshot", "Set TEST_RUNNER_FTW_GRID=lockshot to photograph the lock screen.")
        lockButton()
        lockButton()
        Thread.sleep(forTimeInterval: 3)
        shoot("lock")
    }

    private func labelled(_ label: String) -> XCUIElement {
        springboard.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func tap(_ element: XCUIElement) -> Bool {
        guard element.waitForExistence(timeout: 5) else { return false }
        element.tap()
        return true
    }

    /// Says where it stopped, without failing: a failure makes Xcode collect
    /// a simulator diagnosis that takes minutes.
    private func note(_ text: String) {
        print("GridWidgetTour stopped: \(text)")
        shoot("stopped")
    }

    private func lockButton() {
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        Thread.sleep(forTimeInterval: 1.5)
    }

    private func shoot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
