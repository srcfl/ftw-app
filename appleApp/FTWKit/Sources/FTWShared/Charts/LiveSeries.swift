import CoreGraphics
import Foundation

/// One live frame of a value: when it was stamped, and the watts.
public struct LiveSample: Equatable, Sendable {
    public var t: Double
    public var v: Double

    public init(t: Double, v: Double) {
        self.t = t
        self.v = v
    }
}

/// The live trace's geometry, built once per reading off the main actor.
///
/// It draws one point per reading, not per frame: a slow device repeats its
/// value in every 1 Hz frame, and a frame that repeats is no new truth. The
/// readings pass through a Gaussian in screen space, 2.5 pt wide, whose
/// reach shrinks to nothing at the head, so the head is the raw last reading
/// and the line never leaves the range of the readings near it. A band
/// shows the lowest and highest raw reading of each 2 s frame on the clock,
/// so it holds still as the trace scrolls. A gap stays a break.
///
/// x is placed for `nowMs`: now sits `inset` inside the right edge. A view
/// scrolls by translating by `shift(at:)`; nothing rebuilds per frame.
public struct LiveSeries: Equatable, Sendable {
    public var nowMs: Double
    public var windowMs: Double
    public var size: CGSize
    public var inset: CGFloat
    public var domain: YDomain
    /// Each run's readings, oldest first, as drawn: one per reading. The
    /// scrub's dot sits on these.
    public var runs: [[LiveSample]]
    /// The smoothed line, one subpath per run.
    public var line: ChartPath
    /// The same curves closed on zero.
    public var body: ChartPath
    /// The lowest and highest raw reading per 2 s frame, one shape per run.
    public var band: ChartPath
    /// The last raw reading, where the head's dot sits.
    public var head: CGPoint?

    /// Points per ms across the plot.
    public var ptPerMs: CGFloat { windowMs > 0 ? (size.width - inset) / CGFloat(windowMs) : 0 }

    /// Where a moment sits, for the geometry's own now.
    public func x(_ t: Double) -> CGFloat { size.width - inset - CGFloat(nowMs - t) * ptPerMs }

    /// How far the drawing has moved left by `ms`.
    public func shift(at ms: Double) -> CGFloat { CGFloat(ms - nowMs) * ptPerMs }

    /// Every reading, oldest first, for one binary search under a finger.
    public var readings: [LiveSample] { runs.flatMap { $0 } }

    public static let sigma: CGFloat = 2.5
    public static let headInset: CGFloat = 6
    public static let bandFrameMs: Double = 2_000
    /// After smoothing, one drawn point per this many points of width.
    public static let step: CGFloat = 1.5

    /// The trace of `frames` (sorted by time) in a window `windowMs` long
    /// that ends at `nowMs`, on a plot of `size`. `periodMs` is how often
    /// the device itself reads, `gapMs` how long a silence may last before
    /// the line breaks. `previous` is the domain on screen, so the axis
    /// holds still; `floor` is the node's least scale.
    public static func build(
        _ frames: [LiveSample],
        periodMs: Double = 1_000,
        gapMs: Double,
        windowMs: Double,
        nowMs: Double,
        size: CGSize,
        previous: YDomain? = nil,
        floor: Double = 1,
        sigma: CGFloat = LiveSeries.sigma,
        inset: CGFloat = LiveSeries.headInset
    ) -> LiveSeries {
        // Keep the reading before the window too, so the line runs off the
        // left edge instead of starting inside it.
        let fromMs = nowMs - windowMs
        let firstInside = frames.firstIndex { $0.t >= fromMs } ?? frames.count
        let kept = Array(frames[max(0, firstInside - 1)...].prefix { $0.t <= nowMs })
        let runs = readings(kept, periodMs: periodMs, gapMs: gapMs)
        let frameBands = runs.map { bandFrames($0, frameMs: bandFrameMs) }

        var low = 0.0, high = 0.0
        for run in frameBands {
            for f in run {
                low = min(low, f.low)
                high = max(high, f.high)
            }
        }
        let domain = YDomain.stable(low: low, high: high, previous: previous, floor: floor)
        var series = LiveSeries(nowMs: nowMs, windowMs: windowMs, size: size, inset: inset, domain: domain, runs: runs, line: ChartPath(), body: ChartPath(), band: ChartPath(), head: nil)
        let map = YMap(domain: domain, height: size.height)
        let base = map.baseline

        for (run, frames) in zip(runs, frameBands) {
            let raw = run.map { CGPoint(x: series.x($0.t), y: map.y($0.v)) }
            let drawn = decimated(smoothed(raw, sigma: sigma), step: step)
            let start = series.line.elements.count
            series.line.addMonotone(drawn)
            if drawn.count > 1 {
                series.body.elements.append(contentsOf: series.line.elements[start...])
                series.body.elements.append(.line(CGPoint(x: drawn[drawn.count - 1].x, y: base)))
                series.body.elements.append(.line(CGPoint(x: drawn[0].x, y: base)))
                series.body.elements.append(.close)
            }
            // A frame's point sits at its middle on the clock, kept inside
            // the run, so the band never reaches past the head.
            guard let first = raw.first?.x, let last = raw.last?.x else { continue }
            let xs = frames.map { min(max(series.x($0.startMs + bandFrameMs / 2), first), last) }
            series.band.addBand(
                highs: zip(xs, frames).map { CGPoint(x: $0, y: map.y($1.high)) },
                lows: zip(xs, frames).map { CGPoint(x: $0, y: map.y($1.low)) }
            )
        }
        if let last = runs.last?.last {
            series.head = CGPoint(x: series.x(last.t), y: map.y(last.v))
        }
        return series
    }

