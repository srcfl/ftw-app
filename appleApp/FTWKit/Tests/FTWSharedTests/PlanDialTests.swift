import Foundation
import Testing
@testable import FTWShared

/// The plan dial, worked out from a `PlanEntry` alone. Times are
/// Stockholm's; 13 October 2026 is a Tuesday, and 25 October the night the
/// clocks go back. These read English: the tests run in the development
/// language.
@Suite struct PlanDialTests {
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

    /// Hourly prices from Tuesday's midnight for `hours`; the plan from
    /// 16:10 for a day: the battery gives power 17 to 19, charges 01 to 04
    /// on Wednesday, rests otherwise; the car charges 02:00 to 04:30.
    func entry(priceHours: Int = 48, daylight: PlanEntry.Daylight? = nil) -> PlanEntry {
        let midnight = at(13, 0)
        func price(_ i: Int) -> Double {
            switch i % 24 {
            case 18: return 200
            case 2, 3: return 20
            default: return 80
            }
        }
        let prices = (0..<priceHours).map { (i: Int) -> PriceSlot in
            PriceSlot(startMs: midnight + Double(i) * Self.hour, durationMs: Self.hour, spotMinor: 50, totalMinor: price(i))
        }
        let from = at(13, 16, 10)
        var battery = [PlanEntry.Slot(startMs: from, durationMs: at(13, 16, 15) - from, batteryW: 0, reason: "idle")]
        var t = at(13, 16, 15)
        while t < at(14, 16, 15) {
            let h = calendar.component(.hour, from: Date(timeIntervalSince1970: t / 1000))
            let w: Double = h >= 17 && h < 19 ? -2_000 : (h >= 1 && h < 4 ? 3_000 : 40)
            battery.append(PlanEntry.Slot(startMs: t, durationMs: Self.quarter, batteryW: w, reason: w > 100 ? "cheap_import" : (w < -100 ? "expensive_import" : "idle")))
            t += Self.quarter
        }
        return PlanEntry(
            battery: battery,
            charges: [PlanEntry.Charge(loadpointID: "garage", fromMs: at(14, 2), toMs: at(14, 4, 30), energyWh: 20_000, targetPct: 80)],
            prices: prices,
            currency: "SEK",
            boxStale: false,
            timeZone: "Europe/Stockholm",
            daylight: daylight
        )
    }

    // MARK: The sun's path

    @Test func midnightAtTheBottomNoonAtTheTopUpOnTheLeft() {
        func near(_ p: (x: Double, y: Double), _ x: Double, _ y: Double) -> Bool { abs(p.x - x) < 1e-9 && abs(p.y - y) < 1e-9 }
        // Screen axes: y grows downward.
        #expect(near(PlanDial.unit(0), 0, 1))
        #expect(near(PlanDial.unit(0.25), -1, 0))
        #expect(near(PlanDial.unit(0.5), 0, -1))
        #expect(near(PlanDial.unit(0.75), 1, 0))
        // The morning rises on the left and the evening falls on the right.
        #expect(PlanDial.unit(9.0 / 24).y < PlanDial.unit(6.0 / 24).y)
        #expect(PlanDial.unit(9.0 / 24).x < 0)
        #expect(PlanDial.unit(15.0 / 24).x > 0)
        #expect(PlanDial.unit(21.0 / 24).y > PlanDial.unit(18.0 / 24).y)
        for f in stride(from: 0.0, to: 1, by: 0.03125) {
            let u = PlanDial.unit(f)
            #expect(abs(PlanDial.dayFraction(x: u.x * 0.6, y: u.y * 0.6) - f) < 1e-9)
        }
    }

    @Test func aBarNeverReachesTheTurnOutsideIt() {
        let L = PlanDial.Layout.self
        #expect(L.bar < L.turn)
        #expect(L.spiral(2) + L.bar < L.rim - L.band / 2)
        #expect(L.battery + L.batteryWidth / 2 < L.spiral(0) - L.barInward)
    }

    // MARK: The face

