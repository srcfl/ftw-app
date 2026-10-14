import CoreGraphics
import Foundation

/// One of the box's five-minute means, or none where it has no record.
public struct ChartSample: Equatable, Sendable {
    public var startMs: Double
    public var value: Double?
    /// A hole whose tile is on its way, not one the box has no record for.
    public var fetching: Bool

    public init(startMs: Double, value: Double?, fetching: Bool = false) {
        self.startMs = startMs
        self.value = value
        self.fetching = fetching
    }
}

/// A display bucket: the five-minute means that fall in one slot of the
/// chart, and what they add up to. Nothing in it is invented.
public struct ChartBucket: Equatable, Sendable {
    public var startMs: Double
    public var endMs: Double
    /// The exact mean of the five-minute means it holds; nil when it holds
    /// none.
    public var mean: Double?
    /// The lowest and the highest of those means.
    public var low: Double?
    public var high: Double?
    /// How many five-minute means it holds.
    public var count: Int
    /// Where its point sits: the middle of the means it holds, so a bucket
    /// still filling draws its mean so far where that data is.
    public var atMs: Double
    /// Energy into and out of the site over its means, in watt-hours.
    public var inWh: Double
    public var outWh: Double
    /// It holds no mean, and one of its holes is on its way.
    public var fetching = false
}

/// The smallest bucket of 5, 15, 30 or 60 minutes that leaves each point
/// at least 6 pt of width: Today on a phone is 30 minutes and 48 hours 60,
/// about 48 slots of 7 pt each, the thumb rule of the plan strip. A line
/// with a point every 1 pt draws every step between neighbours as a tooth.
public enum DisplayBucket {
    public static let stepsMs: [Double] = [300_000, 900_000, 1_800_000, 3_600_000]
    public static let minWidth: CGFloat = 6

    public static func stepMs(spanMs: Double, width: CGFloat) -> Double {
        guard spanMs > 0, width > 0 else { return stepsMs[0] }
        return stepsMs.first { CGFloat($0 / spanMs) * width >= minWidth } ?? stepsMs[stepsMs.count - 1]
    }

    /// Five-minute means gathered into buckets `stepMs` long on the local
    /// clock, from the one that holds `fromMs` to the one that holds the
    /// moment before `toMs`. A mean outside the window counts nowhere.
    public static func buckets(_ samples: [ChartSample], sampleMs: Double = 300_000, stepMs: Double, fromMs: Double, toMs: Double, clock: ZoneClock) -> [ChartBucket] {
        guard toMs > fromMs, stepMs > 0 else { return [] }
        let origin = clock.alignDown(fromMs, stepMs: stepMs)
        let count = Int(((toMs - origin) / stepMs).rounded(.up))
        var sum = [Double](repeating: 0, count: count), at = sum, inWh = sum, outWh = sum
        var low = [Double](repeating: .infinity, count: count), high = [Double](repeating: -.infinity, count: count)
        var held = [Int](repeating: 0, count: count)
        var coming = [Bool](repeating: false, count: count)
        let whPerW = sampleMs / 3_600_000
        for s in samples where s.startMs >= fromMs && s.startMs < toMs {
            guard let v = s.value else {
                if s.fetching { coming[min(max(Int(((s.startMs - origin) / stepMs).rounded(.down)), 0), count - 1)] = true }
                continue
            }
            let k = min(max(Int(((s.startMs - origin) / stepMs).rounded(.down)), 0), count - 1)
            sum[k] += v
            held[k] += 1
            low[k] = min(low[k], v)
            high[k] = max(high[k], v)
            at[k] += s.startMs + sampleMs / 2
            if v >= 0 { inWh[k] += v * whPerW } else { outWh[k] -= v * whPerW }
        }
        var out: [ChartBucket] = []
        out.reserveCapacity(count)
        for k in 0..<count {
            let start = origin + Double(k) * stepMs
            let n = held[k]
            out.append(ChartBucket(
                startMs: start,
                endMs: start + stepMs,
                mean: n > 0 ? sum[k] / Double(n) : nil,
                low: n > 0 ? low[k] : nil,
                high: n > 0 ? high[k] : nil,
                count: n,
                atMs: n > 0 ? at[k] / Double(n) : (max(start, fromMs) + min(start + stepMs, toMs)) / 2,
                inWh: inWh[k],
                outWh: outWh[k],
                fetching: n == 0 && coming[k]
            ))
        }
        return out
    }

    /// The lowest and highest five-minute mean over the buckets, with zero.
    public static func extent(_ buckets: [ChartBucket]) -> (low: Double, high: Double) {
        var low = 0.0, high = 0.0
        for b in buckets {
            if let lo = b.low, let hi = b.high {
                low = min(low, lo)
                high = max(high, hi)
            }
        }
        return (low, high)
    }
}

