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
        // About, Privacy and the build live on the Home tab.
        XCTAssertFalse(app.buttons["Source & licenses"].exists)
        app.tabBars.buttons["Home"].tap()
        let about = app.buttons["About FTW"]
        XCTAssertTrue(about.waitForExistence(timeout: 5))
        shoot(app, "home-tab")
        XCTAssertTrue(app.buttons["home.mode"].exists)
        XCTAssertTrue(app.buttons["Pair a home"].exists)
        XCTAssertTrue(app.buttons["Privacy"].exists || app.links["Privacy"].exists)
        XCTAssertTrue(app.buttons["Exit demo"].exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'FTW 0.'")).firstMatch.exists, "no build on Home")
        about.tap()
        XCTAssertTrue(app.navigationBars["Source & licenses"].waitForExistence(timeout: 5))
    }

    /// What the home saved opens from the home's own view and from
    /// History. It fits the screen at the standard size and the
    /// largest, its periods are in reach, and changing one moves nothing
    /// above the chart.
    @MainActor
    func testSavingsOpensFromTheHomeAndHistoryAndFits() throws {
        for text in [Self.standard, Self.largest] {
            let app = launchDemo(text: text)
            app.buttons["now.node.home"].tap()
            let row = app.buttons["node.savings.open"]
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            XCTAssertTrue(row.isHittable)
            row.tap()
            XCTAssertTrue(app.navigationBars["Savings"].waitForExistence(timeout: 5))
            let hero = app.descendants(matching: .any)["savings.hero"]
            XCTAssertTrue(hero.waitForExistence(timeout: 5))
            let periods = app.segmentedControls["savings.period"]
            let footer = app.staticTexts["savings.footer"]
            XCTAssertTrue(footer.waitForExistence(timeout: 5))
            XCTAssertEqual(app.scrollViews.count, 0, "Savings scrolls at \(text)")
            let top = hero.frame.minY
            for name in ["Day", "Week", "Month"] {
                let b = periods.buttons[name]
                XCTAssertTrue(b.isHittable, "\(name) is out of reach at \(text)")
                b.tap()
                XCTAssertEqual(hero.frame.minY, top, accuracy: 0.5, "the hero moved on \(name)")
                XCTAssertTrue(app.windows.firstMatch.frame.contains(footer.frame), "the footer left the screen on \(name)")
            }
            shoot(app, "savings-\(text)")
            app.terminate()
        }
        let app = launchDemo()
        let history = app.tabBars.buttons["History"]
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        history.tap()
        let savings = app.buttons["history.savings"]
        XCTAssertTrue(savings.waitForExistence(timeout: 5))
        savings.tap()
        XCTAssertTrue(app.navigationBars["Savings"].waitForExistence(timeout: 5))
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
        let ids = ["now.node.solar", "now.node.battery", "now.node.home", "now.node.grid", "now.node.car", "now.car", "now.plan", "status.line", "now.title"]
        func frame(_ id: String) -> CGRect { app.descendants(matching: .any)[id].firstMatch.frame }
        let before = ids.map(frame)
        Thread.sleep(forTimeInterval: 6)
        let after = ids.map(frame)
        for (id, (a, b)) in zip(ids, zip(before, after)) {
            XCTAssertEqual(a.minX, b.minX, accuracy: 0.5, "\(id) moved")
            XCTAssertEqual(a.minY, b.minY, accuracy: 0.5, "\(id) moved")
            XCTAssertEqual(a.height, b.height, accuracy: 0.5, "\(id) changed height")
        }
    }

    /// The bar holds still from the first frame: the title and the status
    /// line keep one leading edge whatever the line or the mode button
    /// says, and the button never says "Mode" or "Plan" on its way to the
    /// style's name.
    @MainActor
    func testTheBarHoldsStillFromTheFirstFrame() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-FTWDemo", "YES",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-UIPreferredContentSizeCategoryName", Self.standard,
        ]
        app.launch()
        let title = app.staticTexts["now.title"]
        let line = app.buttons["status.line"]
        let mode = app.buttons["now.mode"]
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        let x = title.frame.minX
        let lineX = line.frame.minX
        var names = Set<String>()
        var lines = Set<String>()
        let end = Date().addingTimeInterval(4)
        while Date() < end {
            XCTAssertEqual(title.frame.minX, x, accuracy: 0.5, "the title moved")
            XCTAssertEqual(line.frame.minX, lineX, accuracy: 0.5, "the status line moved")
            names.insert(mode.value as? String ?? "")
            lines.insert(line.value as? String ?? "")
        }
        XCTAssertEqual(lineX, x, accuracy: 0.5, "the title and the line have two edges")
        XCTAssertTrue(names.isSubset(of: ["", "Balanced"]), "the mode button said \(names)")
        XCTAssertTrue(lines.contains("DEMO · SIMULATED HOME"), "\(lines)")
    }

    /// The price on the strip opens the price; anywhere else on the strip
    /// opens the plan.
    @MainActor
    func testThePriceOpensThePriceAndTheStripThePlan() throws {
        let app = launchDemo()
        let price = app.buttons["now.price"]
        XCTAssertTrue(price.waitForExistence(timeout: 10))
        XCTAssertTrue(price.isHittable)
        price.tap()
        let priceBar = app.navigationBars["Electricity price"]
        XCTAssertTrue(priceBar.waitForExistence(timeout: 5), "the price did not open the price")
        shoot(app, "price-from-now")
        priceBar.buttons.element(boundBy: 0).tap()
        let plan = app.buttons["now.plan"]
        XCTAssertTrue(plan.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        // The header's left, by the kicker, and the bars under the price.
        for spot in [CGVector(dx: 0.1, dy: 0.05), CGVector(dx: 0.9, dy: 0.45)] {
            plan.coordinate(withNormalizedOffset: spot).tap()
            let planBar = app.navigationBars["Plan ahead"]
            XCTAssertTrue(planBar.waitForExistence(timeout: 5), "\(spot) did not open the plan")
            planBar.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(plan.waitForExistence(timeout: 5))
            Thread.sleep(forTimeInterval: 1)
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
        let titleX = app.staticTexts["now.title"].frame.minX
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
        XCTAssertEqual(app.staticTexts["now.title"].frame.minX, titleX, accuracy: 0.5, "the title moved with the receipt")
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

    /// Every node's view is one page at the standard size and the largest:
    /// the chart takes the room, the picker and the footer sit at the foot
    /// in the thumb's reach, one status line speaks for the screen, and a
    /// switch of period moves nothing.
    @MainActor
    func testEveryNodeViewKeepsItsControlsAtTheFoot() throws {
        for text in [Self.standard, Self.largest] {
            for node in ["solar", "battery", "home", "grid", "car"] {
                let app = launchDemo(text: text, more: ["-FTWNode", node, "-FTWPeriod", "today"])
                let picker = app.segmentedControls["node.period"]
                XCTAssertTrue(picker.waitForExistence(timeout: 15), "\(node) never opened at \(text)")
                let footer = app.staticTexts["node.footer"]
                XCTAssertTrue(footer.waitForExistence(timeout: 5))
                Thread.sleep(forTimeInterval: 1.5)
                let window = app.windows.firstMatch.frame
                XCTAssertEqual(app.scrollViews.count, 0, "\(node) scrolls at \(text)")
                XCTAssertTrue(window.contains(footer.frame), "\(node)'s footer is off screen at \(text)")
                XCTAssertFalse(app.staticTexts["node.status"].exists, "\(node) has a second status line")
                // The foot: the picker and what sits under it take the lower
                // part of the screen, and nothing but the footer is under them.
                XCTAssertGreaterThan(picker.frame.minY, window.height * 0.55, "\(node)'s picker floats at \(text)")
                XCTAssertLessThan(window.maxY - footer.frame.maxY, 60, "\(node) leaves ground under its footer at \(text)")
                let top = picker.frame.minY
                for period in ["Live", "48 h", "Today"] {
                    picker.buttons[period].tap()
                    XCTAssertEqual(picker.frame.minY, top, accuracy: 0.5, "\(node)'s picker moved on \(period) at \(text)")
                }
                if node == "battery" { shoot(app, "battery-\(text)") }
                app.terminate()
            }
        }
    }

    /// The chart opens on the whole screen from the button in its corner,
    /// and closes as a sheet does.
    @MainActor
    func testTheNodeChartEnlargesAndCloses() throws {
        let app = launchDemo(more: ["-FTWNode", "battery", "-FTWPeriod", "today"])
        let enlarge = app.buttons["node.chart.enlarge"]
        XCTAssertTrue(enlarge.waitForExistence(timeout: 15))
        XCTAssertTrue(enlarge.isHittable)
        enlarge.tap()
        let close = app.buttons["node.chart.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["node.footer"].exists)
        shoot(app, "chart-enlarged")
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        XCTAssertTrue(enlarge.isHittable)
    }

    /// The mode sheet opens tall enough for its choices, keeps the box's
    /// mode ticked while a new one waits in its own row, moves nothing under
    /// the finger, and closes once the box applied the mode.
    @MainActor
    func testTheModeSheetFitsWaitsInPlaceAndClosesOnceApplied() throws {
        // The box answers after 2.5 s, so the look while it waits comes well
        // before: XCTest's wait for the app to settle after a tap can take a
        // second, and the turning mark keeps it busy that long.
        let app = launchDemo(more: ["-FTWDemoResultDelayMs", "2500"])
        XCTAssertTrue(app.buttons["now.node.home"].waitForExistence(timeout: 15), "Now never drew the home")
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
        // Look well before the box answers.
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

    /// How the home is run, in full: the mode sheet, from Home.
    @MainActor
    private func openSettings(_ app: XCUIApplication) {
        let home = app.tabBars.buttons["Home"]
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 3)
        home.tap()
        let mode = app.buttons["home.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        mode.tap()
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
