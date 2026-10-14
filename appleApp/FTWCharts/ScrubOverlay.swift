import FTWShared
import SwiftUI

/// What the finger can land on in one chart, worked out with its data:
/// the slots, where each one's dot sits, the tag it shows and the slots
/// that earn a firmer haptic.
struct ScrubTrack: Equatable {
    var grid: SlotGrid
    var domain: YDomain
    /// The dot's value per slot, in the domain's unit; nil draws no dot.
    var values: [Double?]
    /// Where each slot's dot sits in time; nil puts it in the slot's middle.
    var atMs: [Double]?
    /// "02:15  31,0 öre", per slot.
    var tags: [String]
    var landmarks: Set<Int>
    /// The dot's colour.
    var color: Color = Theme.ink
    /// Dims what lies right of the finger, for a history's "so far".
    var dimsAfter = false
    /// A value that holds across its slot (a price, a plan quarter): the
    /// slot under the finger lights up as its whole bar and the rest dims,
    /// in place of a dot on a line.
    var bars = false

    func x(_ i: Int, plot: CGRect) -> CGFloat {
        if let atMs, atMs.indices.contains(i) { return plot.minX + grid.x(atMs: atMs[i], width: plot.width) }
        return plot.minX + grid.midX(i, width: plot.width)
    }
}

/// The finger on a chart, in one small Canvas over the surface. It owns
/// the gesture across the whole frame, so a finger past either end or
/// above and below the plot still has a slot, clamped, and the marker
/// never vanishes while it is down. It reads only the scrub model and
/// redraws once per slot change, however fast the finger moves.
///
/// The marks are the lock-on: a 1 px rule, a dot in the series colour with
/// a ring of the ground, corner brackets that close on it and an
/// inverse-video tag at the top of the rule. The position never animates;
/// the marker fades in over 80 ms and out over 150 ms.
struct ScrubOverlay: View {
    let track: ScrubTrack
    let frame: ChartFrame
    let model: ScrubModel
    /// The tag's mono size, scaled with the text.
    var tagSize: CGFloat = 11
    /// The tag over two fingers' span: "02:00–04:00  51,9 öre". Called once
    /// per change of the span.
    var spanTag: (ClosedRange<Int>) -> String = { _ in "" }

    @GestureState private var touching = false
    @State private var size: CGSize = .zero

    var body: some View {
        let down = model.isDown
        let shown = model.shown
        let spanText = shown.flatMap { if case let .span(r) = $0 { return spanTag(r) } else { return nil } }
        Canvas(rendersAsynchronously: false) { g, size in
            #if DEBUG
            let began = ContinuousClock.now
            defer {
                let ms = (ContinuousClock.now - began) / .milliseconds(1)
                ChartDraws.overlay += 1
                ChartDraws.overlayMs += ms
                ChartDraws.worstMs = max(ChartDraws.worstMs, ms)
            }
            #endif
            switch shown {
            case let .slot(i)? where i < track.grid.count: draw(i, in: &g, size: size)
            case let .span(r)? where r.upperBound < track.grid.count: draw(r, tag: spanText ?? "", in: &g, size: size)
            default: break
            }
        }
        .opacity(down ? 1 : 0)
        .animation(.easeOut(duration: down ? 0.08 : 0.15), value: down)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .gesture(
            // Every touch at once: one finger scrubs, two hold a span.
            SpatialEventGesture()
                .updating($touching) { _, state, _ in state = true }
                .onChanged { events in follow(events) }
                .onEnded { _ in model.lift() }
        )
        // A gesture the system takes away ends without onEnded.
        .onChange(of: touching) { _, now in if !now { model.lift() } }
        .sensoryFeedback(.selection, trigger: model.ticks)
        .sensoryFeedback(.impact(weight: .light), trigger: model.bumps)
        #if DEBUG
        .task { await autoScrub() }
        #endif
    }

    private func follow(_ events: SpatialEventCollection) {
        let down = events.filter { $0.phase == .active }.sorted { $0.location.x < $1.location.x }
        if down.count >= 2, let a = slot(down[0].location.x), let b = slot(down[down.count - 1].location.x) {
            model.spread(a, b)
        } else if let one = down.first {
            follow(one.location.x)
        } else {
            model.lift()
        }
    }

