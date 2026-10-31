import Foundation
import Testing
@testable import FTWShared

/// The plan at a glance, on Now and in the plan widget, worked out from a
/// `PlanEntry` alone. Times are Stockholm's; 12 October 2026 is a Monday.
/// These read English: the tests run in the development language.
@Suite struct PlanGlanceTests {
    static let quarter: Double = 900_000
    static let hour: Double = 3_600_000
    let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        return c
    }()

    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Double {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!.timeIntervalSince1970 * 1000
    }

    /// A Monday night: the battery gives power until 21:15, charges 22:00 to
    /// 23:30, gives power again 06:00 to 08:00; the car charges 01:00 to
    /// 04:45 toward 80 %; power is cheapest 02 to 04.
    func night() -> PlanEntry {
        let start = at(12, 20)
        let battery = (0..<64).map { i -> PlanEntry.Slot in
            let t = start + Double(i) * Self.quarter
            let w: Double
            switch i {
            case 0..<5: w = -1_800
            case 8..<14: w = 3_000
            case 40..<48: w = -1_500
            default: w = 40
            }
            return PlanEntry.Slot(startMs: t, durationMs: Self.quarter, batteryW: w, reason: w > 0 ? "cheap_import" : (w < -100 ? "expensive_import" : "idle"))
        }
        let prices = (0..<16).map { i -> PriceSlot in
            let t = start + Double(i) * Self.hour
            let h = calendar.component(.hour, from: Date(timeIntervalSince1970: t / 1000))
            let p: Double = h == 2 || h == 3 ? 30 : (h >= 6 && h < 9 || h < 21 && h >= 17 ? 160 : 70)
            return PriceSlot(startMs: t, durationMs: Self.hour, spotMinor: p, totalMinor: p)
        }
        return PlanEntry(
            battery: battery,
            charges: [PlanEntry.Charge(loadpointID: "garage", fromMs: at(13, 1), toMs: at(13, 4, 45), energyWh: 42_000, targetPct: 80)],
            prices: prices,
            currency: "SEK",
            boxStale: false
        )
    }

    func read(_ entry: PlanEntry, readAtMs: Double, srcState: SourceState = .live) -> CacheRead<PlanEntry> {
        CacheRead(record: CacheRecord(siteId: "home", carrier: .relay, srcState: srcState, readAtMs: readAtMs, value: entry), origin: .app)
    }

    @Test func runsOfTheBatteryTheCarAndTheCheapHours() {
        let events = PlanGlance.events(night(), fromMs: at(12, 20), toMs: at(13, 8))
        #expect(events.map(\.kind) == [.discharge, .charge, .car, .cheap, .discharge])
        #expect(events[0].startMs == at(12, 20) && events[0].endMs == at(12, 21, 15))
        #expect(events[0].peakW == 1_800)
        #expect(events[0].reason == "expensive_import")
        #expect(events[1].startMs == at(12, 22) && events[1].endMs == at(12, 23, 30))
        #expect(events[2].targetPct == 80)
        #expect(events[3].startMs == at(13, 2) && events[3].endMs == at(13, 4))
        // The battery resting under the idle line is no event.
        #expect(!events.contains { $0.startMs == at(12, 21, 15) })
        // A run under way starts now; one that runs past the window keeps
        // the end the box planned.
        let later = PlanGlance.events(night(), fromMs: at(12, 22, 30), toMs: at(13, 7))
        #expect(later.first?.kind == .charge && later.first?.startMs == at(12, 22, 30))
        #expect(later.last?.kind == .discharge && later.last?.endMs == at(13, 8))
    }

    @Test func flatPricesHaveNoCheapestHours() {
        var flat = night()
        flat.prices = flat.prices.map { PriceSlot(startMs: $0.startMs, durationMs: $0.durationMs, spotMinor: 70, totalMinor: 70) }
        #expect(!PlanGlance.events(flat, fromMs: at(12, 20), toMs: at(13, 8)).contains { $0.kind == .cheap })
    }

    @Test func theNightInOneLine() {
        let now = PlanGlance.live(night(), nowMs: at(12, 20), calendar: calendar)
        #expect(now.state == .plan)
        // The car's charge and the battery's next move, in order, then the
        // cheap hours. "02–04" at 20:00 can only be tonight.
        #expect(now.summary == "now–21:15 battery gives power · 01:00–04:45 car charges to 80\u{00A0}% · cheapest 02–04")
        #expect(now.next?.kind == .discharge)
        #expect(now.nextWhen == "Now")
        #expect(now.nextWhat == "Battery gives power")
        #expect(now.nextUntil == "until 21:15")
        #expect(now.cheapText == "cheapest 02–04")
        // Beside the next thing, what comes after it.
        #expect(now.laterText == "01:00–04:45 car charges to 80\u{00A0}% · cheapest 02–04")
        #expect(now.ageText == nil)

        // Half a minute before it starts is now: a screen marks the minute.
        let almost = PlanGlance.live(night(), nowMs: at(12, 20) - 30_000, calendar: calendar)
        #expect(almost.nextWhen == "Now")
        #expect(almost.summary.hasPrefix("now–21:15"))

        // Later, the next thing has not begun: its clock, not "now".
        let later = PlanGlance.live(night(), nowMs: at(12, 23, 45), calendar: calendar)
        #expect(later.nextWhen == "01:00")
        #expect(later.nextWhat == "Car charges to 80\u{00A0}%")
        #expect(later.summary.hasPrefix("01:00–04:45 car charges to 80\u{00A0}% · 06–08 battery gives power"))
    }

    @Test func tomorrowIsNamedOnlyWhereTheClockWouldMislead() {
        // A charge from 21:00 tomorrow: seen at 14:00, "21–23" alone would
        // read as tonight; seen at 22:00, it can only be tomorrow's.
        let charge = PlanGlance.Event(kind: .car, startMs: at(13, 21), endMs: at(13, 23))
        let clock = Clock(calendar: calendar)
        #expect(PlanGlance.range(charge, from: at(12, 14), clock: clock, ongoingIsNow: true) == "tomorrow 21–23")
        #expect(PlanGlance.range(charge, from: at(12, 22), clock: clock, ongoingIsNow: true) == "21–23")
        #expect(PlanGlance.ahead(at(13, 21), asEnd: false, from: at(12, 14), clock: clock) == "tomorrow 21:00")
    }

    /// Two runs of the battery doing the same thing are said once, with
    /// both times: Anders read "laddar batteriet ur" twice on 28 Oct 2026.
    @Test func twoRunsOfTheSameKindAreSaidOnce() {
        let start = at(12, 20)
        let battery = (0..<8).map { i -> PlanEntry.Slot in
            let w: Double = i < 3 || i == 4 || i == 5 ? -480 : 0
            return PlanEntry.Slot(startMs: start + Double(i) * Self.quarter, durationMs: Self.quarter, batteryW: w, reason: "expensive_import")
        }
        let entry = PlanEntry(battery: battery, charges: [], prices: [], currency: "SEK", boxStale: false)
        let m = PlanGlance.live(entry, nowMs: start, calendar: calendar)
        #expect(m.summary == "now–20:45 and 21:00–21:30 battery gives power")
        // Different moves keep a clause each.
        #expect(PlanGlance.live(night(), nowMs: at(12, 21, 30), calendar: calendar).summary.hasPrefix("22:00–23:30 battery charges · 01:00–04:45 car charges"))
    }

    /// The lanes show the whole plan the box sent (Anders, 28 Oct 2026:
    /// "no way to see the plan further ahead"): to its last slot or car
    /// window, at least Now's twelve hours, never past the end of tomorrow.
    @Test func theLanesReachTheWholePlan() {
        var long = night()
        long.timeZone = "Europe/Stockholm"
        // The night plan runs to 12:00; it charges 10:00–11:00 tomorrow.
        long.battery = long.battery!.map { s in
            s.startMs >= at(13, 10) && s.startMs < at(13, 11) ? PlanEntry.Slot(startMs: s.startMs, durationMs: s.durationMs, batteryW: 2_000, reason: "solar_surplus") : s
        }
        #expect(PlanGlance.reach(long, fromMs: at(12, 20), calendar: calendar) == at(13, 12))
        let whole = PlanGlance.live(long, nowMs: at(12, 20), calendar: calendar, whole: true)
        let now = PlanGlance.live(long, nowMs: at(12, 20), calendar: calendar)
        #expect(whole.toMs == at(13, 12) && now.toMs == at(13, 8))
        #expect(whole.events.contains { $0.kind == .charge && $0.startMs == at(13, 10) })
        #expect(!now.events.contains { $0.startMs == at(13, 10) })
        #expect(whole.levels.isEmpty == now.levels.isEmpty)
        // A short plan keeps twelve hours; a long one stops at tomorrow's end.
        let short = PlanEntry(battery: Array(night().battery!.prefix(4)), charges: [], prices: [], currency: "SEK", boxStale: false)
        #expect(PlanGlance.reach(short, fromMs: at(12, 20), calendar: calendar) == at(13, 8))
        let far = PlanEntry(battery: [PlanEntry.Slot(startMs: at(12, 20), durationMs: 60 * Self.hour, batteryW: 0, reason: "idle")], charges: [], prices: [], currency: "SEK", boxStale: false)
        #expect(PlanGlance.reach(far, fromMs: at(12, 20), calendar: calendar) == at(14, 0))
        // The finger reads a quarter anywhere on the lanes, past one turn too.
        let dial = PlanDial(plan: long, prices: nil, nowMs: at(12, 20), untilMs: at(14, 0))
        #expect(dial.quarters.count == 112)
        #expect(dial.grid.index(atMs: at(13, 22)) != nil)
        // Past one turn the finger's clock names the day.
        #expect(dial.time(95) == "19:45")
        #expect(dial.time(96) == "TOMORROW 20:00")
        #expect(PlanDial(plan: long, prices: nil, nowMs: at(12, 20), untilMs: at(13, 12)).quarters.count == PlanDial.count)
    }

    /// A row's times name tomorrow where the clock would mislead, as the
    /// line does, now that the lanes reach into tomorrow evening.
    @Test func aRowNamesTomorrowWhereTheClockWouldMislead() {
        let m = PlanGlance.live(night(), nowMs: at(12, 14), calendar: calendar)
        #expect(m.times(PlanGlance.Event(kind: .car, startMs: at(13, 21), endMs: at(13, 22, 30))) == "tomorrow 21:00–22:30")
        #expect(m.times(PlanGlance.Event(kind: .charge, startMs: at(12, 23, 15), endMs: at(13, 0))) == "23:15–24:00")
        #expect(m.times(PlanGlance.Event(kind: .discharge, startMs: at(12, 13), endMs: at(12, 15))) == "now–15:00")
        // The same clock time tomorrow would read as now.
        let eight = PlanGlance.live(night(), nowMs: at(12, 20), calendar: calendar)
        let again = PlanGlance.Event(kind: .discharge, startMs: at(13, 20), endMs: at(13, 22))
        #expect(eight.times(again) == "tomorrow 20:00–22:00")
        #expect(PlanGlance.range(again, from: at(12, 20), clock: Clock(calendar: calendar), ongoingIsNow: true) == "tomorrow 20–22")
    }

    /// The widget never shows an old plan as if it held now: an hour after
    /// the box made it, the moment goes grey, says how old it is, and stops
    /// naming what happens "now".
    @Test func anOldPlanGoesGreyAndSaysSo() {
        let made = at(12, 20)
        let moments = PlanGlance.moments(read(night(), readAtMs: made), nowMs: at(12, 20, 5), calendar: calendar)
        #expect(moments.first?.state == .plan)
        #expect(moments.first?.ageText == "Planned 20:00")
        #expect(moments.first?.nextWhen == "Now")
        // One moment falls exactly where the plan turns old.
        let turn = moments.first { $0.atMs == made + PlanGlance.staleAfterMs }
        #expect(turn?.state == .old)
        #expect(turn?.isGrey == true)
        #expect(turn?.ageText == "Plan from 20:00 · open FTW")
        #expect(turn?.next == nil)
        #expect(turn?.nextWhen == nil)
        #expect(turn?.summary.contains("now") == false)
        // Everything after that is old too.
        #expect(moments.filter { $0.atMs >= made + PlanGlance.staleAfterMs }.allSatisfy { $0.state == .old })
        // Every edge ahead has its moment, in order, within the horizon.
        #expect(moments.map(\.atMs) == moments.map(\.atMs).sorted())
        #expect(moments.contains { $0.atMs == at(13, 1) })
        #expect(moments.allSatisfy { $0.atMs <= at(12, 20, 5) + PlanGlance.horizonMs })
    }

    /// A plan from a box this phone cannot reach is old at once, however
    /// fresh: the box may have planned again since. Grey, dated, no "now".
    @Test func aPlanFromABoxOutOfReachIsOldAtOnce() {
        let made = at(12, 20)
        let reached = PlanGlance.kept(night(), readAtMs: made, nowMs: at(12, 20, 5), calendar: calendar)
        #expect(reached.state == .plan)
        let away = PlanGlance.kept(night(), readAtMs: made, nowMs: at(12, 20, 5), unreachable: true, calendar: calendar)
        #expect(away.state == .old)
        #expect(away.isGrey)
        #expect(away.nextWhen == nil)
        #expect(away.summary.contains("now") == false)
    }

    @Test func aPlanTheBoxCouldNotMakeIsSaidAsSuch() {
        var entry = night()
        entry.boxStale = true
        let m = PlanGlance.moment(read(entry, readAtMs: at(12, 20), srcState: .stale), atMs: at(12, 20, 1), calendar: calendar)
        #expect(m.state == .boxStale)
        #expect(m.isGrey)
        #expect(m.next == nil)
        #expect(m.summary == "Your box couldn't plan ahead · it runs on safe defaults")
    }

    @Test func noRecordSendsTheReaderToTheApp() {
        let m = PlanGlance.moments(nil, nowMs: at(12, 20), calendar: calendar)
        #expect(m.count == 1)
        #expect(m[0].state == .nothing)
        #expect(m[0].summary == "Open FTW to see the plan")
        // No plan yet is not "nothing planned".
        let empty = PlanEntry(battery: nil, charges: [], prices: night().prices, currency: "SEK", boxStale: false)
        #expect(PlanGlance.live(empty, nowMs: at(12, 20), calendar: calendar).summary == "No plan from your box yet")
        let resting = PlanEntry(battery: [], charges: [], prices: [], currency: "SEK", boxStale: false)
        #expect(PlanGlance.live(resting, nowMs: at(12, 20), calendar: calendar).summary == "Nothing planned for 12 hours")
    }

    @Test func theRecordRoundTripsThroughTheAppGroup() throws {
        let files = AppGroupFiles(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ftw-plan-\(UUID().uuidString)"))
        let record = CacheRecord(siteId: "home", carrier: .relay, srcState: .live, readAtMs: at(12, 20), value: night())
        try files.write(record)
        let back = try #require(CacheReader(sources: [files]).read(PlanEntry.self, siteId: "home"))
        #expect(back.value == night())
        #expect(back.carrier == .cache)
        #expect(back.record.readAtMs == at(12, 20))
        #expect(files.siteIDs(PlanEntry.self) == ["home"])
    }

    /// A widget reads the clock the way the home does: the zone the box
    /// names travels in the record, whatever zone the phone is in.
    @Test func theClockIsTheHouseholds() throws {
        var entry = night()
        entry.timeZone = "Europe/Helsinki"
        let m = PlanGlance.live(entry, nowMs: at(12, 20))
        #expect(m.timeZone.identifier == "Europe/Helsinki")
        // 21:15 in Stockholm is 22:15 in Helsinki.
        #expect(m.summary.hasPrefix("now–22:15 battery gives power"))
        #expect(m.nextUntil == "until 22:15")
        // A record from before the zone was kept reads as the phone's.
        let old = try JSONEncoder().encode(night())
        let back = try JSONDecoder().decode(PlanEntry.self, from: old)
        #expect(back.timeZone == nil)
        #expect(Calendar.household(nil).timeZone == Calendar.current.timeZone)
        #expect(Calendar.household("Nowhere/Bogus").timeZone == Calendar.current.timeZone)
        #expect(Calendar.household("Asia/Tokyo").timeZone.identifier == "Asia/Tokyo")
    }

    /// A car that charges in several windows toward one goal (Erik, 31
    /// Oct 2026): a quarter now and the night later, toward 100 % by
    /// Tuesday 17:00. Seen on Monday at 13:30.
    func steps(goalMs: Double?) -> PlanEntry {
        PlanEntry(battery: [], charges: [
            PlanEntry.Charge(loadpointID: "garage", fromMs: at(12, 14), toMs: at(12, 14, 15), energyWh: 2_750, targetPct: 100, goalMs: goalMs),
            PlanEntry.Charge(loadpointID: "garage", fromMs: at(13, 1), toMs: at(13, 5), energyWh: 44_000, targetPct: 100, goalMs: goalMs),
        ], prices: [], currency: "SEK", boxStale: false)
    }

    /// A window with more after it does not say "to 100 %": the car is not
    /// there when it ends. It says the goal is still ahead, and when.
    @Test func aWindowOnTheWaySaysTheGoalIsAhead() {
        let entry = steps(goalMs: at(13, 17))
        let events = PlanGlance.events(entry, fromMs: at(12, 13, 30), toMs: at(13, 8)).filter { $0.kind == .car }
        #expect(events.map(\.chargesAgain) == [true, false])
        let m = PlanGlance.live(entry, nowMs: at(12, 13, 30), calendar: calendar)
        #expect(m.nextText == "Car charges 14:00–14:15 and later, toward 100\u{00A0}% by Tue 17:00. Then the car charges 01:00, to 100\u{00A0}%.")
        #expect(m.story.map(\.plain) == ["Car charges 14:00–14:15 and later, toward 100\u{00A0}% by Tue 17:00."])
        #expect(m.summary == "14:00–14:15 car charges toward 100\u{00A0}%")
        #expect(m.nextWhat == "Car charges toward 100\u{00A0}%")
        // Under way, it says until when.
        let under = PlanGlance.live(entry, nowMs: at(12, 14, 5), calendar: calendar)
        #expect(under.nextText.hasPrefix("Car charges until 14:15 and later, toward 100\u{00A0}% by Tue 17:00."))
        // Once the last window is all that is left, it goes to the goal.
        let last = PlanGlance.live(entry, nowMs: at(12, 20), calendar: calendar)
        #expect(last.nextText == "Car charges 01:00–05:00, to 100\u{00A0}%.")
        #expect(last.nextWhat == "Car charges to 100\u{00A0}%")
    }

    /// A goal later today has its clock alone; a box that sent no deadline
    /// still says the goal is ahead.
    @Test func theGoalsTimeIsSaidAsTheClockReadsIt() {
        let today = PlanGlance.live(steps(goalMs: at(12, 23)), nowMs: at(12, 13, 30), calendar: calendar)
        #expect(today.nextText.hasPrefix("Car charges 14:00–14:15 and later, toward 100\u{00A0}% by 23:00."))
        let none = PlanGlance.live(steps(goalMs: nil), nowMs: at(12, 13, 30), calendar: calendar)
        #expect(none.nextText.hasPrefix("Car charges 14:00–14:15 and later, toward 100\u{00A0}%."))
        // A deadline already behind the window is not repeated as one ahead.
        let gone = PlanGlance.live(steps(goalMs: at(12, 13)), nowMs: at(12, 13, 30), calendar: calendar)
        #expect(gone.nextText.hasPrefix("Car charges 14:00–14:15 and later, toward 100\u{00A0}%."))
    }

    /// Another charger's windows are not this car's: each car's last window
    /// is its own.
    @Test func eachCarHasItsOwnLastWindow() {
        var entry = steps(goalMs: at(13, 17))
        entry.charges.insert(PlanEntry.Charge(loadpointID: "drive", fromMs: at(12, 22), toMs: at(12, 23), energyWh: 11_000, targetPct: 80), at: 1)
        #expect(entry.charges.map { entry.chargesAgain(after: $0) } == [true, false, false])
    }

    /// A record from before the deadline was kept still reads.
    @Test func aChargeWithoutItsDeadlineStillReads() throws {
        let entry = steps(goalMs: at(13, 17))
        #expect(try JSONDecoder().decode(PlanEntry.self, from: JSONEncoder().encode(entry)) == entry)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        json["charges"] = (json["charges"] as? [[String: Any]])?.map { var c = $0; c["goalMs"] = nil; return c }
        let old = try JSONDecoder().decode(PlanEntry.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.charges.map(\.goalMs) == [nil, nil])
    }

    /// Every sentence has Swedish, with as many blanks as the English.
    @Test func everyWordHasSwedish() throws {
        let url = try #require(Words.bundle.url(forResource: "Plan", withExtension: "strings", subdirectory: nil, localization: "sv"))
        let sv = try #require(NSDictionary(contentsOf: url) as? [String: String])
        for word in PlanWord.allCases {
            let swedish = try #require(sv[word.rawValue], "no Swedish for \"\(word.rawValue)\"")
            #expect(!swedish.isEmpty)
            #expect(word.rawValue.components(separatedBy: "%@").count == swedish.components(separatedBy: "%@").count, "\(word.rawValue)")
        }
    }
}
