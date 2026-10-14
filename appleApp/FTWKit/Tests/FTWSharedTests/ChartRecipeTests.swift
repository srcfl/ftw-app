import CoreGraphics
import Foundation
import Testing
@testable import FTWShared

/// How a line looks, in numbers: how often it turns and how much ink it
/// spends. A turn counts once the line travels more than one stroke width
/// back from its last extreme; ink is line length per 100 pt of width.
enum Calm {
    static let stroke: CGFloat = 2.5

    static func turnsPer100(_ pts: [CGPoint], travel: CGFloat = stroke) -> Double {
        guard pts.count > 1, let first = pts.first, let last = pts.last, last.x > first.x else { return 0 }
        var dir = 0, ext = first.y, lo = first.y, hi = first.y, turns = 0
        for p in pts.dropFirst() {
            switch dir {
            case 1:
                if p.y > ext { ext = p.y } else if ext - p.y > travel { dir = -1; ext = p.y; turns += 1 }
            case -1:
                if p.y < ext { ext = p.y } else if p.y - ext > travel { dir = 1; ext = p.y; turns += 1 }
            default:
                lo = min(lo, p.y)
                hi = max(hi, p.y)
                if p.y - lo > travel { dir = 1; ext = p.y } else if hi - p.y > travel { dir = -1; ext = p.y }
            }
        }
        return Double(turns) / Double(last.x - first.x) * 100
    }

    static func inkPer100(_ pts: [CGPoint]) -> Double {
        guard pts.count > 1, let first = pts.first, let last = pts.last, last.x > first.x else { return 0 }
        var length: CGFloat = 0
        for i in 1..<pts.count { length += hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y) }
        return Double(length / (last.x - first.x)) * 100
    }
}

/// The research's recipe for calm, honest lines (WP3 of the polish
/// release): the band, a domain that holds it, the live series and the
/// price chart.
@Suite struct ChartRecipeTests {
    static let clock = ChartGeometryTests.clock
    static let words = ChartGeometryTests.words

    // MARK: Band and domain

    /// A heater that switches inside each half hour, with holes.
    static func heaterDay(from: Double, seed: UInt64 = 3) -> [ChartSample] {
        var dice = ChartGeometryTests.Dice(state: seed)
        return (0..<288).map { i in
            let on = (i / 3) % 2 == 0
            let v: Double? = (96..<102).contains(i) ? nil : 300 + (on ? 1_800 : 0) + dice.next() * 80
            return ChartSample(startMs: from + Double(i) * 300_000, value: v)
        }
    }

    @Test func everySlotMeanSitsInsideItsBandAndTheDomainHoldsEveryEdge() {
        let from = ChartGeometryTests.at(13, 0)
        let series = ChartSeries.history(Self.heaterDay(from: from), fromMs: from, toMs: from + 86_400_000, size: CGSize(width: 350, height: 280), clock: Self.clock, words: Self.words)
        #expect(series.grid.stepMs == 1_800_000)
        #expect(series.grid.count == 48)
        let map = YMap(domain: series.domain, height: 280)
        for (b, p) in zip(series.buckets, series.points) {
            guard let m = b.mean, let lo = b.low, let hi = b.high, let p else { continue }
            #expect(lo <= m && m <= hi)
            #expect(map.y(hi) <= p.y + 1e-9 && p.y <= map.y(lo) + 1e-9)
            #expect(series.domain.lower <= lo && hi <= series.domain.upper)
        }
        // One closed band per run: the hole makes two.
        let moves = series.band.elements.filter { if case .move = $0 { return true } else { return false } }.count
        let closes = series.band.elements.filter { $0 == .close }.count
        #expect(moves == 2 && closes == 2)
        // The band's vertices are the slot highs and lows, nothing past them.
        let ys = series.band.flattened().map(\.y)
        let edges = series.buckets.compactMap { b in b.low.map { (map.y(b.high!), map.y($0)) } }
        #expect((ys.min() ?? 0) >= (edges.map(\.0).min() ?? 0) - 1e-6)
        #expect((ys.max() ?? 0) <= (edges.map(\.1).max() ?? 0) + 1e-6)
    }

