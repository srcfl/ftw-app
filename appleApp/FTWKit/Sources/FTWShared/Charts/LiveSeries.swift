import CoreGraphics
import Foundation

/// One live frame of a value: when it was stamped, the watts, and whether
/// this phone saw it live.
public struct LiveSample: Equatable, Sendable {
    public var t: Double
    public var v: Double
    /// False for a point kept from before this launch or filled in from
    /// history: drawn in ink, never in phosphor.
    public var seen: Bool

    public init(t: Double, v: Double, seen: Bool = true) {
        self.t = t
        self.v = v
        self.seen = seen
    }
}

/// The live trace's geometry, built once per reading off the main actor.
///
/// It draws one point per reading, not per frame: a slow device repeats its
/// value in every 1 Hz frame, and a frame that repeats is no new truth. The
/// readings pass through a Gaussian in screen space, 2.5 pt wide or most of
/// one read period for a slower device, whose reach shrinks to nothing at
/// the head, so the head is the raw last reading
/// and the line never leaves the range of the readings near it. A band
/// shows the lowest and highest raw reading of each 2 s frame on the clock,
/// so it holds still as the trace scrolls.
///
/// A silence up to three of the device's own read periods is joined: a
/// device read every 5 s leaves 5 s between readings, and that is no gap.
/// Only a longer silence breaks the line. Points this phone did not see
/// live draw in ink.
///
/// x is placed for `nowMs`: now sits `inset` inside the right edge. A view
/// scrolls by translating by `shift(at:)`; nothing rebuilds per frame.
public struct LiveSeries: Equatable, Sendable {
    /// A smoothed point, in time and watts.
    public struct Point: Equatable, Sendable {
        public var t: Double
        public var v: Double
        public var seen: Bool
    }

    /// A silence that breaks the line, from the last reading before it to
    /// the first after it, or to now when the stream is quiet.
    public struct Gap: Equatable, Sendable {
        public var fromMs: Double
        public var toMs: Double
    }

    public var nowMs: Double
    public var windowMs: Double
    public var size: CGSize
    public var inset: CGFloat
    public var domain: YDomain
    /// How often the device itself reads, as its readings show.
    public var periodMs: Double
    /// The longest silence the line joins.
    public var gapMs: Double
    /// Each run's readings, oldest first: one per reading. The scrub's dot
    /// sits on these.
    public var runs: [[LiveSample]]
    /// Each run smoothed and thinned, in time and watts, so a slide can
    /// blend one geometry into the next by reading time.
    public var curves: [[Point]]
    /// The lowest and highest raw reading per 2 s frame, per run.
    public var frames: [[Frame]]
    /// The silences, oldest first, the quiet head last.
    public var gaps: [Gap]
    /// The smoothed line where this phone saw it live, and where it did not.
    public var line: ChartPath
    public var lineUnseen: ChartPath
    /// The same curves closed on zero.
    public var body: ChartPath
    public var bodyUnseen: ChartPath
    /// One shape per run.
    public var band: ChartPath
    /// The last raw reading, where the head sits.
    public var head: CGPoint?
    public var last: LiveSample?
    /// Every reading in the window is at rest: the chart draws the dotted
    /// baseline mid-plot, as Now draws a node at rest, and no line.
    public var atRest = false

    /// Points per ms across the plot.
    public var ptPerMs: CGFloat { windowMs > 0 ? (size.width - inset) / CGFloat(windowMs) : 0 }

    /// Where a moment sits, for the geometry's own now.
    public func x(_ t: Double) -> CGFloat { size.width - inset - CGFloat(nowMs - t) * ptPerMs }

    /// How far the drawing has moved left by `ms`.
    public func shift(at ms: Double) -> CGFloat { CGFloat(ms - nowMs) * ptPerMs }

    public var map: YMap { YMap(domain: domain, height: size.height) }

    /// Every reading, oldest first, for one binary search under a finger.
    public var readings: [LiveSample] { runs.flatMap { $0 } }

    /// The whole line, seen or not, for tests and the calm metrics.
    public var wholeLine: ChartPath {
        var p = ChartPath()
        for curve in curves { p.addMonotone(curve.map { CGPoint(x: x($0.t), y: map.y($0.v)) }) }
        return p
    }

