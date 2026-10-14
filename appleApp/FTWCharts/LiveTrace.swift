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

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.scenePhase) private var phase
    /// Set 0.3 s after a reading came or a finger lifted, so the rest of
    /// the second runs at 15 fps.
    @State private var settledAt: Date?

    static let slide: TimeInterval = 0.25
    static let spring: TimeInterval = 0.35

    var body: some View {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let moving = settledAt.map { $0 < max(frame.arrivedAt, catchUp?.at ?? .distantPast) } ?? true
        let still = reduceMotion || frozenAtMs != nil || phase != .active
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

    /// A critically damped ease from 0 to 1 over `duration`.
    static func ease(_ elapsed: TimeInterval, _ duration: TimeInterval) -> Double {
        guard elapsed < duration else { return 1 }
        let w = 6.0 / duration, t = max(0, elapsed)
        return min(1, 1 - (1 + w * t) * exp(-w * t))
    }

    private func draw(in g: inout GraphicsContext, size: CGSize, at date: Date, slides: Bool) {
        let series = frame.series
        let plot = chartFrame.plot(in: size)
        let px = 1 / max(g.environment.displayScale, 1)
        let dark = scheme == .dark
        let glows = dark && live && !reduceTransparency

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
        if let previous = frame.previous, previous.domain != series.domain {
            let k = Self.ease(date.timeIntervalSince(frame.arrivedAt), Self.spring)
            let h = series.size.height
            let lower = previous.domain.lower + (series.domain.lower - previous.domain.lower) * k
            let upper = previous.domain.upper + (series.domain.upper - previous.domain.upper) * k
            let span = max(upper - lower, 1)
            let aNew = -h / CGFloat(series.domain.span), bNew = h * CGFloat(series.domain.upper / series.domain.span)
            let aNow = -h / CGFloat(span), bNow = h * CGFloat(upper / span)
            let d = aNow / aNew
            scale = CGAffineTransform(a: 1, b: 0, c: 0, d: d, tx: 0, ty: bNow - d * bNew)
        }
        let baseline = CGPoint(x: 0, y: base).applying(scale).y

        // Axes first, still: zero, the magnitudes in the gutter, and the
        // direction words when both signs show.
        drawAxes(in: &g, plot: plot, px: px, baseline: plot.minY + baseline)

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
            head = head?.applying(scale)
        }

        let width = series.size.width + shift + 40
        let above = Path(CGRect(x: -width, y: -40, width: 3 * width, height: baseline + 40))
        let below = Path(CGRect(x: -width, y: baseline, width: 3 * width, height: series.size.height - baseline + 40))
        let peak = dark ? 0.30 : 0.18

        // The band, under everything: how far the raw readings swung.
        for (side, color) in [(above, look.up), (below, look.down)] {
            var s = plotting
            s.clip(to: side)
            s.fill(p.band, with: .color(color.opacity(dark ? 0.14 : 0.10)))
        }
        // The body: one gradient from nothing at zero to `peak` at the
        // scale's edge, in each direction's colour.
        do {
            var s = plotting
            s.clip(to: above)
            s.fill(p.body, with: .linearGradient(Gradient(colors: [look.up.opacity(0), look.up.opacity(peak)]), startPoint: CGPoint(x: 0, y: baseline), endPoint: CGPoint(x: 0, y: 0)))
            s.fill(p.bodyUnseen, with: .linearGradient(Gradient(colors: [Theme.ink.opacity(0), Theme.ink.opacity(peak * 0.5)]), startPoint: CGPoint(x: 0, y: baseline), endPoint: CGPoint(x: 0, y: 0)))
        }
        do {
            var s = plotting
            s.clip(to: below)
            s.fill(p.body, with: .linearGradient(Gradient(colors: [look.down.opacity(0), look.down.opacity(peak)]), startPoint: CGPoint(x: 0, y: baseline), endPoint: CGPoint(x: 0, y: series.size.height)))
            s.fill(p.bodyUnseen, with: .linearGradient(Gradient(colors: [Theme.ink.opacity(0), Theme.ink.opacity(peak * 0.5)]), startPoint: CGPoint(x: 0, y: baseline), endPoint: CGPoint(x: 0, y: series.size.height)))
        }

        // A silence the line does not join: a dotted baseline across it.
        plotting.stroke(p.gaps, with: .color(Theme.ink.opacity(0.35)), style: StrokeStyle(lineWidth: px, lineCap: .butt, lineJoin: .round, dash: [1, 3]))

        // What this phone did not see live: ink, no glow.
        plotting.stroke(p.lineUnseen, with: .color(Theme.ink2), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

        // The line, each side of zero in its colour; glowing only while live.
        for (side, color) in [(above, look.up), (below, look.down)] {
            var s = plotting
            s.clip(to: side)
            if glows {
                s.stroke(p.line, with: .color(color.opacity(0.12)), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                s.stroke(p.line, with: .color(color.opacity(0.25)), style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
            }
            s.stroke(p.line, with: .color(live ? color : Theme.ink2), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }

        // The head: quiet, on the raw last reading, a small halo only while
        // live in the dark.
        if let head {
            let color = head.y <= baseline ? look.up : look.down
            if glows {
                plotting.fill(Path(ellipseIn: CGRect(x: head.x - 4.5, y: head.y - 4.5, width: 9, height: 9)), with: .color(color.opacity(0.3)))
            }
            let r: CGFloat = 1.75
            plotting.fill(Path(ellipseIn: CGRect(x: head.x - r, y: head.y - r, width: 2 * r, height: 2 * r)), with: .color(live ? Theme.ink : Theme.ink2))
        }
    }

    private func drawAxes(in g: inout GraphicsContext, plot: CGRect, px: CGFloat, baseline: CGFloat) {
        let domain = frame.series.domain
        var zero = Path()
        zero.move(to: CGPoint(x: plot.minX, y: (baseline / px).rounded() * px + px / 2))
        zero.addLine(to: CGPoint(x: plot.maxX, y: (baseline / px).rounded() * px + px / 2))
        g.stroke(zero, with: .color(Theme.ink.opacity(0.35)), style: StrokeStyle(lineWidth: px, lineCap: .butt, lineJoin: .round))
        let map = YMap(domain: domain, height: plot.height)
        for v in [domain.upper, domain.lower] where v != 0 {
            let y = plot.minY + map.y(v)
            var grid = Path()
            grid.move(to: CGPoint(x: plot.minX, y: y))
            grid.addLine(to: CGPoint(x: plot.maxX, y: y))
            g.stroke(grid, with: .color(Theme.ink.opacity(0.12)), style: StrokeStyle(lineWidth: px, lineCap: .butt, lineJoin: .round, dash: [1, 3]))
            let label = g.resolve(ChartText.label(PowerFormat.scale(abs(v)), size: axisSize))
            g.draw(label, at: CGPoint(x: plot.maxX + 4, y: y), anchor: .leading)
        }
        if domain.lower < 0, domain.upper > 0 {
            if let up = look.upWord {
                g.draw(g.resolve(ChartText.label(up, size: axisSize)), at: CGPoint(x: plot.minX + 2, y: plot.minY + 2), anchor: .topLeading)
            }
            if let down = look.downWord {
                g.draw(g.resolve(ChartText.label(down, size: axisSize)), at: CGPoint(x: plot.minX + 2, y: plot.maxY - 2), anchor: .bottomLeading)
            }
        }
    }
}

/// The finger on the live trace. The window holds still under it; the dot
/// sits on the nearest raw reading, so it may sit a little off the
/// smoothed line, inside the band. A tick per reading crossed, a light
/// impact at the window's high and low and at the edges of a silence. Two
/// fingers hold a span of readings.
struct LiveScrubOverlay: View {
    let frame: TraceFrame
    let chartFrame: ChartFrame
    let model: ScrubModel
    /// The moment the window holds at: x maps to time through it.
    let viewMs: Double
    let look: TraceLook
    var tagSize: CGFloat = 11
    /// "14:31:42  2 412 W"
    let tag: (LiveSample) -> String
    /// "14:30:10–14:31:40  avg 1.2 kW"
    let spanTag: (ClosedRange<Int>) -> String

    @GestureState private var touching = false
    @State private var size: CGSize = .zero

    var body: some View {
        let down = model.isDown
        let shown = model.shown
        let text: String = {
            switch shown {
            case let .slot(i)? where frame.readings.indices.contains(i): return tag(frame.readings[i])
            case let .span(r)? where r.upperBound < frame.readings.count: return spanTag(r)
            default: return ""
            }
        }()
        Canvas(rendersAsynchronously: false) { g, size in
            #if DEBUG
            let began = ContinuousClock.now
            defer { ChartDraws.overlayDrew(ContinuousClock.now - began) }
            #endif
            switch shown {
            case let .slot(i)? where frame.readings.indices.contains(i): draw(i, text: text, in: &g, size: size)
            case let .span(r)? where r.upperBound < frame.readings.count: draw(r, text: text, in: &g, size: size)
            default: break
            }
        }
        .opacity(down ? 1 : 0)
        .animation(.easeOut(duration: down ? 0.08 : 0.15), value: down)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .gesture(
            SpatialEventGesture()
                .updating($touching) { _, state, _ in state = true }
                .onChanged { events in follow(events) }
                .onEnded { _ in model.lift() }
        )
        .onChange(of: touching) { _, now in if !now { model.lift() } }
        .sensoryFeedback(.selection, trigger: model.ticks)
        .sensoryFeedback(.impact(weight: .light), trigger: model.bumps)
    }

    private func reading(atX x: CGFloat) -> Int? {
        let s = frame.series
        let plot = chartFrame.plot(in: size)
        guard s.ptPerMs > 0 else { return nil }
        // x on screen, with the window held at `viewMs`, back to a moment.
        let t = viewMs - Double((plot.width - s.inset - (x - plot.minX)) / s.ptPerMs)
        return SlotGrid.nearest(frame.times, to: t)
    }

    private func follow(_ events: SpatialEventCollection) {
        let down = events.filter { $0.phase == .active }.sorted { $0.location.x < $1.location.x }
        if down.count >= 2, let a = reading(atX: down[0].location.x), let b = reading(atX: down[down.count - 1].location.x) {
            model.spread(a, b)
        } else if let one = down.first, let i = reading(atX: one.location.x) {
            model.move(to: i, landmark: frame.landmarks.contains(i))
        } else if down.isEmpty {
            model.lift()
        }
    }

    private func point(_ i: Int, plot: CGRect) -> CGPoint {
        let s = frame.series, r = frame.readings[i]
        return CGPoint(x: plot.minX + s.x(r.t) - s.shift(at: viewMs), y: plot.minY + s.map.y(r.v))
    }

    private func draw(_ i: Int, text: String, in g: inout GraphicsContext, size: CGSize) {
        let plot = chartFrame.plot(in: size)
        let px = 1 / max(g.environment.displayScale, 1)
        let p = point(i, plot: plot)
        let x = (p.x / px).rounded() * px + px / 2
        LockOn.rule(at: x, plot: plot, px: px, in: &g)
        LockOn.dot(at: CGPoint(x: x, y: p.y), color: frame.readings[i].v >= 0 ? look.up : look.down, in: &g)
        LockOn.tag(text, over: x, plot: plot, size: tagSize, in: &g, canvas: size)
    }

    private func draw(_ r: ClosedRange<Int>, text: String, in g: inout GraphicsContext, size: CGSize) {
        let plot = chartFrame.plot(in: size)
        let px = 1 / max(g.environment.displayScale, 1)
        let a = point(r.lowerBound, plot: plot).x, b = point(r.upperBound, plot: plot).x
        g.fill(Path(CGRect(x: a, y: plot.minY, width: max(px, b - a), height: plot.height)), with: .color(Theme.ink.opacity(0.08)))
        LockOn.rule(at: (a / px).rounded() * px + px / 2, plot: plot, px: px, in: &g)
        LockOn.rule(at: (b / px).rounded() * px + px / 2, plot: plot, px: px, in: &g)
        LockOn.tag(text, over: (a + b) / 2, plot: plot, size: tagSize, in: &g, canvas: size)
    }
}