/// A history chart's geometry, built once per change of data off the main
/// actor: its slots, its stable domain, the line, band and body in screen
/// points, where each slot's value sits, and its readout table. A view
/// only reads it.
public struct ChartSeries: Equatable, Sendable {
    public var grid: SlotGrid
    public var buckets: [ChartBucket]
    public var domain: YDomain
    public var size: CGSize
    /// The line, one subpath per run of data: a gap stays a break.
    public var line: ChartPath
    /// The same curves closed on zero.
    public var body: ChartPath
    /// How far the five-minute means swung inside each slot: one shape per
    /// run, from the slot highs' curve over to the slot lows' curve. A
    /// steady load hides it under the line; an on/off load shows it.
    public var band: ChartPath
    /// Where each slot's value sits on the line; nil in a gap.
    public var points: [CGPoint?]
    /// Where each slot's highest and lowest five-minute mean sit.
    public var highs: [CGPoint?]
    public var lows: [CGPoint?]
    /// Holes on their way, and holes the box has no record for, as slots.
    /// A slot after now is neither: it has not happened.
    public var fetching: [ClosedRange<Int>]
    public var missing: [ClosedRange<Int>]
    /// A dashed straight line across each hole on its way, from the
    /// measured slot before it to the one after: an estimate, never a value.
    public var estimate: ChartPath
    /// The last slot with data.
    public var lastData: Int?
    public var readouts: ReadoutTable

    /// The history of one node between `fromMs` and `toMs` on a plot of
    /// `size`. `previous` is the domain on screen (or the cached day's),
    /// so the axis holds still. `nowMs` and `landmarksMs` mark slots that
    /// earn a light impact, besides the slots with the highest and lowest
    /// five-minute mean.
    public static func history(
        _ samples: [ChartSample],
        sampleMs: Double = 300_000,
        fromMs: Double,
        toMs: Double,
        nowMs: Double? = nil,
        size: CGSize,
        previous: YDomain? = nil,
        floor: Double = 1,
        clock: ZoneClock,
        landmarksMs: [Double] = [],
        domain forced: YDomain? = nil,
        words: ReadoutWords
    ) -> ChartSeries {
        let stepMs = DisplayBucket.stepMs(spanMs: toMs - fromMs, width: size.width)
        let buckets = DisplayBucket.buckets(samples, sampleMs: sampleMs, stepMs: stepMs, fromMs: fromMs, toMs: toMs, clock: clock)
        let grid = SlotGrid(firstMs: buckets.first?.startMs ?? fromMs, stepMs: stepMs, count: buckets.count, fromMs: fromMs, toMs: toMs)

        // The domain holds the band, not just the means, so the highest
        // five-minute mean always fits. Several series on one chart share
        // one, given.
        let extent = DisplayBucket.extent(buckets)
        let domain = forced ?? YDomain.stable(low: extent.low, high: extent.high, previous: previous, floor: floor)
        let map = YMap(domain: domain, height: size.height)

        var points = [CGPoint?](repeating: nil, count: buckets.count)
        var highPoints = points, lowPoints = points
        for (i, b) in buckets.enumerated() {
            guard let m = b.mean, let lo = b.low, let hi = b.high else { continue }
            let x = grid.x(atMs: b.atMs, width: size.width)
            points[i] = CGPoint(x: x, y: map.y(m))
            highPoints[i] = CGPoint(x: x, y: map.y(hi))
            lowPoints[i] = CGPoint(x: x, y: map.y(lo))
        }
        let (line, body, band) = paths(points: points, highs: highPoints, lows: lowPoints, baseline: map.baseline)

        // Holes: on their way, or none on record, but only before now.
        let until = nowMs ?? toMs
        var fetching: [ClosedRange<Int>] = [], missing: [ClosedRange<Int>] = []
        var estimate = ChartPath()
        var i = 0
        while i < buckets.count {
            guard buckets[i].mean == nil, buckets[i].startMs < until else {
                i += 1
                continue
            }
            let coming = buckets[i].fetching
            var j = i
            while j + 1 < buckets.count, buckets[j + 1].mean == nil, buckets[j + 1].startMs < until, buckets[j + 1].fetching == coming { j += 1 }
            if coming {
                fetching.append(i...j)
                if i > 0, j + 1 < buckets.count, let a = points[i - 1], let b = points[j + 1] {
                    estimate.elements += [.move(a), .line(b)]
                }
            } else {
                missing.append(i...j)
            }
            i = j + 1
        }
        let lastData = buckets.lastIndex { $0.mean != nil }

        var when: [String] = [], what: [String] = []
        var inWh: [Double] = [0], outWh: [Double] = [0]
        when.reserveCapacity(buckets.count)
        what.reserveCapacity(buckets.count)
        inWh.reserveCapacity(buckets.count + 1)
        outWh.reserveCapacity(buckets.count + 1)
        var highest: (i: Int, v: Double)?, lowest: (i: Int, v: Double)?
        // Each slot ends where the next starts: one clock label per edge.
        var edges: [String] = buckets.map { clock.label(max($0.startMs, fromMs)) }
        if let last = buckets.last { edges.append(clock.label(min(last.endMs, toMs))) }
        for (i, b) in buckets.enumerated() {
            when.append(edges[i] + "–" + edges[i + 1])
            if let m = b.mean, let lo = b.low, let hi = b.high {
                what.append(lo == hi ? words.value(m) : words.value(m) + " · " + words.range(lo, hi))
                if hi > 0, hi > highest?.v ?? 0 { highest = (i, hi) }
                if lo < 0, lo < lowest?.v ?? 0 { lowest = (i, lo) }
            } else {
                what.append(words.none)
            }
            inWh.append(inWh[i] + b.inWh)
            outWh.append(outWh[i] + b.outWh)
        }

        var landmarks = Set<Int>()
        if let highest { landmarks.insert(highest.i) }
        if let lowest { landmarks.insert(lowest.i) }
        for ms in (nowMs.map { [$0] } ?? []) + landmarksMs where ms >= fromMs && ms < toMs {
            if let i = grid.index(atMs: ms) { landmarks.insert(i) }
        }

        return ChartSeries(
            grid: grid,
            buckets: buckets,
            domain: domain,
            size: size,
            line: line,
            body: body,
            band: band,
            points: points,
            highs: highPoints,
            lows: lowPoints,
            fetching: fetching,
            missing: missing,
            estimate: estimate,
            lastData: lastData,
            readouts: ReadoutTable(when: when, what: what, inWh: inWh, outWh: outWh, landmarks: landmarks)
        )
    }
}