    public static let sigma: CGFloat = 2.5
    public static let headInset: CGFloat = 6
    public static let bandFrameMs: Double = 2_000
    /// After smoothing, one drawn point per this many points of width.
    public static let step: CGFloat = 1.5
    /// A silence up to this many read periods is joined.
    public static let joinPeriods: Double = 3
    /// The Gaussian is at least this many read periods wide.
    public static let periodReach: Double = 1

    /// The trace of `frames` (sorted by time) in a window `windowMs` long
    /// that ends at `nowMs`, on a plot of `size`. `sourceGapMs` is the
    /// longest silence the way the frames came by allows (3.5 s on the
    /// relay); the device's own read period, from its readings unless
    /// `periodMs` is given, can only lengthen it. `previous` is the domain
    /// on screen, so the axis holds still; `floor` is the node's least
    /// scale. With `restW`, the scale comes from the window alone
    /// (`domain(low:high:restW:previous:)`) and `floor` is not used.
    public static func build(
        _ frames: [LiveSample],
        sourceGapMs: Double,
        periodMs: Double? = nil,
        windowMs: Double,
        nowMs: Double,
        size: CGSize,
        previous: YDomain? = nil,
        floor: Double = 1,
        restW: Double? = nil,
        sigma: CGFloat = LiveSeries.sigma,
        inset: CGFloat = LiveSeries.headInset
    ) -> LiveSeries {
        // Keep the reading before the window too, so the line runs off the
        // left edge instead of starting inside it.
        let fromMs = nowMs - windowMs
        let firstInside = frames.firstIndex { $0.t >= fromMs } ?? frames.count
        let kept = Array(frames[max(0, firstInside - 1)...].prefix { $0.t <= nowMs })
        let period = periodMs ?? Self.period(of: kept) ?? 1_000
        let gap = max(sourceGapMs, joinPeriods * period)
        let runs = readings(kept, periodMs: period, gapMs: gap)
        let frameBands = runs.map { bandFrames($0, frameMs: bandFrameMs) }

        var low = 0.0, high = 0.0
        for run in frameBands {
            for f in run {
                low = min(low, f.low)
                high = max(high, f.high)
            }
        }
        let domain = restW.map { Self.domain(low: low, high: high, restW: $0, previous: previous) }
            ?? YDomain.stable(low: low, high: high, previous: previous, floor: floor)
        var series = LiveSeries(
            nowMs: nowMs, windowMs: windowMs, size: size, inset: inset, domain: domain, periodMs: period, gapMs: gap,
            runs: runs, curves: [], frames: frameBands, gaps: [],
            line: ChartPath(), lineUnseen: ChartPath(), body: ChartPath(), bodyUnseen: ChartPath(), band: ChartPath(),
            head: nil, last: runs.last?.last
        )
        if let restW, !runs.isEmpty { series.atRest = high <= restW && low >= -restW }
        let pt = series.ptPerMs
        // 2.5 pt is about 2 s: enough to calm a 1 Hz meter. A slower device
        // leaves its readings further apart than that, so the Gaussian
        // widens to most of one read period and still reaches its
        // neighbours; the band keeps the peaks it cuts.
        let sigmaMs = pt > 0 ? max(Double(sigma / pt), periodReach * period) : 0
        let stepMs = pt > 0 ? Double(step / pt) : 0

        for (run, frames) in zip(runs, frameBands) {
            let curve = thinned(smoothed(run, sigmaMs: sigmaMs), stepMs: stepMs)
            series.curves.append(curve)
            series.addCurve(curve)
            series.addBand(run, frames)
        }
        for (a, b) in zip(runs, runs.dropFirst()) {
            if let end = a.last, let start = b.first { series.gaps.append(Gap(fromMs: end.t, toMs: start.t)) }
        }
        if let last = series.last {
            if nowMs - last.t > gap { series.gaps.append(Gap(fromMs: last.t, toMs: nowMs)) }
            series.head = CGPoint(x: series.x(last.t), y: series.map.y(last.v))
        }
        return series
    }

    /// The live scale, from the window's own readings: each side ends on
    /// nice(1.1 × its peak), and a side is there only when the window goes
    /// past rest that way, so a window of one sign keeps zero at the edge
    /// and a 450 W battery fills most of the plot. A window at rest has no
    /// peak to fit: zero sits mid-plot, on the least scale either side.
    /// The scale holds still as `YDomain.stable` does, except that the
    /// rest scale is never held.
    public static func domain(low: Double, high: Double, restW: Double, previous: YDomain?) -> YDomain {
        let rest = restDomain(restW)
        let up = high > restW ? high : 0
        let down = low < -restW ? low : 0
        guard up > 0 || down < 0 else { return rest }
        return YDomain.stable(low: down, high: up, previous: previous == rest ? nil : previous, floor: max(restW, 1))
    }

