import FTWShared
import SwiftUI

/// Where the parts of Now's plan strip sit, from the top of its Canvas:
/// room for the lock-on's brackets, two 6 pt lanes 4 pt apart (battery,
/// then car), on the plan's lanes a row for the battery's level, the price
/// bars from zero in a row of 20 pt or more, and the hours under them. The price's scale takes a gutter on the right, so the
/// quarters run across the rest. The surface and the finger's overlay
/// share it, so a lit quarter and its bar meet.
struct PlanStripLayout: Equatable {
    static let lane: CGFloat = 6
    static let batteryY: CGFloat = 3
    static let carY: CGFloat = 13
    /// Where the lanes end; the level row, or the price, starts here.
    static let lanesBottom: CGFloat = 25
    /// The price row at its least, and the most it grows to when Now has
    /// room: the same two Now's layout reads.
    static let leastPrice = PlanStrip.leastPrice
    static let mostPrice = PlanStrip.mostPrice

    /// The hours' mono size, scaled with the text.
    var axis: CGFloat = 10
    /// The price row's height: 20 pt, or what Now gives it.
    var priceHeight: CGFloat = Self.leastPrice
    /// The battery level's row, between the lanes and the price: none on
    /// Now, where the strip stays small.
    var levelHeight: CGFloat = 0

    var priceTop: CGFloat { Self.lanesBottom + levelHeight }
    var priceBottom: CGFloat { priceTop + priceHeight }
    /// 100 % and 0 % in the level's row, clear of the lanes and the bars,
    /// and 0 %'s figure clear of the price's top figure at any text size.
    var levelTop: CGFloat { Self.lanesBottom + 5 }
    var levelBottom: CGFloat { priceTop - max(14, (axis * 1.2).rounded(.up)) }
    func levelY(_ pct: Double) -> CGFloat { levelBottom - CGFloat(min(100, max(0, pct)) / 100) * (levelBottom - levelTop) }
    var hoursTop: CGFloat { priceBottom + 3 }
    /// Room on the right for the scale's figures, "600", in the axis's
    /// mono at nine tenths of its size, or "100 %" beside a level row.
    var gutter: CGFloat { (axis * (levelHeight > 0 ? 3.4 : 2.4)).rounded(.up) + 4 }
    /// The width the quarters run across.
    func plotWidth(_ width: CGFloat) -> CGFloat { max(0, width - gutter) }
    var height: CGFloat { hoursTop + (axis * 1.25).rounded(.up) }
    /// The tallest the strip's drawing grows to.
    var tallest: CGFloat { height + Self.mostPrice - priceHeight }
    /// What a finger lights: the lanes and the bars, not the hours or the
    /// scale.
    func plot(width: CGFloat) -> CGRect { CGRect(x: 0, y: 0, width: plotWidth(width), height: priceBottom) }

    /// The same parts in a drawing `height` tall: the price row takes what
    /// the lanes and the hours leave.
    func fitting(_ height: CGFloat) -> PlanStripLayout {
        var out = self
        out.priceHeight = min(Self.mostPrice, max(Self.leastPrice, height - (self.height - priceHeight)))
        return out
    }

    /// A quarter run's left and right edge, pixel-snapped, with a 1 px gap
    /// before the next run.
    static func span(first: Int, last: Int, grid: SlotGrid, width: CGFloat, scale: CGFloat) -> (x0: CGFloat, x1: CGFloat) {
        func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        let x0 = snap(max(0, grid.x(atMs: grid.startMs(first), width: width)))
        let x1 = snap(min(width, grid.x(atMs: grid.endMs(last), width: width))) - 1 / scale
        return (x0, max(x0, x1))
    }

    /// Where a price sits in the row, from its scale.
    func priceY(_ minor: Double, _ scale: PriceScale) -> CGFloat {
        priceBottom - CGFloat(scale.fraction(minor)) * priceHeight
    }

    /// A price's bar from the zero line: rounded at its far end, and never
    /// thinner than a point, so a price near zero still shows.
    func bar(_ minor: Double, _ scale: PriceScale, x0: CGFloat, x1: CGFloat) -> Path {
        let zero = priceY(0, scale), end = priceY(minor, scale)
        let up = end <= zero
        let h = max(1, abs(zero - end))
        let rect = CGRect(x: x0, y: up ? zero - h : zero, width: x1 - x0, height: h)
        let r = min(1.25, rect.width / 2)
        let radii = up
            ? RectangleCornerRadii(topLeading: r, bottomLeading: 0, bottomTrailing: 0, topTrailing: r)
            : RectangleCornerRadii(topLeading: 0, bottomLeading: r, bottomTrailing: r, topTrailing: 0)
        return Path(roundedRect: rect, cornerRadii: radii, style: .circular)
    }
}

