import CoreGraphics
import Foundation
import Testing
@testable import FTWShared

/// UX pass 3, U4: a tap enlarges, the edge goes back, no empty plot. The
/// finger's rules, the live scale from its own five minutes, Today's ghost
/// of the rest of the day, the forecast's curve, the car's fixed scale, the
/// gutter, the corner words and the price view's plan line.
@Suite struct ChartFingerTests {
    static let clock = ChartGeometryTests.clock
    static let words = ChartGeometryTests.words
    static let size = CGSize(width: 350, height: 240)

    // MARK: Tap or scrub

    @Test func aTouchThatLiftsSoonAndStillIsATapAndNeverAScrub() {
        var touch = TouchIntent(at: CGPoint(x: 100, y: 80), ms: 1_000)
        #expect(touch.moved(to: CGPoint(x: 103, y: 82), atMs: 1_060) == .waiting)
        #expect(touch.held(atMs: 1_140) == .waiting)
        #expect(touch.lifted() == .tap)
    }

    @Test func sixPointsOrAHundredAndFiftyMillisecondsStartTheScrub() {
        var moved = TouchIntent(at: CGPoint(x: 100, y: 80), ms: 0)
        #expect(moved.moved(to: CGPoint(x: 105.9, y: 80), atMs: 40) == .waiting)
        #expect(moved.moved(to: CGPoint(x: 106, y: 80), atMs: 50) == .scrub)
        // Once it scrubs, a lift is the end of a scrub, not a tap.
        #expect(moved.lifted() == .scrub)

        var held = TouchIntent(at: CGPoint(x: 100, y: 80), ms: 0)
        #expect(held.held(atMs: 149) == .waiting)
        #expect(held.held(atMs: 150) == .scrub)

        var two = TouchIntent(at: CGPoint(x: 100, y: 80), ms: 0)
        #expect(two.moved(to: CGPoint(x: 100, y: 80), atMs: 10, fingers: 2) == .scrub)
    }

    @Test func theTouchesNearTheLeadingEdgeAreTheBackSwipes() {
        // The node chart sits 4 pt in, the price 16, the style scale 16.
        #expect(EdgeRule.inset(minX: 4) == 16)
        #expect(EdgeRule.inset(minX: 16) == 4)
        #expect(EdgeRule.inset(minX: 20) == 0)
        #expect(EdgeRule.inset(minX: 120) == 0)
        #expect(EdgeRule.inset(minX: .nan) == 0)
    }

    @Test func theRingScrubsAlongItAndTheScrollTakesUpAndDown() {
        let c = CGPoint(x: 170, y: 170)
        let top = CGPoint(x: 170, y: 20), left = CGPoint(x: 20, y: 170), upperRight = CGPoint(x: 276, y: 64)
        // Too soon to tell.
        #expect(RingIntent.decide(start: top, now: CGPoint(x: 173, y: 21), centre: c, heldMs: 40) == nil)
        // Along the ring at the top: sideways.
        #expect(RingIntent.decide(start: top, now: CGPoint(x: 180, y: 21), centre: c, heldMs: 40) == .scrub)
        // At the top, straight down is across the ring: the page's.
        #expect(RingIntent.decide(start: top, now: CGPoint(x: 171, y: 34), centre: c, heldMs: 40) == .pass)
        // At the left, up or down runs along the ring but is a scroll.
        #expect(RingIntent.decide(start: left, now: CGPoint(x: 21, y: 150), centre: c, heldMs: 40) == .pass)
        // Half way round, along the ring and as much sideways as down.
        #expect(RingIntent.decide(start: upperRight, now: CGPoint(x: 284, y: 72), centre: c, heldMs: 40) == .scrub)
        // A finger that rests 0.1 s scrubs, wherever it goes next.
        #expect(RingIntent.decide(start: left, now: left, centre: c, heldMs: 100) == .scrub)
        #expect(RingIntent.decide(start: left, now: CGPoint(x: 21, y: 150), centre: c, heldMs: 120) == .scrub)
    }

    // MARK: The live scale

    static let liveSize = CGSize(width: 350, height: 280)

    static func steady(_ watts: (Int) -> Double, seconds: Int = 300, now: Double = 1_000_000) -> [LiveSample] {
        (0..<seconds).map { LiveSample(t: now - Double(seconds - 1 - $0) * 1_000, v: watts($0)) }
    }

    static func build(_ frames: [LiveSample], previous: YDomain? = nil) -> LiveSeries {
        LiveSeries.build(frames, sourceGapMs: 3_500, windowMs: 300_000, nowMs: frames.last!.t, size: liveSize, previous: previous, floor: 3_000, restW: 42)
    }