    /// Zero mid-plot, on the least scale a side may have.
    public static func restDomain(_ restW: Double) -> YDomain {
        let r = YDomain.nice(max(restW, 1) * 1.1)
        return YDomain(lower: -r, upper: r)
    }

    /// One run's curve into the line and body paths, split where this
    /// phone's view changes between live and not. The curve is one Steffen
    /// cubic over the whole run, so the colour changes and the shape does
    /// not.
    mutating func addCurve(_ curve: [Point]) {
        let pts = curve.map { CGPoint(x: x($0.t), y: map.y($0.v)) }
        guard !pts.isEmpty else { return }
        var whole = ChartPath()
        whole.addMonotone(pts)
        guard pts.count > 1 else {
            if curve[0].seen { line.elements += whole.elements } else { lineUnseen.elements += whole.elements }
            return
        }
        let base = map.baseline
        var groupStart = 0
        var groupSeen = curve[0].seen && curve[1].seen
        func close(_ end: Int) {
            var l = ChartPath([.move(pts[groupStart])])
            l.elements += whole.elements[(groupStart + 1)...end]
            var b = l
            b.elements.append(.line(CGPoint(x: pts[end].x, y: base)))
            b.elements.append(.line(CGPoint(x: pts[groupStart].x, y: base)))
            b.elements.append(.close)
            if groupSeen {
                line.elements += l.elements
                body.elements += b.elements
            } else {
                lineUnseen.elements += l.elements
                bodyUnseen.elements += b.elements
            }
        }
        for k in 1..<pts.count {
            let seen = curve[k - 1].seen && curve[k].seen
            if seen != groupSeen {
                close(k - 1)
                groupStart = k - 1
                groupSeen = seen
            }
        }
        close(pts.count - 1)
    }

    /// One run's band: a frame's point sits at its middle on the clock,
    /// kept inside the run, so the band never reaches past the head.
    mutating func addBand(_ run: [LiveSample], _ frames: [Frame]) {
        guard let first = run.first?.t, let lastT = run.last?.t else { return }
        let xs = frames.map { x(min(max($0.startMs + Self.bandFrameMs / 2, first), lastT)) }
        band.addBand(
            highs: zip(xs, frames).map { CGPoint(x: $0, y: map.y($1.high)) },
            lows: zip(xs, frames).map { CGPoint(x: $0, y: map.y($1.low)) }
        )
    }

