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
    /// The dot's colour, and below zero when that differs, as on the live
    /// trace.
    var color: Color = Theme.ink
    var downColor: Color?
    /// A value that holds across its slot (a price, a plan quarter): the
    /// slot under the finger lights up as its whole bar and the rest dims,
    /// in place of a dot on a line.
    var bars = false
    /// How much of its slot a bar fills, centred, and its corner: a day's
    /// bar stands apart from its neighbours, a quarter's touches them.
    var barShare: CGFloat = 1
    var barRadius: CGFloat = 1.25
    /// The last slot a finger may reach: the slots after it have not
    /// happened yet.
    var limit: Int?

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
/// It owns the tap too (`FingerGate`): a touch that lifts before it moves
/// 6 pt and before 150 ms calls `onTap` and never moves the scrub, so the
/// marker, the hero and the haptics stay still. A touch that starts within
/// 20 pt of the screen's leading edge is the system's back swipe.
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
    /// A touch that lifted before it scrubbed: the node view opens the chart
    /// on the whole screen.
    var onTap: (() -> Void)?
    /// Where a chart can be moved through time: a one-finger drag moves
    /// the window instead of reading it, and a finger that rests reads.
    /// Given where the finger came down and where it is, each across the
    /// plot, and whether this is the first event of that move. A chart
    /// without it reads on the move, as every chart always has.
    var onPan: ((Double, Double, Bool) -> Void)?
    var onPanEnded: (() -> Void)?

    @GestureState private var touching = false
    @State private var size: CGSize = .zero
    @State private var gate = FingerGate()
    #if DEBUG
    /// The newest track, for the debug driver: its task keeps the view
    /// value it started with, often from before the data came.
    @State private var newest: ScrubTrack?
    #endif

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
        .leavesTheEdge()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .gesture(
            // Every touch at once: one finger scrubs, two hold a span, once
            // the gate says it is no tap.
            SpatialEventGesture()
                .updating($touching) { _, state, _ in state = true }
                .onChanged { events in
                    gate.changed(events, pans: onPan != nil, scrub: { follow($0) }, pan: { anchor, to, began in
                        let plot = frame.plot(in: size)
                        guard plot.width > 0 else { return }
                        onPan?(Double((anchor - plot.minX) / plot.width), Double((to - plot.minX) / plot.width), began)
                    })
                }
                .onEnded { _ in
                    if gate.ended() { onTap?() }
                    model.lift()
                    onPanEnded?()
                }
        )
        // A gesture the system takes away ends without onEnded.
        .onChange(of: touching) { _, now in
            if !now {
                gate.cancelled()
                model.lift()
                onPanEnded?()
            }
        }
        .sensoryFeedback(.selection, trigger: model.ticks)
        .sensoryFeedback(.impact(weight: .light), trigger: model.bumps)
        #if DEBUG
        .onChange(of: track, initial: true) { _, now in newest = now }
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

    private func slot(_ x: CGFloat, on given: ScrubTrack? = nil) -> Int? {
        let track = given ?? track
        let plot = frame.plot(in: size)
        guard let i = track.grid.index(atX: x - plot.minX, width: plot.width) else { return nil }
        return track.limit.map { min(i, $0) } ?? i
    }

    private func follow(_ x: CGFloat, on given: ScrubTrack? = nil) {
        guard let i = slot(x, on: given) else {
            ScrubModel.log.error("touching with no slot at x \(x)")
            return
        }
        model.move(to: i, landmark: (given ?? track).landmarks.contains(i))
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
        rule(at: x, plot: plot, px: px, in: &g)

        if track.values.indices.contains(i), let v = track.values[i] {
            let y = plot.minY + YMap(domain: track.domain, height: plot.height).y(v)
            let dot = CGPoint(x: x, y: y)
            LockOn.dot(at: dot, color: v < 0 ? track.downColor ?? track.color : track.color, in: &g)
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
            var a = snap(plot.minX + grid.x(atMs: max(grid.startMs(i), grid.fromMs), width: plot.width))
            var b = snap(plot.minX + grid.x(atMs: min(grid.endMs(i), grid.toMs), width: plot.width)) - px
            if track.barShare < 1 {
                let inset = snap((b - a) * (1 - track.barShare) / 2)
                a += inset
                b -= inset
            }
            let y = plot.minY + snap(map.y(v))
            let bar = CGRect(x: a, y: min(y, base), width: max(px, b - a), height: abs(y - base))
            let radius = min(track.barRadius, bar.width / 2, bar.height)
            let radii = v > 0
                ? RectangleCornerRadii(topLeading: radius, bottomLeading: 0, bottomTrailing: 0, topTrailing: radius)
                : RectangleCornerRadii(topLeading: 0, bottomLeading: radius, bottomTrailing: radius, topTrailing: 0)
            g.fill(Path(roundedRect: bar, cornerRadii: radii, style: .circular), with: .color(Theme.ink))
        }
    }

    private func rule(at x: CGFloat, plot: CGRect, px: CGFloat, in g: inout GraphicsContext) {
        LockOn.rule(at: x, plot: plot, px: px, in: &g)
    }

    private func tag(_ string: String, over x: CGFloat, plot: CGRect, in g: inout GraphicsContext, size: CGSize) {
        LockOn.tag(string, over: x, plot: plot, size: tagSize, in: &g, canvas: size)
    }

    static func brackets(around p: CGPoint, half: CGFloat, arm: CGFloat) -> Path {
        LockOn.brackets(around: p, half: half, arm: arm)
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
            follow(CGFloat(-0.05 + 1.1 * along) * size.width, on: newest)
            try? await Task.sleep(for: .milliseconds(8))
        }
        // Then two fingers, held for three seconds.
        if let a = slot(0.3 * size.width, on: newest), let b = slot(0.55 * size.width, on: newest) { model.spread(a, b) }
        try? await Task.sleep(for: .seconds(3))
        model.lift()
    }
    #endif
}