    @Test func a450WattBatteryFillsMostOfThePlot() throws {
        let series = Self.build(Self.steady { 440 + Double($0 % 3) * 5 })
        #expect(series.domain == YDomain(lower: 0, upper: 500))
        #expect(!series.atRest)
        let head = try #require(series.head)
        // The reading spans at least half the plot, from zero at the foot.
        #expect(series.map.baseline - head.y >= Self.liveSize.height / 2)
        // The old rule, on the node's 3 kW floor, kept it in the bottom sixth.
        let floored = LiveSeries.build(Self.steady { 440 + Double($0 % 3) * 5 }, sourceGapMs: 3_500, windowMs: 300_000, nowMs: 1_000_000, size: Self.liveSize, floor: 3_000)
        #expect(floored.domain.upper == 3_000)
    }

    @Test func oneSignKeepsZeroAtTheEdgeAndABlipAtRestOpensNoSecondSide() {
        let series = Self.build(Self.steady { $0 == 120 ? -6 : 2_400 })
        #expect(series.domain.lower == 0 && series.domain.upper == 3_000)
        let both = Self.build(Self.steady { $0 < 150 ? 1_200 : -800 })
        #expect(both.domain == YDomain(lower: -1_000, upper: 1_500))
    }

    @Test func aSourceAtRestPutsZeroMidPlot() {
        let night = Self.build(Self.steady { _ in 0 })
        #expect(night.atRest)
        #expect(night.domain == YDomain(lower: -50, upper: 50))
        #expect(abs(night.map.baseline - Self.liveSize.height / 2) < 1e-9)
        // A battery that idles a few watts either way rests too.
        #expect(Self.build(Self.steady { Double($0 % 7) * 6 - 18 }).atRest)
        // The rest scale is not held once the source moves; the scale
        // grows at once and holds while the data fills it.
        let woke = Self.build(Self.steady { $0 < 280 ? 0 : 900 }, previous: night.domain)
        #expect(!woke.atRest && woke.domain == YDomain(lower: 0, upper: 1_000))
        let held = Self.build(Self.steady { _ in 700 }, previous: woke.domain)
        #expect(held.domain == woke.domain)
        // The trace without a rest keeps the node's floor: the watch's.
        let watch = LiveSeries.build(Self.steady { _ in 0 }, sourceGapMs: 3_500, windowMs: 300_000, nowMs: 1_000_000, size: Self.liveSize, floor: 3_000)
        #expect(!watch.atRest && watch.domain == YDomain(lower: 0, upper: 3_000))
    }

    // MARK: Gutter and corner words

    @Test func theGutterHoldsTheWidestLabelWhole() {
        // 0.4.3 gave 32 pt at 10 pt, and "20 kW" lost its W.
        let gutter = ChartGutter.trailing(ChartGutter.scaleLabels(YDomain(lower: -15_000, upper: 20_000)), size: 10)
        #expect(gutter >= ChartGutter.gap + 5 * 6.18)
        #expect(gutter < 40)
        #expect(ChartGutter.scaleLabels(YDomain(lower: 0, upper: 3_000)) == ["3 kW", "1 kW", "2 kW"])
        #expect(ChartGutter.trailing(["1,5 kW"], size: 10) > ChartGutter.trailing(["3 kW"], size: 10))
    }

    /// Anders, 28 Oct 2026: "a few lines on the y-axis". Up to two round
    /// rungs between the ends, never zero, never an end.
    @Test func aScaleIsMarkedAtUpToTwoRoundRungs() {
        #expect(YDomain(lower: -2_000, upper: 7_500).rungs == [2_500, 5_000])
        #expect(YDomain(lower: 0, upper: 3_000).rungs == [1_000, 2_000])
        #expect(YDomain(lower: 0, upper: 1_000).rungs == [500])
        #expect(YDomain(lower: 0, upper: 7_500).rungs == [2_500, 5_000])
        #expect(YDomain(lower: -15_000, upper: 20_000).rungs == [-10_000, 10_000])
        #expect(YDomain(lower: -1_000, upper: 1_000).rungs == [-500, 500])
        // −2.5 kW would sit on top of the −3 kW end.
        #expect(YDomain(lower: -3_000, upper: 5_000).rungs == [2_500])
        #expect(YDomain(lower: 0, upper: 0).rungs.isEmpty)
        for d in [YDomain(lower: -2_000, upper: 7_500), YDomain(lower: 0, upper: 150), YDomain(lower: -300, upper: 20_000)] {
            #expect(d.rungs.count <= 2)
            #expect(d.rungs.allSatisfy { $0 != 0 && $0 > d.lower && $0 < d.upper })
        }
    }

