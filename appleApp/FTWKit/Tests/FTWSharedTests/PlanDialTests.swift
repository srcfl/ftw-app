import Foundation
import Testing
@testable import FTWShared

/// The plan dial as the phone, its widget and the watch draw it: the
/// twelve hours from now, a finger round the ring that winds the face on,
/// the sun from the box's forecast and the words a finger reads. The plan and prices are `WatchTests`': from Wednesday
/// 12:00 the battery discharges 17–19 and stores 22:00–23:30, the car
/// charges 01:00–04:45 toward 80 %, and power costs 30 öre 02–04, 160 öre
/// 17–21 and 70 öre otherwise.
@Suite struct PlanDialTests {
    let watch = WatchTests()
    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Double { watch.at(day, hour, minute) }
    func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 || abs(abs(a - b) - 2 * .pi) < 1e-9 }

    /// The twelve hours from now, or with `untilMs` the quarters on to it.
    func dial(at t: Double? = nil, daylight: PlanEntry.Daylight? = nil, untilMs: Double? = nil) -> PlanDial {
        var plan = watch.plan()
        plan.daylight = daylight
        return PlanDial(plan: plan, prices: watch.prices(), nowMs: t ?? at(14, 12, 7), untilMs: untilMs)
    }

    /// Where a finger at quarter `i`'s middle sits, `r` from the centre.
    func finger(_ d: PlanDial, _ i: Int, r: Double = 120) -> (x: Double, y: Double) {
        let a = d.angle(quarter: i)
        return (r * sin(a), -r * cos(a))
    }

    /// Tomorrow's sun sits just behind the hand at night, and read as sun
    /// that had just set (xorath, 6 Nov 2026). The rim names its day, between
    /// two hours; today's sun needs no word.
    @Test func tomorrowsSunIsNamedOnTheRim() throws {
        let hours = [14, 15].flatMap { d in (7..<17).map { h in PlanEntry.Daylight.Step(fromMs: at(d, h), toMs: at(d, h + 1), w: 3_000) } }
        let day = PlanEntry.Daylight(covered: .init(fromMs: at(14, 0), toMs: at(16, 0)), sun: [
            .init(fromMs: at(14, 7), toMs: at(14, 17)),
            .init(fromMs: at(15, 7), toMs: at(15, 17)),
        ], power: hours)
        // 23:20: the face ends at 11:15 tomorrow, so the run's middle is 09:07.
        let night = dial(at: at(14, 23, 20), daylight: day)
        #expect(near(try #require(night.sunTomorrowAngle), night.angle(at(15, 9, 30))))
        // By day the sun on the face is today's.
        #expect(dial(at: at(14, 12), daylight: day).sunTomorrowAngle == nil)
        // Past midnight it is today's again.
        #expect(dial(at: at(15, 1), daylight: day).sunTomorrowAngle == nil)
        // A run at the very end of the turn: the word stays clear of the hand.
        let late = dial(at: at(14, 19, 30), daylight: day)
        #expect(near(try #require(late.sunTomorrowAngle), late.angle(at(15, 6, 30))))
        // No forecast of the sun's power, no area and no word.
        let plain = PlanEntry.Daylight(covered: day.covered, sun: day.sun)
        #expect(dial(at: at(14, 23, 20), daylight: plain).sunTomorrowAngle == nil)
    }

    /// The face opens on the twelve hours from now, its seam at now.
    @Test func theFaceIsTheNextTwelveHours() {
        let d = dial()
        #expect(near(d.seam, d.angle(at(14, 12))) && d.offset == 0 && d.window == 0..<48)
        #expect(d.times[0] == "12:07")
        // The hand at now sits just past the seam, inside the first quarter.
        #expect(d.handAngle(selected: nil) > d.seam)
        #expect(d.handAngle(selected: nil) - d.seam < 2 * .pi / 48)
    }

    /// A clock: 18 straight down, the real hours round the rim, none on
    /// top of the hand or the seam.
    @Test func theHoursSitWhereAClockHasThem() {
        let d = dial()
        #expect(near(d.angle(at(14, 18)), .pi))
        #expect(near(d.angle(at(14, 15)), .pi / 2))
        #expect(near(d.angle(at(14, 21)), 1.5 * .pi))
        #expect(near(d.angle(at(15, 0)), 0))
        // From 12:07 the turn runs to midnight: 13 to 23, with 12 and 00
        // left off at the hand and the seam.
        #expect(d.hours.map(\.label) == ["13", "14", "15", "16", "17", "18", "19", "20", "21", "22", "23"])
        #expect(near(d.hours.first { $0.label == "18" }!.angle, .pi))
        // At 20:07, 06 sits at the foot, the next morning's.
        #expect(dial(at: at(14, 20, 7)).hours.contains { $0.label == "06" && near($0.angle, .pi) })
        // At 17:34, 18 is 26 minutes past the hand and stands at the foot;
        // 05 is half an hour before the seam. Neither sits on either.
        let evening = dial(at: at(14, 17, 34))
        #expect(evening.hours.first?.label == "18" && evening.hours.last?.label == "05")
        #expect(evening.hours.count == 12)
    }

    /// A finger that runs on past the twelve hours turns the face to the
    /// next twelve, whole at once, and back across the seam.
    @Test func aFingerTurnsTheFaceOn() {
        let d = dial(at: at(14, 17, 34), untilMs: at(16, 0))
        #expect(d.quarters.count == 26 + 96 && d.maxOffset == 96)
        // On past the seam the finger reads the quarter after the last, and
        // the face is the twelve hours that hold it.
        let seam = finger(d, 0)
        #expect(d.index(x: seam.x, y: seam.y, from: 47) == 48)
        #expect(d.offset(keeping: 47) == 0 && d.offset(keeping: 48) == 48 && d.offset(keeping: 95) == 48)
        let next = d.wound(to: 48)
        #expect(next.window == 48..<96 && near(next.seam, d.seam))
        // The same place on the ring is now a turn on: tomorrow's 05:45.
        let on = finger(next, 49)
        #expect(next.index(x: on.x, y: on.y, from: 48) == 49)
        #expect(next.time(49) == "05:45" && next.day(49) == "TOMORROW")
        // Its hours are tomorrow's, none on the seam.
        #expect(next.hours.first?.label == "06" && next.hours.last?.label == "17")
        // Back across the seam, the finger is on today's turn again.
        #expect(next.index(x: finger(next, 95).x, y: finger(next, 95).y, from: 48) == 47)
        // The last turn holds what the plan has of it.
        #expect(d.wound(to: 96).window == 96..<122)
        // Never past the plan's last turn, nor before now.
        #expect(d.offset(keeping: 500) == 96 && d.wound(to: 500).offset == 96)
        #expect(d.index(x: finger(d, 47).x, y: finger(d, 47).y, from: 0) == 0)
    }

    /// A tick is as long as the battery's planned power, against the most
    /// it moves in the turn; a quarter in which it waits has none.
    @Test func aTickIsTheBatterysPower() {
        let d = dial()
        #expect(d.fullW == 3_000)
        #expect(d.reach(d.grid.index(atMs: at(14, 22))!) == 1)
        #expect(abs(d.reach(d.grid.index(atMs: at(14, 18))!)! - 2.0 / 3) < 1e-9)
        #expect(d.reach(d.grid.index(atMs: at(14, 13))!) == nil)
        #expect(PlanDial(plan: nil, prices: watch.prices(), nowMs: at(14, 12)).reach(3) == nil)
    }

    @Test func aFingerFindsTheQuarterUnderIt() {
        let d = dial()
        for i in [0, 1, 17, 24, 40, 47] {
            let p = finger(d, i)
            #expect(d.index(x: p.x, y: p.y, from: nil) == i)
            #expect(d.index(x: p.x, y: p.y, from: max(0, i - 1)) == i)
        }
    }

    /// With no more of the plan to wind into, the finger stops at the seam:
    /// from the end it stays on the last quarter, from now on the first.
    @Test func theSeamStopsAFinger() {
        let d = dial()
        let start = finger(d, 0), end = finger(d, 47)
        #expect(d.index(x: start.x, y: start.y, from: 47) == 47)
        #expect(d.index(x: start.x, y: start.y, from: 42) == 47)
        #expect(d.index(x: end.x, y: end.y, from: 0) == 0)
        #expect(d.index(x: end.x, y: end.y, from: 3) == 0)
        // Half a turn on is still an honest move.
        #expect(d.index(x: finger(d, 23).x, y: finger(d, 23).y, from: 1) == 23)
    }

    /// The sky is the box's forecast inside the turn, never astronomy: at
    /// noon the turn holds this afternoon's sun, at two in the night the
    /// morning's.
    @Test func theSunComesFromTheForecast() {
        let day = PlanEntry.Daylight(covered: .init(fromMs: at(14, 0), toMs: at(16, 0)), sun: [
            .init(fromMs: at(14, 7, 30), toMs: at(14, 17, 30)),
            .init(fromMs: at(15, 7, 45), toMs: at(15, 17, 15)),
        ])
        let d = dial(daylight: day)
        #expect(d.sun == [at(14, 12, 7)...at(14, 17, 30)])
        // Round the turn from the seam: from now to sunset, 22 quarters on.
        let quarter = 2 * Double.pi / 48
        #expect(d.sunAlong.count == 1)
        #expect(abs(d.sunAlong[0].lowerBound - 7.0 / 15 * quarter) < 1e-9)
        #expect(abs(d.sunAlong[0].upperBound - 22 * quarter) < 1e-9)
        // With the seam at 02:00: the morning's sun sits 23 quarters on and
        // runs to the end of the turn.
        let night = dial(at: at(15, 2, 7), daylight: day)
        #expect(night.sunAlong.count == 1)
        #expect(abs(night.sunAlong[0].lowerBound - 23 * quarter) < 1e-9)
        #expect(abs(night.sunAlong[0].upperBound - 2 * .pi) < 1e-9)
        // At 18:07 the turn runs to 06:00 and holds no sun; wound on to
        // tomorrow 06:00, the face holds tomorrow's.
        #expect(dial(at: at(14, 18, 7), daylight: day).sunAlong.isEmpty)
        let morning = dial(at: at(14, 18, 7), daylight: day, untilMs: at(16, 0)).wound(to: 48)
        #expect(morning.sunAlong.count == 1)
        #expect(abs(morning.sunAlong[0].lowerBound - 7 * quarter) < 1e-9 && abs(morning.sunAlong[0].upperBound - 45 * quarter) < 1e-9)
        // A sun that never sets fills the turn from now.
        let polar = PlanEntry.Daylight(covered: .init(fromMs: at(14, 0), toMs: at(16, 0)), sun: [.init(fromMs: at(14, 0), toMs: at(16, 0))])
        let whole = dial(at: at(14, 18, 7), daylight: polar).sunAlong
        #expect(whole.count == 1 && abs(whole[0].lowerBound - 7.0 / 15 * quarter) < 1e-9 && abs(whole[0].upperBound - 2 * .pi) < 1e-9)
        // No forecast, no sky.
        #expect(dial().sun.isEmpty)
        // A forecast that has run out draws none either.
        let old = PlanEntry.Daylight(covered: .init(fromMs: at(12, 0), toMs: at(13, 0)), sun: [.init(fromMs: at(12, 7), toMs: at(12, 17))])
        #expect(dial(daylight: old).sun.isEmpty)
    }

    /// From the forecast's quarters: sun where it expects the panels to
    /// make at least 10 W, joined into runs.
    @Test func daylightFromTheForecast() throws {
        let slots: [(startMs: Double, durationMs: Double, pvW: Double)] = (0..<96).map { i in
            let t = at(14, 0) + Double(i) * WatchTests.quarter
            let h = Double(i) / 4
            return (t, WatchTests.quarter, h >= 7.5 && h < 17 ? 1_500 : (h == 7.25 ? 4 : 0))
        }
        let d = try #require(PlanEntry.Daylight(slots))
        #expect(d.covered == .init(fromMs: at(14, 0), toMs: at(15, 0)))
        #expect(d.sun == [.init(fromMs: at(14, 7, 30), toMs: at(14, 17))])
        // Its watts travel too, each step with sun, for the dial's area.
        #expect(d.power?.count == 38 && d.power?.first == .init(fromMs: at(14, 7, 30), toMs: at(14, 7, 45), w: 1_500))
        #expect(PlanEntry.Daylight([]) == nil)
    }

    /// The sun is an area as deep as the forecast's watts against the most
    /// it expects, from now on: a bright noon full, a dull morning lower.
    @Test func theSunIsAnAreaOfTheForecastsWatts() {
        let steps = (0..<96).compactMap { i -> PlanEntry.Daylight.Step? in
            let t = at(14, 0) + Double(i) * WatchTests.quarter
            let h = Double(i % 96) / 4
            guard h >= 8, h < 16 else { return nil }
            return .init(fromMs: t, toMs: t + WatchTests.quarter, w: h < 10 ? 1_000 : 4_000)
        }
        let day = PlanEntry.Daylight(covered: .init(fromMs: at(14, 0), toMs: at(15, 0)), sun: [.init(fromMs: at(14, 8), toMs: at(14, 16))], power: steps)
        let morning = dial(at: at(14, 7, 10), daylight: day)
        #expect(morning.sunFullW == 4_000)
        #expect(morning.sunReach(morning.grid.index(atMs: at(14, 9))!) == 0.25)
        #expect(morning.sunReach(morning.grid.index(atMs: at(14, 11))!) == 1)
        #expect(morning.sunReach(morning.grid.index(atMs: at(14, 7, 30))!) == nil)
        // At 12:07 the quarter running now reads the forecast for the part
        // of it to come.
        #expect(dial(at: at(14, 12, 7), daylight: day).sunReach(0) == 1)
        // A record kept before the watts travelled draws no area.
        #expect(dial(at: at(14, 12, 7), daylight: .init(covered: day.covered, sun: day.sun)).quarters.allSatisfy { $0.sunW == nil })
    }

    @Test func theMiddleAndTheScrubLineAreMadeOnce() {
        let d = dial(at: at(14, 17, 7))
        let six = d.grid.index(atMs: at(14, 18))!, ten = d.grid.index(atMs: at(14, 22))!, goal = d.grid.index(atMs: at(15, 4, 30))!
        #expect(d.times[0] == "17:07" && d.times[six] == "18:00")
        // Past midnight the day stands apart from the time, so neither is
        // cut to fit the middle.
        #expect(d.times[goal] == "04:30" && d.day(goal) == "TOMORROW")
        #expect(d.when(goal) == "TOMORROW 04:30" && d.when(six) == "18:00")
        #expect(d.day(six) == nil && d.day(d.tomorrowFrom - 1) == nil)
        #expect(d.times[d.tomorrowFrom] == "00:00")
        #expect(d.prices[six] == "160 ÖRE/KWH")
        #expect(d.doing[six] == "DISCHARGES · 2.0 KW")
        #expect(d.doing[ten] == "CHARGES · 3.0 KW")
        #expect(d.doing[goal] == "WAITS · CAR TO 80\u{00A0}%")
        #expect(d.doing[d.grid.index(atMs: at(15, 2))!] == "WAITS · CAR")
        #expect(d.figure(six) == "160")
        #expect(d.cheapestText == "CHEAPEST 02:00–04:00 · 30.0 ÖRE")
        // Without a plan, nothing is claimed about the battery.
        let bare = PlanDial(plan: nil, prices: watch.prices(), nowMs: at(14, 12))
        #expect(bare.doing[0] == "NO PLAN")
        // Before the market prices a quarter, the middle says so.
        let short = PlanDial(plan: watch.plan(), prices: watch.prices(days: 1), nowMs: at(14, 17))
        #expect(short.prices[short.grid.index(atMs: at(15, 3))!] == "NO PRICE YET")
        #expect(short.figure(short.grid.index(atMs: at(15, 3))!) == "–")
    }

    /// The box starts its plan the moment it makes it, so the first slot
    /// begins inside the quarter running now. That quarter still has its
    /// battery and its price.
    @Test func theQuarterRunningNowReadsAPlanMadeInsideIt() {
        var plan = watch.plan()
        let made = at(14, 17, 7)
        plan.battery = [PlanEntry.Slot(startMs: made, durationMs: at(14, 17, 15) - made, batteryW: -2_000, reason: "test")]
            + (plan.battery ?? []).filter { $0.startMs >= at(14, 17, 15) }
        let d = PlanDial(plan: plan, prices: watch.prices(), nowMs: at(14, 17, 8))
        #expect(d.quarters[0].battery == .gives)
        #expect(d.doing[0] == "DISCHARGES · 2.0 KW")
        #expect(d.quarters[0].minor == 160)
    }

    /// The middle and the Crown say where the plan leaves the battery.
    @Test func theMiddleSaysWhereTheBatteryIs() {
        var plan = watch.plan()
        plan.battery = plan.battery?.enumerated().map { i, s in
            var s = s
            s.levelPct = 50 + Double(i % 40)
            return s
        }
        let d = PlanDial(plan: plan, prices: watch.prices(), nowMs: at(14, 12, 7))
        let ten = d.grid.index(atMs: at(14, 22))!
        #expect(d.quarters[ten].levelPct == 50 + Double(ten % 40))
        #expect(d.doing[ten] == "CHARGES · 3.0 KW · \(50 + ten % 40)\u{00A0}%")
        #expect(d.what(ten) == "Battery charges 3.0 kW · \(50 + ten % 40)\u{00A0}%")
    }

    /// Only the quarters a new plan changed cross-fade on the dial.
    @Test func onlyTheMovedTicksChange() {
        var plan = watch.plan()
        let a = PlanDial(plan: plan, prices: watch.prices(), nowMs: at(14, 12, 7))
        plan.battery = plan.battery?.map { s in
            var s = s
            if s.startMs >= at(14, 22) && s.startMs < at(14, 23) { s.batteryW = 40 }
            return s
        }
        let b = PlanDial(plan: plan, prices: watch.prices(), nowMs: at(14, 12, 7))
        let ten = a.grid.index(atMs: at(14, 22))!
        #expect(b.moved(from: a) == Array(ten..<(ten + 4)))
        #expect(PlanDial(plan: plan, prices: watch.prices(), nowMs: at(14, 12, 20)).moved(from: a).isEmpty)
    }

    @Test func thePlannedLine() {
        let zone = TimeZone(identifier: WatchTests.zone)!
        #expect(PlanDial.planned(atMs: at(14, 16, 51), old: false, zone: zone) == "PLANNED 16:51 · REPLANS EVERY 15 MIN")
        #expect(PlanDial.planned(atMs: at(14, 14, 5), old: true, zone: zone) == "PLAN FROM 14:05 · OLD")
    }

    /// The sun travels to the watch with the plan: an older record without
    /// it still reads.
    @Test func aRecordWithoutTheSunStillReads() throws {
        var entry = watch.plan()
        entry.daylight = PlanEntry.Daylight(covered: .init(fromMs: at(14, 0), toMs: at(15, 0)), sun: [.init(fromMs: at(14, 8), toMs: at(14, 16))])
        let back = try JSONDecoder().decode(PlanEntry.self, from: JSONEncoder().encode(entry))
        #expect(back == entry)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        json["daylight"] = nil
        let old = try JSONDecoder().decode(PlanEntry.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.daylight == nil)
        // A record from before the meter's watts were kept sells nothing.
        #expect(old.battery?.allSatisfy { $0.gridW == nil && $0.soldW == 0 } == true)
    }

    /// A car that charges in two windows toward one goal has the goal once,
    /// where its last window ends (Erik read "100 %" all round the ring on
    /// 31 Oct 2026). The window on the way is a car quarter, no more.
    @Test func theGoalIsOnTheDialOnce() {
        var plan = watch.plan()
        plan.charges.insert(PlanEntry.Charge(loadpointID: plan.charges[0].loadpointID, fromMs: at(14, 17, 15), toMs: at(14, 17, 30), energyWh: 2_750, targetPct: 80), at: 0)
        let d = PlanDial(plan: plan, prices: watch.prices(), nowMs: at(14, 17, 7))
        let step = d.grid.index(atMs: at(14, 17, 15))!, goal = d.grid.index(atMs: at(15, 4, 30))!
        #expect(d.quarters.indices.filter { d.quarters[$0].carGoalPct != nil } == [goal])
        #expect(d.quarters[step].car && d.doing[step].hasSuffix(" · CAR"))
        #expect(d.doing[goal] == "WAITS · CAR TO 80\u{00A0}%")
        #expect(d.landmarks.contains(goal) && !d.landmarks.contains(step))
    }

    /// What the battery gives that the home sells ends its tick in the
    /// grid's colour, as far as it goes, and the middle says so (Anders,
    /// 4 Nov 2026). From 17 the home sells 1.5 of the battery's 2 kW, from
    /// 18 half a kilowatt.
    @Test func whatTheHomeSellsEndsTheTick() {
        var plan = watch.plan()
        for i in plan.battery!.indices {
            let s = plan.battery![i]
            guard s.batteryW < 0 else { continue }
            plan.battery![i].gridW = s.startMs < at(14, 18) ? -1_500 : -500
        }
        let d = PlanDial(plan: plan, prices: watch.prices(), nowMs: at(14, 12, 7))
        let five = d.grid.index(atMs: at(14, 17))!, six = d.grid.index(atMs: at(14, 18))!, ten = d.grid.index(atMs: at(14, 22))!
        #expect(d.quarters[five].soldW == 1_500 && d.soldShare(five) == 0.75)
        #expect(d.soldShare(six) == 0.25)
        #expect(d.soldShare(ten) == 0 && d.soldShare(d.grid.index(atMs: at(14, 13))!) == 0)
        // The tick keeps its length: the battery's whole power.
        #expect(abs(d.reach(five)! - 2.0 / 3) < 1e-9)
        #expect(d.doing[five] == "DISCHARGES · SELLS 1.5 KW")
        #expect(d.doing[six] == "DISCHARGES · SELLS 500 W")
        #expect(d.what(five).hasPrefix("Battery discharges 2.0 kW, selling 1.5 kW"))
        // The plan without the meter's watts sells nothing.
        let bare = dial()
        #expect(bare.soldShare(five) == 0 && bare.doing[five] == "DISCHARGES · 2.0 KW")
    }

    /// Every word has Swedish, with as many blanks as the English.
    @Test func everyWordHasSwedish() throws {
        let url = try #require(Words.bundle.url(forResource: "Dial", withExtension: "strings", subdirectory: nil, localization: "sv"))
        let sv = try #require(NSDictionary(contentsOf: url) as? [String: String])
        for word in DialWord.allCases {
            let swedish = try #require(sv[word.rawValue], "no Swedish for \"\(word.rawValue)\"")
            #expect(!swedish.isEmpty)
            #expect(word.rawValue.components(separatedBy: "%@").count == swedish.components(separatedBy: "%@").count, "\(word.rawValue)")
        }
    }
}
