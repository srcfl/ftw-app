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
        #expect(!WatchContext.signOut(sentAtMs: 1).hasHome)
        #expect(!WatchContext.opening(sentAtMs: 1).hasHome)
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

    /// The watch's short form: live is a word, anything else the minute it
    /// was read, never "as of" and never seconds.
    @Test func theStatusLineSaysLiveOrTheMinuteItWasRead() {
        let t = at(14, 10, 5)
        let zone = TimeZone(identifier: Self.zone)!
        #expect(WatchGlance.status(now(readAtMs: t), lit: true, demo: false, zone: zone).text == "LIVE · FTW IN CONTROL")
        #expect(WatchGlance.status(now(readAtMs: t), lit: false, demo: false, zone: zone).text == "10:05 · FTW IN CONTROL")
        #expect(WatchGlance.status(now(readAtMs: t), lit: true, demo: true, zone: zone).text == "DEMO · FTW IN CONTROL")
        #expect(WatchGlance.status(nil, lit: false, demo: false, zone: zone).text == "NO READING YET")
        var out = now(readAtMs: t)
        out.value.control = .notInControl
        let warn = WatchGlance.status(out, lit: true, demo: false, zone: zone)
        #expect(warn.alarm && warn.text == "LIVE · ▲ FTW NOT IN CONTROL")
        #expect(warn.parts.map(\.tone) == [.ink, .alarm])
    }

    /// One size holds every ordinary line, so the line never shrinks
    /// between live and cached: the cached one is one character longer.
    @Test func theStatusLineHasOneWidthInEveryState() {
        let t = at(14, 23, 59)
        let zone = TimeZone(identifier: Self.zone)!
        #expect(WatchGlance.statusChars == 22)
        for lit in [true, false] {
            for demo in [true, false] {
                #expect(WatchGlance.status(now(readAtMs: t), lit: lit, demo: demo, zone: zone).text.count <= WatchGlance.statusChars)
            }
        }
        // So do the line before the first reading and a receipt on its way.
        #expect(WatchGlance.status(nil, lit: false, demo: false, zone: zone).text.count <= WatchGlance.statusChars)
        let c = WatchCommand(op: .mode("idle"), home: "s1", sentAtMs: t)
        for accepted in [WatchReceipt.Mark.waiting, .done] {
            let r = WatchReceipt(commandID: c.id, op: c.op, sent: .done, accepted: accepted, confirmed: .waiting, text: "", tone: .working)
            #expect(WatchGlance.status(now(readAtMs: t), lit: true, demo: false, zone: zone, receipt: r).text.count <= WatchGlance.statusChars)
        }
    }

    /// After a change of mode the box's receipt takes the line for its
    /// time, mark by mark, and never a mark the box has not given.
    @Test func theReceiptTakesTheLineMarkByMark() {
        let t = at(14, 10)
        let zone = TimeZone(identifier: Self.zone)!
        let c = WatchCommand(op: .mode("idle"), home: "s1", sentAtMs: t)
        func line(_ r: WatchReceipt) -> WatchGlance.Status {
            WatchGlance.status(now(readAtMs: t), lit: true, demo: false, zone: zone, receipt: r)
        }
        #expect(line(.tapped(c)).text == "SENDING…")
        var r = WatchReceipt(commandID: c.id, op: c.op, sent: .done, accepted: .waiting, confirmed: .waiting, text: "", tone: .working)
        #expect(line(r).text == "SENT ▸")
        r.accepted = .done
        #expect(line(r).text == "SENT ▸ ACCEPTED ▸")
        r.confirmed = .done
        r.tone = .done
        #expect(line(r).text == "SENT ▸ CONFIRMED" && line(r).parts.first?.tone == .live)
        #expect(line(.unreachable(c)).text == "▲ NOT SENT" && line(.unreachable(c)).alarm)
        #expect(line(WatchReceipt.tapped(c).noAnswer()).text == "▲ NOT CONFIRMED")
        r.sent = .done
        r.confirmed = .failed
        r.tone = .failed
        #expect(line(r).text == "▲ REFUSED")
        // The dot still says whether Now is live.
        #expect(line(r).lit)
    }

    // MARK: Now's figures

    @Test func theBatteryAndTheGridMarkTheirWay() {
        let figures = WatchGlance.figures(now(readAtMs: 0).value, lit: false)
        #expect(figures.map(\.direction) == [nil, .down, .up])
        let shape = WatchGlance.figures(WatchNow.shape, lit: true)
        #expect(Set(shape.map(\.node)) == Set(WatchNow.Node.allCases))
        #expect(shape.allSatisfy { !$0.lit })
    }

    /// Under a finger the large figure gives the reading and its way, with
    /// no minus sign.
    @Test func aFingerOnTheTraceReadsTheWay() {
        let selling = WatchGlance.figure(.grid, at: LiveSample(t: 0, v: -1_200))
        #expect(selling.value == "1.2" && selling.unit == "kW" && selling.word == "selling" && selling.direction == .down)
        let storing = WatchGlance.figure(.battery, at: LiveSample(t: 0, v: 800))
        #expect(storing.value == "800" && storing.word == "charging" && storing.direction == .up)
        #expect(WatchGlance.figure(.battery, at: LiveSample(t: 0, v: -30)).direction == nil)
        #expect(WatchGlance.figure(.home, at: LiveSample(t: 0, v: 412)).word == "using")
        #expect(WatchGlance.figure(.solar, at: LiveSample(t: 0, v: 2_000)).direction == nil)
        #expect(!WatchGlance.figure(.home, at: LiveSample(t: 0, v: 412)).lit)
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
        #expect(WatchNow.Node.home.floorW == 500 && WatchNow.Node.car.floorW == 925)
    }

    @Test func aCheapWindowHasOneFigureForASmallSlot() {
        let w = WatchGlance.cheapWindows(prices(), nowMs: at(14, 12))
        #expect(w.map(\.short) == ["70", "30"])
    }

    // MARK: The last three minutes

    /// Readings at about 1 Hz with the jitter of a real stream, and values
    /// that move every second.
    func samples(from: Double, to: Double, everyMs: Double = 1_000, seed: UInt64 = 7) -> [LiveSample] {
        var g = Seeded(seed)
        var out = [LiveSample]()
        var t = from
        var v = 1_500.0
        while t <= to {
            v = max(-9_000, min(9_000, v + Double(Int.random(in: -400...400, using: &g))))
            out.append(LiveSample(t: t, v: v + Double.random(in: -0.5..<0.5, using: &g)))
            t += everyMs + Double(Int.random(in: -40...40, using: &g))
        }
        return out
    }

    /// Five nodes for three minutes at 1 Hz fit one reply with room to
    /// spare, and come back to the millisecond and the watt.
    @Test func theLastThreeMinutesFitOneReply() throws {
        let t = at(14, 12)
        var all = [WatchNow.Node: [LiveSample]]()
        for (i, node) in WatchNow.Node.allCases.enumerated() {
            all[node] = samples(from: t - 4 * 60_000, to: t, seed: UInt64(i + 1))
        }
        let recent = WatchRecent.make(all, nowMs: t)
        #expect(recent.lanes.count == 5)
        #expect(recent.wireBytes <= WatchRecent.maxBytes)
        // Nothing thinned: every reading in the window is there.
        for node in WatchNow.Node.allCases {
            let sent = try #require(all[node]).filter { $0.t >= t - WatchRecent.windowMs }
            let back = recent.samples(node)
            #expect(back.count == sent.count)
            for (a, b) in zip(sent, back) {
                #expect(abs(a.t - b.t) <= 1)
                #expect(abs(a.v - b.v) <= 1)
                #expect(!b.seen)
            }
        }
        let news = try WatchNews.recent(recent).data()
        #expect(news.count <= WatchRecent.maxBytes)
        #expect(WatchNews.from(news) == .recent(recent))
        #expect(recent.newestMs == WatchNow.Node.allCases.compactMap { recent.samples($0).last?.t }.max())
    }

    /// A window too dense for one reply keeps every other reading until it
    /// fits, and always the newest.
    @Test func aWindowTooDenseIsThinnedToFit() {
        let t = at(14, 12)
        var all = [WatchNow.Node: [LiveSample]]()
        for (i, node) in WatchNow.Node.allCases.enumerated() {
            all[node] = samples(from: t - WatchRecent.windowMs, to: t, everyMs: 100, seed: UInt64(10 + i))
        }
        let recent = WatchRecent.make(all, nowMs: t)
        #expect(recent.wireBytes <= WatchRecent.maxBytes)
        for node in WatchNow.Node.allCases {
            let back = recent.samples(node)
            #expect(back.count > 100)
            #expect(abs((back.last?.t ?? 0) - (all[node]?.last?.t ?? 0)) <= 1)
            #expect(zip(back, back.dropFirst()).allSatisfy { $0.t < $1.t })
        }
        #expect(WatchRecent.make([:], nowMs: t).lanes.isEmpty)
    }

    // MARK: What the watch keeps

    func context(home: String = "s1", readAtMs t: Double, prices: Bool = true, plan: Bool = true, now: Bool = true) -> WatchContext {
        WatchContext(
            home: home, isDemo: false,
            prices: prices ? CacheRecord(siteId: home, carrier: .relay, srcState: .live, readAtMs: t, value: self.prices()) : nil,
            plan: plan ? CacheRecord(siteId: home, carrier: .relay, srcState: .live, readAtMs: t, value: self.plan()) : nil,
            now: now ? self.now(readAtMs: t) : nil,
            modes: WatchModes(modes: [.init(key: "planner_self", name: "Plan", isPlan: true)], shown: "planner_self", label: "Plan · Balanced", mayControl: true),
            sentAtMs: t
        )
    }

    /// A phone that has not read its prices or its plan since it opened
    /// sends a context without them: the watch keeps the ones it has.
    @Test func aNilRecordKeepsTheOldOne() throws {
        let t = at(14, 12)
        let kept = context(readAtMs: t)
        var next = context(readAtMs: t + 60_000, prices: false, plan: false)
        next.modes = nil
        let merged = try #require(WatchContext.merging(next, over: kept))
        #expect(merged.prices == kept.prices)
        #expect(merged.plan == kept.plan)
        #expect(merged.modes == kept.modes)
        #expect(merged.now == next.now)
        // An older record never takes the place of a newer one.
        let late = context(readAtMs: t - 60_000)
        #expect(WatchContext.merging(late, over: kept)?.now == kept.now)
        #expect(WatchContext.merging(late, over: kept)?.prices == kept.prices)
    }

    /// Only an explicit sign-out forgets; a phone still opening its home
    /// changes nothing; another home replaces the whole.
    @Test func onlyASignOutForgets() throws {
        let t = at(14, 12)
        let kept = context(readAtMs: t)
        #expect(WatchContext.merging(.opening(sentAtMs: t + 1), over: kept) == kept)
        #expect(WatchContext.merging(.opening(sentAtMs: t + 1), over: nil) == nil)
        let out = try #require(WatchContext.merging(.signOut(sentAtMs: t + 1), over: kept))
        #expect(!out.hasHome && out.signedOut == true && out.prices == nil && out.now == nil)
        let other = context(home: "s2", readAtMs: t - 1, prices: false)
        #expect(WatchContext.merging(other, over: kept) == other)
        // The two differ on the wire.
        let opening = try #require(WatchContext.unpacked(try WatchContext.opening(sentAtMs: 1).packed()))
        let signedOut = try #require(WatchContext.unpacked(try WatchContext.signOut(sentAtMs: 1).packed()))
        #expect(opening.signedOut == nil && signedOut.signedOut == true)
    }

    /// The dial keeps the last sun the box forecast until a newer forecast
    /// comes; the trace the watch kept stays with the newer of the two.
    @Test func theDialKeepsTheLastSunAndTheTraceItsNewest() throws {
        let t = at(14, 12)
        var kept = context(readAtMs: t)
        let sun = PlanEntry.Daylight(covered: .init(fromMs: t, toMs: t + 86_400_000), sun: [.init(fromMs: at(15, 7), toMs: at(15, 17))])
        kept.plan?.value.daylight = sun
        kept.recent = WatchRecent.make([.home: samples(from: t - 60_000, to: t)], nowMs: t)
        var next = context(readAtMs: t + 900_000)
        #expect(WatchContext.merging(next, over: kept)?.plan?.value.daylight == sun)
        #expect(WatchContext.merging(next, over: kept)?.recent == kept.recent)
        let later = PlanEntry.Daylight(covered: .init(fromMs: t + 1, toMs: t + 86_400_000), sun: [])
        next.plan?.value.daylight = later
        #expect(WatchContext.merging(next, over: kept)?.plan?.value.daylight == later)
    }

    /// The watch's own cache from before this build, without the trace or
    /// the sign-out mark, still opens.
    @Test func aContextKeptByTheLastBuildStillOpens() throws {
        let t = at(14, 12)
        var ctx = context(readAtMs: t)
        ctx.recent = WatchRecent.make([.home: samples(from: t - 60_000, to: t)], nowMs: t)
        let packed = try ctx.packed()
        #expect(WatchContext.unpacked(packed) == ctx)
        var json = try #require(try JSONSerialization.jsonObject(with: try JSONEncoder().encode(ctx)) as? [String: Any])
        json["recent"] = nil
        json["signedOut"] = nil
        let old = try (JSONSerialization.data(withJSONObject: json) as NSData).compressed(using: .lzfse) as Data
        let back = try #require(WatchContext.unpacked(old))
        #expect(back.recent == nil && back.prices == ctx.prices)
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

/// A small fixed generator, so the noisy readings are the same each run.
struct Seeded: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