    @Test func aDirectionWordStaysOffTheLine() {
        let map = YMap(domain: YDomain(lower: -1_000, upper: 1_000), height: 200)
        // A grid that sells 950 W at the left runs through "↓ SELLING".
        let selling = (0..<40).map { ChartReach(x: CGFloat($0) * 9, low: $0 < 8 ? -950 : 100, high: $0 < 8 ? -950 : 100) }
        #expect(!CornerWords.clear("↓ SELLING", size: 10, top: false, data: selling, map: map))
        #expect(CornerWords.clear("↑ BUYING", size: 10, top: true, data: selling, map: map))
        // The same dip further right leaves the word alone.
        let later = (0..<40).map { ChartReach(x: CGFloat($0) * 9, low: $0 > 20 ? -950 : 100, high: 100) }
        #expect(CornerWords.clear("↓ SELLING", size: 10, top: false, data: later, map: map))
    }

    // MARK: Today's ghost

    static func quarters(from: Double, count: Int, _ watts: (Int) -> Double) -> [AheadPicture.Mark] {
        (0..<count).map { AheadPicture.Mark(startMs: from + Double($0) * 900_000, endMs: from + Double($0 + 1) * 900_000, watts: watts($0)) }
    }

    static func hours(from: Double, count: Int, _ watts: (Int) -> Double) -> [AheadPicture.Mark] {
        (0..<count).map { AheadPicture.Mark(startMs: from + Double($0) * 3_600_000, endMs: from + Double($0 + 1) * 3_600_000, watts: watts($0)) }
    }

    @Test func todayAtSixShowsTheWholeDayInOnePicture() throws {
        let (from, to) = HistoryPicture.day(ChartGeometryTests.at(14, 12), clock: Self.clock)
        let now = ChartGeometryTests.at(14, 6, 7)
        let measured = (0..<73).map { ChartSample(startMs: from + Double($0) * 300_000, value: 300) }
        // The battery stores 09–15 at 2.5 kW and gives 17–21 at 3 kW; the
        // sun peaks at 4 kW, the home at 1.2 kW.
        let battery = Self.quarters(from: ChartGeometryTests.at(14, 6), count: 72) { i in (12..<36).contains(i) ? 2_500 : (44..<60).contains(i) ? -3_000 : 0 }
        let sun = Self.hours(from: from, count: 24) { h in max(0, 4_000 - Double(abs(h - 12)) * 700) }
        let picture = HistoryPicture.build(
            [("battery", measured), ("solar", [])],
            ahead: ["battery": (.plan, battery), "solar": (.forecast, sun)],
            fromMs: from, toMs: to, nowMs: now, size: Self.size, floor: 3_000, clock: Self.clock, words: Self.words
        )
        // One scale for the measured night and the planned day.
        #expect(picture.domain.upper >= 4_000 && picture.domain.lower <= -3_000)
        let plan = try #require(picture.layers[0].ghost)
        #expect(plan.kind == .plan && plan.grid.stepMs == 900_000)
        #expect(plan.grid.fromMs == from && plan.grid.toMs == to)
        #expect(plan.grid.firstMs == ChartGeometryTests.at(14, 6))
        let at10 = try #require(plan.grid.index(atMs: ChartGeometryTests.at(14, 10)))
        #expect(plan.values[at10] == 2_500)
        // On the chart's own x: 10:00 sits at 10/24 of the width.
        #expect(abs(plan.grid.x(atMs: ChartGeometryTests.at(14, 10), width: 240) - 100) < 1e-9)
        let forecast = try #require(picture.layers[1].ghost)
        #expect(forecast.kind == .forecast && !forecast.line.isEmpty)
        // The finger still stops at the last measured slot: a plan is not
        // a reading.
        #expect(picture.limit == 12)
        // No plan, no ghost; and 48 h, which ends at now, has none.
        let bare = HistoryPicture.build([("battery", measured)], fromMs: from, toMs: to, nowMs: now, size: Self.size, clock: Self.clock, words: Self.words)
        #expect(bare.layers[0].ghost == nil)
        let twoDays = HistoryPicture.twoDays(now)
        let past = HistoryPicture.build([("battery", measured)], ahead: ["battery": (.plan, battery.filter { $0.endMs <= now })], fromMs: twoDays.fromMs, toMs: twoDays.toMs, nowMs: now, size: Self.size, clock: Self.clock, words: Self.words)
        #expect(past.layers[0].ghost == nil)
    }