    @Test func theDomainFitsTheHighestFiveMinuteMeanNotJustTheSlotMean() {
        let from = ChartGeometryTests.at(13, 0)
        // One spike of 4 kW in a quiet half hour: its slot mean is 1 kW.
        let samples = (0..<6).map { ChartSample(startMs: from + Double($0) * 300_000, value: $0 == 2 ? 4_000 : 400) }
        let series = ChartSeries.history(samples, fromMs: from, toMs: from + 1_800_000, size: CGSize(width: 10, height: 100), clock: Self.clock, words: Self.words)
        #expect(series.domain.upper >= 4_000)
    }

    @Test func aHoleNeverCountsAsZeroInABand() {
        let from = ChartGeometryTests.at(13, 0)
        let samples = [500.0, nil, 700, nil, 600, 650].enumerated().map { ChartSample(startMs: from + Double($0.offset) * 300_000, value: $0.element) }
        let b = DisplayBucket.buckets(samples, stepMs: 1_800_000, fromMs: from, toMs: from + 1_800_000, clock: Self.clock)
        #expect(b.count == 1)
        #expect(b[0].low == 500 && b[0].high == 700 && b[0].count == 4)
    }

    @Test func aReversedPathDrawsTheSameShapeTheOtherWay() {
        var p = ChartPaths.monotone([CGPoint(x: 0, y: 10), CGPoint(x: 5, y: 2), CGPoint(x: 9, y: 7), CGPoint(x: 14, y: 7)])
        p.elements.append(.quad(CGPoint(x: 20, y: 0), control: CGPoint(x: 17, y: 9)))
        let back = p.reversed()
        #expect(back.reversed() == p)
        let a = p.flattened(), b = back.flattened()
        #expect(a.count == b.count)
        for (x, y) in zip(a, b.reversed()) { #expect(hypot(x.x - y.x, x.y - y.y) < 1e-9) }
        // Two subpaths come back in the other order, a closed one closed.
        let two = ChartPath([.move(CGPoint(x: 0, y: 0)), .line(CGPoint(x: 1, y: 1)), .close, .move(CGPoint(x: 5, y: 5)), .line(CGPoint(x: 6, y: 5))])
        #expect(two.reversed().elements == [.move(CGPoint(x: 6, y: 5)), .line(CGPoint(x: 5, y: 5)), .move(CGPoint(x: 0, y: 0)), .line(CGPoint(x: 1, y: 1)), .line(CGPoint(x: 0, y: 0)), .close])
    }

    // MARK: Live

    /// The research's live trace: house 450 W, meter noise ±25 W, a 2 kW
    /// heater 40 s on and 50 s off, five minutes at 1 Hz.
    static func liveHeater(seconds: Int = 300, seed: UInt64 = 9) -> (frames: [LiveSample], edges: Int) {
        var dice = ChartGeometryTests.Dice(state: seed)
        var edges = 0, was = false
        let frames = (0..<seconds).map { s -> LiveSample in
            let on = s % 90 < 40
            if s > 0, on != was { edges += 1 }
            was = on
            return LiveSample(t: Double(s) * 1_000, v: 450 + (on ? 2_000 : 0) + (dice.next() - 0.5) * 50)
        }
        return (frames, edges)
    }

    static let liveSize = CGSize(width: 350, height: 280)

    static func live(_ frames: [LiveSample], nowMs: Double? = nil, gapMs: Double = 3_500, periodMs: Double = 1_000) -> LiveSeries {
        LiveSeries.build(frames, periodMs: periodMs, gapMs: gapMs, windowMs: 300_000, nowMs: nowMs ?? frames.last!.t, size: liveSize, floor: 3_000)
    }

    @Test func theLiveLineIsCalmOnAnOnOffLoad() {
        let (frames, edges) = Self.liveHeater()
        let series = Self.live(frames)
        let line = series.line.flattened(steps: 8)
        let edgesPer100 = Double(edges) / Double(Self.liveSize.width) * 100
        let turns = Calm.turnsPer100(line)
        // Every frame drawn raw, as 0.3.2 did, for comparison.
        let map = YMap(domain: series.domain, height: Self.liveSize.height)
        let raw = frames.map { CGPoint(x: series.x($0.t), y: map.y($0.v)) }
        #expect(turns <= 2 * edgesPer100 + 2, "live turns \(turns) per 100 pt, edges \(edgesPer100)")
        #expect(Calm.turnsPer100(raw) > 5 * turns, "raw \(Calm.turnsPer100(raw)) against \(turns)")
        #expect(Calm.inkPer100(line) < Calm.inkPer100(raw))
    }

    @Test func theHeadIsTheLastRawReadingAndTheLineEndsOnIt() throws {
        let (frames, _) = Self.liveHeater()
        let series = Self.live(frames)
        let last = try #require(frames.last)
        let map = YMap(domain: series.domain, height: Self.liveSize.height)
        let head = try #require(series.head)
        #expect(head == CGPoint(x: series.x(last.t), y: map.y(last.v)))
        #expect(abs(head.x - (Self.liveSize.width - LiveSeries.headInset)) < 1e-9)
        let end = try #require(series.line.flattened().last)
        #expect(hypot(end.x - head.x, end.y - head.y) < 1e-9)
    }

    @Test func theLiveLineNeverLeavesTheReadingsNearIt() {
        let (frames, _) = Self.liveHeater(seed: 21)
        let series = Self.live(frames)
        let map = YMap(domain: series.domain, height: Self.liveSize.height)
        let raw = series.readings.map { CGPoint(x: series.x($0.t), y: map.y($0.v)) }
        let reach = 3 * LiveSeries.sigma + LiveSeries.step
        for p in series.line.flattened(steps: 6) {
            let near = raw.filter { abs($0.x - p.x) <= reach }.map(\.y)
            guard let lo = near.min(), let hi = near.max() else { continue }
            #expect(p.y >= lo - 1e-6 && p.y <= hi + 1e-6, "at x \(p.x): \(p.y) outside \(lo)…\(hi)")
        }
    }

    @Test func theBandSitsOnTheClockNotOnTheWindowEdge() {
        let (frames, _) = Self.liveHeater(seconds: 400)
        let a = Self.live(frames, nowMs: 380_000)
        let b = Self.live(frames, nowMs: 380_300)
        // Frames inside both windows hold the same readings.
        let from = 380_300 - 300_000 + LiveSeries.bandFrameMs
        let fa = a.runs.flatMap { LiveSeries.bandFrames($0, frameMs: LiveSeries.bandFrameMs) }.filter { $0.startMs >= from && $0.startMs < 378_000 }
        let fb = b.runs.flatMap { LiveSeries.bandFrames($0, frameMs: LiveSeries.bandFrameMs) }.filter { $0.startMs >= from && $0.startMs < 378_000 }
        #expect(!fa.isEmpty && fa == fb)
        #expect(fa.allSatisfy { $0.startMs.truncatingRemainder(dividingBy: LiveSeries.bandFrameMs) == 0 })
        // And they draw at the same place once the 0.3 s scroll is taken
        // off.
        for (x, y) in zip(fa, fb) { #expect(abs(a.x(x.startMs) - (b.x(y.startMs) + 300 * b.ptPerMs)) < 1e-9) }
    }

    @Test func aSilenceBreaksTheLineAndIsNeverBridged() {
        var (frames, _) = Self.liveHeater()
        frames.removeAll { $0.t > 100_000 && $0.t < 112_000 }
        let series = Self.live(frames)
        #expect(series.runs.count == 2)
        let moves = series.line.elements.filter { if case .move = $0 { return true } else { return false } }.count
        #expect(moves == 2)
        let gap = (series.x(100_000)...series.x(112_000))
        // Nothing drawn inside the silence but the ends of the two runs.
        let inside = series.line.flattened().filter { gap.contains($0.x) && $0.x > gap.lowerBound + 0.01 && $0.x < gap.upperBound - 0.01 }
        #expect(inside.isEmpty)
    }

    @Test func oneReadingPerValueAndASteadyValueStaysFlat() {
        // A device read every 10 s, its value in every 1 Hz frame.
        let values: [Double] = [100, 300, 300, 200]
        let frames = (0..<40).map { LiveSample(t: Double($0) * 1_000, v: values[$0 / 10]) }
        let runs = LiveSeries.readings(frames, periodMs: 10_000, gapMs: 3_500)
        #expect(runs.count == 1)
        // 100 at 0; 300 at 10 s, held until one period before 200 arrives;
        // 200 at 30 s and its last frame at the head.
        #expect(runs[0] == [LiveSample(t: 0, v: 100), LiveSample(t: 10_000, v: 300), LiveSample(t: 20_000, v: 300), LiveSample(t: 30_000, v: 200), LiveSample(t: 39_000, v: 200)])
        // At 1 Hz an equal neighbour is a reading of its own, kept as a flat.
        let steady = [5.0, 5, 5, 5, 9].enumerated().map { LiveSample(t: Double($0.offset) * 1_000, v: $0.element) }
        #expect(LiveSeries.readings(steady, periodMs: 1_000, gapMs: 3_500)[0].map(\.t) == [0, 3_000, 4_000])
    }

    @Test func theLiveDomainHoldsTheBandOnTheNodesFloor() {
        let quiet = (0..<120).map { LiveSample(t: Double($0) * 1_000, v: Double($0 % 7) * 20 - 60) }
        let series = Self.live(quiet)
        #expect(series.domain.upper == 3_000 && series.domain.lower == -3_000)
    }

    // MARK: Price

    static func quarters(from: Double, count: Int, price: (Int) -> Double) -> [PriceSlot] {
        (0..<count).map { PriceSlot(startMs: from + Double($0) * 900_000, durationMs: 900_000, spotMinor: price($0), totalMinor: price($0)) }
    }

    @Test func thePriceChartStartsAtTheCurrentSlotAndCoversADay() throws {
        let midnight = ChartGeometryTests.at(14, 0)
        // Today only: tomorrow is not published yet.
        let slots = Self.quarters(from: midnight, count: 96) { 20 + Double($0) }
        let now = ChartGeometryTests.at(14, 10, 7)
        let chart = PriceChart.build(slots, currency: "SEK", nowMs: now, clock: Self.clock)
        #expect(chart.grid.count == 96 && chart.grid.stepMs == 900_000)
        #expect(chart.grid.firstMs == ChartGeometryTests.at(14, 10))
        #expect(chart.nowIndex == 0)
        // From midnight on, nothing is published: hatched, with its hint.
        #expect(chart.pending == 56...95)
        #expect(!chart.pendingText.isEmpty)
        #expect(chart.minor[55] == 115 && chart.minor[56] == nil)
        #expect(chart.landmarks.isSuperset(of: [0, 4, 8, 95]))
        #expect(!chart.landmarks.contains(1))
        // Hour labels at 12 and 18 local, never within 1.5 h of now's label
        // or an hour of the right edge.
        #expect(chart.hours.map(\.label) == ["12", "18", "00", "06"])
        #expect(chart.when[0] == "10:00–10:15")
        #expect(chart.tag[0] == "10:00  60.0 öre" || chart.tag[0] == "10:00  60,0 öre")
    }

    @Test func hourlyPricesTickPerSlotAndBumpOnlyAtTheirLandmarks() {
        let from = ChartGeometryTests.at(14, 0)
        let slots = (0..<48).map { PriceSlot(startMs: from + Double($0) * 3_600_000, durationMs: 3_600_000, spotMinor: 50, totalMinor: Double(40 + $0 % 5)) }
        let chart = PriceChart.build(slots, currency: "SEK", nowMs: ChartGeometryTests.at(14, 9, 30), clock: Self.clock)
        #expect(chart.grid.count == 24 && chart.grid.stepMs == 3_600_000)
        #expect(chart.landmarks.count <= 5)
        #expect(chart.landmarks.isSuperset(of: [0, 23]))
    }

    @Test func barsAreInkByThirdsOfTheRange() {
        let from = ChartGeometryTests.at(14, 0)
        let slots = Self.quarters(from: from, count: 96) { [10, 39, 40, 69, 70, 100][$0 % 6] }
        let chart = PriceChart.build(slots, currency: "SEK", nowMs: from, clock: Self.clock)
        #expect(Array(chart.thirds.prefix(6)) == [.cheap, .cheap, .middle, .middle, .dear, .dear])
        #expect(chart.domain.upper >= 100 && chart.domain.lower == 0)
        #expect(chart.meanShown == 54.666666666666664)
    }

    @Test func aNegativePriceHangsBelowZeroAndIsSaidInWords() throws {
        let from = ChartGeometryTests.at(14, 0)
        let slots = Self.quarters(from: from, count: 96) { $0 == 8 ? -12.5 : 40 }
        let chart = PriceChart.build(slots, currency: "SEK", nowMs: from, clock: Self.clock)
        #expect(chart.domain.lower < -12.5)
        for s in chart.figure + chart.tag { #expect(!s.contains("-") && !s.contains("−")) }
        #expect(chart.doing[8].hasPrefix(PriceWord.paid.text))
        #expect(chart.doing[9].isEmpty)
    }

    @Test func hourlyPricesFillTheQuarterGridAndTheCheapestTwoHoursAreFound() throws {
        let from = ChartGeometryTests.at(14, 0)
        // Quarters today, hours tomorrow, as some markets publish.
        let today = Self.quarters(from: from, count: 96) { $0 >= 80 && $0 < 88 ? 5 : 50 }
        let tomorrow = (0..<24).map { PriceSlot(startMs: from + 86_400_000 + Double($0) * 3_600_000, durationMs: 3_600_000, spotMinor: 60, totalMinor: 60) }
        let chart = PriceChart.build(today + tomorrow, currency: "SEK", nowMs: ChartGeometryTests.at(14, 18), clock: Self.clock)
        #expect(chart.grid.stepMs == 900_000 && chart.pending == nil)
        #expect(chart.minor[95] == 60)
        let cheap = try #require(chart.cheapest)
        #expect(chart.when[cheap.lowerBound].hasPrefix("20:00") && chart.when[cheap.upperBound].hasSuffix("22:00"))
        #expect(chart.landmarks.contains(cheap.lowerBound) && chart.landmarks.contains(cheap.upperBound))
        #expect(chart.cheapestText.contains("20:00–22:00"))
    }

    @Test func thePlanSaysWhatHappensInEachSlot() throws {
        let from = ChartGeometryTests.at(14, 0)
        let slots = Self.quarters(from: from, count: 96) { _ in 40 }
        let plan = PlanEntry(battery: [PlanEntry.Slot(startMs: from + 3_600_000, durationMs: 900_000, batteryW: 3_000, reason: "")], charges: [], prices: [], currency: "SEK", boxStale: false)
        let chart = PriceChart.build(slots, currency: "SEK", nowMs: from, plan: plan, clock: Self.clock)
        #expect(chart.doing[4] == PlanGlance.what(PlanGlance.Event(kind: .charge, startMs: 0, endMs: 1)))
        #expect(chart.doing[3].isEmpty && chart.doing[5].isEmpty)
    }

    /// The audit found the price marker vanished at the right edge and in
    /// a hole. Past either edge the finger keeps the edge's slot; a hole
    /// keeps its own slot and says it has no price.
    @Test func aFingerAlwaysHasAPriceSlot() {
        let from = ChartGeometryTests.at(14, 0)
        var slots = Self.quarters(from: from, count: 96) { 50 + Double($0) }
        slots.remove(at: 2)
        let chart = PriceChart.build(slots, currency: "SEK", nowMs: from, clock: Self.clock)
        #expect(chart.grid.index(atX: -40, width: 300) == 0)
        #expect(chart.grid.index(atX: 340, width: 300) == 95)
        #expect(chart.minor[2] == nil && chart.minor[1] == 51 && chart.minor[3] == 53)
        #expect(chart.figure[2] == "—" && chart.doing[2] == PriceWord.noPriceYet.text)
        #expect(chart.pending == nil)
        // Two fingers over the hole average the prices that exist.
        #expect(chart.mean(1...3) == 52)
        #expect(chart.mean(2...2) == nil)
        #expect(chart.when(0...7) == "00:00–02:00")
    }

    @Test func everyPriceWordHasSwedish() throws {
        let url = try #require(Words.bundle.url(forResource: "Price", withExtension: "strings", subdirectory: nil, localization: "sv"))
        let sv = try #require(NSDictionary(contentsOf: url) as? [String: String])
        for word in PriceWord.allCases {
            let swedish = try #require(sv[word.rawValue], "no Swedish for \"\(word.rawValue)\"")
            #expect(!swedish.isEmpty)
            #expect(word.rawValue.components(separatedBy: "%@").count == swedish.components(separatedBy: "%@").count, "\(word.rawValue)")
        }
    }
}
