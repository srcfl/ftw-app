import FTWShared
import SwiftUI

/// The price chart's shapes on one plot, from its `PriceChart`. A price
/// holds across its slot, so each slot is a bar: slot width less 1 px, top
/// corners rounded to 1.25 pt, square on zero, equal neighbours merged into
/// one pixel-snapped shape. The app's Canvas and the widget's still shapes
/// both draw these, so the two never differ.
struct PricePaths {
    /// The bars by third of the window's range, the now slot apart.
    var cheap = Path()
    var middle = Path()
    var dear = Path()
    var now = Path()
    /// Zero, one device pixel.
    var zero = Path()
    /// The window's average, across the plot.
    var average = Path()
    var averageY: CGFloat?
    /// The now rule, full height.
    var nowRule = Path()
    var nowX: CGFloat?
    /// Stubs where tomorrow's prices are still to come, and their hatch.
    var pending = Path()
    var pendingHatch = Path()
    /// `└──┘` under the cheapest two hours.
    var bracket = Path()
    var bracketSpan: ClosedRange<CGFloat>?
    var baseline: CGFloat = 0

    static let stub: CGFloat = 6

    init(_ chart: PriceChart, plot: CGRect, scale: CGFloat) {
        let scale = max(scale, 1)
        func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        let origin = CGPoint(x: snap(plot.minX), y: snap(plot.minY))
        let map = YMap(domain: chart.domain, height: plot.height)
        let width = plot.width
        baseline = origin.y + snap(map.baseline)
        let px = 1 / scale

        func bars(_ keep: (Int) -> Bool) -> Path {
            let values = chart.shown.indices.map { keep($0) ? chart.shown[$0] : nil }
            var path = Path()
            for run in ChartPaths.runs(values, grid: chart.grid, width: width, map: map, scale: scale, maxRadius: 1.25) {
                let r = run.rect.offsetBy(dx: origin.x, dy: origin.y)
                let radii = run.value > 0
                    ? RectangleCornerRadii(topLeading: run.radius, bottomLeading: 0, bottomTrailing: 0, topTrailing: run.radius)
                    : RectangleCornerRadii(topLeading: 0, bottomLeading: run.radius, bottomTrailing: run.radius, topTrailing: 0)
                path.addPath(Path(roundedRect: r, cornerRadii: radii, style: .circular))
            }
            return path
        }
        let nowIndex = chart.nowIndex
        cheap = bars { $0 != nowIndex && chart.thirds[$0] == .cheap }
        middle = bars { $0 != nowIndex && chart.thirds[$0] == .middle }
        dear = bars { $0 != nowIndex && chart.thirds[$0] == .dear }
        now = bars { $0 == nowIndex }

        zero.move(to: CGPoint(x: origin.x, y: baseline + px / 2))
        zero.addLine(to: CGPoint(x: origin.x + width, y: baseline + px / 2))

        if let mean = chart.meanShown {
            let y = origin.y + snap(map.y(mean)) + px / 2
            averageY = y
            average.move(to: CGPoint(x: origin.x, y: y))
            average.addLine(to: CGPoint(x: origin.x + width, y: y))
        }

        if nowIndex != nil {
            let x = origin.x + snap(chart.grid.x(atMs: chart.nowMs, width: width)) + px / 2
            nowX = x
            nowRule.move(to: CGPoint(x: x, y: origin.y))
            nowRule.addLine(to: CGPoint(x: x, y: origin.y + plot.height))
        }

        if let p = chart.pending {
            let x0 = origin.x + snap(chart.grid.x(atMs: chart.grid.startMs(p.lowerBound), width: width))
            let x1 = origin.x + snap(chart.grid.x(atMs: chart.grid.endMs(p.upperBound), width: width))
            let rect = CGRect(x: x0, y: baseline - Self.stub, width: max(0, x1 - x0), height: Self.stub)
            pending = Path(rect)
            var x = x0 - Self.stub
            while x < x1 {
                pendingHatch.move(to: CGPoint(x: x, y: rect.maxY))
                pendingHatch.addLine(to: CGPoint(x: x + Self.stub, y: rect.minY))
                x += 3
            }
        }

        if let c = chart.cheapest {
            let x0 = origin.x + snap(chart.grid.x(atMs: chart.grid.startMs(c.lowerBound), width: width)) + px / 2
            let x1 = origin.x + snap(chart.grid.x(atMs: chart.grid.endMs(c.upperBound), width: width)) - px * 1.5
            let y = origin.y + plot.height + 6
            bracketSpan = x0...max(x0, x1)
            bracket.move(to: CGPoint(x: x0, y: y - 3))
            bracket.addLine(to: CGPoint(x: x0, y: y))
            bracket.addLine(to: CGPoint(x: max(x0, x1), y: y))
            bracket.addLine(to: CGPoint(x: max(x0, x1), y: y - 3))
        }
    }
}

