import Foundation
import Testing
@testable import FTWShared

/// The Apple Watch: what the phone hands over, how a command's receipt may
/// move, when a reading may glow, and the plan dial's face. Stockholm's
/// clock; 14 October 2026 is a Wednesday. English: the tests run in the
/// development language.
@Suite struct WatchTests {
    static let quarter: Double = 900_000
    static let hour: Double = 3_600_000
    static let zone = "Europe/Stockholm"
    let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: WatchTests.zone)!
        return c
    }()

    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Double {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!.timeIntervalSince1970 * 1000
    }

    /// Today and tomorrow in quarters: 30 öre from 02 to 04 each night,
    /// 160 from 17 to 21, 70 otherwise.
    func prices(days: Int = 2) -> PriceEntry {
        let start = at(14, 0)
        let slots = (0..<(96 * days)).map { i -> PriceSlot in
            let t = start + Double(i) * Self.quarter
            let h = calendar.component(.hour, from: Date(timeIntervalSince1970: t / 1000))
            let p: Double = h == 2 || h == 3 ? 30 : (h >= 17 && h < 21 ? 160 : 70)
            return PriceSlot(startMs: t, durationMs: Self.quarter, spotMinor: p - 20, totalMinor: p)
        }
        return PriceEntry(fromMs: start, prices: Prices(zone: "SE3", currency: "SEK", slots: slots, stale: false), timeZone: Self.zone)
    }

    /// The battery stores 22:00–23:30 and gives power 17:00–19:00; the car
    /// charges 01:00–04:45 toward 80 %.
    func plan() -> PlanEntry {
        let start = at(14, 12)
        let battery = (0..<96).map { i -> PlanEntry.Slot in
            let t = start + Double(i) * Self.quarter
            let h = calendar.component(.hour, from: Date(timeIntervalSince1970: t / 1000))
            let m = calendar.component(.minute, from: Date(timeIntervalSince1970: t / 1000))
            let w: Double = h == 22 || (h == 23 && m < 30) ? 3_000 : (h >= 17 && h < 19 ? -2_000 : 40)
            return PlanEntry.Slot(startMs: t, durationMs: Self.quarter, batteryW: w, reason: "test")
        }
        return PlanEntry(
            battery: battery,
            charges: [.init(loadpointID: "lp1", fromMs: at(15, 1), toMs: at(15, 4, 45), energyWh: 20_000, targetPct: 80)],
            prices: [],
            currency: "SEK",
            boxStale: false,
            timeZone: Self.zone
        )
    }

    func now(carrier: CarrierKind = .relay, srcState: SourceState = .live, readAtMs: Double, live: Bool = true) -> CacheRecord<WatchNow> {
        let value = WatchNow(readings: [
            .init(node: .solar, watts: 2_300, way: .making, live: live),
            .init(node: .battery, watts: 1_200, way: .giving, levelPct: 64, live: live),
            .init(node: .grid, watts: 120, way: .buying, live: false),
        ], control: .inControl)
        return CacheRecord(siteId: "s1", carrier: carrier, srcState: srcState, readAtMs: readAtMs, value: value)
    }

    // MARK: The wire

    @Test func aContextSurvivesThePackingAndShrinks() throws {
        let t = at(14, 12)
        let ctx = WatchContext(
            home: "s1", isDemo: false,
            prices: CacheRecord(siteId: "s1", carrier: .relay, srcState: .live, readAtMs: t, value: prices()),
            plan: CacheRecord(siteId: "s1", carrier: .relay, srcState: .live, readAtMs: t, value: plan()),
            now: now(readAtMs: t),
            modes: WatchModes(modes: [.init(key: "planner_self", name: "Plan", isPlan: true)], shown: "planner_self", label: "Plan · Balanced", mayControl: true),
            sentAtMs: t
        )
        let packed = try ctx.packed()
        #expect(WatchContext.unpacked(packed) == ctx)
        // A day of quarters twice over still fits WatchConnectivity easily.
        let json = try JSONEncoder().encode(ctx)
        #expect(packed.count < json.count / 3)
        #expect(packed.count < 32_000)
        #expect(WatchContext.unpacked(Data("not a context".utf8)) == nil)
    }

    @Test func aContextOfAnotherVersionIsNotRead() throws {
        var ctx = WatchContext(home: "s1", isDemo: false, sentAtMs: 1)
        ctx.version = WatchContext.version + 1
        #expect(WatchContext.unpacked(try ctx.packed()) == nil)
    }

    @Test func theSameRecordsSentAgainAreTheSame() {
        let a = WatchContext(home: "s1", isDemo: false, prices: nil, sentAtMs: 1)
        var b = a
        b.sentAtMs = 99
        #expect(a.sameAs(b))
        b.home = "s2"
        #expect(!a.sameAs(b))
        #expect(!WatchContext.empty(sentAtMs: 1).hasHome)
    }

    @Test func asksAndNewsRoundTrip() throws {
        let c = WatchCommand(op: .chargeNow(loadpointID: "lp1"), home: "s1", sentAtMs: 1_000)
        #expect(c.notValidAfterMs == 1_000 + WatchCommand.lifeMs)
        for ask in [WatchAsk.look, .away, .command(c)] {
            #expect(WatchAsk.from(try ask.data()) == ask)
        }
        let news = WatchNews.receipt(.phoneHasIt(c))
        #expect(WatchNews.from(try news.data()) == news)
    }

    /// The watch makes the box's `cmdId`: a UUIDv7 that starts with the time.
    @Test func theWatchMakesAUUIDv7() {
        let t = at(14, 12)
        let id = WatchCommand.newID(nowMs: t)
        #expect(WatchCommand.isID(id))
        #expect(id != WatchCommand.newID(nowMs: t))
        let hex = id.replacingOccurrences(of: "-", with: "").prefix(12)
        #expect(UInt64(hex, radix: 16) == UInt64(t))
        #expect(WatchCommand(op: .mode("idle"), home: "s1", sentAtMs: t).id.hasPrefix(String(id.prefix(8))))
        #expect(!WatchCommand.isID(UUID().uuidString))
        #expect(!WatchCommand.isID(id.uppercased()))
        #expect(!WatchCommand.isID("0190f2c4-aaaa-4bbb-8ccc-dddddddddddd"))
        #expect(!WatchCommand.isID("not-a-command"))
    }

    // MARK: The receipt

    /// The watch alone can say it is sending, that the phone was out of
    /// reach, or that no answer came. None of them marks the box's answer.
    @Test func theWatchNeverMarksWhatOnlyTheBoxCan() {
        let c = WatchCommand(op: .pause(loadpointID: "lp1"), home: "s1", sentAtMs: 0)
        for r in [WatchReceipt.tapped(c), .unreachable(c), .phoneHasIt(c), WatchReceipt.tapped(c).noAnswer()] {
            #expect(r.accepted != .done, "\(r.text)")
            #expect(r.confirmed != .done, "\(r.text)")
            #expect(r.tone != .done, "\(r.text)")
        }
        #expect(WatchReceipt.unreachable(c).sent == .failed)
        #expect(WatchReceipt.tapped(c).noAnswer().tone == .warning)
    }

    @Test func aReceiptTakesOnlyItsOwnCommandAndKeepsItsEnd() {
        let c = WatchCommand(op: .chargeNow(loadpointID: "lp1"), home: "s1", sentAtMs: 0)
        let other = WatchCommand(op: .chargeNow(loadpointID: "lp1"), home: "s1", sentAtMs: 0)
        let tapped = WatchReceipt.tapped(c)
        #expect(tapped.taking(.phoneHasIt(other)) == nil)
        let done = WatchReceipt(commandID: c.id, op: c.op, sent: .done, accepted: .done, confirmed: .done, text: "Charge now is on.", tone: .done)
        #expect(tapped.taking(done) == done)
        // A late "still working" never undoes the box's answer.
        #expect(done.taking(.phoneHasIt(c)) == nil)
        #expect(done.noAnswer() == done)
        // The phone's answer still lands after the watch gave up waiting.
        #expect(tapped.noAnswer().taking(done) == done)
    }

    // MARK: Light means live

    @Test func onlyAFreshLiveFrameGlows() {
        let t = at(14, 12)
        let frame = now(readAtMs: t)
        #expect(WatchGlance.lit(frame, arrivedAtMs: t, nowMs: t + 1_000))
        #expect(!WatchGlance.lit(frame, arrivedAtMs: t, nowMs: t + WatchGlance.liveForMs + 1))
        // The context's copy, or anything from the watch's cache, never does.
        #expect(!WatchGlance.lit(frame, arrivedAtMs: nil, nowMs: t))
        #expect(!WatchGlance.lit(now(carrier: .cache, readAtMs: t), arrivedAtMs: t, nowMs: t))
        #expect(!WatchGlance.lit(now(srcState: .lagging, readAtMs: t), arrivedAtMs: t, nowMs: t))
        #expect(!WatchGlance.lit(nil, arrivedAtMs: t, nowMs: t))
        #expect(WatchGlance.lit(now(carrier: .cloud, readAtMs: t), arrivedAtMs: t, nowMs: t))
    }

    @Test func aFigureGlowsOnlyWhenItsOwnReadingIsLive() {
        let figures = WatchGlance.figures(now(readAtMs: 0).value, lit: true)
        #expect(figures.map(\.lit) == [true, true, false])
        #expect(WatchGlance.figures(now(readAtMs: 0).value, lit: false).allSatisfy { !$0.lit })
        #expect(figures[0].value == "2.3" && figures[0].unit == "kW")
        #expect(figures[1].level == "64\u{00A0}%")
        #expect(figures[2].value == "120" && figures[2].word == "buying")
    }

    @Test func theStatusLineSaysLiveOrTheMinuteItWasRead() {
        let t = at(14, 10, 5)
        let zone = TimeZone(identifier: Self.zone)!
        #expect(WatchGlance.status(now(readAtMs: t), lit: true, demo: false, zone: zone).text == "LIVE · FTW IN CONTROL")
        #expect(WatchGlance.status(now(readAtMs: t), lit: false, demo: false, zone: zone).text == "AS OF 10:05 · FTW IN CONTROL")
        #expect(WatchGlance.status(now(readAtMs: t), lit: true, demo: true, zone: zone).text == "DEMO · FTW IN CONTROL")
        #expect(WatchGlance.status(nil, lit: false, demo: false, zone: zone).text == "NO READING YET")
        var out = now(readAtMs: t)
        out.value.control = .notInControl
        let warn = WatchGlance.status(out, lit: true, demo: false, zone: zone)
        #expect(warn.alarm && warn.text == "LIVE · ▲ FTW NOT IN CONTROL")
    }

    // MARK: The dial

    @Test func theFaceIsTheNextDayInQuarters() {
        let t = at(14, 12, 7)
        let dial = PlanDial(plan: plan(), prices: prices(), nowMs: t)
        #expect(dial.quarters.count == 96)
        #expect(dial.quarters[0].startMs == at(14, 12))
        #expect(dial.quarters[95].startMs == at(15, 11, 45))
        #expect(dial.time(0) == "12:07")
        #expect(dial.time(4) == "13:00")
        #expect(dial.hasPlan)
    }

    /// 00 at the bottom, 06 on the left, 12 at the top, 18 on the right.
    @Test func midnightSitsAtTheBottomAndNoonAtTheTop() {
        let dial = PlanDial(plan: nil, prices: prices(), nowMs: at(14, 12))
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 || abs(abs(a - b) - 2 * .pi) < 1e-9 }
        #expect(near(dial.angle(at(14, 0)), .pi))
        #expect(near(dial.angle(at(14, 6)), 1.5 * .pi))
        #expect(near(dial.angle(at(14, 12)), 0))
        #expect(near(dial.angle(at(14, 18)), 0.5 * .pi))
        #expect(near(dial.handAngle(selected: nil), dial.angle(at(14, 12))))
        #expect(near(dial.handAngle(selected: 8), dial.angle(at(14, 14))))
    }

    @Test func eachTickHoldsItsPriceLevelAndWhatTheBatteryDoes() {
        let dial = PlanDial(plan: plan(), prices: prices(), nowMs: at(14, 12))
        func q(_ day: Int, _ h: Int, _ m: Int = 0) -> PlanDial.Quarter { dial.quarters[dial.grid.index(atMs: at(day, h, m))!] }
        #expect(q(14, 18).level == 7)
        #expect(q(15, 2).level == 0)
        #expect(q(14, 13).level == 2)
        #expect(q(14, 22).battery == .stores)
        #expect(q(14, 17).battery == .gives)
        #expect(q(14, 13).battery == .waits)
        #expect(q(15, 2).car && !q(14, 20).car)
        #expect(q(15, 4, 30).carGoalPct == 80)
        #expect(dial.what(dial.grid.index(atMs: at(14, 22))!) == "Battery stores 3.0 kW")
        #expect(dial.price(dial.grid.index(atMs: at(14, 18))!) == "160 öre")
    }

    /// A tick never shows without a price: before tomorrow's prices come,
    /// those quarters have no level.
    @Test func unpricedQuartersHaveNoLevel() {
        let dial = PlanDial(plan: plan(), prices: prices(days: 1), nowMs: at(14, 12))
        let tomorrow = dial.grid.index(atMs: at(15, 3))!
        #expect(dial.quarters[tomorrow].minor == nil && dial.quarters[tomorrow].level == nil)
        #expect(dial.price(tomorrow) == "—")
        #expect(dial.what(tomorrow).contains("no price yet"))
    }

    @Test func theCrownTapsAtNowTheCheapestEdgesAndTheCarsGoal() {
        let dial = PlanDial(plan: plan(), prices: prices(), nowMs: at(14, 12))
        let cheap = try! #require(dial.cheapest)
        #expect(dial.grid.startMs(cheap.lowerBound) == at(15, 2))
        #expect(dial.grid.startMs(cheap.upperBound) == at(15, 3, 45))
        #expect(dial.landmarks == [0, cheap.lowerBound, cheap.upperBound, dial.grid.index(atMs: at(15, 4, 30))!])
    }

    @Test func aFlatDaySitsInTheMiddle() {
        #expect(PlanDial.level(50, lo: 50, hi: 50) == 3)
        #expect(PlanDial.level(50, lo: 0, hi: 100) == 4)
        #expect(PlanDial.level(100, lo: 0, hi: 100) == 7)
    }

    // MARK: The car, cheap power and the complication

    @Test func theCarSaysWhatTheBoxLastConfirmedAndWhen() {
        let t = at(14, 12, 30)
        let car = CarEntry.Car(loadpointID: "lp1", pluggedIn: true, socPct: 42, socSource: "assumed", socReadAtMs: t, powerW: 0, targetSocPct: 80, holding: false)
        let record = CacheRecord(siteId: "s1", carrier: .relay, srcState: .live, readAtMs: t, value: CarEntry(cars: [car]))
        let glance = WatchGlance.cars(record, plan: plan(), nowMs: t, zone: TimeZone(identifier: Self.zone)!)[0]
        #expect(glance.cells == 4)
        #expect(glance.levelText == "42\u{00A0}% assumed")
        #expect(glance.state == "Plugged in")
        #expect(glance.goal == "Goal 80\u{00A0}%")
        #expect(glance.next == "Charges 01:00–04:45")
        #expect(glance.asOf == "AS OF 12:30")
        var holding = record
        holding.value.cars[0].holding = true
        #expect(WatchGlance.cars(holding, plan: nil, nowMs: t, zone: .current)[0].state == "Charge now on")
    }

    @Test func cheapPowerIsEachDaysCheapestTwoHoursLeft() {
        // Today's 02–04 is over by noon: what is left of today is cheapest
        // 12–14, well under the evening. Tomorrow's 02–04 stands whole.
        let windows = WatchGlance.cheapWindows(prices(), nowMs: at(14, 12))
        #expect(windows.map(\.startMs) == [at(14, 12), at(15, 2)])
        #expect(windows[1].range == "02:00–04:00")
        #expect(windows[1].price == "30.0 öre")
        #expect(windows[0].price == "70.0 öre")
        // After the evening peak nothing stands out from what is left.
        #expect(WatchGlance.cheapWindows(prices(days: 1), nowMs: at(14, 21)).isEmpty)
        // A flat day has nothing to point at.
        var flat = prices()
        flat.prices.slots = flat.prices.slots.map { var s = $0; s.totalMinor = 70; return s }
        #expect(WatchGlance.cheapWindows(flat, nowMs: at(14, 1)).isEmpty)
    }

    @Test func tomorrowsPricesWakeTheComplicationOnce() {
        let t = at(14, 13, 5)
        #expect(PriceEntry.bringsNewDay(old: prices(days: 1), new: prices(days: 2), nowMs: t))
        #expect(!PriceEntry.bringsNewDay(old: prices(days: 2), new: prices(days: 2), nowMs: t))
        #expect(!PriceEntry.bringsNewDay(old: nil, new: prices(days: 1), nowMs: t))
        #expect(PriceEntry.bringsNewDay(old: nil, new: prices(days: 2), nowMs: t))
    }

    @Test func theComplicationStepsByTheQuarterAndDropsAnOldLevel() {
        let t = at(14, 12, 7)
        let plan = CacheRead(record: CacheRecord(siteId: "s1", carrier: .relay, srcState: .live, readAtMs: t, value: plan()), origin: .app)
        let price = CacheRead(record: CacheRecord(siteId: "s1", carrier: .relay, srcState: .live, readAtMs: t, value: prices()), origin: .app)
        let now = CacheRead(record: now(readAtMs: t), origin: .app)
        let faces = WatchGlance.faces(plan: plan, prices: price, now: now, nowMs: t)
        // Now, then every quarter for a day.
        #expect(faces.count == 97)
        #expect(faces[1].atMs == at(14, 12, 15))
        #expect(faces[0].batteryPct == 64)
        #expect(faces.first { $0.atMs - t > WatchGlance.levelForMs }?.batteryPct == nil)
        #expect(faces.allSatisfy { $0.dial != nil })
    }

    // MARK: The trace on the wrist

    /// The trace draws each direction on its side of zero, as the phone's
    /// node view does: giving and selling below, everything else above.
    @Test func aReadingKeepsItsDirectionForTheTrace() {
        func r(_ node: WatchNow.Node, _ w: Double?, _ way: WatchNow.Way) -> Double? {
            WatchNow.Reading(node: node, watts: w, way: way, live: true).signedW
        }
        #expect(r(.battery, 1_200, .giving) == -1_200)
        #expect(r(.battery, 900, .charging) == 900)
        #expect(r(.grid, 300, .selling) == -300)
        #expect(r(.grid, 300, .buying) == 300)
        #expect(r(.solar, 2_000, .making) == 2_000)
        #expect(r(.home, 412, .using) == 412)
        #expect(r(.grid, nil, .noReading) == nil)
        #expect(WatchNow.Node.home.floorW == 2_000 && WatchNow.Node.car.floorW == 3_700)
    }

    @Test func aCheapWindowHasOneFigureForASmallSlot() {
        let w = WatchGlance.cheapWindows(prices(), nowMs: at(14, 12))
        #expect(w.map(\.short) == ["70", "30"])
    }

    // MARK: Words

    @Test func everyWatchWordHasSwedish() throws {
        let url = try #require(Words.bundle.url(forResource: "Watch", withExtension: "strings", subdirectory: nil, localization: "sv"))
        let sv = try #require(NSDictionary(contentsOf: url) as? [String: String])
        for word in WatchWord.allCases {
            let swedish = try #require(sv[word.rawValue], "no Swedish for \"\(word.rawValue)\"")
            #expect(!swedish.isEmpty)
            #expect(word.rawValue.components(separatedBy: "%@").count == swedish.components(separatedBy: "%@").count, "\(word.rawValue)")
        }
    }
}