    /// The device's read period, from how often its value changes. A
    /// reading that repeats the last one only lengthens the time to the
    /// next change, never shortens it, so the period is near the short end:
    /// the fifth of the times between one new value and the next. Nil when
    /// it changed too seldom to tell.
    public static func period(of frames: [LiveSample]) -> Double? {
        var changes: [Double] = []
        var last: LiveSample?
        var lastChange: Double?
        for f in frames {
            defer { last = f }
            guard let l = last, f.v != l.v else { continue }
            if let c = lastChange { changes.append(f.t - c) }
            lastChange = f.t
        }
        guard changes.count >= 3 else { return nil }
        let short = changes.sorted()[changes.count / 5]
        return min(max((short / 1_000).rounded() * 1_000, 1_000), 120_000)
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
            // The equal frames that start at i, inside one run, seen alike.
            var j = i
            while j + 1 < frames.count, frames[j + 1].v == frames[i].v, frames[j + 1].seen == frames[i].seen, frames[j + 1].t - frames[j].t <= gapMs { j += 1 }
            let first = frames[i], lastEqual = frames[j]
            run.append(first)
            let next = j + 1 < frames.count ? frames[j + 1] : nil
            if let next, next.t - lastEqual.t <= gapMs {
                // The value changes inside the run.
                let held = next.t - periodMs
                if next.t - first.t > 1.5 * periodMs, held > first.t { run.append(LiveSample(t: held, v: first.v, seen: first.seen)) }
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

    /// Zero-phase Gaussian over one run, `sigmaMs` wide in time (2.5 pt of
    /// width). The reach shrinks to nothing at the head, so the last reading
    /// is drawn raw. It weights real readings only, so it stays inside their
    /// range.
    public static func smoothed(_ run: [LiveSample], sigmaMs: Double) -> [Point] {
        var out = run.map { Point(t: $0.t, v: $0.v, seen: $0.seen) }
        guard run.count > 2, sigmaMs > 0, let head = run.last?.t else { return out }
        for i in run.indices {
            let reach = min(3 * sigmaMs, head - run[i].t)
            guard reach > 0 else { continue }
            var sw = 0.0, sv = 0.0
            var j = i
            while j >= 0, run[i].t - run[j].t <= reach {
                let d = (run[j].t - run[i].t) / sigmaMs, w = exp(-0.5 * d * d)
                sw += w
                sv += w * run[j].v
                j -= 1
            }
            j = i + 1
            while j < run.count, run[j].t - run[i].t <= reach {
                let d = (run[j].t - run[i].t) / sigmaMs, w = exp(-0.5 * d * d)
                sw += w
                sv += w * run[j].v
                j += 1
            }
            out[i].v = sv / sw
        }
        return out
    }

    /// At most one point per `stepMs`, on buckets of the clock so the same
    /// readings stay from one build to the next; the first and the last
    /// point always stay.
    public static func thinned(_ p: [Point], stepMs: Double) -> [Point] {
        guard p.count > 2, stepMs > 0 else { return p }
        var out: [Point] = [p[0]]
        out.reserveCapacity(p.count)
        var bucket = (p[0].t / stepMs).rounded(.down)
        for q in p.dropFirst().dropLast() {
            let b = (q.t / stepMs).rounded(.down)
            guard b != bucket else { continue }
            bucket = b
            out.append(q)
        }
        let last = p[p.count - 1]
        if out.count > 1, last.t - out[out.count - 1].t < stepMs / 2 { out.removeLast() }
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

// MARK: - The slide

extension LiveSeries {
    /// The last run part way from `old` to `self`, `progress` from 0 to 1,
    /// in this geometry's points. Each point the two share by reading time
    /// moves from its old value to its new one; the head travels the
    /// segment from the old head to the new one. Every value drawn lies
    /// between two values the readings gave, so the slide shows nothing the
    /// box did not send. Nil when there is nothing to blend: no old run, a
    /// new run, or another domain.
    public func sliding(from old: LiveSeries, progress: Double) -> [Point]? {
        guard progress < 1, old.domain == domain, let newRun = curves.last, let oldRun = old.curves.last,
              let oldHead = oldRun.last, let newHead = newRun.last, newHead.t > oldHead.t,
              let first = newRun.first, first.t <= oldHead.t else { return nil }
        let p = min(max(progress, 0), 1)
        var before = [Double: Double](minimumCapacity: oldRun.count)
        for q in oldRun { before[q.t] = q.v }
        let headT = oldHead.t + (newHead.t - oldHead.t) * p
        var out: [Point] = []
        out.reserveCapacity(newRun.count)
        for q in newRun where q.t <= oldHead.t {
            let v = before[q.t].map { $0 + (q.v - $0) * p } ?? q.v
            out.append(Point(t: q.t, v: v, seen: q.seen))
        }
        // The head on its way along the segment between two readings.
        if headT > (out.last?.t ?? -.infinity) {
            out.append(Point(t: headT, v: oldHead.v + (newHead.v - oldHead.v) * p, seen: newHead.seen))
        }
        return out
    }

    /// A curve as line and body paths in this geometry, for one frame of a
    /// slide: the same split by sight as a built run.
    public func paths(_ curve: [Point]) -> (line: ChartPath, lineUnseen: ChartPath, body: ChartPath, bodyUnseen: ChartPath) {
        var scratch = self
        scratch.line = ChartPath()
        scratch.lineUnseen = ChartPath()
        scratch.body = ChartPath()
        scratch.bodyUnseen = ChartPath()
        scratch.addCurve(curve)
        return (scratch.line, scratch.lineUnseen, scratch.body, scratch.bodyUnseen)
    }

    /// The runs before the last, as built: a slide redraws only the last.
    public func pathsBeforeLast() -> (line: ChartPath, lineUnseen: ChartPath, body: ChartPath, bodyUnseen: ChartPath) {
        var scratch = self
        scratch.line = ChartPath()
        scratch.lineUnseen = ChartPath()
        scratch.body = ChartPath()
        scratch.bodyUnseen = ChartPath()
        for curve in curves.dropLast() { scratch.addCurve(curve) }
        return (scratch.line, scratch.lineUnseen, scratch.body, scratch.bodyUnseen)
    }
}
