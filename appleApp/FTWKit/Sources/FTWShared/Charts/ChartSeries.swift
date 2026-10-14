import CoreGraphics
import Foundation

/// One of the box's five-minute means, or none where it has no record.
public struct ChartSample: Equatable, Sendable {
    public var startMs: Double
    public var value: Double?

    public init(startMs: Double, value: Double?) {
        self.startMs = startMs
        self.value = value
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
        let whPerW = sampleMs / 3_600_000
        for s in samples where s.startMs >= fromMs && s.startMs < toMs {
            guard let v = s.value else { continue }
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
                outWh: outWh[k]
            ))
        }
        return out
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
        words: ReadoutWords
    ) -> ChartSeries {
        let stepMs = DisplayBucket.stepMs(spanMs: toMs - fromMs, width: size.width)
        let buckets = DisplayBucket.buckets(samples, sampleMs: sampleMs, stepMs: stepMs, fromMs: fromMs, toMs: toMs, clock: clock)
        let grid = SlotGrid(firstMs: buckets.first?.startMs ?? fromMs, stepMs: stepMs, count: buckets.count, fromMs: fromMs, toMs: toMs)

        // The domain holds the band, not just the means, so the highest
        // five-minute mean always fits.
        var low = 0.0, high = 0.0
        for b in buckets {
            if let lo = b.low, let hi = b.high {
                low = min(low, lo)
                high = max(high, hi)
            }
        }
        let domain = YDomain.stable(low: low, high: high, previous: previous, floor: floor)
        let map = YMap(domain: domain, height: size.height)

        var line = ChartPath(), body = ChartPath(), band = ChartPath()
        var points = [CGPoint?](repeating: nil, count: buckets.count)
        var run: [CGPoint] = [], highs: [CGPoint] = [], lows: [CGPoint] = []
        run.reserveCapacity(buckets.count)
        let base = map.baseline
        func endRun() {
            let start = line.elements.count
            line.addMonotone(run)
            // The body is the same curve, closed on zero: made once.
            if run.count > 1 {
                body.elements.append(contentsOf: line.elements[start...])
                body.elements.append(.line(CGPoint(x: run[run.count - 1].x, y: base)))
                body.elements.append(.line(CGPoint(x: run[0].x, y: base)))
                body.elements.append(.close)
                band.addBand(highs: highs, lows: lows)
            }
            run.removeAll(keepingCapacity: true)
            highs.removeAll(keepingCapacity: true)
            lows.removeAll(keepingCapacity: true)
        }
        for (i, b) in buckets.enumerated() {
            guard let m = b.mean, let lo = b.low, let hi = b.high else {
                endRun()
                continue
            }
            let x = grid.x(atMs: b.atMs, width: size.width)
            let p = CGPoint(x: x, y: map.y(m))
            points[i] = p
            run.append(p)
            highs.append(CGPoint(x: x, y: map.y(hi)))
            lows.append(CGPoint(x: x, y: map.y(lo)))
        }
        endRun()

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
            readouts: ReadoutTable(when: when, what: what, inWh: inWh, outWh: outWh, landmarks: landmarks)
        )
    }
}