    /// Frames to readings, split into runs at each silence longer than
    /// `gapMs`. A run of equal frames is one reading at its first frame. If
    /// it lasts longer than 1.5 read periods it also keeps a point one
    /// period before the next value, so a steady value draws flat and only
    /// the last period slopes. A run's last frame stays, so the line holds
    /// its value up to the silence or the head.
    public static func readings(_ frames: [LiveSample], periodMs: Double, gapMs: Double) -> [[LiveSample]] {
        var runs: [[LiveSample]] = []
        var run: [LiveSample] = []
        var i = 0
        while i < frames.count {
            // The equal frames that start at i, inside one run.
            var j = i
            while j + 1 < frames.count, frames[j + 1].v == frames[i].v, frames[j + 1].t - frames[j].t <= gapMs { j += 1 }
            let first = frames[i], lastEqual = frames[j]
            run.append(first)
            let next = j + 1 < frames.count ? frames[j + 1] : nil
            if let next, next.t - lastEqual.t <= gapMs {
                // The value changes inside the run.
                let held = next.t - periodMs
                if next.t - first.t > 1.5 * periodMs, held > first.t { run.append(LiveSample(t: held, v: first.v)) }
            } else {
                // A silence or the head: the run ends on its last frame.
                if lastEqual.t > first.t { run.append(lastEqual) }
                runs.append(run)
                run = []
            }
            i = j + 1
        }
        return runs
    }

    /// Zero-phase Gaussian in screen space, for one run sorted by x. The
    /// reach shrinks to nothing at the head, so the last reading is drawn
    /// raw. It weights real readings only, so it stays inside their range.
    public static func smoothed(_ p: [CGPoint], sigma: CGFloat) -> [CGPoint] {
        guard p.count > 2, sigma > 0, let head = p.last?.x else { return p }
        var out = p
        for i in p.indices {
            let reach = min(3 * sigma, head - p[i].x)
            guard reach > 0 else { continue }
            var sw: CGFloat = 0, sy: CGFloat = 0
            var j = i
            while j >= 0, p[i].x - p[j].x <= reach {
                let d = (p[j].x - p[i].x) / sigma, w = exp(-0.5 * d * d)
                sw += w
                sy += w * p[j].y
                j -= 1
            }
            j = i + 1
            while j < p.count, p[j].x - p[i].x <= reach {
                let d = (p[j].x - p[i].x) / sigma, w = exp(-0.5 * d * d)
                sw += w
                sy += w * p[j].y
                j += 1
            }
            out[i].y = sy / sw
        }
        return out
    }

    /// At most one point per `step` of width, the first and the last kept.
    public static func decimated(_ p: [CGPoint], step: CGFloat) -> [CGPoint] {
        guard p.count > 2, step > 0 else { return p }
        var out: [CGPoint] = [p[0]]
        out.reserveCapacity(p.count)
        for q in p.dropFirst().dropLast() where q.x - out[out.count - 1].x >= step {
            out.append(q)
        }
        let last = p[p.count - 1]
        if out.count > 1, last.x - out[out.count - 1].x < step / 2 { out.removeLast() }
        out.append(last)
        return out
    }

    /// One 2 s frame of the band: where it starts on the clock and the
    /// lowest and highest reading in it.
    public struct Frame: Equatable, Sendable {
        public var startMs: Double
        public var low: Double
        public var high: Double
    }

    /// The readings of one run in frames `frameMs` long that start on the
    /// clock (a multiple of `frameMs` since 1970), never at the window's
    /// edge, so a frame holds the same readings however the window moves.
    public static func bandFrames(_ run: [LiveSample], frameMs: Double) -> [Frame] {
        var out: [Frame] = []
        for s in run {
            let start = (s.t / frameMs).rounded(.down) * frameMs
            if let last = out.last, last.startMs == start {
                out[out.count - 1].low = min(last.low, s.v)
                out[out.count - 1].high = max(last.high, s.v)
            } else {
                out.append(Frame(startMs: start, low: s.v, high: s.v))
            }
        }
        return out
    }
}
