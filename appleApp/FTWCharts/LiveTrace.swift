import FTWShared
import SwiftUI

/// How a node's live trace is coloured: one hue each side of zero, and the
/// words for each direction when the scale holds both.
struct TraceLook: Equatable {
    var up: Color
    var down: Color
    /// "↑ STORING", drawn only when the scale has both signs.
    var upWord: String?
    var downWord: String?
}

/// One built trace, ready to draw: the geometry for the newest reading,
/// the one before it for the slide, and the paths made once from it. A
/// view only translates and strokes them.
struct TraceFrame: Equatable {
    let series: LiveSeries
    let previous: LiveSeries?
    /// When this reading came: the slide runs for 0.25 s from here.
    let arrivedAt: Date
    let paths: Paths
    /// Every reading, oldest first, and their times for a binary search.
    let readings: [LiveSample]
    let times: [Double]
    /// Readings that give a light impact under a finger: the window's high
    /// and low, and the edges of each silence.
    let landmarks: Set<Int>

    struct Paths: Equatable {
        var line = Path()
        var lineUnseen = Path()
        var body = Path()
        var bodyUnseen = Path()
        var band = Path()
        /// The runs before the last, for the slide, which redraws only the last.
        var beforeLine = Path()
        var beforeLineUnseen = Path()
        var beforeBody = Path()
        var beforeBodyUnseen = Path()
        /// Dotted baselines across the silences.
        var gaps = Path()
        /// A source at rest: the dotted baseline under its readings.
        var rest = Path()
    }

    /// The frame after `old`. Its slide starts where `old` draws its head
    /// now, so a reading that lands while the last one still slides carries
    /// on from there rather than jumping to where that slide was headed.
    init(series: LiveSeries, after old: TraceFrame?, arrivedAt: Date) {
        var from = old?.series
        if let old, let before = old.previous {
            let progress = TraceInk.ease(arrivedAt.timeIntervalSince(old.arrivedAt), TraceInk.slide)
            if progress < 1 { from = old.series.midSlide(from: before, progress: progress) }
        }
        self.init(series: series, previous: from, arrivedAt: arrivedAt)
    }

    init(series: LiveSeries, previous: LiveSeries?, arrivedAt: Date) {
        self.series = series
        self.previous = previous
        self.arrivedAt = arrivedAt
        var p = Paths()
        p.line = Path(series.line.cgPath)
        p.lineUnseen = Path(series.lineUnseen.cgPath)
        p.body = Path(series.body.cgPath)
        p.bodyUnseen = Path(series.bodyUnseen.cgPath)
        p.band = Path(series.band.cgPath)
        if previous != nil {
            let before = series.pathsBeforeLast()
            p.beforeLine = Path(before.line.cgPath)
            p.beforeLineUnseen = Path(before.lineUnseen.cgPath)
            p.beforeBody = Path(before.body.cgPath)
            p.beforeBodyUnseen = Path(before.bodyUnseen.cgPath)
        }
        let base = series.map.baseline
        for gap in series.gaps {
            p.gaps.move(to: CGPoint(x: series.x(gap.fromMs), y: base))
            p.gaps.addLine(to: CGPoint(x: series.x(gap.toMs), y: base))
        }
        if series.atRest {
            for run in series.runs {
                guard let first = run.first, let last = run.last else { continue }
                p.rest.move(to: CGPoint(x: series.x(first.t), y: base))
                p.rest.addLine(to: CGPoint(x: series.x(last.t), y: base))
            }
        }
        paths = p
        let all = series.readings
        readings = all
        times = all.map(\.t)
        var marks = Set<Int>()
        if let hi = all.indices.max(by: { all[$0].v < all[$1].v }) { marks.insert(hi) }
        if let lo = all.indices.min(by: { all[$0].v < all[$1].v }) { marks.insert(lo) }
        var i = 0
        for run in series.runs where !run.isEmpty {
            marks.insert(i)
            marks.insert(i + run.count - 1)
            i += run.count
        }
        landmarks = marks
    }

    static func == (a: TraceFrame, b: TraceFrame) -> Bool {
        a.arrivedAt == b.arrivedAt && a.series == b.series
    }
}

