import FTWShared
import SwiftUI

/// Where the parts of Now's plan strip sit, from the top of its Canvas:
/// room for the lock-on's brackets, two 6 pt lanes 4 pt apart (battery,
/// then car), the price bars in eight levels on a floor of 20 pt or more,
/// and the hours under them. The surface and the finger's overlay share
/// it, so a lit quarter and its bar meet.
struct PlanStripLayout: Equatable {
    static let lane: CGFloat = 6
    static let batteryY: CGFloat = 3
    static let carY: CGFloat = 13
    static let priceTop: CGFloat = 25
    /// The price row at its least, and the most it grows to when Now has
    /// room: the same two Now's layout reads.
    static let leastPrice = PlanStrip.leastPrice
    static let mostPrice = PlanStrip.mostPrice

    /// The hours' mono size, scaled with the text.
    var axis: CGFloat = 10
    /// The price row's height: 20 pt, or what Now gives it.
    var priceHeight: CGFloat = Self.leastPrice

    var priceBottom: CGFloat { Self.priceTop + priceHeight }
    var levelStep: CGFloat { priceHeight / CGFloat(PlanStrip.levels) }
    var hoursTop: CGFloat { priceBottom + 3 }
    var height: CGFloat { hoursTop + (axis * 1.25).rounded(.up) }
    /// The tallest the strip's drawing grows to.
    var tallest: CGFloat { height + Self.mostPrice - priceHeight }
    /// What a finger lights: the lanes and the bars, not the hours.
    func plot(width: CGFloat) -> CGRect { CGRect(x: 0, y: 0, width: width, height: priceBottom) }

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

    func barHeight(_ level: Int) -> CGFloat { CGFloat(level + 1) * levelStep }
}

/// Now's plan strip, in one Canvas: the battery's lane (gold gives, cyan
/// stores), the car's (violet, a 2 pt tick at its goal), an idle hairline
/// where a lane has nothing, 48 price bars in eight levels by ink third,
/// the now rule across lanes and bars, and the hours. Equal neighbours are
/// one shape, so no run shows a seam. The lanes are a plan, so they are a
/// ghost: their colour at `Theme.plan`, never the full strength that says
/// live. A plan that is old, that the box could not make, or from a box
/// this phone cannot reach, is ink3 throughout. It never sees a finger.
struct PlanStripDrawing: ChartDrawing {
    let strip: PlanStrip
    var layout = PlanStripLayout()

    func draw(in g: inout GraphicsContext, size: CGSize) {
        let layout = self.layout.fitting(size.height)
        let scale = max(g.environment.displayScale, 1)
        let px = 1 / scale
        func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        let width = size.width
        let grid = strip.grid
        let grey = strip.grey
        let ghost = Theme.plan(g.environment.colorSchemeContrast)
        let oldInk = Theme.oldPlan

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

        var stores = Path(), gives = Path()
        for run in strip.batteryRuns {
            let p = capsule(run.first, run.last, y: PlanStripLayout.batteryY)
            if run.value == .stores { stores.addPath(p) } else { gives.addPath(p) }
        }
        g.fill(stores, with: .color(grey ? oldInk : Theme.stores.opacity(ghost)))
        g.fill(gives, with: .color(grey ? oldInk : Theme.gives.opacity(ghost)))

        var car = Path()
        for run in strip.carRuns { car.addPath(capsule(run.first, run.last, y: PlanStripLayout.carY)) }
        // The goal: a 2 pt tick at the end of its quarter, past the lane.
        for (i, _) in strip.goals {
            let s = PlanStripLayout.span(first: i, last: i, grid: grid, width: width, scale: scale)
            car.addRect(CGRect(x: s.x1 - 2, y: PlanStripLayout.carY - 2, width: 2, height: PlanStripLayout.lane + 4))
        }
        g.fill(car, with: .color(grey ? oldInk : Theme.car.opacity(ghost)))

        // The price: a bar per stretch of equal level, ink by third.
        var thirds: [PriceChart.Third: Path] = [:]
        for run in strip.priceRuns {
            let s = PlanStripLayout.span(first: run.first, last: run.last, grid: grid, width: width, scale: scale)
            let h = layout.barHeight(run.value)
            let rect = CGRect(x: s.x0, y: layout.priceBottom - h, width: s.x1 - s.x0, height: h)
            let r = min(1.25, rect.width / 2)
            let bar = Path(roundedRect: rect, cornerRadii: RectangleCornerRadii(topLeading: r, bottomLeading: 0, bottomTrailing: 0, topTrailing: r), style: .circular)
            thirds[PlanStrip.third(run.value), default: Path()].addPath(bar)
        }
        for (third, path) in thirds {
            g.fill(path, with: .color(grey ? Theme.ink3.opacity(0.6) : Theme.ink.opacity(Self.ink(third))))
        }
        // Not priced yet: a hatched stub, so a guess never looks like a price.
        if !strip.pending.isEmpty {
            var stubs = Path(), hatch = Path()
            let stub = layout.levelStep * 2
            for run in strip.pending {
                let s = PlanStripLayout.span(first: run.first, last: run.last, grid: grid, width: width, scale: scale)
                let rect = CGRect(x: s.x0, y: layout.priceBottom - stub, width: s.x1 - s.x0, height: stub)
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

        // Now, one pixel across the lanes and the bars.
        let nowX = snap(grid.x(atMs: strip.nowMs, width: width))
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
        let s = PlanStripLayout.span(first: i, last: i, grid: strip.grid, width: size.width, scale: scale)
        let column = CGRect(x: s.x0, y: plot.minY, width: max(px, s.x1 - s.x0), height: plot.height)

        g.fill(Path(CGRect(x: 0, y: plot.minY, width: column.minX, height: plot.height)), with: .color(Theme.ground.opacity(0.5)))
        g.fill(Path(CGRect(x: column.maxX, y: plot.minY, width: max(0, plot.maxX - column.maxX), height: plot.height)), with: .color(Theme.ground.opacity(0.5)))
        g.fill(Path(column), with: .color(Theme.ink.opacity(0.16)))
        if let level = strip.levels[i] {
            let h = layout.barHeight(level)
            let bar = CGRect(x: column.minX, y: layout.priceBottom - h, width: column.width, height: h)
            g.fill(Path(roundedRect: bar, cornerRadius: min(1.25, bar.width / 2), style: .circular), with: .color(Theme.ink))
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
