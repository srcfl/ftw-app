import CoreGraphics
import Foundation
import Testing
@testable import FTWShared

/// History and the hours ahead on the engine (WP7 of the polish release):
/// holes, one scale for several series, Today's fixed day, the ahead
/// picture, and calm on the home box's own days.
@Suite struct HistoryRecipeTests {
    static let clock = ChartGeometryTests.clock
    static let words = ChartGeometryTests.words
    static let size = CGSize(width: 350, height: 240)

    static func day(_ day: Int) -> (fromMs: Double, toMs: Double) {
        HistoryPicture.day(ChartGeometryTests.at(day, 12), clock: clock)
    }

    static func samples(from: Double, count: Int, _ value: (Int) -> Double?) -> [ChartSample] {
        (0..<count).map { ChartSample(startMs: from + Double($0) * 300_000, value: value($0)) }
    }

    // MARK: Holes

    @Test func aHoleOnItsWayIsDashedAndOneWithNoRecordIsNot() {
        let (from, to) = Self.day(13)
        var samples = Self.samples(from: from, count: 288) { 500 + Double($0 % 7) * 30 }
        // 02:00–03:00 on its way; 06:00–07:00 not on record.
        for i in 24..<36 { samples[i] = ChartSample(startMs: samples[i].startMs, value: nil, fetching: true) }
        for i in 72..<84 { samples[i] = ChartSample(startMs: samples[i].startMs, value: nil) }
        let series = ChartSeries.history(samples, fromMs: from, toMs: to, nowMs: to, size: Self.size, clock: Self.clock, words: Self.words)
        #expect(series.grid.stepMs == 1_800_000)
        #expect(series.fetching == [4...5])
        #expect(series.missing == [12...13])
        // One straight estimate across the hole on its way, from slot 3 to 6.
        #expect(series.estimate.elements == [.move(series.points[3]!), .line(series.points[6]!)])
        #expect(series.points[4] == nil && series.points[12] == nil)
        // As on the live trace, a finger feels each end of a run of data.
        #expect(series.readouts.landmarks.isSuperset(of: [0, 3, 6, 11, 14, 47]))
        #expect(!series.readouts.landmarks.contains(4) && !series.readouts.landmarks.contains(12))
    }

    @Test func slotsAfterNowAreNeitherHolesNorData() {
        let (from, to) = Self.day(13)
        let now = from + 9 * 3_600_000 + 10 * 60_000
        let samples = Self.samples(from: from, count: 110) { _ in 800 }
        let series = ChartSeries.history(samples, fromMs: from, toMs: to, nowMs: now, size: Self.size, clock: Self.clock, words: Self.words)
        #expect(series.grid.count == 48)
        #expect(series.missing.isEmpty && series.fetching.isEmpty)
        #expect(series.lastData == 18)
    }

    // MARK: One scale for several series

    @Test func seriesShareOneScaleAndAHiddenOneChangesNothingTheOthersSay() throws {
        let (from, to) = Self.day(13)
        let battery = Self.samples(from: from, count: 288) { Double($0 % 12) * 100 - 400 }
        let solar = Self.samples(from: from, count: 288) { $0 > 80 && $0 < 200 ? 4_500 : 0 }
        let both = HistoryPicture.build([("battery", battery), ("solar", solar)], fromMs: from, toMs: to, nowMs: to, size: Self.size, clock: Self.clock, words: Self.words)
        let alone = HistoryPicture.build([("battery", battery)], fromMs: from, toMs: to, nowMs: to, size: Self.size, clock: Self.clock, words: Self.words)
        #expect(both.domain.upper >= 4_500 && alone.domain.upper < 4_500)
        #expect(both.layers.map(\.key) == ["battery", "solar"])
        #expect(both.layers.allSatisfy { $0.series.domain == both.domain })
        // The battery's readout is the same whether the sun is shown or not.
        let a = try #require(both.layers.first?.series.readouts), b = try #require(alone.layers.first?.series.readouts)
        #expect(a.what == b.what && a.when == b.when && a.inWh == b.inWh)
        // Each series keeps its own band.
        #expect(both.layers.allSatisfy { !$0.series.band.isEmpty })
    }