/// Now's plan strip, in one Canvas: the battery's lane (gold gives, cyan
/// stores), the car's (violet, a 2 pt tick at its goal), an idle hairline
/// where a lane has nothing, 48 price bars from zero by ink third under
/// two grid lines with their figures, a dashed line at the price now, the
/// now rule across lanes and bars, and the hours. Equal neighbours are
/// one shape, so no run shows a seam. The lanes are a plan, so they are a
/// ghost: their colour at `Theme.plan`, never the full strength that says
/// live. A plan that is old, that the box could not make, or from a box
/// this phone cannot reach, is ink3 throughout. It never sees a finger.
///
/// The pass a tap chose stands out (Now, proposal 5): its run in full
/// colour, a faint column of its colour behind it, and the bars under it in
/// its colour, so the prices it meets read at a glance. The bars under the
/// battery's other runs take their colour faintly. Nothing glows: a plan
/// is not live.
struct PlanStripDrawing: ChartDrawing {
    let strip: PlanStrip
    var layout = PlanStripLayout()
    /// The pass a tap chose; nil draws every run as a ghost.
    var chosen: PlanPass?

    static func hue(_ kind: PlanPass.Kind) -> Color {
        switch kind {
        case .gives: return Theme.gives
        case .stores: return Theme.stores
        case .car: return Theme.car
        }
    }

