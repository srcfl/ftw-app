import XCTest

/// Now is built to be read without scrolling. On the smallest and the
/// largest iPhone that runs iOS 26, at the standard text size and the
/// largest one that is not an accessibility size, its last element can be
/// tapped where it stands, nothing on it moves while readings arrive, and
/// every node opens its view. The status line opens the control sheet, the
/// title's menu holds the rest.
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
    private func launchDemo(text: String = NowFitsTests.standard, more: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-FTWDemo", "YES",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-UIPreferredContentSizeCategoryName", text,
        ] + more
        app.launch()
        if more.isEmpty {
            XCTAssertTrue(app.buttons["now.node.home"].waitForExistence(timeout: 15), "Now never drew the home")
        }
        return app
    }

    /// The car's view opens with Plan, Charge now and Pause on screen, at
    /// the standard size and the largest; a tap moves no button, and the
    /// box's answer moves the choice, not the buttons.
    @MainActor
    func testChargeNowIsOnTheCarsFirstScreenAndHoldsItsPlace() throws {
        for text in [Self.standard, "UICTContentSizeCategoryAccessibilityXXXL"] {
            let app = launchDemo(text: text, more: ["-FTWTab", "car"])
            let charge = app.buttons["car.control.chargeNow"]
            XCTAssertTrue(charge.waitForExistence(timeout: 15), "no Charge now at \(text)")
            Thread.sleep(forTimeInterval: 2)
            let window = app.windows.firstMatch.frame
            for c in ["plan", "chargeNow", "pause"] {
                let b = app.buttons["car.control.\(c)"]
                XCTAssertTrue(b.isHittable, "\(c) cannot be tapped at \(text)")
                XCTAssertTrue(window.contains(b.frame), "\(c) is off screen at \(text)")
            }
            guard text == Self.standard else {
                shoot(app, "car-ax5")
                app.terminate()
                continue
            }
            shoot(app, "car-before")
            let frames = ["plan", "chargeNow", "pause"].map { app.buttons["car.control.\($0)"].frame }
            XCTAssertTrue(app.buttons["car.control.plan"].isSelected)
            charge.tap()
            Thread.sleep(forTimeInterval: 0.3)
            shoot(app, "car-sending")
            let chargedChosen = NSPredicate(format: "isSelected == true")
            expectation(for: chargedChosen, evaluatedWith: charge)
            waitForExpectations(timeout: 10)
            shoot(app, "car-after")
            XCTAssertEqual(["plan", "chargeNow", "pause"].map { app.buttons["car.control.\($0)"].frame }, frames, "a button moved")
            // Back as it was, for the next test.
            app.buttons["car.control.plan"].tap()
            Thread.sleep(forTimeInterval: 3)
            app.terminate()
        }
    }

    @MainActor
    func testTheFootOfNowIsTappableWithoutScrolling() throws {
        let app = launchDemo()
        let foot = app.buttons["now.plan"]
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
        XCTAssertTrue(app.buttons["status.line"].isHittable)
        // About, Privacy and the build moved from the foot into the title's menu.
        XCTAssertFalse(app.buttons["Source & licenses"].exists)
        app.buttons["now.title"].tap()
        let about = app.buttons["About FTW"]
        XCTAssertTrue(about.waitForExistence(timeout: 5))
        shoot(app, "title-menu")
        XCTAssertTrue(app.buttons["Homes"].exists)
        XCTAssertTrue(app.buttons["Settings"].exists)
        XCTAssertTrue(app.buttons["Privacy"].exists)
        XCTAssertTrue(app.buttons["Exit demo"].exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'FTW 0.'")).firstMatch.exists, "no build in the menu")
        about.tap()
        XCTAssertTrue(app.navigationBars["Source & licenses"].waitForExistence(timeout: 5))
    }

    /// Only the accessibility sizes may scroll.
    @MainActor
    func testAtTheLargestStandardTextSizeNowStillFits() throws {
        let app = launchDemo(text: Self.largest)
        let foot = app.buttons["now.plan"]
        XCTAssertTrue(foot.waitForExistence(timeout: 5))
        XCTAssertTrue(app.windows.firstMatch.frame.contains(foot.frame), "\(foot.frame) is outside \(app.windows.firstMatch.frame)")
        XCTAssertTrue(foot.isHittable)
        XCTAssertEqual(app.scrollViews.count, 0, "Now scrolls at the largest standard text size")
        for node in ["solar", "battery", "home", "grid", "car"] {
            XCTAssertTrue(app.buttons["now.node.\(node)"].isHittable, "\(node) cannot be tapped at the largest standard size")
        }
        XCTAssertTrue(app.buttons["status.line"].isHittable)
        shoot(app, "now-xxxl")
    }

    /// Nothing on Now moves or changes size while it runs: every node, the
    /// plan and the mode keep their frames from the first live seconds on,
    /// whatever the readings say.
    @MainActor
    func testNowHoldsItsShapeWhileReadingsArrive() throws {
        let app = launchDemo()
        let ids = ["now.node.solar", "now.node.battery", "now.node.home", "now.node.grid", "now.node.car", "now.plan", "status.line", "now.title"]
        let before = ids.map { app.buttons[$0].frame }
        Thread.sleep(forTimeInterval: 6)
        let after = ids.map { app.buttons[$0].frame }
        for (id, (a, b)) in zip(ids, zip(before, after)) {
            XCTAssertEqual(a.minX, b.minX, accuracy: 0.5, "\(id) moved")
            XCTAssertEqual(a.minY, b.minY, accuracy: 0.5, "\(id) moved")
            XCTAssertEqual(a.height, b.height, accuracy: 0.5, "\(id) changed height")
        }
    }

    /// The status line says live, opens the box's own answer to "Are we in
    /// control?" with a section per device, and closes again.
    @MainActor
    func testTheStatusLineOpensTheControlSheet() throws {
        let app = launchDemo()
        let line = app.buttons["status.line"]
        XCTAssertTrue(line.waitForExistence(timeout: 10))
        let live = NSPredicate(format: "value == 'DEMO · SIMULATED HOME'")
        expectation(for: live, evaluatedWith: line)
        waitForExpectations(timeout: 10)
        line.tap()
        XCTAssertTrue(app.navigationBars["Are we in control?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["control.summary"].waitForExistence(timeout: 5))
        let battery = app.staticTexts["Following FTW"]
        XCTAssertTrue(battery.waitForExistence(timeout: 5), "the box's answer for the battery never came")
        Thread.sleep(forTimeInterval: 1)
        shoot(app, "control-sheet")
        // Full height, so the list draws the battery's rows, then its receipt.
        app.navigationBars["Are we in control?"].swipeUp()
        let receipt = app.buttons["How FTW knows"].firstMatch
        if !receipt.waitForExistence(timeout: 3) || !receipt.isHittable {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(receipt.waitForExistence(timeout: 3))
        receipt.tap()
        XCTAssertTrue(app.staticTexts["SENT"].waitForExistence(timeout: 3))
        shoot(app, "control-sheet-receipt")
        app.buttons["control.close"].tap()
        XCTAssertTrue(app.navigationBars["Are we in control?"].waitForNonExistence(timeout: 5))
    }

    /// A mode from the button beside the title: its sheet closes once the
    /// box applied it, the button names it, the status line walks the box's
    /// receipt, and then returns.
    @MainActor
    func testTheModeMenuChangesTheModeAndTheLineFollowsTheBox() throws {
        let app = launchDemo()
        let button = app.buttons["now.mode"]
        let line = app.buttons["status.line"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        // The button rests until the box has spoken.
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(button.value as? String, "Balanced")
        let frame = button.frame
        button.tap()
        let own = app.buttons["mode.choice.self_consumption"]
        XCTAssertTrue(own.waitForExistence(timeout: 5))
        shoot(app, "mode-menu")
        reveal(own, in: app)
        own.tap()
        let confirmed = NSPredicate(format: "value CONTAINS 'CONFIRMED'")
        expectation(for: confirmed, evaluatedWith: line)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(own.waitForNonExistence(timeout: 5), "the sheet stayed open after the box applied the mode")
        shoot(app, "mode-confirmed")
        XCTAssertEqual(button.value as? String, "Own use")
        XCTAssertEqual(button.frame.maxX, frame.maxX, accuracy: 0.5, "the mode button moved its trailing edge")
        let back = NSPredicate(format: "value == 'DEMO · SIMULATED HOME'")
        expectation(for: back, evaluatedWith: line)
        waitForExpectations(timeout: 10)
        // Back to the plan, for the next test.
        button.tap()
        let plan = app.buttons["mode.choice.plan"]
        XCTAssertTrue(plan.waitForExistence(timeout: 5))
        plan.tap()
        XCTAssertTrue(plan.waitForNonExistence(timeout: 10))
    }

    /// The planning style from Now's button: a finger drags the scale two
    /// stops and lets go, one command goes, the box confirms it, the sheet
    /// stays and says what the new plan moved. A second drag goes back.
    @MainActor
    func testTheStyleScaleSendsOnceWhenTheFingerLetsGo() throws {
        let app = launchDemo()
        let button = app.buttons["now.mode"]
        let line = app.buttons["status.line"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(button.value as? String, "Balanced")
        button.tap()
        let scale = app.descendants(matching: .any).matching(identifier: "style.scale").firstMatch
        XCTAssertTrue(scale.waitForExistence(timeout: 5))
        XCTAssertTrue((scale.value as? String ?? "").hasPrefix("Balanced."), "\(String(describing: scale.value))")
        shoot(app, "style-open")
        // The track sits under the ends' line; its stops are spread across
        // the width inside the thumb's half.
        let f = scale.frame
        let y = f.minY + 14 + 8 + 16
        func stop(_ i: Int) -> XCUICoordinate {
            let x = f.minX + 16 + (f.width - 32) * CGFloat(i) / 4
            return app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
        }
        stop(2).press(forDuration: 0.2, thenDragTo: stop(4), withVelocity: 300, thenHoldForDuration: 0.3)
        let confirmed = NSPredicate(format: "value CONTAINS 'CONFIRMED'")
        expectation(for: confirmed, evaluatedWith: line)
        waitForExpectations(timeout: 10)
        XCTAssertTrue((scale.value as? String ?? "").hasPrefix("Very bold."), "\(String(describing: scale.value))")
        // The sheet stays for the other settings, and says what moved.
        XCTAssertTrue(scale.exists)
        XCTAssertTrue(app.staticTexts["style.moved"].waitForExistence(timeout: 5), "no line says what the new plan moved")
        shoot(app, "style-moved")
        // VoiceOver reads it as one element with the style's name and help.
        XCTAssertEqual(scale.label, "Planning style")
        // Back to where it was, for the next test.
        Thread.sleep(forTimeInterval: 1)
        stop(4).press(forDuration: 0.2, thenDragTo: stop(2), withVelocity: 300, thenHoldForDuration: 0.3)
        expectation(for: NSPredicate(format: "value BEGINSWITH 'Balanced.'"), evaluatedWith: scale)
        waitForExpectations(timeout: 10)
        app.buttons["mode.close"].tap()
        expectation(for: NSPredicate(format: "value == 'Balanced'"), evaluatedWith: button)
        waitForExpectations(timeout: 10)
    }

    /// At the largest accessibility size the drawing gives way to a row
    /// per node; the page may scroll, and every row still opens its node.
    @MainActor
    func testAtTheLargestAccessibilitySizeEveryNodeIsARow() throws {
        let app = launchDemo(text: "UICTContentSizeCategoryAccessibilityXXXL")
        for node in ["home", "solar", "battery", "grid", "car"] {
            XCTAssertTrue(app.buttons["now.node.\(node)"].exists, "no row for \(node)")
        }
        shoot(app, "now-ax5")
        let battery = app.buttons["now.node.battery"]
        if !battery.isHittable { app.swipeUp() }
        battery.tap()
        XCTAssertTrue(app.navigationBars["Battery"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 2)
        shoot(app, "battery-ax5")
    }

    /// At the largest accessibility size the mode sheet still shows its
    /// choices: the bar at its foot stops growing before they do.
    @MainActor
    func testAtTheLargestAccessibilitySizeTheModeSheetShowsItsChoices() throws {
        let app = launchDemo(text: "UICTContentSizeCategoryAccessibilityXXXL")
        openSettings(app)
        let plan = app.buttons["mode.choice.plan"]
        XCTAssertTrue(plan.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1.5)
        shoot(app, "mode-ax5")
        XCTAssertTrue(plan.isHittable, "the plan's row is hidden")
        let window = app.windows.firstMatch.frame
        let bar = app.descendants(matching: .any)["mode.receipt"].firstMatch
        XCTAssertTrue(bar.exists)
        XCTAssertLessThan(bar.frame.height, window.height * 0.25, "the receipt bar takes \(bar.frame.height) of \(window.height)")
    }

    @MainActor
    func testANodeOpensItsLiveHistoryPlanAndMode() throws {
        let app = launchDemo()
        app.buttons["now.node.battery"].tap()
        XCTAssertTrue(app.navigationBars["Battery"].waitForExistence(timeout: 5))
        // The view opens on the timebase this phone chose last; Live is one tap.
        app.segmentedControls["node.period"].buttons["Live"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["node.live.chart"].waitForExistence(timeout: 5))
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
        openSettings(app)
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
        reveal(idle, in: app)
        XCTAssertTrue(window.contains(idle.frame), "\(idle.frame) is outside \(window)")
        let top = idle.frame.minY
        idle.tap()
        // The demo box answers after 0.9 s; look well before that.
        Thread.sleep(forTimeInterval: 0.15)
        XCTAssertTrue(plan.isSelected, "the box's mode lost its tick before the box answered")
        XCTAssertEqual(idle.frame.minY, top, accuracy: 1, "the row moved under the finger")
        shoot(app, "mode-sending")
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

    /// How the home is run, in full: Settings, in the title's menu.
    @MainActor
    private func openSettings(_ app: XCUIApplication) {
        let title = app.buttons["now.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 3)
        title.tap()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
    }

    @MainActor
    /// Scrolls the mode sheet a little at a time until the middle of a row,
    /// where a tap lands, clears the receipt bar at its foot: on a small
    /// phone the sheet is full height and scrolls. The bar and the home
    /// indicator take less than 100 pt. Short, slow drags keep the rows
    /// above in place.
    private func reveal(_ row: XCUIElement, in app: XCUIApplication) {
        let window = app.windows.firstMatch.frame
        for _ in 0..<4 where row.frame.midY > window.maxY - 100 {
            let list = app.collectionViews.firstMatch
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                .press(forDuration: 0.1, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)), withVelocity: .slow, thenHoldForDuration: 0.3)
            Thread.sleep(forTimeInterval: 0.6)
        }
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
