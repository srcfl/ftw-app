import CoreGraphics
import Foundation
import Testing
@testable import FTWShared

/// The chart engine's geometry: the rules WP1 of the polish release must
/// prove before any chart draws with it.
@Suite struct ChartGeometryTests {
    static let stockholm = TimeZone(identifier: "Europe/Stockholm")!
    static let clock = ZoneClock.of(stockholm)
    static let words = ReadoutWords(value: { "\(Int($0.rounded())) W" }, range: { "\(Int($0.rounded()))–\(Int($1.rounded()))" }, none: "no data")

    /// Wall clock in Stockholm, as ms.
    static func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Double {
        clock.calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!.timeIntervalSince1970 * 1000
    }

    /// The same numbers on every run.
    struct Dice {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    /// A home with an on/off heater and noise: the shape that looked like a
    /// saw in 0.3.0, one point every 1.2 pt.
    static func heater(_ n: Int, seed: UInt64 = 7) -> [CGPoint] {
        var dice = Dice(state: seed)
        var on = false
        return (0..<n).map { i in
            if dice.next() < 0.08 { on.toggle() }
            let w = (on ? 1_000 : 0) + dice.next() * 60
            return CGPoint(x: CGFloat(i) * 1.2, y: 200 - CGFloat(w) / 6)
        }
    }

    /// Distance from `p` to the nearest piece of a polyline that runs left
    /// to right, looking only at pieces within `near` of it across.
    static func distance(_ p: CGPoint, to line: [CGPoint], near: CGFloat = 4) -> CGFloat {
        guard line.count > 1 else { return line.first.map { hypot($0.x - p.x, $0.y - p.y) } ?? .infinity }
        var lo = 0, hi = line.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if line[mid].x < p.x - near { lo = mid + 1 } else { hi = mid }
        }
        var best = CGFloat.infinity
        var i = max(lo, 1)
        while i < line.count {
            best = min(best, ChartPaths.distance2(p, line[i - 1], line[i]))
            if line[i - 1].x > p.x + near { break }
            i += 1
        }
        return best.squareRoot()
    }

    /// How often a line turns from rising to falling or back.
    static func turns(_ pts: [CGPoint], tolerance: CGFloat = 1e-6) -> Int {
        var count = 0, last: CGFloat = 0
        for i in 1..<pts.count {
            let dy = pts[i].y - pts[i - 1].y
            guard abs(dy) > tolerance else { continue }
            if last != 0, (dy > 0) != (last > 0) { count += 1 }
            last = dy
        }
        return count
    }

    // MARK: Steffen

    @Test func steffenNeverLeavesItsNeighboursRange() {
        var dice = Dice(state: 42)
        var series: [[CGPoint]] = [Self.heater(300)]
        series.append((0..<200).map { CGPoint(x: CGFloat($0) * 3.85, y: CGFloat(dice.next() * 240)) })
        series.append([0, 0, 0, 100, 100, 100, 20, 20, 240].enumerated().map { CGPoint(x: CGFloat($0.offset) * 4, y: CGFloat($0.element)) })
        // Uneven steps, as a bucket still filling sits nearer its data.
        series.append((0..<50).map { CGPoint(x: CGFloat($0) * 4 + CGFloat(dice.next() * 3), y: CGFloat(dice.next() * 100)) })
        for pts in series {
            let path = ChartPaths.monotone(pts)
            #expect(path.elements.count == pts.count)
            for k in 1..<pts.count {
                guard case let .curve(to, c1, c2) = path.elements[k] else {
                    Issue.record("element \(k) is not a curve")
                    continue
                }
                let a = pts[k - 1], lo = min(a.y, to.y) - 1e-9, hi = max(a.y, to.y) + 1e-9
                for step in 0...32 {
                    let s = CGFloat(step) / 32, r = 1 - s
                    let x = r * r * r * a.x + 3 * r * r * s * c1.x + 3 * r * s * s * c2.x + s * s * s * to.x
                    let y = r * r * r * a.y + 3 * r * r * s * c1.y + 3 * r * s * s * c2.y + s * s * s * to.y
                    #expect(y >= lo && y <= hi)
                    #expect(x >= a.x - 1e-9 && x <= to.x + 1e-9)
                }
            }
        }
    }

