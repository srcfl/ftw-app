import XCTest

/// Photographs the first page of the home screen, with whatever widgets
/// were placed on it (`IconState.plist`, before boot). Skipped unless asked
/// for:
///
///     TEST_RUNNER_FTW_WIDGETS=home xcodebuild test … -only-testing:FTWUITests/WidgetTour
@MainActor
final class WidgetTour: XCTestCase {
    func testHomeScreen() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FTW_WIDGETS"] == "home", "Set TEST_RUNNER_FTW_WIDGETS=home to photograph the home screen.")
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 4)
        shoot("home")
    }

    private func shoot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