    @Test func todayInsideTomorrowOutsideAQuarterABar() {
        let face = PlanDial.face(entry(), nowMs: at(13, 16, 20))
        #expect(face.quarters.count == 192)
        #expect(face.dayStartMs == at(13, 0) && face.tomorrowStartMs == at(14, 0) && face.endMs == at(15, 0))
        #expect(face.quarters.filter { $0.turn == 0 }.count == 96)
        #expect(face.quarters[0].minuteOfDay == 0 && face.quarters[95].minuteOfDay == 23 * 60 + 45)
        #expect(face.quarters[96].turn == 1 && face.quarters[96].minuteOfDay == 0)
        #expect(face.tomorrowPriced)
        // Each quarter of an hourly price stands as tall as that hour.
        #expect(face.quarters[72...75].allSatisfy { $0.priceMinor == 200 })
        #expect(face.scale == 200)
        #expect(face.index(at: at(13, 16, 20)) == 65)
        #expect(face.index(at: at(12, 23)) == nil)
    }

    @Test func theColourIsWhatThePlanDoesWithTheBattery() {
        let face = PlanDial.face(entry(), nowMs: at(13, 16, 20))
        func q(_ day: Int, _ h: Int, _ m: Int = 0) -> PlanDial.Quarter { face.quarters[face.index(at: at(day, h, m))!] }
        // Before the plan there is no plan: a price, no colour.
        #expect(q(13, 9).action == .unplanned && q(13, 9).priceMinor == 80)
        // The quarter the plan was made in is the plan's.
        #expect(q(13, 16).action == .wait)
        #expect(q(13, 17, 30).action == .use && q(13, 17, 30).reason == "expensive_import")
        #expect(q(14, 2).action == .store)
        #expect(q(14, 12).action == .wait)
        // Past the plan's end, again nothing.
        #expect(q(14, 20).action == .unplanned)
        // The car: 02:00 to 04:30, ten quarters.
        #expect(face.quarters.filter(\.car).count == 10)
        #expect(q(14, 2).car && q(14, 4, 15).car && !q(14, 4, 30).car)
    }

    @Test func noPricesForTomorrowLeaveTheOuterTurnEmpty() {
        let face = PlanDial.face(entry(priceHours: 24), nowMs: at(13, 11))
        #expect(!face.tomorrowPriced)
        #expect(face.quarters.filter { $0.turn == 1 }.allSatisfy { $0.priceMinor == nil })
        // Never a bar without a price; the plan's own colour stays, for
        // the finger to read.
        #expect(PlanDial.tomorrowNote(face, nowMs: at(13, 11)) == "Tomorrow's prices come around 13:00")
        #expect(PlanDial.tomorrowNote(face, nowMs: at(13, 15)) == "Tomorrow's prices are not in yet")
        #expect(PlanDial.tomorrowNote(face, nowMs: at(13, 11), short: true) == "Prices around 13:00")
        #expect(PlanDial.tomorrowNote(PlanDial.face(entry(), nowMs: at(13, 15)), nowMs: at(13, 15)) == nil)
        // Before any price at all there is nothing to say.
        #expect(PlanDial.tomorrowNote(PlanDial.face(entry(priceHours: 0), nowMs: at(13, 11)), nowMs: at(13, 11)) == nil)
    }

    @Test func theNightTheClocksGoBackHasTwentyFiveHours() {
        var e = entry()
        e.prices = []
        e.battery = nil
        e.charges = []
        let face = PlanDial.face(e, nowMs: at(25, 12))
        // Sunday has 100 quarters, Monday 96.
        #expect(face.quarters.count == 196)
        #expect(face.quarters.filter { $0.turn == 0 }.count == 100)
        // 02:00 to 03:00 comes twice and stands at the same place.
        let twos = face.quarters.filter { $0.turn == 0 && $0.minuteOfDay == 120 }
        #expect(twos.count == 2)
        #expect(face.reach == nil)
    }