/// The app's price chart, drawn in one Canvas: bars in ink by thirds, the
/// now slot in full ink with its rule, the average as a dotted rule with
/// its figure in the right gutter, the cheapest two hours bracketed and
/// named, tomorrow's slots as hatched stubs, and the hours under it.
struct PriceBarsDrawing: ChartDrawing {
    let chart: PriceChart
    let frame: ChartFrame
    /// The axis labels' mono size and the bracket line's, scaled with the
    /// text and held at accessibility1.
    var axis: CGFloat = 10
    var kicker: CGFloat = 10.5

    /// The frame this chart draws in, for axis and kicker sizes.
    static func frame(axis: CGFloat, kicker: CGFloat, tag: CGFloat) -> ChartFrame {
        ChartFrame(top: tag * 1.35 + 6, bottom: 6 + 3 + kicker * 1.35 + 3 + axis * 1.35, trailing: axis * 2.8)
    }

    func draw(in g: inout GraphicsContext, size: CGSize) {
        let plot = frame.plot(in: size)
        let scale = max(g.environment.displayScale, 1)
        let px = 1 / scale
        let p = PricePaths(chart, plot: plot, scale: scale)

        g.fill(p.cheap, with: .color(Theme.ink.opacity(0.32)))
        g.fill(p.middle, with: .color(Theme.ink.opacity(0.5)))
        g.fill(p.dear, with: .color(Theme.ink.opacity(0.8)))
        g.fill(p.now, with: .color(Theme.ink))
        g.stroke(p.zero, with: .color(Theme.ink.opacity(0.35)), style: StrokeStyle(lineWidth: px, lineCap: .butt, lineJoin: .round))

        if !p.pending.isEmpty {
            var hatch = g
            hatch.clip(to: p.pending)
            hatch.stroke(p.pendingHatch, with: .color(Theme.ink3), style: StrokeStyle(lineWidth: px, lineCap: .butt, lineJoin: .round))
            if !chart.pendingText.isEmpty {
                // From the first stub on, never over a bar to its left.
                let span = p.pending.boundingRect
                let text = Self.fitted(chart.pendingText, size: axis, width: size.width - span.minX - 2, in: g)
                g.draw(text, at: CGPoint(x: span.minX + 2, y: span.minY - 4), anchor: .bottomLeading)
            }
        }

        if let y = p.averageY {
            g.stroke(p.average, with: .color(Theme.ink2), style: StrokeStyle(lineWidth: px * 2, lineCap: .butt, lineJoin: .round, dash: [1, 3]))
            let word = g.resolve(ChartText.label(PriceChart.averageWord, size: axis))
            let figure = g.resolve(ChartText.label(chart.meanText, size: axis, color: Theme.ink2))
            let x = plot.maxX + 4
            g.draw(word, at: CGPoint(x: x, y: y - 1), anchor: .bottomLeading)
            g.draw(figure, at: CGPoint(x: x, y: y + 1), anchor: .topLeading)
        }

        // The time axis: NOW first, then each hour label that has room.
        var taken: [ClosedRange<CGFloat>] = []
        if let x = p.nowX {
            g.stroke(p.nowRule, with: .color(Theme.ink), style: StrokeStyle(lineWidth: px, lineCap: .butt, lineJoin: .round))
            let now = g.resolve(ChartText.label(PriceChart.nowWord, size: axis, weight: .semibold, color: Theme.ink2))
            let w = now.measure(in: size).width
            let left = min(max(plot.minX, x - w / 2), plot.maxX - w)
            taken.append(left...(left + w))
            g.draw(now, at: CGPoint(x: left, y: size.height), anchor: .bottomLeading)
        }
        for tick in chart.hours {
            let text = g.resolve(ChartText.label(tick.label, size: axis))
            let w = text.measure(in: size).width
            let x = plot.minX + chart.grid.x(atMs: tick.ms, width: plot.width)
            let span = (x - w / 2 - 4)...(x + w / 2 + 4)
            guard span.lowerBound >= plot.minX, span.upperBound <= size.width, !taken.contains(where: { $0.overlaps(span) }) else { continue }
            taken.append(span)
            g.draw(text, at: CGPoint(x: x, y: size.height), anchor: .bottom)
        }

        if let span = p.bracketSpan {
            g.stroke(p.bracket, with: .color(Theme.ink.opacity(0.7)), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
            let text = Self.fitted(chart.cheapestText, size: kicker, width: size.width - plot.minX, color: Theme.ink2, in: g)
            let w = text.measure(in: size).width
            let x = min(max(span.lowerBound, plot.minX), max(plot.minX, size.width - w))
            g.draw(text, at: CGPoint(x: x, y: plot.maxY + 6 + 3), anchor: .topLeading)
        }
    }

    /// A mono label that fits `width`: at its size if it can, else as much
    /// smaller as it needs, down to 70 %.
    static func fitted(_ string: String, size: CGFloat, width: CGFloat, color: Color = Theme.ink3, in g: GraphicsContext) -> GraphicsContext.ResolvedText {
        let text = g.resolve(ChartText.label(string, size: size, color: color))
        let w = text.measure(in: CGSize(width: CGFloat.infinity, height: .infinity)).width
        guard w > width, w > 0 else { return text }
        return g.resolve(ChartText.label(string, size: max(size * 0.7, (size * width / w).rounded(.down)), color: color))
    }
}

/// The same bars as still shapes, for a widget: no Canvas, no motion and
/// no finger. Tinted and clear home screens draw them in one colour.
struct PriceBarsStill: View {
    let chart: PriceChart
    var monochrome = false
    @Environment(\.displayScale) private var scale