/// The node view's hero chart: the last five minutes, one smooth line with
/// its band and body, the head on the raw last reading. It scrolls with
/// the clock by translation alone, at 15 fps at rest; a new reading slides
/// in over 0.25 s at the display's rate, and every value drawn on the way
/// lies between two readings the box sent. It glows only while live, and
/// only in dark mode. What this phone did not see live is drawn in ink. No
/// dot ever travels along the line.
///
/// A source at rest (`LiveSeries.atRest`) draws no line: zero sits
/// mid-plot as a dotted baseline under its readings, in place of the solid
/// zero, as Now draws a node at rest, with the head on the last reading.
///
/// While a finger is down the window holds still (`frozenAtMs`); on lift
/// it catches up with the spring.
struct LiveTraceSurface: View {
    let frame: TraceFrame
    let look: TraceLook
    let live: Bool
    let chartFrame: ChartFrame
    /// The moment the window holds at while a finger is down.
    var frozenAtMs: Double?
    /// The moment the window was held at before the finger lifted, and
    /// when it lifted: the window springs from there back to now.
    var catchUp: (fromMs: Double, at: Date)?
    var axisSize: CGFloat = 10
    /// Hold still at the last reading: a trace that is not live has
    /// nothing to scroll toward (the watch, whose redraws cost battery).
    var paused = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    /// Set 0.3 s after a reading came or a finger lifted, so the rest of
    /// the second runs at 15 fps.
    @State private var settledAt: Date?

    static let slide = TraceInk.slide
    static let spring = TraceInk.spring

    var body: some View {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let moving = settledAt.map { $0 < max(frame.arrivedAt, catchUp?.at ?? .distantPast) } ?? true
        let still = reduceMotion || frozenAtMs != nil || phase != .active || paused
        TimelineView(.animation(minimumInterval: lowPower ? 1.0 / 10 : (moving ? nil : 1.0 / 15), paused: still)) { tick in
            Canvas(rendersAsynchronously: false) { g, size in
                #if DEBUG
                let began = ContinuousClock.now
                defer { ChartDraws.trace(ContinuousClock.now - began) }
                #endif
                draw(in: &g, size: size, at: still && frozenAtMs == nil ? Date(timeIntervalSince1970: frame.series.nowMs / 1000) : tick.date, slides: !lowPower && !reduceMotion)
            }
        }
        .task(id: max(frame.arrivedAt, catchUp?.at ?? .distantPast)) {
            try? await Task.sleep(for: .milliseconds(300))
            settledAt = .now
        }
    }

    static func ease(_ elapsed: TimeInterval, _ duration: TimeInterval) -> Double {
        TraceInk.ease(elapsed, duration)
    }