    private func slot(_ x: CGFloat) -> Int? {
        let plot = frame.plot(in: size)
        return track.grid.index(atX: x - plot.minX, width: plot.width)
    }

    private func follow(_ x: CGFloat) {
        guard let i = slot(x) else {
            ScrubModel.log.error("touching with no slot at x \(x)")
            return
        }
        model.move(to: i, landmark: track.landmarks.contains(i))
    }

    private func draw(_ i: Int, in g: inout GraphicsContext, size: CGSize) {
        let plot = frame.plot(in: size)
        let px = 1 / max(g.environment.displayScale, 1)
        let x = (track.x(i, plot: plot) / px).rounded() * px + px / 2

        if track.bars {
            lit(i...i, plot: plot, px: px, in: &g)
            rule(at: x, plot: plot, px: px, in: &g)
            tag(track.tags.indices.contains(i) ? track.tags[i] : "", over: x, plot: plot, in: &g, size: size)
            return
        }
        if track.dimsAfter {
            g.fill(Path(CGRect(x: x, y: 0, width: max(0, plot.maxX - x), height: size.height)), with: .color(Theme.ground.opacity(0.55)))
        }
        rule(at: x, plot: plot, px: px, in: &g)

        if track.values.indices.contains(i), let v = track.values[i] {
            let y = plot.minY + YMap(domain: track.domain, height: plot.height).y(v)
            let dot = CGPoint(x: x, y: y)
            g.fill(Path(ellipseIn: CGRect(x: x - 6, y: y - 6, width: 12, height: 12)), with: .color(Theme.ground))
            g.fill(Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8)), with: .color(track.color))
            g.stroke(Self.brackets(around: dot, half: 11, arm: 5), with: .color(Theme.ink.opacity(0.8)), style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
        }
        tag(track.tags.indices.contains(i) ? track.tags[i] : "", over: x, plot: plot, in: &g, size: size)
    }

    /// Two fingers: the slots between them under a faint wash, a rule at
    /// each end, and the span's tag over its middle.
    private func draw(_ r: ClosedRange<Int>, tag text: String, in g: inout GraphicsContext, size: CGSize) {
        let plot = frame.plot(in: size)
        let px = 1 / max(g.environment.displayScale, 1)
        func snap(_ v: CGFloat) -> CGFloat { (v / px).rounded() * px + px / 2 }
        let x0 = snap(plot.minX + track.grid.x(atMs: max(track.grid.startMs(r.lowerBound), track.grid.fromMs), width: plot.width))
        let x1 = snap(plot.minX + track.grid.x(atMs: min(track.grid.endMs(r.upperBound), track.grid.toMs), width: plot.width))
        if track.bars {
            lit(r, plot: plot, px: px, in: &g)
        } else {
            g.fill(Path(CGRect(x: x0, y: plot.minY, width: max(px, x1 - x0), height: plot.height)), with: .color(Theme.ink.opacity(0.08)))
        }
        rule(at: x0, plot: plot, px: px, in: &g)
        rule(at: x1, plot: plot, px: px, in: &g)
        tag(text, over: (x0 + x1) / 2, plot: plot, in: &g, size: size)
    }

    /// Bars: the slots in `r` light up. Everything else in the plot dims
    /// under the ground at half strength, each lit slot's column takes a
    /// faint wash from top to bottom, and its bar is drawn again in full
    /// ink, its whole width and height. A slot with no value keeps its
    /// wash, so the finger still sees where it is.
    private func lit(_ r: ClosedRange<Int>, plot: CGRect, px: CGFloat, in g: inout GraphicsContext) {
        func snap(_ v: CGFloat) -> CGFloat { (v / px).rounded() * px }
        let grid = track.grid
        let x0 = snap(plot.minX + grid.x(atMs: max(grid.startMs(r.lowerBound), grid.fromMs), width: plot.width))
        let x1 = snap(plot.minX + grid.x(atMs: min(grid.endMs(r.upperBound), grid.toMs), width: plot.width))
        g.fill(Path(CGRect(x: plot.minX, y: plot.minY, width: max(0, x0 - plot.minX), height: plot.height)), with: .color(Theme.ground.opacity(0.5)))
        g.fill(Path(CGRect(x: x1, y: plot.minY, width: max(0, plot.maxX - x1), height: plot.height)), with: .color(Theme.ground.opacity(0.5)))
        g.fill(Path(CGRect(x: x0, y: plot.minY, width: max(px, x1 - x0 - px), height: plot.height)), with: .color(Theme.ink.opacity(0.16)))
        let map = YMap(domain: track.domain, height: plot.height)
        let base = plot.minY + snap(map.baseline)
        for i in r where track.values.indices.contains(i) {
            guard let v = track.values[i], v != 0 else { continue }
            let a = snap(plot.minX + grid.x(atMs: max(grid.startMs(i), grid.fromMs), width: plot.width))
            let b = snap(plot.minX + grid.x(atMs: min(grid.endMs(i), grid.toMs), width: plot.width)) - px
            let y = plot.minY + snap(map.y(v))
            let bar = CGRect(x: a, y: min(y, base), width: max(px, b - a), height: abs(y - base))
            let radius = min(1.25, bar.width / 2, bar.height)
            let radii = v > 0
                ? RectangleCornerRadii(topLeading: radius, bottomLeading: 0, bottomTrailing: 0, topTrailing: radius)
                : RectangleCornerRadii(topLeading: 0, bottomLeading: radius, bottomTrailing: radius, topTrailing: 0)
            g.fill(Path(roundedRect: bar, cornerRadii: radii, style: .circular), with: .color(Theme.ink))
        }
    }

    private func rule(at x: CGFloat, plot: CGRect, px: CGFloat, in g: inout GraphicsContext) {
        var rule = Path()
        rule.move(to: CGPoint(x: x, y: plot.minY))
        rule.addLine(to: CGPoint(x: x, y: plot.maxY))
        g.stroke(rule, with: .color(Theme.ink.opacity(0.5)), style: StrokeStyle(lineWidth: px, lineCap: .round, lineJoin: .round))
    }

    /// The tag rides the top of the rule, clear of the thumb, kept inside
    /// the frame: inverse video, an ink capsule with the ground for words.
    private func tag(_ string: String, over x: CGFloat, plot: CGRect, in g: inout GraphicsContext, size: CGSize) {
        let text = g.resolve(Text(verbatim: string)
            .font(.system(size: tagSize, weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.ground))
        let t = text.measure(in: CGSize(width: size.width, height: .infinity))
        let w = t.width + 8, h = t.height + 3
        let box = CGRect(x: min(max(x - w / 2, 0), max(0, size.width - w)), y: max(0, plot.minY - h - 2), width: w, height: h)
        g.fill(Path(roundedRect: box, cornerRadius: 3), with: .color(Theme.ink))
        g.draw(text, at: CGPoint(x: box.midX, y: box.midY), anchor: .center)
    }

    /// Four corners of a square around `p`, each an arm long.
    static func brackets(around p: CGPoint, half: CGFloat, arm: CGFloat) -> Path {
        var path = Path()
        for (sx, sy) in [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)] {
            let corner = CGPoint(x: p.x + sx * half, y: p.y + sy * half)
            path.move(to: CGPoint(x: corner.x, y: corner.y - sy * arm))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x - sx * arm, y: corner.y))
        }
        return path
    }

    #if DEBUG
    /// With `-FTWAutoScrub YES`, ten seconds of a fast thumb, back and
    /// forth past both edges, then a two-finger span, through the same path
    /// touches take after they arrive. For measuring frames where nothing
    /// can touch.
    private func autoScrub() async {
        guard UserDefaults.standard.bool(forKey: "FTWAutoScrub") else { return }
        try? await Task.sleep(for: .seconds(2))
        let began = ContinuousClock.now
        while ContinuousClock.now - began < .seconds(10) {
            let t = (ContinuousClock.now - began) / .milliseconds(800)
            let phase = t.truncatingRemainder(dividingBy: 2)
            let along = phase < 1 ? phase : 2 - phase
            follow(CGFloat(-0.05 + 1.1 * along) * size.width)
            try? await Task.sleep(for: .milliseconds(8))
        }
        // Then two fingers, held for three seconds.
        if let a = slot(0.3 * size.width), let b = slot(0.55 * size.width) { model.spread(a, b) }
        try? await Task.sleep(for: .seconds(3))
        model.lift()
    }
    #endif
}