    @Test func aTileThatLandsMovesEachSlotFromItsOldMeanToItsNewOne() throws {
        let (from, to) = Self.day(13)
        let before = Self.samples(from: from, count: 120) { _ in 500 }
        var after = before
        for i in 108..<120 { after[i].value = 1_500 }
        let a = ChartSeries.history(before, fromMs: from, toMs: to, nowMs: to, size: Self.size, clock: Self.clock, domain: YDomain(lower: 0, upper: 2_000), words: Self.words)
        let b = ChartSeries.history(after, fromMs: from, toMs: to, nowMs: to, size: Self.size, clock: Self.clock, domain: YDomain(lower: 0, upper: 2_000), words: Self.words)
        let start = try #require(b.blended(from: a, progress: 0))
        #expect(start.line == ChartSeries.paths(points: a.points, highs: a.highs, lows: a.lows, baseline: YMap(domain: a.domain, height: Self.size.height).baseline).line)
        let half = try #require(b.blended(from: a, progress: 0.5))
        let ys = half.line.flattened().map(\.y)
        let y500 = YMap(domain: b.domain, height: Self.size.height).y(500), y1500 = YMap(domain: b.domain, height: Self.size.height).y(1_500)
        #expect((ys.min() ?? 0) > y1500 - 1e-6 && (ys.max() ?? 0) < y500 + 1e-6)
        #expect(b.blended(from: a, progress: 1) == nil)
        // Another window or scale morphs nothing: it cross-fades.
        let other = ChartSeries.history(after, fromMs: from, toMs: to, nowMs: to, size: Self.size, clock: Self.clock, domain: YDomain(lower: 0, upper: 3_000), words: Self.words)
        #expect(other.blended(from: a, progress: 0.5) == nil)
    }