    /// A finger finds its quarter in one lookup, on the nights the clocks
    /// change too: the hour that comes twice gives its first quarters, the
    /// hour that never comes gives the quarter before it.
    @Test func aFingerFindsItsQuarterOnTheNightsTheClocksChange() {
        func prices(from start: Double) -> [PriceSlot] {
            (0..<200).map { PriceSlot(startMs: start + Double($0) * Self.quarter, durationMs: Self.quarter, spotMinor: 50, totalMinor: 80) }
        }
        var back = entry()
        back.prices = prices(from: at(25, 0))
        let autumn = PlanDial.face(back, nowMs: at(25, 12))
        let first = autumn.quarters.firstIndex { $0.minuteOfDay == 150 }
        #expect(autumn.index(atProgress: 152.0 / 1440) == first)
        #expect(autumn.quarters[autumn.index(atProgress: 12.1 / 24)!].minuteOfDay == 720)

        var spring = calendar
        spring.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        let march = spring.date(from: DateComponents(year: 2026, month: 3, day: 29))!.timeIntervalSince1970 * 1000
        var forward = entry()
        forward.prices = prices(from: march)
        let face = PlanDial.face(forward, nowMs: march + 12 * Self.hour, calendar: spring)
        #expect(face.quarters.filter { $0.turn == 0 }.count == 92)
        let skipped = face.index(atProgress: 152.0 / 1440)!
        #expect(face.quarters[skipped].minuteOfDay == 105)
        #expect(face.quarters[face.index(atProgress: 3.1 / 24)!].minuteOfDay == 180)
    }

    // MARK: A finger

    @Test func aFingerGoesOnRoundPastMidnight() {
        let L = PlanDial.Layout.self
        func spot(_ f: Double, _ r: Double) -> (Double, Double) {
            let u = PlanDial.unit(f)
            return (u.x * r, u.y * r)
        }
        // Coming down, the turn whose bars are nearest.
        let inner = spot(0.9, L.spiral(0.9) + L.bar / 2)
        #expect(abs(PlanDial.progress(x: inner.0, y: inner.1, from: nil) - 0.9) < 1e-9)
        let outer = spot(0.3, L.spiral(1.3) + L.bar / 2)
        #expect(abs(PlanDial.progress(x: outer.0, y: outer.1, from: nil) - 1.3) < 1e-9)
        // Moving on past the bottom carries on into tomorrow, whatever the
        // radius, and back again.
        let past = spot(0.05, 0.4)
        let p = PlanDial.progress(x: past.0, y: past.1, from: 0.97)
        #expect(abs(p - 1.05) < 1e-9)
        let back = spot(0.95, 0.9)
        #expect(abs(PlanDial.progress(x: back.0, y: back.1, from: p) - 0.95) < 1e-9)
    }

    @Test func theFingerStaysWhereThereIsAPriceOrAPlan() {
        let face = PlanDial.face(entry(priceHours: 24), nowMs: at(13, 16, 20))
        // Today's prices from midnight, the plan into Wednesday afternoon.
        let reach = try! #require(face.reach)
        #expect(reach.lowerBound == 0)
        #expect(face.quarters[reach.upperBound].startMs == at(14, 16))
        #expect(face.index(atProgress: 1.99) == reach.upperBound)
        #expect(face.index(atProgress: 0.505) == face.index(at: at(13, 12)))
        #expect(face.index(atProgress: -0.2) == 0)
    }

    @Test func voiceOverStepsByTheHourFromNow() {
        let face = PlanDial.face(entry(), nowMs: at(13, 16, 20))
        let stops = face.hourStops(nowMs: at(13, 16, 20))
        #expect(stops.count == 48 + 1)
        #expect(stops.contains(65))
        #expect(stops.filter { $0 != 65 }.allSatisfy { face.quarters[$0].minuteOfDay % 60 == 0 })
        #expect(stops == stops.sorted())
        // From now an hour on, then back to now, and back to the hour before.
        #expect(face.step(from: nil, forward: true, nowMs: at(13, 16, 20)) == face.index(at: at(13, 17)))
        #expect(face.step(from: face.index(at: at(13, 17)), forward: false, nowMs: at(13, 16, 20)) == 65)
        #expect(face.step(from: 65, forward: false, nowMs: at(13, 16, 20)) == face.index(at: at(13, 16)))
        // The ends stop.
        #expect(face.step(from: stops.last, forward: true, nowMs: at(13, 16, 20)) == nil)
        #expect(face.step(from: 0, forward: false, nowMs: at(13, 16, 20)) == nil)
    }