    var body: some View {
        GeometryReader { geo in
            let frame = ChartFrame(top: 2, bottom: 22, trailing: 0)
            let plot = frame.plot(in: geo.size)
            let p = PricePaths(chart, plot: plot, scale: scale)
            let ink: Color = monochrome ? .primary : Theme.ink
            ZStack(alignment: .topLeading) {
                p.cheap.fill(ink.opacity(0.32))
                p.middle.fill(ink.opacity(0.5))
                p.dear.fill(ink.opacity(0.8))
                p.now.fill(ink).widgetAccentable()
                p.zero.stroke(ink.opacity(0.35), style: StrokeStyle(lineWidth: 1 / max(scale, 1), lineCap: .butt, lineJoin: .round))
                p.pendingHatch.stroke(ink.opacity(0.4), style: StrokeStyle(lineWidth: 1 / max(scale, 1), lineCap: .butt, lineJoin: .round))
                    .clipShape(p.pending)
                p.average.stroke(ink.opacity(0.6), style: StrokeStyle(lineWidth: 1, lineCap: .butt, lineJoin: .round, dash: [1, 3]))
                p.bracket.stroke(ink.opacity(0.7), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                ForEach(chart.hours, id: \.ms) { tick in
                    Text(verbatim: tick.label)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(monochrome ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.ink3))
                        .fixedSize()
                        .position(x: plot.minX + chart.grid.x(atMs: tick.ms, width: plot.width), y: geo.size.height - 6)
                }
            }
        }
    }
}