extension ChartSeries {
    /// The line, body and band through slot points: one run per stretch of
    /// slots with data, so a hole stays a break. The body is the line's own
    /// curve closed on zero; the band runs from the highs' curve back along
    /// the lows'.
    public static func paths(points: [CGPoint?], highs: [CGPoint?], lows: [CGPoint?], baseline: CGFloat) -> (line: ChartPath, body: ChartPath, band: ChartPath) {
        var line = ChartPath(), body = ChartPath(), band = ChartPath()
        var run: [CGPoint] = [], hi: [CGPoint] = [], lo: [CGPoint] = []
        func endRun() {
            let start = line.elements.count
            line.addMonotone(run)
            if run.count > 1 {
                body.elements.append(contentsOf: line.elements[start...])
                body.elements.append(.line(CGPoint(x: run[run.count - 1].x, y: baseline)))
                body.elements.append(.line(CGPoint(x: run[0].x, y: baseline)))
                body.elements.append(.close)
                band.addBand(highs: hi, lows: lo)
            }
            run.removeAll(keepingCapacity: true)
            hi.removeAll(keepingCapacity: true)
            lo.removeAll(keepingCapacity: true)
        }
        for i in points.indices {
            guard let p = points[i], let h = highs[i], let l = lows[i] else {
                endRun()
                continue
            }
            run.append(p)
            hi.append(h)
            lo.append(l)
        }
        endRun()
        return (line, body, band)
    }

    /// Part way from `old` to this series, `progress` from 0 to 1: each slot
    /// both have moves from its old mean and swing to its new one, matched
    /// by slot; a slot only this one has is drawn as it is. Nil when the two
    /// do not share their slots and scale: then nothing morphs.
    public func blended(from old: ChartSeries, progress: Double) -> (line: ChartPath, body: ChartPath, band: ChartPath)? {
        guard progress < 1, old.grid == grid, old.domain == domain, old.points.count == points.count else { return nil }
        let k = CGFloat(min(max(progress, 0), 1))
        func mix(_ a: [CGPoint?], _ b: [CGPoint?]) -> [CGPoint?] {
            zip(a, b).map { o, n in
                guard let n else { return nil }
                guard let o else { return n }
                return CGPoint(x: o.x + (n.x - o.x) * k, y: o.y + (n.y - o.y) * k)
            }
        }
        return Self.paths(points: mix(old.points, points), highs: mix(old.highs, highs), lows: mix(old.lows, lows), baseline: YMap(domain: domain, height: size.height).baseline)
    }
}
