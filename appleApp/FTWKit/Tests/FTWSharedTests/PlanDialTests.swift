import Foundation
import Testing
@testable import FTWShared

/// The plan dial as the phone, its widget and the watch draw it: half a
/// day to a face, a finger round the ring, the sun from the box's forecast
/// and the words a finger reads. The plan and prices are `WatchTests`': from Wednesday
/// 12:00 the battery gives power 17–19 and stores 22:00–23:30, the car
/// charges 01:00–04:45 toward 80 %, and power costs 30 öre 02–04, 160 öre
/// 17–21 and 70 öre otherwise.
@Suite struct PlanDialTests {
    let watch = WatchTests()
    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Double { watch.at(day, hour, minute) }
    func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 || abs(abs(a - b) - 2 * .pi) < 1e-9 }

    /// Now's half day, or with `page` nil the twelve hours from now.
    func dial(at t: Double? = nil, daylight: PlanEntry.Daylight? = nil, page: Int? = 0) -> PlanDial {
        var plan = watch.plan()
        plan.daylight = daylight
        return PlanDial(plan: plan, prices: watch.prices(), nowMs: t ?? at(14, 12, 7), page: page)
    }

    /// Where a finger at quarter `i`'s middle sits, `r` from the centre.
    func finger(_ d: PlanDial, _ i: Int, r: Double = 120) -> (x: Double, y: Double) {
        let a = d.angle(quarter: i)
        return (r * sin(a), -r * cos(a))
    }

    /// A face is half a day, noon to midnight or midnight to noon, with its
    /// seam at the top. Now's face keeps the hours gone by: the plan starts
    /// at now's quarter.
    @Test func aFaceIsHalfADay() {
        let d = dial(at: at(14, 17, 34))
        #expect(d.grid.firstMs == at(14, 12) && d.grid.toMs == at(15, 0) && d.turn == 48)
        #expect(near(d.seam, 0))
        #expect(d.nowIndex == 22 && d.first == 22)
        #expect(d.times[22] == "17:34" && d.times[23] == "17:45")
        #expect(near(d.handAngle(selected: nil), d.angle(at(14, 17, 34))) && d.hasHand(selected: nil))
        // Before now the plan says nothing.
        #expect(d.quarters[10].batteryW == nil && d.quarters[10].minor == nil && d.reach(10) == nil)
        #expect(d.quarters[22].battery == .gives && d.landmarks.contains(22))
        // The next face is tonight's, midnight to noon: no hand until a
        // finger chooses, and its name over the span.
        let night = dial(at: at(14, 17, 34), page: 1)
        #expect(night.grid.firstMs == at(15, 0) && night.grid.toMs == at(15, 12))
        #expect(night.nowIndex == nil && night.first == 0 && !night.hasHand(selected: nil) && night.hasHand(selected: 4))
        #expect(night.span == "00–12" && night.faceName == "TOMORROW 00–12" && night.day(0) == "TOMORROW")
        #expect(night.quarters[night.grid.index(atMs: at(15, 2))!].car)
        // In the morning the face is midnight to noon, and the next one
        // this afternoon's.
        let morning = dial(at: at(14, 8), page: 1)
        #expect(morning.grid.firstMs == at(14, 12) && morning.span == "12–24" && morning.faceName == "12–24")
        #expect(dial(at: at(14, 8)).span == "00–12")
    }

    /// A clock: 18 straight down and every hour of the half round the rim,
    /// the ones gone by marked so.
    @Test func theHoursSitWhereAClockHasThem() {
        let d = dial(at: at(14, 17, 34))
        #expect(near(d.angle(at(14, 18)), .pi))
        #expect(near(d.angle(at(14, 15)), .pi / 2))
        #expect(near(d.angle(at(14, 21)), 1.5 * .pi))
        #expect(near(d.angle(at(15, 0)), 0))
        #expect(d.hours.map(\.label) == ["12", "13", "14", "15", "16", "17", "18", "19", "20", "21", "22", "23"])
        #expect(near(d.hours.first { $0.label == "18" }!.angle, .pi))
        #expect(d.hours.filter(\.past).map(\.label) == ["12", "13", "14", "15", "16"])
        // Tonight's face: 00 at the top, 06 at the foot, none gone by.
        let night = dial(at: at(14, 17, 34), page: 1)
        #expect(night.hours.first?.label == "00" && night.hours.contains { $0.label == "06" && near($0.angle, .pi) })
        #expect(night.hours.allSatisfy { !$0.past })
    }

    /// The faces follow the plan to the end of tomorrow, and the Crown runs
    /// across them a quarter at a time.
    @Test func theFacesFollowThePlan() {
        let bounds = PlanDial.pages(plan: watch.plan(), prices: watch.prices(), nowMs: at(14, 17, 34))
        #expect(bounds == [at(14, 12), at(15, 0), at(15, 12), at(16, 0)])
        // Prices for today only: the plan's car still reaches tonight.
        #expect(PlanDial.pages(plan: watch.plan(), prices: watch.prices(days: 1), nowMs: at(14, 17, 34)) == [at(14, 12), at(15, 0), at(15, 12)])
        // Nothing ahead still has now's face.
        #expect(PlanDial.pages(plan: nil, prices: nil, nowMs: at(14, 17, 34)) == [at(14, 12), at(15, 0)])
        // Never past tomorrow, even with a plan that runs on.
        var long = watch.plan()
        long.battery = [PlanEntry.Slot(startMs: at(14, 8), durationMs: 72 * 3_600_000, batteryW: 0, reason: "test")]
        #expect(PlanDial.pages(plan: long, prices: nil, nowMs: at(14, 8)).last == at(16, 0))
        let now = at(14, 17, 34)
        #expect(PlanDial.steps(faces: bounds, nowMs: now) == 26 + 96)
        func step(_ q: Int) -> [Double] {
            let s = PlanDial.step(q, faces: bounds, nowMs: now)
            return [Double(s.page), s.atMs]
        }
        #expect(step(0) == [0, now])
        #expect(step(25) == [0, at(14, 23, 45)])
        #expect(step(26) == [1, at(15, 0)])
        #expect(step(121) == [2, at(15, 23, 45)])
    }

    /// The night the clocks go back, the morning's face holds 13 hours.
    @Test func theNightTheClocksGoBack() {
        let d = PlanDial(plan: nil, prices: watch.prices(), nowMs: at(25, 1), page: 0)
        #expect(d.grid.firstMs == at(25, 0) && d.turn == 52)
    }

    /// A swipe sideways across the middle turns the face once it has gone
    /// 40 pt, mostly sideways.
    @Test func aSwipeTurnsTheFace() {
        #expect(FaceSwipe.step(CGSize(width: -41, height: 10)) == 1)
        #expect(FaceSwipe.step(CGSize(width: 45, height: -20)) == -1)
        #expect(FaceSwipe.step(CGSize(width: -30, height: 0)) == nil)
        #expect(FaceSwipe.step(CGSize(width: -50, height: 40)) == nil)
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

    /// On now's face the hours gone by read nothing: a finger there stays
    /// on now, or on the last quarter where the seam is nearer.
    @Test func theHoursGoneByStayOnNow() {
        let d = dial(at: at(14, 17, 34))
        let early = finger(d, 10), late = finger(d, 15)
        #expect(d.index(x: early.x, y: early.y, from: nil) == 47)
        #expect(d.index(x: late.x, y: late.y, from: nil) == 22)
        #expect(d.index(x: finger(d, 30).x, y: finger(d, 30).y, from: 29) == 30)
        // Coming from now across the past, it stays at now.
        #expect(d.index(x: late.x, y: late.y, from: 23) == 22)
    }

    /// Past the seam the finger winds no further: from the end it stays on
    /// the last quarter, from now on the first.
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
        // Round the face from its top: from now to sunset, 22 quarters on.
        let quarter = 2 * Double.pi / 48
        #expect(d.sunAlong.count == 1)
        #expect(abs(d.sunAlong[0].lowerBound - 7.0 / 15 * quarter) < 1e-9)
        #expect(abs(d.sunAlong[0].upperBound - 22 * quarter) < 1e-9)
        // At 02:07 the morning's face holds the sun from 07:45 to noon.
        let night = dial(at: at(15, 2, 7), daylight: day)
        #expect(night.sunAlong.count == 1)
        #expect(abs(night.sunAlong[0].lowerBound - 31 * quarter) < 1e-9)
        #expect(abs(night.sunAlong[0].upperBound - 2 * .pi) < 1e-9)
        // At 18:07 the sun has set on this face; tomorrow morning's has it.
        #expect(dial(at: at(14, 18, 7), daylight: day).sunAlong.isEmpty)
        #expect(dial(at: at(14, 18, 7), daylight: day, page: 1).sun == [at(15, 7, 45)...at(15, 12)])
        // A sun that never sets fills the face from now.
        let polar = PlanEntry.Daylight(covered: .init(fromMs: at(14, 0), toMs: at(16, 0)), sun: [.init(fromMs: at(14, 0), toMs: at(16, 0))])
        let whole = dial(at: at(14, 18, 7), daylight: polar).sunAlong
        #expect(whole.count == 1 && abs(whole[0].lowerBound - (24 + 7.0 / 15) * quarter) < 1e-9 && abs(whole[0].upperBound - 2 * .pi) < 1e-9)
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
        #expect(PlanEntry.Daylight([]) == nil)
    }

    @Test func theMiddleAndTheScrubLineAreMadeOnce() {
        let d = dial(at: at(14, 17, 7), page: nil)
        let six = d.grid.index(atMs: at(14, 18))!, ten = d.grid.index(atMs: at(14, 22))!, goal = d.grid.index(atMs: at(15, 4, 30))!
        #expect(d.times[0] == "17:07" && d.times[six] == "18:00")
        // Past midnight the day stands apart from the time, so neither is
        // cut to fit the middle.
        #expect(d.times[goal] == "04:30" && d.day(goal) == "TOMORROW")
        #expect(d.when(goal) == "TOMORROW 04:30" && d.when(six) == "18:00")
        #expect(d.day(six) == nil && d.day(d.tomorrowFrom - 1) == nil)
        #expect(d.times[d.tomorrowFrom] == "00:00")
        #expect(d.prices[six] == "160 ÖRE/KWH")
        #expect(d.doing[six] == "GIVES · 2.0 KW")
        #expect(d.doing[ten] == "STORES · 3.0 KW")
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
        #expect(d.doing[0] == "GIVES · 2.0 KW")
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
        #expect(d.doing[ten] == "STORES · 3.0 KW · \(50 + ten % 40)\u{00A0}%")
        #expect(d.what(ten) == "Battery stores 3.0 kW · \(50 + ten % 40)\u{00A0}%")
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