/// A touch on a chart, held until `TouchIntent` says it is a scrub or a
/// tap. Nothing that draws reads it, so a touch costs no redraw while it
/// waits. A finger that rests is a scrub after 150 ms, with no event to
/// say so; one short sleep per touch decides it.
@MainActor
final class FingerGate {
    private var intent: TouchIntent?
    private var hold: Task<Void, Never>?
    private var last: SpatialEventCollection?
    private var scrub: ((SpatialEventCollection) -> Void)?

    private static func ms() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }

    /// The fingers moved. `scrub` takes every event once the touch is a
    /// scrub; `pan` takes it where the chart can be moved through time and
    /// the finger moved before it rested.
    func changed(
        _ events: SpatialEventCollection,
        pans: Bool = false,
        scrub: @escaping (SpatialEventCollection) -> Void,
        pan: @escaping (CGFloat, CGFloat, Bool) -> Void = { _, _, _ in }
    ) {
        let down = events.filter { $0.phase == .active }
        self.scrub = scrub
        last = events
        guard let first = down.first else {
            if intent?.state == .scrub { scrub(events) }
            return
        }
        if intent == nil {
            intent = TouchIntent(at: first.location, ms: Self.ms(), pans: pans)
            hold = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(TouchIntent.holdMs)))
                guard !Task.isCancelled else { return }
                self?.rested()
            }
        }
        guard var touch = intent else { return }
        let was = touch.state
        touch.moved(to: first.location, atMs: Self.ms(), fingers: down.count)
        intent = touch
        if touch.state == .pan {
            if was == .waiting {
                ScrubModel.log.debug("pan starts: moved \(Double(touch.travel), format: .fixed(precision: 1)) pt")
                hold?.cancel()
            }
            pan(touch.start.x, first.location.x, was == .waiting)
            return
        }
        guard touch.state == .scrub else { return }
        if was == .waiting {
            ScrubModel.log.debug("scrub starts: moved \(Double(touch.travel), format: .fixed(precision: 1)) pt, fingers \(down.count)")
            hold?.cancel()
        }
        scrub(events)
    }

    /// The finger rested 150 ms where it came down.
    private func rested() {
        guard var touch = intent, touch.state == .waiting else { return }
        touch.held(atMs: Self.ms())
        intent = touch
        guard touch.state == .scrub, let last else { return }
        ScrubModel.log.debug("scrub starts: rested \(Int(TouchIntent.holdMs)) ms, moved \(Double(touch.travel), format: .fixed(precision: 1)) pt")
        scrub?(last)
    }

    /// Every finger lifted. True when the touch never scrubbed: a tap.
    func ended() -> Bool {
        defer { reset() }
        guard var touch = intent else { return false }
        let tap = touch.lifted() == .tap
        if tap {
            ScrubModel.log.debug("tap: lifted after \(Int(Self.ms() - touch.startMs)) ms, moved \(Double(touch.travel), format: .fixed(precision: 1)) pt, no scrub")
        }
        return tap
    }

    /// The system took the touch: no tap, no scrub.
    func cancelled() {
        reset()
    }

    private func reset() {
        hold?.cancel()
        hold = nil
        intent = nil
        last = nil
        scrub = nil
    }
}

