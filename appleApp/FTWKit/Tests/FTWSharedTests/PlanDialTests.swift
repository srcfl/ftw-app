import Foundation
import Testing
@testable import FTWShared

/// The plan dial as the phone, its widget and the watch draw it: the seam,
/// a finger round the ring, the sun from the box's forecast and the words
/// a finger reads. The plan and prices are `WatchTests`': from Wednesday
/// 12:00 the battery gives power 17–19 and stores 22:00–23:30, the car
/// charges 01:00–04:45 toward 80 %, and power costs 30 öre 02–04, 160 öre
/// 17–21 and 70 öre otherwise.
@Suite struct PlanDialTests {
    let watch = WatchTests()
    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Double { watch.at(day, hour, minute) }
    func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 || abs(abs(a - b) - 2 * .pi) < 1e-9 }

    func dial(at t: Double? = nil, daylight: PlanEntry.Daylight? = nil) -> PlanDial {
        var plan = watch.plan()
        plan.daylight = daylight
        return PlanDial(plan: plan, prices: watch.prices(), nowMs: t ?? at(14, 12, 7))
    }

    /// Where a finger at quarter `i`'s middle sits, `r` from the centre.
    func finger(_ d: PlanDial, _ i: Int, r: Double = 120) -> (x: Double, y: Double) {
        let a = d.angle(quarter: i)
        return (r * sin(a), -r * cos(a))
    }

    @Test func theSeamIsWhereTheTurnBegins() {
        let d = dial()
        #expect(near(d.seam, d.angle(at(14, 12))))
        // The hand at now sits just past it, inside the first quarter.
        #expect(d.handAngle(selected: nil) > d.seam)
        #expect(d.handAngle(selected: nil) - d.seam < 2 * .pi / 96)
    }

    @Test func aFingerFindsTheQuarterUnderIt() {
        let d = dial()
        for i in [0, 1, 17, 48, 80, 95] {
            let p = finger(d, i)
            #expect(d.index(x: p.x, y: p.y, from: nil) == i)
            #expect(d.index(x: p.x, y: p.y, from: max(0, i - 1)) == i)
        }
    }

    /// Past the seam the finger winds no further: from the end it stays on
    /// the last quarter, from now on the first.
    @Test func theSeamStopsAFinger() {
        let d = dial()
        let start = finger(d, 0), end = finger(d, 95)
        #expect(d.index(x: start.x, y: start.y, from: 95) == 95)
        #expect(d.index(x: start.x, y: start.y, from: 90) == 95)
        #expect(d.index(x: end.x, y: end.y, from: 0) == 0)
        #expect(d.index(x: end.x, y: end.y, from: 3) == 0)
        // Half a turn on is still an honest move.
        #expect(d.index(x: finger(d, 47).x, y: finger(d, 47).y, from: 1) == 47)
    }

    /// The sky is the box's forecast inside the turn, never astronomy: at
    /// noon the turn holds this afternoon's sun and tomorrow morning's.
    @Test func theSunComesFromTheForecast() {
        let day = PlanEntry.Daylight(covered: .init(fromMs: at(14, 0), toMs: at(16, 0)), sun: [
            .init(fromMs: at(14, 7, 30), toMs: at(14, 17, 30)),
            .init(fromMs: at(15, 7, 45), toMs: at(15, 17, 15)),
        ])
        let d = dial(daylight: day)
        #expect(d.sun == [at(14, 12)...at(14, 17, 30), at(15, 7, 45)...at(15, 12)])
        // Round the turn: this afternoon's sun starts at the seam, not a
        // whole turn on, and tomorrow morning's runs to the end.
        let quarter = 2 * Double.pi / 96
        #expect(d.sunAlong.count == 2)
        #expect(near(d.sunAlong[0].lowerBound, 0) && d.sunAlong[0].lowerBound < quarter)
        #expect(abs(d.sunAlong[0].upperBound - 22 * quarter) < 1e-9)
        #expect(abs(d.sunAlong[1].lowerBound - 79 * quarter) < 1e-9)
        #expect(abs(d.sunAlong[1].upperBound - 2 * .pi) < 1e-9)
        // With the seam at 18:00: tomorrow's sun sits 55 to 93 quarters on.
        let evening = dial(at: at(14, 18, 7), daylight: day)
        #expect(evening.sunAlong.count == 1)
        #expect(abs(evening.sunAlong[0].lowerBound - 55 * quarter) < 1e-9)
        #expect(abs(evening.sunAlong[0].upperBound - 93 * quarter) < 1e-9)
        // A sun that never sets fills the turn.
        let polar = PlanEntry.Daylight(covered: .init(fromMs: at(14, 0), toMs: at(16, 0)), sun: [.init(fromMs: at(14, 0), toMs: at(16, 0))])
        let whole = dial(at: at(14, 18, 7), daylight: polar).sunAlong
        #expect(whole.count == 1 && whole[0].lowerBound == 0 && abs(whole[0].upperBound - 2 * .pi) < 1e-9)
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
        let d = dial()
        let six = d.grid.index(atMs: at(14, 18))!, ten = d.grid.index(atMs: at(14, 22))!, goal = d.grid.index(atMs: at(15, 4, 30))!
        #expect(d.times[0] == "12:07" && d.times[six] == "18:00")
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
        let short = PlanDial(plan: watch.plan(), prices: watch.prices(days: 1), nowMs: at(14, 12))
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