    // MARK: Ahead

    @Test func anHourlyForecastBendsThroughItsHoursInsteadOfStepping() {
        let now = ChartGeometryTests.at(14, 10, 7)
        let sun = Self.hours(from: ChartGeometryTests.at(14, 10), count: 12) { h in 600 + Double(h) * 300 }
        let prices = Self.quarters(from: ChartGeometryTests.at(14, 10), count: 48) { _ in 50 }.map { (startMs: $0.startMs, endMs: $0.endMs, minor: $0.watts) }
        let picture = AheadPicture.build(kind: .forecast, slots: sun.map { ($0.startMs, $0.endMs, Optional($0.watts)) }, prices: prices, nowMs: now, size: Self.size, clock: Self.clock)
        // The grid is the prices' quarters; the line is the forecast's hours.
        #expect(picture.grid.stepMs == 900_000)
        let points = picture.line.elements.filter { if case .move = $0 { return false } else { return true } }.count
        // One point at the left edge, then one per hour: 12 curves, not 47.
        #expect(points == 12)
        #expect(picture.marks.count == 12)
    }

    @Test func theCarsScaleIsTheChargersMostWithOrWithoutAPlan() {
        let now = ChartGeometryTests.at(14, 10, 7)
        let night: [(startMs: Double, endMs: Double, watts: Double?)] = [(ChartGeometryTests.at(14, 18), ChartGeometryTests.at(14, 21), 11_000)]
        let planned = AheadPicture.build(kind: .plan, slots: night, prices: [], nowMs: now, size: Self.size, floor: 3_700, top: 11_000, clock: Self.clock)
        let none = AheadPicture.build(kind: .plan, slots: [], prices: [], nowMs: now, size: Self.size, floor: 3_700, top: 11_000, clock: Self.clock)
        #expect(planned.domain == YDomain(lower: 0, upper: 11_000))
        #expect(none.domain == planned.domain)
        // Without a charger's most, the scale fits the plan as before.
        let fitted = AheadPicture.build(kind: .plan, slots: night, prices: [], nowMs: now, size: Self.size, floor: 3_700, clock: Self.clock)
        #expect(fitted.domain.upper == 15_000)
    }

    // MARK: The price view's plan line

    @Test func thePlanLineSaysWhenTheBatteryStoresAndGivesAndAtWhatPrice() {
        let from = ChartGeometryTests.at(14, 9)
        let slots = (0..<96).map { i -> PriceSlot in
            let p: Double = i < 26 ? 58 + Double(i) : i >= 32 && i < 44 ? 150 + Double(i - 32) * 2 : 120
            return PriceSlot(startMs: from + Double(i) * 900_000, durationMs: 900_000, spotMinor: p, totalMinor: p)
        }
        // Stores 09:15–15:30, gives 17:00–20:00.
        let battery = (1..<26).map { PlanEntry.Slot(startMs: from + Double($0) * 900_000, durationMs: 900_000, batteryW: 2_500, reason: "") }
            + (32..<44).map { PlanEntry.Slot(startMs: from + Double($0) * 900_000, durationMs: 900_000, batteryW: -3_000, reason: "") }
        let plan = PlanEntry(battery: battery, charges: [], prices: [], currency: "SEK", boxStale: false)
        let chart = PriceChart.build(slots, currency: "SEK", nowMs: from, plan: plan, clock: Self.clock)
        let unit = PriceUnits.unit("SEK").label.uppercased()
        #expect(chart.planLine == PriceWord.stores.format("09:15–15:30", "59–83") + " · " + PriceWord.gives.format("17–20", "150–172") + " " + unit)
        // Where both do not fit, the first part alone, never "…".
        #expect(chart.planLineShort == PriceWord.stores.format("09:15–15:30", "59–83") + " " + unit)
        #expect(PriceChart.build(slots, currency: "SEK", nowMs: from, clock: Self.clock).planLine.isEmpty)
        #expect(PriceChart.build(slots, currency: "SEK", nowMs: from, clock: Self.clock).planLineShort.isEmpty)
        let idle = PlanEntry(battery: [], charges: [], prices: [], currency: "SEK", boxStale: false)
        #expect(PriceChart.build(slots, currency: "SEK", nowMs: from, plan: idle, clock: Self.clock).planLine.isEmpty)
    }
}