    func draw(in g: inout GraphicsContext, size: CGSize) {
        let layout = self.layout.fitting(size.height)
        let scale = max(g.environment.displayScale, 1)
        let px = 1 / scale
        func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        let width = layout.plotWidth(size.width)
        let grid = strip.grid
        let grey = strip.grey
        let ghost = Theme.plan(g.environment.colorSchemeContrast)
        let oldInk = Theme.oldPlan
        let chosen = grey ? nil : self.chosen
        func inChosen(_ first: Int, _ last: Int, battery: Bool) -> Bool {
            guard let chosen, chosen.isBattery == battery else { return false }
            return first >= chosen.first && last <= chosen.last
        }

        // The chosen pass's column, behind everything: its colour fading
        // from the lanes down to the bars' foot.
        if let chosen {
            let s = PlanStripLayout.span(first: chosen.first, last: chosen.last, grid: grid, width: width, scale: scale)
            let x0 = max(0, s.x0 - 3), x1 = min(width, s.x1 + 3)
            let rect = CGRect(x: x0, y: 0, width: x1 - x0, height: layout.priceBottom)
            let hue = Self.hue(chosen.kind)
            g.fill(Path(roundedRect: rect, cornerRadius: 5, style: .continuous),
                   with: .linearGradient(Gradient(colors: [hue.opacity(0.16), hue.opacity(0.03)]), startPoint: CGPoint(x: rect.midX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
        }

        // A lane with nothing keeps a hairline, so a run never appears out
        // of nothing.
        var idle = Path()
        idle.addRect(CGRect(x: 0, y: snap(PlanStripLayout.batteryY + PlanStripLayout.lane / 2), width: width, height: px))
        if strip.hasCar {
            idle.addRect(CGRect(x: 0, y: snap(PlanStripLayout.carY + PlanStripLayout.lane / 2), width: width, height: px))
        }
        g.fill(idle, with: .color(Theme.ink.opacity(0.08)))

        func capsule(_ first: Int, _ last: Int, y: CGFloat) -> Path {
            let s = PlanStripLayout.span(first: first, last: last, grid: grid, width: width, scale: scale)
            let rect = CGRect(x: s.x0, y: y, width: s.x1 - s.x0, height: PlanStripLayout.lane)
            return Path(roundedRect: rect, cornerRadius: min(3, rect.width / 2), style: .circular)
        }

        var stores = Path(), gives = Path(), lit = Path()
        for run in strip.batteryRuns {
            let p = capsule(run.first, run.last, y: PlanStripLayout.batteryY)
            if inChosen(run.first, run.last, battery: true) { lit.addPath(p) } else if run.value == .stores { stores.addPath(p) } else { gives.addPath(p) }
        }
        g.fill(stores, with: .color(grey ? oldInk : Theme.stores.opacity(ghost)))
        g.fill(gives, with: .color(grey ? oldInk : Theme.gives.opacity(ghost)))

        var car = Path()
        for run in strip.carRuns {
            let p = capsule(run.first, run.last, y: PlanStripLayout.carY)
            if inChosen(run.first, run.last, battery: false) { lit.addPath(p) } else { car.addPath(p) }
        }
        if let chosen { g.fill(lit, with: .color(Self.hue(chosen.kind))) }
        // The goal: a 2 pt tick at the end of its quarter, past the lane.
        for (i, _) in strip.goals {
            let s = PlanStripLayout.span(first: i, last: i, grid: grid, width: width, scale: scale)
            car.addRect(CGRect(x: s.x1 - 2, y: PlanStripLayout.carY - 2, width: 2, height: PlanStripLayout.lane + 4))
        }
        g.fill(car, with: .color(grey ? oldInk : Theme.car.opacity(ghost)))

        if layout.levelHeight > 0 { drawLevel(in: &g, layout: layout, width: width, px: px, ghost: ghost, chosen: chosen) }

        // The scale: a hairline at half the top and at the top, each with
        // its figure in the gutter where there is room for it, and the zero
        // line when a price falls under it. In a short row at a large text
        // size the top keeps its figure and half the top keeps only its line.
        let priceScale = strip.scale
        var lines = Path()
        for v in priceScale.lines + (priceScale.bottom < 0 ? [0] : []) {
            lines.addRect(CGRect(x: 0, y: snap(layout.priceY(v, priceScale)), width: width, height: px))
        }
        g.fill(lines, with: .color(Theme.ink.opacity(0.1)))
        var lastY: CGFloat?
        for v in priceScale.lines.sorted(by: >) {
            let text = g.resolve(ChartText.label(priceScale.label(v), size: layout.axis * 0.9))
            let y = layout.priceY(v, priceScale)
            if let lastY, abs(y - lastY) < text.measure(in: size).height + 2 { continue }
            g.draw(text, at: CGPoint(x: width + 4, y: y), anchor: .leading)
            lastY = y
        }

        // The price: a bar per stretch of equal price and equal ink. Ink by
        // third, or the colour of the pass over it: full under the chosen
        // pass, faint under the battery's other runs.
        var inks: [BarInk: Path] = [:]
        for seg in segments(chosen: chosen) {
            let s = PlanStripLayout.span(first: seg.first, last: seg.last, grid: grid, width: width, scale: scale)
            inks[seg.ink, default: Path()].addPath(layout.bar(seg.minor, priceScale, x0: s.x0, x1: s.x1))
        }
        for (ink, path) in inks {
            g.fill(path, with: .color(grey ? Theme.ink3.opacity(0.6) : ink.color(chosen: chosen)))
        }
        // Not priced yet: a hatched stub, so a guess never looks like a price.
        if !strip.pending.isEmpty {
            var stubs = Path(), hatch = Path()
            let stub = layout.priceHeight / 4
            let base = layout.priceY(0, priceScale)
            for run in strip.pending {
                let s = PlanStripLayout.span(first: run.first, last: run.last, grid: grid, width: width, scale: scale)
                let rect = CGRect(x: s.x0, y: base - stub, width: s.x1 - s.x0, height: stub)
                stubs.addRect(rect)
                var x = rect.minX - stub
                while x < rect.maxX {
                    hatch.move(to: CGPoint(x: x, y: rect.maxY))
                    hatch.addLine(to: CGPoint(x: x + stub, y: rect.minY))
                    x += 3
                }
            }
            var clipped = g
            clipped.clip(to: stubs)
            clipped.stroke(hatch, with: .color(Theme.ink3), style: StrokeStyle(lineWidth: px, lineCap: .butt, lineJoin: .round))
        }

        // Now, one pixel across the lanes and the bars, and the price now
        // carried on as a dashed line, so a bar over it is dearer than now.
        let nowX = snap(grid.x(atMs: strip.nowMs, width: width))
        if let now = strip.nowMinor {
            var dash = Path()
            let y = snap(layout.priceY(now, priceScale)) + px / 2
            dash.move(to: CGPoint(x: nowX, y: y))
            dash.addLine(to: CGPoint(x: width, y: y))
            g.stroke(dash, with: .color(grey ? Theme.ink3 : Theme.ink2), style: StrokeStyle(lineWidth: 1, lineCap: .butt, lineJoin: .round, dash: [2, 2]))
        }
        g.fill(Path(CGRect(x: nowX, y: PlanStripLayout.batteryY, width: px, height: layout.priceBottom - PlanStripLayout.batteryY)), with: .color(grey ? Theme.ink3 : Theme.ink))

        // The hours, never cut at either edge.
        for tick in strip.hours {
            let text = g.resolve(ChartText.label(tick.label, size: layout.axis))
            let w = text.measure(in: size).width
            let x = grid.x(atMs: tick.ms, width: width)
            guard x - w / 2 >= 0, x + w / 2 <= width else { continue }
            g.draw(text, at: CGPoint(x: x, y: layout.hoursTop), anchor: .top)
        }
    }

    /// The battery's planned level through the strip, between hairlines at
    /// 0 and 100 % with their figures in the gutter: a line through the
    /// level at each quarter's end, in gold where the battery gives power,
    /// cyan where it stores and ink where it waits. A ghost, but the chosen
    /// pass's stretch at full strength.
    private func drawLevel(in g: inout GraphicsContext, layout: PlanStripLayout, width: CGFloat, px: CGFloat, ghost: Double, chosen: PlanPass?) {
        let grid = strip.grid
        var frame = Path()
        for pct in [0.0, 100.0] { frame.addRect(CGRect(x: 0, y: layout.levelY(pct), width: width, height: px)) }
        g.fill(frame, with: .color(Theme.ink.opacity(0.08)))
        for pct in [0.0, 100.0] {
            let text = g.resolve(ChartText.label("\(Int(pct))\u{00A0}%", size: layout.axis * 0.9))
            g.draw(text, at: CGPoint(x: width + 4, y: layout.levelY(pct)), anchor: .leading)
        }
        guard strip.levelPct.contains(where: { $0 != nil }) else { return }
        var paths: [String: Path] = [:]
        var last: CGPoint?
        for i in strip.levelPct.indices {
            guard let pct = strip.levelPct[i] else {
                last = nil
                continue
            }
            let p = CGPoint(x: grid.x(atMs: grid.endMs(i), width: width), y: layout.levelY(pct))
            if let from = last {
                let lit = !strip.grey && chosen.map { $0.isBattery && i >= $0.first && i <= $0.last } == true
                let key = (strip.battery[i].map { $0 == .stores ? "stores" : "gives" } ?? "waits") + (lit ? "!" : "")
                paths[key, default: Path()].move(to: from)
                paths[key, default: Path()].addLine(to: p)
            }
            last = p
        }
        let style = StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round)
        for (key, path) in paths {
            let lit = key.hasSuffix("!")
            let color: Color = strip.grey ? Theme.ink3
                : key.hasPrefix("stores") ? Theme.stores : key.hasPrefix("gives") ? Theme.gives : Theme.ink2
            g.stroke(path, with: .color(color.opacity(lit ? 1 : ghost)), style: style)
        }
    }

    /// What a price bar is filled with.
    enum BarInk: Hashable {
        case third(PriceChart.Third)
        /// A quarter gone by, under the dial: its price, fainter.
        case past(PriceChart.Third)
        /// Under the chosen pass; dear is the top third.
        case chosen(dear: Bool)
        /// Under another run of the battery.
        case battery(PlanStrip.Battery, dear: Bool)

        func color(chosen: PlanPass?) -> Color {
            switch self {
            case let .third(t): return Theme.ink.opacity(PlanStripDrawing.ink(t))
            case let .past(t): return Theme.ink.opacity(PlanStripDrawing.ink(t) * 0.4)
            case let .chosen(dear): return PlanStripDrawing.hue(chosen?.kind ?? .gives).opacity(dear ? 0.9 : 0.7)
            case let .battery(b, dear): return (b == .stores ? Theme.stores : Theme.gives).opacity(dear ? 0.5 : 0.36)
            }
        }
    }

    /// The price runs cut where the ink changes, so each piece is one fill.
    private func segments(chosen: PlanPass?) -> [(first: Int, last: Int, minor: Double, ink: BarInk)] {
        func ink(_ i: Int) -> BarInk? {
            guard strip.minor[i] != nil else { return nil }
            let third = strip.thirds[i] ?? .middle
            if strip.grid.endMs(i) <= strip.nowMs { return .past(third) }
            if let chosen, i >= chosen.first, i <= chosen.last, !chosen.isBattery || strip.battery[i] != nil {
                return .chosen(dear: third == .dear)
            }
            if let b = strip.battery[i], chosen != nil { return .battery(b, dear: third == .dear) }
            return .third(third)
        }
        var out: [(first: Int, last: Int, minor: Double, ink: BarInk)] = []
        for i in strip.minor.indices {
            guard let m = strip.minor[i], let k = ink(i) else { continue }
            if let prev = out.last, prev.last == i - 1, prev.minor == m, prev.ink == k {
                out[out.count - 1].last = i
            } else {
                out.append((i, i, m, k))
            }
        }
        return out
    }

    /// The design's thirds: the dearer, the stronger.
    static func ink(_ third: PriceChart.Third) -> Double {
        switch third {
        case .cheap: return 0.32
        case .middle: return 0.5
        case .dear: return 0.8
        }
    }
}

/// The finger on the strip, in one small Canvas over the surface: the
/// quarter under it lights as a column with its bar in full ink, the rest
/// dims, a 1 px rule runs through it and the lock-on brackets close on it.
/// It reads only the scrub model, so a finger redraws this and nothing
/// else, once per quarter. The position never animates; the marks fade in
/// over 80 ms and out over 150 ms.
struct PlanStripOverlay: View {
    let strip: PlanStrip
    let model: ScrubModel
    var layout = PlanStripLayout()

    var body: some View {
        let down = model.isDown
        let shown = model.shown
        Canvas(rendersAsynchronously: false) { g, size in
            #if DEBUG
            let began = ContinuousClock.now
            defer { ChartDraws.overlayDrew(ContinuousClock.now - began) }
            #endif
            guard case let .slot(i)? = shown, i < strip.grid.count else { return }
            draw(i, in: &g, size: size)
        }
        .opacity(down ? 1 : 0)
        .animation(.easeOut(duration: down ? 0.08 : 0.15), value: down)
        .allowsHitTesting(false)
        .sensoryFeedback(.selection, trigger: model.ticks)
        .sensoryFeedback(.impact(weight: .light), trigger: model.bumps)
    }

    private func draw(_ i: Int, in g: inout GraphicsContext, size: CGSize) {
        let layout = self.layout.fitting(size.height)
        let scale = max(g.environment.displayScale, 1)
        let px = 1 / scale
        let plot = layout.plot(width: size.width)
        let s = PlanStripLayout.span(first: i, last: i, grid: strip.grid, width: plot.width, scale: scale)
        let column = CGRect(x: s.x0, y: plot.minY, width: max(px, s.x1 - s.x0), height: plot.height)

        g.fill(Path(CGRect(x: 0, y: plot.minY, width: column.minX, height: plot.height)), with: .color(Theme.ground.opacity(0.5)))
        g.fill(Path(CGRect(x: column.maxX, y: plot.minY, width: max(0, plot.maxX - column.maxX), height: plot.height)), with: .color(Theme.ground.opacity(0.5)))
        g.fill(Path(column), with: .color(Theme.ink.opacity(0.16)))
        if let minor = strip.minor[i] {
            g.fill(layout.bar(minor, strip.scale, x0: column.minX, x1: column.maxX), with: .color(Theme.ink))
        }
        LockOn.rule(at: (column.midX * scale).rounded() / scale + px / 2, plot: plot, px: px, in: &g)
        let frame = CGRect(x: column.minX - 3, y: 0.75, width: column.width + 6, height: layout.priceBottom + 1.5)
        g.stroke(LockOn.brackets(around: frame, arm: 4), with: .color(Theme.ink.opacity(0.8)), style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
    }
}

extension LockOn {
    /// Four corners of a rectangle, each an arm long: the lock-on around a
    /// whole slot rather than a point.
    static func brackets(around r: CGRect, arm: CGFloat) -> Path {
        var path = Path()
        for (x, y, sx, sy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0), (r.maxX, r.maxY, -1.0, -1.0), (r.minX, r.maxY, 1.0, -1.0)] {
            path.move(to: CGPoint(x: x, y: y + sy * arm))
            path.addLine(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x + sx * arm, y: y))
        }
        return path
    }
}