    @Test func todayIsAFixedDayFromMidnightToMidnight() {
        let (from, to) = Self.day(13)
        #expect(to - from == 86_400_000)
        // The day the clocks go back is 25 hours long.
        let (a, b) = HistoryPicture.day(ChartGeometryTests.clock.calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 12))!.timeIntervalSince1970 * 1000, clock: Self.clock)
        #expect(b - a == 25 * 3_600_000)
        let now = from + 15 * 3_600_000 + 20 * 60_000
        let picture = HistoryPicture.build([("home", Self.samples(from: from, count: 184) { _ in 600 })], fromMs: from, toMs: to, nowMs: now, size: Self.size, clock: Self.clock, words: Self.words)
        #expect(picture.ticks.map(\.label) == ["00", "06", "12", "18"])
        #expect(picture.limit == 30)
        #expect(picture.asOfMs == nil)
        // An hour without tiles before now says where the data ends.
        let stale = HistoryPicture.build([("home", Self.samples(from: from, count: 160) { _ in 600 })], fromMs: from, toMs: to, nowMs: now, size: Self.size, clock: Self.clock, words: Self.words)
        #expect(stale.asOfMs == from + 160 * 300_000)
        let window = HistoryPicture.twoDays(now)
        #expect(window.toMs - window.fromMs == 48 * 3_600_000 && window.toMs.truncatingRemainder(dividingBy: 300_000) == 0)
    }

    @Test func twoDaysNameEachMidnight() {
        let now = ChartGeometryTests.at(14, 10, 3)
        let (from, to) = HistoryPicture.twoDays(now)
        let picture = HistoryPicture.build([("grid", Self.samples(from: from, count: 576) { _ in 100 })], fromMs: from, toMs: to, nowMs: now, size: Self.size, clock: Self.clock, everyHours: 12, weekday: { _ in "MON" }, words: Self.words)
        #expect(picture.grid.stepMs == 3_600_000)
        #expect(picture.ticks.map(\.label) == ["12", "MON", "12", "MON"])
    }

    // MARK: Ahead

    @Test func thePlanAheadIsGhostSlotsAndAForecastIsAnEstimatedLine() {
        let now = ChartGeometryTests.at(14, 10, 7)
        let start = ChartGeometryTests.at(14, 10)
        func watts(_ i: Int) -> Double { i < 8 ? 3_000 : i < 20 ? -2_000 : 0 }
        var slots: [(startMs: Double, endMs: Double, watts: Double?)] = []
        var prices: [(startMs: Double, endMs: Double, minor: Double)] = []
        for i in 0..<48 {
            let a = start + Double(i) * 900_000
            slots.append((a, a + 900_000, watts(i)))
            prices.append((a, a + 900_000, 40 + Double(i)))
        }
        let plan = AheadPicture.build(kind: .plan, slots: slots, prices: prices, nowMs: now, size: Self.size, floor: 3_000, clock: Self.clock)
        #expect(plan.grid.firstMs == start && plan.grid.count == 48)
        #expect(plan.values[0] == 3_000 && plan.values[10] == -2_000)
        #expect(plan.domain.lower <= -2_000 && plan.domain.upper >= 3_000)
        #expect(plan.line.isEmpty)
        #expect(plan.priceThirds[0] == PriceChart.Third.cheap && plan.priceThirds[47] == PriceChart.Third.dear)
        #expect(plan.priceLevels[0] == 1 && plan.priceLevels[47] == 8)
        #expect(plan.ticks.map(\.label) == ["12", "15", "18", "21"])
        let made: [(startMs: Double, endMs: Double, watts: Double?)] = slots.map { ($0.startMs, $0.endMs, abs($0.watts ?? 0)) }
        let forecast = AheadPicture.build(kind: .forecast, slots: made, prices: [], nowMs: now, size: Self.size, clock: Self.clock)
        #expect(!forecast.line.isEmpty)
        #expect(forecast.priceThirds.allSatisfy { (t: PriceChart.Third?) in t == nil })
    }

    @Test func aNewPlanForTheSameSlotsMovesEachSlotToItsNewValue() throws {
        let now = ChartGeometryTests.at(14, 10, 7)
        let start = ChartGeometryTests.at(14, 10)
        func slots(_ w: @escaping (Int) -> Double?) -> [(startMs: Double, endMs: Double, watts: Double?)] {
            (0..<48).map { i in (start + Double(i) * 900_000, start + Double(i + 1) * 900_000, w(i)) }
        }
        let old = AheadPicture.build(kind: .forecast, slots: slots { _ in 1_000 }, prices: [], nowMs: now, size: Self.size, floor: 3_000, clock: Self.clock)
        let new = AheadPicture.build(kind: .forecast, slots: slots { $0 == 5 ? nil : 2_000 }, prices: [], nowMs: now, size: Self.size, previous: old.domain, floor: 3_000, clock: Self.clock)
        let half = try #require(new.blended(from: old, progress: 0.5))
        #expect(half.values[0] == 1_500 && half.values[5] == nil)
        #expect(!half.line.isEmpty)
        #expect(new.blended(from: old, progress: 1) == nil)
        // A window that moved on draws at once.
        let later = AheadPicture.build(kind: .forecast, slots: slots { _ in 2_000 }, prices: [], nowMs: now + 900_000, size: Self.size, floor: 3_000, clock: Self.clock)
        #expect(later.blended(from: old, progress: 0.5) == nil)
    }

    // MARK: Calm on the home box's days

    struct Days: Decodable {
        var t0_ms: Double
        var series: [String: [[Double]]]
    }

    static func recorded() throws -> Days {
        let url = try #require(Bundle.module.url(forResource: "sungrow-days", withExtension: "json", subdirectory: "Resources"))
        return try JSONDecoder().decode(Days.self, from: Data(contentsOf: url))
    }

    /// Today on the home box, 12 and 13 October 2026, drawn as WP7 does
    /// (30-minute means) and as 0.3.2 did (every five-minute mean through a
    /// monotone curve).
    @Test func todayIsCalmOnTheHomeBoxsOwnDays() throws {
        let days = try Self.recorded()
        for name in ["battery_w", "pv_w", "meter_w"] {
            let rows = try #require(days.series[name])
            let samples = rows.map { ChartSample(startMs: days.t0_ms + $0[0] * 1_000, value: $0[1]) }
            for d in [12, 13] {
                let (from, to) = Self.day(d)
                let series = ChartSeries.history(samples, fromMs: from, toMs: to, nowMs: to, size: CGSize(width: 350, height: 280), floor: 3_000, clock: Self.clock, words: Self.words)
                let turns = Calm.turnsPer100(series.line.flattened(steps: 8))
                let map = YMap(domain: series.domain, height: 280)
                let fine = samples.filter { $0.startMs >= from && $0.startMs < to }.compactMap { s in s.value.map { CGPoint(x: series.grid.x(atMs: s.startMs + 150_000, width: 350), y: map.y($0)) } }
                let before = Calm.turnsPer100(ChartPaths.monotone(fine).flattened(steps: 8))
                #expect(turns <= 12, "\(name) on \(d) Oct: \(turns) turns per 100 pt")
                #expect(turns < before / 2 || before < 4, "\(name) on \(d) Oct: \(turns) against \(before) in 0.3.2")
            }
        }
    }
}