    @Test func theCheapestHoursAreLandmarks() {
        let face = PlanDial.face(entry(), nowMs: at(13, 16, 20))
        let cheapest = try! #require(face.cheapest)
        #expect(cheapest.fromMs == at(14, 2) && cheapest.toMs == at(14, 4))
        #expect(face.edgesCheapest(face.index(at: at(14, 2))!))
        #expect(face.edgesCheapest(face.index(at: at(14, 3, 45))!))
        #expect(!face.edgesCheapest(face.index(at: at(14, 3))!))
    }

    // MARK: The sky and the middle

    @Test func theSkyComesFromTheBoxsForecastOnly() {
        #expect(PlanDial.face(entry(), nowMs: at(13, 16)).sky(nowMs: at(13, 16)).covered.isEmpty)
        // Forecast slots from 16:00 for a day: sun until 17:30, again 07:30
        // to 17:30 on Wednesday.
        var slots = [(startMs: Double, durationMs: Double, pvW: Double)]()
        var t = at(13, 16)
        while t < at(14, 16) {
            let date = Date(timeIntervalSince1970: t / 1000)
            let h: Double = Double(calendar.component(.hour, from: date)) + Double(calendar.component(.minute, from: date)) / 60
            let pv: Double = h >= 7.5 && h < 17.5 ? 1_200 : 0
            slots.append((startMs: t, durationMs: Self.quarter, pvW: pv))
            t += Self.quarter
        }
        let daylight = try! #require(PlanEntry.Daylight(slots))
        #expect(daylight.covered == PlanEntry.Span(fromMs: at(13, 16), toMs: at(14, 16)))
        #expect(daylight.sun == [PlanEntry.Span(fromMs: at(13, 16), toMs: at(13, 17, 30)), PlanEntry.Span(fromMs: at(14, 7, 30), toMs: at(14, 16))])
        let sky = PlanDial.face(entry(daylight: daylight), nowMs: at(13, 16)).sky(nowMs: at(13, 16))
        // The 24 hours from now round the rim: the whole ring, in two arcs
        // cut at midnight.
        #expect(sky.covered.count == 2)
        #expect(abs(sky.covered[0].lowerBound - 16.0 / 24) < 1e-9 && abs(sky.covered[0].upperBound - 1) < 1e-9)
        #expect(abs(sky.covered.map { $0.upperBound - $0.lowerBound }.reduce(0, +) - 1) < 1e-9)
        // Sun from now to 17:30 and from 07:30 round to now.
        #expect(sky.sun.count == 2)
        #expect(abs(sky.sun[1].lowerBound - 7.5 / 24) < 1e-9 && abs(sky.sun[1].upperBound - 16.0 / 24) < 1e-9)
    }

    @Test func theMiddleIsTheClockAndThePriceThere() {
        let face = PlanDial.face(entry(), nowMs: at(13, 18, 7))
        let now = PlanDial.centre(face, nowMs: at(13, 18, 7))
        #expect(now.time == "18:07" && now.price == "200" && now.unit == "öre/kWh" && now.day == nil)
        let night = PlanDial.centre(face, nowMs: at(13, 18, 7), selected: face.index(at: at(14, 2, 15)))
        #expect(night.time == "02:15" && night.price == "20.0" && night.day == "Tomorrow")
    }

    @Test func aRecordWithoutTheNewFieldsStillReads() throws {
        var e = entry()
        e.daylight = nil
        e.batteryLevel = nil
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(e)) as! [String: Any]
        json.removeValue(forKey: "daylight")
        json.removeValue(forKey: "batteryLevel")
        let back = try JSONDecoder().decode(PlanEntry.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(back == e)
    }
}