/// The view takes no touch that starts within 20 pt of the screen's
/// leading edge (`EdgeRule`), so the system's back swipe goes back.
struct LeavesTheEdge: ViewModifier {
    @State private var minX: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .contentShape(EdgeClear(leading: EdgeRule.inset(minX: minX)))
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: { minX = $0 }
    }
}

/// A rectangle with its leading `leading` points cut away.
struct EdgeClear: Shape {
    var leading: CGFloat

    func path(in rect: CGRect) -> Path {
        let cut = min(max(0, leading), rect.width)
        return Path(CGRect(x: rect.minX + cut, y: rect.minY, width: rect.width - cut, height: rect.height))
    }
}

extension View {
    /// Leaves the screen's leading 20 pt to the system's back swipe.
    func leavesTheEdge() -> some View { modifier(LeavesTheEdge()) }
}

/// The lock-on, one of the six TUI details: what the finger is on, drawn
/// the same on every chart. A 1 px rule, a dot in the series colour with a
/// ring of the ground and corner brackets closing on it, and an
/// inverse-video tag at the top of the rule.
enum LockOn {
    static func rule(at x: CGFloat, plot: CGRect, px: CGFloat, in g: inout GraphicsContext) {
        var rule = Path()
        rule.move(to: CGPoint(x: x, y: plot.minY))
        rule.addLine(to: CGPoint(x: x, y: plot.maxY))
        g.stroke(rule, with: .color(Theme.ink.opacity(0.5)), style: StrokeStyle(lineWidth: px, lineCap: .round, lineJoin: .round))
    }

    static func dot(at p: CGPoint, color: Color, in g: inout GraphicsContext) {
        g.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(Theme.ground))
        g.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(color))
        g.stroke(brackets(around: p, half: 11, arm: 5), with: .color(Theme.ink.opacity(0.8)), style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
    }

    /// The tag rides the top of the rule, clear of the thumb, kept inside
    /// the canvas: an ink capsule with the ground for words.
    static func tag(_ string: String, over x: CGFloat, plot: CGRect, size: CGFloat, in g: inout GraphicsContext, canvas: CGSize) {
        let text = g.resolve(Text(verbatim: string)
            .font(.system(size: size, weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.ground))
        let t = text.measure(in: CGSize(width: canvas.width, height: .infinity))
        let w = t.width + 8, h = t.height + 3
        let box = CGRect(x: min(max(x - w / 2, 0), max(0, canvas.width - w)), y: max(0, plot.minY - h - 2), width: w, height: h)
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
}