    @Test func aStepBetweenFlatsTurnsWithLevelShoulders() {
        let pts = [0, 0, 100, 100].enumerated().map { CGPoint(x: CGFloat($0.offset) * 10, y: CGFloat($0.element)) }
        let path = ChartPaths.monotone(pts)
        guard case let .curve(_, c1, c2) = path.elements[2] else {
            Issue.record("no curve over the step")
            return
        }
        // Both control points level with their ends: no overshoot, soft turn.
        #expect(c1.y == 0)
        #expect(c2.y == 100)
    }

    @Test func aLonePointIsADotAndAGapIsABreak() {
        let p = CGPoint(x: 5, y: 5)
        #expect(ChartPaths.monotone([p]).elements == [.move(p), .line(p)])
        var path = ChartPath()
        path.addMonotone([CGPoint(x: 0, y: 0), CGPoint(x: 4, y: 1)])
        path.addMonotone([CGPoint(x: 12, y: 0), CGPoint(x: 16, y: 1)])
        #expect(path.elements.filter { if case .move = $0 { return true } else { return false } }.count == 2)
    }

    // MARK: RDP and the rounded polyline

    @Test func simplifyingKeepsEverySampleWithinEpsilon() {
        let pts = Self.heater(300)
        for epsilon: CGFloat in [0.25, 0.5] {
            let kept = ChartPaths.simplify(pts, epsilon: epsilon)
            #expect(kept.first == pts.first && kept.last == pts.last)
            #expect(kept.count < pts.count)
            for p in pts { #expect(Self.distance(p, to: kept) <= epsilon + 1e-9) }
        }
        let straight = (0..<50).map { CGPoint(x: CGFloat($0), y: CGFloat($0) * 2) }
        #expect(ChartPaths.simplify(straight, epsilon: 0.5).count == 2)
    }

    @Test func theRoundedPolylineMovesNoPointMoreThanHalfAPointAndAddsNoExtreme() {
        for seed: UInt64 in [1, 7, 99] {
            let pts = ChartPaths.simplify(Self.heater(300, seed: seed), epsilon: 0.5)
            let drawn = ChartPaths.roundedPolyline(pts).flattened(steps: 64)
            for p in pts { #expect(Self.distance(p, to: drawn) <= 0.5 + 1e-6) }
            #expect(Self.turns(drawn) <= Self.turns(pts))
            let ys = pts.map(\.y), drawnYs = drawn.map(\.y)
            #expect(drawnYs.min()! >= ys.min()! - 1e-9 && drawnYs.max()! <= ys.max()! + 1e-9)
        }
    }

    @Test func theTraceKeepsEverySampleWithinHalfAPoint() {
        let samples = Self.heater(300)
        let drawn = ChartPaths.trace(samples).flattened(steps: 64)
        for p in samples { #expect(Self.distance(p, to: drawn) <= 0.5 + 1e-6) }
        #expect(Self.turns(drawn) <= Self.turns(samples))
    }

    @Test func aCornerIsRoundedWithinItsCaps() {
        // A gentle bend: the 5 pt radius caps it, not the shift.
        let gentle = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 200, y: 10)]
        guard case let .line(a) = ChartPaths.roundedPolyline(gentle).elements[1] else {
            Issue.record("no rounded corner")
            return
        }
        let turn = atan2(10.0, 100.0)
        #expect(abs((100 - a.x) - 5 * tan(turn / 2)) < 1e-6)
        // A right angle: the shift caps it, and the corner is cut.
        let square = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100)]
        let drawn = ChartPaths.roundedPolyline(square).flattened(steps: 256)
        let corner = Self.distance(CGPoint(x: 100, y: 0), to: drawn)
        #expect(corner > 0.4 && corner <= 0.5 + 1e-6)
        // Short segments: half of each, so two corners never overlap.
        let zig = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 40), CGPoint(x: 2, y: 0)]
        guard case let .line(b) = ChartPaths.roundedPolyline(zig).elements[1] else { return }
        #expect(hypot(b.x - 1, b.y - 40) <= hypot(1, 40) / 2 + 1e-9)
    }

    // MARK: Rounded steps and merged runs

    @Test func roundedStepsHoldEachSlotsValueAndBreakAtAGap() {
        let steps = [ChartPath.Step(x0: 0, x1: 10, y: 50), ChartPath.Step(x0: 10, x1: 20, y: 20), ChartPath.Step(x0: 20, x1: 30, y: 20), ChartPath.Step(x0: 40, x1: 50, y: 80)]
        let path = ChartPaths.roundedSteps(steps)
        let drawn = path.flattened()
        for s in steps {
            let mid = CGPoint(x: (s.x0 + s.x1) / 2, y: s.y)
            #expect(Self.distance(mid, to: drawn.filter { abs($0.x - mid.x) <= 6 }) < 1e-9)
        }
        #expect(drawn.allSatisfy { $0.y >= 20 && $0.y <= 80 })
        #expect(path.elements.filter { if case .move = $0 { return true } else { return false } }.count == 2)
    }

    @Test func equalSlotsMergeIntoOnePixelSnappedRun() {
        let grid = SlotGrid(firstMs: 0, stepMs: 900_000, count: 8, fromMs: 0, toMs: 8 * 900_000)
        let map = YMap(domain: YDomain(lower: -3_000, upper: 3_000), height: 100)
        let values: [Double?] = [2_000, 2_000, 2_000, nil, -1_000, -1_000, 0, 1_500]
        let runs = ChartPaths.runs(values, grid: grid, width: 301, map: map, scale: 3, maxRadius: 4)
        #expect(runs.map(\.first) == [0, 4, 7])
        #expect(runs.map(\.count) == [3, 2, 1])
        for r in runs {
            for edge in [r.rect.minX, r.rect.maxX, r.rect.minY, r.rect.maxY] {
                #expect(abs(edge * 3 - (edge * 3).rounded()) < 1e-9)
            }
            #expect(r.radius <= 4 && r.radius <= r.rect.width / 2)
        }
        // One device pixel between a run and the next slot's start.
        #expect(abs((runs[0].rect.maxX + 1.0 / 3) - (301.0 * 3 / 8 * 3).rounded() / 3) < 1e-9)
        // A negative run hangs below zero.
        #expect(runs[1].rect.minY == (map.baseline * 3).rounded() / 3)
    }

    // MARK: The domain

    @Test func theDomainGrowsAtOnceShrinksBelowFiftyFivePercentAndEndsOnNiceSteps() {
        let first = YDomain.stable(low: 0, high: 900)
        #expect(first == YDomain(lower: 0, upper: 1_000))
        // More than fits: it grows in the same step.
        #expect(YDomain.stable(low: 0, high: 1_200, previous: first).upper == 1_500)
        // Down to 60 % and to 55 %: it holds.
        #expect(YDomain.stable(low: 0, high: 600, previous: first) == first)
        #expect(YDomain.stable(low: 0, high: 550, previous: first) == first)
        // Under 55 %: it shrinks to fit.
        #expect(YDomain.stable(low: 0, high: 540, previous: first).upper == 750)
        // Each side on its own; a side with no data is zero.
        let signed = YDomain.stable(low: -2_600, high: 400, previous: nil)
        #expect(signed == YDomain(lower: -3_000, upper: 500))
        #expect(YDomain.stable(low: -1_800, high: 400, previous: signed).lower == -3_000)
        #expect(YDomain.stable(low: -100, high: 400, previous: signed).lower == -150)
        #expect(YDomain.stable(low: 0, high: 400, previous: signed).lower == 0)
        // No data at all: the floor.
        #expect(YDomain.stable(low: 0, high: 0, floor: 100) == YDomain(lower: 0, upper: 100))
        #expect(YDomain.stable(low: -4, high: 3, floor: 100) == YDomain(lower: -100, upper: 100))

        let nice: Set<Double> = [1, 1.5, 2, 3, 5, 7.5]
        var dice = Dice(state: 3)
        var previous: YDomain?
        for _ in 0..<2_000 {
            let peak = pow(10, dice.next() * 6)
            let d = YDomain.stable(low: -peak * dice.next(), high: peak, previous: previous)
            for side in [d.upper, -d.lower] where side > 0 {
                let mantissa = side / pow(10, log10(side).rounded(.down))
                #expect(nice.contains((mantissa * 1e6).rounded() / 1e6))
            }
            #expect(d.upper >= peak)
            previous = d
        }
    }

    // MARK: Slots under a finger

    @Test func theIndexClampsAtBothEdgesAndInGaps() {
        let grid = SlotGrid(firstMs: 0, stepMs: 900_000, count: 4, fromMs: 0, toMs: 3_600_000)
        #expect(grid.index(atX: -40, width: 300) == 0)
        #expect(grid.index(atX: 0, width: 300) == 0)
        #expect(grid.index(atX: 300, width: 300) == 3)
        #expect(grid.index(atX: 900, width: 300) == 3)
        #expect(grid.index(atMs: -.infinity) == 0)
        #expect(grid.index(atMs: .infinity) == 3)
        #expect(grid.index(atMs: .nan) == 0)
        #expect(SlotGrid(firstMs: 0, stepMs: 1, count: 0, fromMs: 0, toMs: 1).index(atMs: 0) == nil)

        // A gap keeps its slot: the rule stays, the dot does not, the
        // readout says so.
        let from = Self.at(13, 0)
        let samples = (0..<12).map { ChartSample(startMs: from + Double($0) * 300_000, value: (3..<6).contains($0) ? nil : 500) }
        let series = ChartSeries.history(samples, fromMs: from, toMs: from + 3_600_000, size: CGSize(width: 40, height: 100), clock: Self.clock, words: Self.words)
        #expect(series.grid.stepMs == 900_000)
        let gap = series.grid.index(atMs: from + 1_200_000)
        #expect(gap == 1)
        #expect(series.points[1] == nil)
        #expect(series.readouts.what[1] == "no data")
        #expect(series.grid.index(atX: 1_000, width: 40) == 3)

        // The live curve: one binary search, clamped, nearest either way.
        let times: [Double] = [0, 1_000, 2_000, 9_000]
        #expect(SlotGrid.nearest(times, to: -500) == 0)
        #expect(SlotGrid.nearest(times, to: 1e12) == 3)
        #expect(SlotGrid.nearest(times, to: 5_000) == 2)
        #expect(SlotGrid.nearest(times, to: 5_600) == 3)
        #expect(SlotGrid.nearest([], to: 0) == nil)
    }

    // MARK: Buckets

    @Test func displayBucketsAreTheSmallestThatLeaveSixPoints() {
        let day = 86_400_000.0
        // About 48 slots of 7 pt across a phone, the plan strip's rule.
        #expect(DisplayBucket.stepMs(spanMs: day, width: 370) == 1_800_000)
        #expect(DisplayBucket.stepMs(spanMs: 2 * day, width: 370) == 3_600_000)
        #expect(DisplayBucket.stepMs(spanMs: day, width: 800) == 900_000)
        #expect(DisplayBucket.stepMs(spanMs: 3_600_000, width: 370) == 300_000)
        #expect(DisplayBucket.stepMs(spanMs: 30 * day, width: 370) == 3_600_000)
    }

    @Test func aBucketIsTheExactMeanOfItsFiveMinuteMeans() {
        let from = Self.at(13, 0), to = Self.at(14, 0)
        var dice = Dice(state: 11)
        let samples = (0..<288).map { i in
            ChartSample(startMs: from + Double(i) * 300_000, value: dice.next() < 0.1 ? nil : (dice.next() - 0.4) * 5_000)
        }
        let buckets = DisplayBucket.buckets(samples, stepMs: 900_000, fromMs: from, toMs: to, clock: Self.clock)
        #expect(buckets.count == 96)
        var inWh = 0.0, outWh = 0.0
        for b in buckets {
            let held = samples.filter { $0.startMs >= b.startMs && $0.startMs < b.endMs }.compactMap(\.value)
            #expect(b.count == held.count)
            if held.isEmpty {
                #expect(b.mean == nil)
                continue
            }
            #expect(b.mean == held.reduce(0, +) / Double(held.count))
            #expect(b.low == held.min() && b.high == held.max())
            inWh += held.filter { $0 >= 0 }.reduce(0, +) / 12
            outWh -= held.filter { $0 < 0 }.reduce(0, +) / 12
        }
        // 15-minute slots need 8 pt each: an iPad's or a landscape width.
        let series = ChartSeries.history(samples, fromMs: from, toMs: to, size: CGSize(width: 800, height: 200), clock: Self.clock, words: Self.words)
        #expect(series.buckets == buckets)
        let all = series.readouts.soFar(95)
        #expect(abs(all.inWh - inWh) < 1e-6 && abs(all.outWh - outWh) < 1e-6)
    }

    @Test func bucketsSitOnTheLocalClockAndAnOpenOneWhereItsDataIs() {
        // India is 5:30 ahead: an hour still starts at :00 there.
        let kolkata = ZoneClock.of(TimeZone(identifier: "Asia/Kolkata")!)
        var c = kolkata.calendar
        c.timeZone = kolkata.zone
        let from = c.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 9, minute: 10))!.timeIntervalSince1970 * 1000
        let buckets = DisplayBucket.buckets([], stepMs: 3_600_000, fromMs: from, toMs: from + 7_200_000, clock: kolkata)
        #expect(kolkata.minuteOfDay(buckets[0].startMs) == 9 * 60)
        // A bucket with two of its three means sits between those two.
        let open = DisplayBucket.buckets([ChartSample(startMs: 0, value: 1), ChartSample(startMs: 300_000, value: 3)], stepMs: 900_000, fromMs: 0, toMs: 900_000, clock: ZoneClock.of(TimeZone(identifier: "UTC")!))
        #expect(open[0].atMs == 300_000)
        #expect(open[0].mean == 2)
    }

    // MARK: Readouts

    @Test func theReadoutTableSaysWhenWhatAndSoFar() {
        let from = Self.at(13, 14)
        let values: [Double?] = [0, 600, 1_100, 1_000, nil, nil, -2_000, -1_000, -1_500]
        let samples = values.enumerated().map { ChartSample(startMs: from + Double($0.offset) * 300_000, value: $0.element) }
        let series = ChartSeries.history(samples, fromMs: from, toMs: from + 2_700_000, nowMs: from + 2_000_000, size: CGSize(width: 20, height: 100), clock: Self.clock, words: Self.words)
        let t = series.readouts
        #expect(t.when == ["14:00–14:15", "14:15–14:30", "14:30–14:45"])
        #expect(t.what == ["567 W · 0–1100", "1000 W", "-1500 W · -2000–-1000"])
        #expect(t.soFar(0).inWh == 1_700.0 / 12)
        #expect(t.between(2, 1).outWh == 4_500.0 / 12)
        // The highest mean, the lowest and now.
        #expect(t.landmarks == [0, 2])
        #expect(series.grid.index(atMs: from + 2_000_000) == 2)
    }

    // MARK: Scrub rules

    @Test func aTickOnlyOnACrossingAtMostOnePer40Ms() {
        var step = ScrubStep()
        let t0 = ContinuousClock.now
        #expect(step.move(to: 3, landmark: false, at: t0) == .selection)
        #expect(step.move(to: 3, landmark: false, at: t0 + .milliseconds(100)) == .none)
        #expect(step.move(to: 4, landmark: false, at: t0 + .milliseconds(10)) == .none)
        #expect(step.index == 4)
        #expect(step.move(to: 5, landmark: false, at: t0 + .milliseconds(45)) == .selection)
        // A landmark always lands, and holds the next tick off.
        #expect(step.move(to: 6, landmark: true, at: t0 + .milliseconds(50)) == .impact)
        #expect(step.move(to: 7, landmark: false, at: t0 + .milliseconds(60)) == .none)
        #expect(step.ticks == 2 && step.bumps == 1)
        step.lift()
        #expect(step.index == nil)
        #expect(step.move(to: 7, landmark: false, at: t0 + .seconds(1)) == .selection)
    }

    // MARK: The clock

    @Test func theZoneClockReadsAsTheCalendarDoesAcrossTheTurnOfTheClocks() {
        // Summer time ends in Stockholm on 25 October 2026.
        let start = Self.at(24, 0)
        var c = Calendar(identifier: .gregorian)
        c.timeZone = Self.stockholm
        for k in 0..<(96 * 3) {
            let ms = start + Double(k) * 900_000 + 37_000
            let d = c.dateComponents([.hour, .minute, .second], from: Date(timeIntervalSince1970: ms / 1000))
            #expect(Self.clock.label(ms) == String(format: "%02d:%02d", d.hour!, d.minute!))
            #expect(Self.clock.seconds(ms) == String(format: "%02d:%02d:%02d", d.hour!, d.minute!, d.second!))
        }
        #expect(ZoneClock.label(minute: 1_439) == "23:59")
        #expect(ZoneClock.label(minute: 1_440 + 7 * 60) == "07:00")
        #expect(ZoneClock.label(minute: -1) == "23:59")
        #expect(ZoneClock.of(Self.stockholm).calendar == Self.clock.calendar)
    }

    // MARK: Cost

    #if DEBUG
    /// Plain `swift test` builds without optimisation, which runs this
    /// code 20 to 60 times slower than the app ships it, and other suites
    /// run beside it. There the bound catches a slip in kind, such as a
    /// loop inside a loop. `swift test -c release -Xswiftc -enable-testing`
    /// checks the 2 ms itself.
    static let budget: Duration = .milliseconds(20)
    #else
    static let budget: Duration = .milliseconds(2)
    #endif

    /// The best of a few runs, so a busy machine does not decide.
    static func cost(_ body: () -> Void) -> Duration {
        var best = Duration.seconds(1)
        for _ in 0..<9 {
            let began = ContinuousClock.now
            body()
            best = min(best, ContinuousClock.now - began)
        }
        return best
    }

    @Test func geometryForSevenHundredTwentyPointsBuildsInUnderTwoMilliseconds() {
        let from = Self.at(13, 0)
        var dice = Dice(state: 5)
        let samples = (0..<720).map { ChartSample(startMs: from + Double($0) * 300_000, value: dice.next() < 0.05 ? nil : (dice.next() - 0.3) * 4_000) }
        // 6 pt a point: 720 five-minute points, more than any phone chart
        // draws.
        var points = 0
        let history = Self.cost {
            let series = ChartSeries.history(samples, fromMs: from, toMs: from + 720 * 300_000, nowMs: from + 600 * 300_000, size: CGSize(width: 4_320, height: 300), clock: Self.clock, words: Self.words)
            points = series.points.count
        }
        #expect(points == 720)
        #expect(history < Self.budget, "history built in \(history)")
        // The live trace at 720 samples, more than twice its 300.
        let noisy = Self.heater(720)
        let trace = Self.cost { _ = ChartPaths.trace(noisy) }
        #expect(trace < Self.budget, "trace built in \(trace)")
        // The live series at 720 frames: readings, Gaussian, Steffen, band.
        let frames = (0..<720).map { LiveSample(t: Double($0) * 1_000, v: Double(200 - noisy[$0].y) * 6) }
        let live = Self.cost { _ = LiveSeries.build(frames, sourceGapMs: 3_500, windowMs: 720_000, nowMs: 719_000, size: CGSize(width: 350, height: 300)) }
        #expect(live < Self.budget, "live series built in \(live)")
    }
}