    private func draw(in g: inout GraphicsContext, size: CGSize, at date: Date, slides: Bool) {
        let series = frame.series
        let plot = chartFrame.plot(in: size)
        let px = 1 / max(g.environment.displayScale, 1)
        let glows = TraceInk.glows(live: live, in: g)

        // The window's moment: held under a finger, springing back on lift.
        var viewMs = frozenAtMs ?? date.timeIntervalSince1970 * 1000
        if frozenAtMs == nil, let catchUp {
            let k = Self.ease(date.timeIntervalSince(catchUp.at), Self.spring)
            viewMs = catchUp.fromMs + (viewMs - catchUp.fromMs) * k
        }
        let shift = series.shift(at: viewMs)
        let map = series.map
        let base = map.baseline

        // A new scale moves as one spring, never jumps: y on the new scale
        // back to watts, then onto the scale on its way.
        var scale = CGAffineTransform.identity
        var shown = series.domain
        if let previous = frame.previous, previous.domain != series.domain {
            let k = Self.ease(date.timeIntervalSince(frame.arrivedAt), Self.spring)
            shown = TraceInk.between(previous.domain, series.domain, k)
            scale = TraceInk.rescale(series.domain, shown, height: series.size.height)
        }
        let baseline = CGPoint(x: 0, y: base).applying(scale).y

        // Axes first, still: zero, the magnitudes in the gutter, and the
        // direction words when both signs show and no reading runs under
        // them, as on every chart.
        // Only the left of the window can run under a word.
        let reach = frame.readings.prefix { series.x($0.t) - shift <= 120 }.map { ChartReach(x: series.x($0.t) - shift, low: $0.v, high: $0.v) }
        ChartAxes.draw(in: &g, plot: plot, domain: series.domain, px: px, axis: axisSize, look: look, shown: shown, reach: reach, zero: !series.atRest)

        var plotting = g
        plotting.clip(to: Path(CGRect(x: plot.minX, y: plot.minY - 12, width: plot.width, height: plot.height + 24)))
        plotting.translateBy(x: plot.minX - shift, y: plot.minY)

        // The paths for this frame: as built, or the last run on its way.
        var p = frame.paths
        var head = series.head
        if slides, let previous = frame.previous {
            let progress = Self.ease(date.timeIntervalSince(frame.arrivedAt), Self.slide)
            if let curve = series.sliding(from: previous, progress: progress) {
                let last = series.paths(curve)
                p.line = p.beforeLine
                p.line.addPath(Path(last.line.cgPath))
                p.lineUnseen = p.beforeLineUnseen
                p.lineUnseen.addPath(Path(last.lineUnseen.cgPath))
                p.body = p.beforeBody
                p.body.addPath(Path(last.body.cgPath))
                p.bodyUnseen = p.beforeBodyUnseen
                p.bodyUnseen.addPath(Path(last.bodyUnseen.cgPath))
                if let h = curve.last { head = CGPoint(x: series.x(h.t), y: map.y(h.v)) }
            }
        }
        if scale != .identity {
            p.line = p.line.applying(scale)
            p.lineUnseen = p.lineUnseen.applying(scale)
            p.body = p.body.applying(scale)
            p.bodyUnseen = p.bodyUnseen.applying(scale)
            p.band = p.band.applying(scale)
            p.gaps = p.gaps.applying(scale)
            p.rest = p.rest.applying(scale)
            head = head?.applying(scale)
        }

        let width = series.size.width + shift + 40
        let above = Path(CGRect(x: -width, y: -40, width: 3 * width, height: baseline + 40))
        let below = Path(CGRect(x: -width, y: baseline, width: 3 * width, height: series.size.height - baseline + 40))

        // At rest: the dotted baseline under the readings, the head on the
        // last, and nothing else.
        if series.atRest {
            TraceInk.dotted(p.rest, px: px, in: plotting)
            TraceInk.dotted(p.gaps, px: px, in: plotting)
            if let head { Self.head(head, baseline: baseline, look: look, live: live, glows: glows, in: plotting) }
            return
        }

        // The band, under everything: how far the raw readings swung. Then
        // the body; what this phone did not see live in ink.
        TraceInk.band(p.band, look: look, above: above, below: below, in: plotting)
        TraceInk.body(p.body, look: look, baseline: baseline, height: series.size.height, above: above, below: below, in: plotting)
        TraceInk.body(p.bodyUnseen, look: look, ink: true, baseline: baseline, height: series.size.height, above: above, below: below, in: plotting)

        // A silence the line does not join: a dotted baseline across it.
        TraceInk.dotted(p.gaps, px: px, in: plotting)

        // What this phone did not see live: ink, no glow.
        plotting.stroke(p.lineUnseen, with: .color(Theme.ink2), style: StrokeStyle(lineWidth: TraceInk.line, lineCap: .round, lineJoin: .round))

        // The line, each side of zero in its colour; glowing only while
        // live, and in ink once the reading is not.
        TraceInk.line(p.line, look: live ? look : TraceLook(up: Theme.ink2, down: Theme.ink2), glows: glows, above: above, below: below, in: plotting)

        if let head { Self.head(head, baseline: baseline, look: look, live: live, glows: glows, in: plotting) }
    }

    /// The head: quiet, on the raw last reading, a small halo only while
    /// live in the dark.
    private static func head(_ head: CGPoint, baseline: CGFloat, look: TraceLook, live: Bool, glows: Bool, in g: GraphicsContext) {
        let color = head.y <= baseline ? look.up : look.down
        if glows {
            g.fill(Path(ellipseIn: CGRect(x: head.x - 4.5, y: head.y - 4.5, width: 9, height: 9)), with: .color(color.opacity(0.3)))
        }
        let r: CGFloat = 1.75
        g.fill(Path(ellipseIn: CGRect(x: head.x - r, y: head.y - r, width: 2 * r, height: 2 * r)), with: .color(live ? Theme.ink : Theme.ink2))
    }
}

