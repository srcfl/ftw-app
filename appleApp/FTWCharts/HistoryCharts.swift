import FTWShared
import SwiftUI

/// The fixed words a history or ahead chart draws, worded by the app.
struct ChartLabels: Equatable {
    /// "FETCHING…", over a hole on its way.
    var fetching = "FETCHING…"
    /// "AS OF 15:30", where the newest data ends when it is old.
    var asOf: String?
    /// "NOW", under the now rule.
    var now = "NOW"
}

/// Today or the last two days, in one Canvas: per series its band of the
/// five-minute means, the chart's own series' body, and a 2.5 pt line
/// through the exact slot means. A hole on its way is a hatch with a dashed
/// estimate across it; a hole the box has no record for is a dotted
/// baseline. The past does not glow. Axes are drawn here too, so they never
/// reflow: zero as one device pixel, the scale's ends in the right gutter,
/// the direction words when both signs show, the hours, and NOW.
///
/// When a tile lands in the same window, each slot moves from its old mean
/// to its new one (`from`, `progress`); a new window cross-fades instead.
struct HistoryDrawing: ChartDrawing {
    let picture: HistoryPicture
    /// The colours per series key, each side of zero.
    let looks: [String: TraceLook]
    let frame: ChartFrame
    var words = ChartLabels()
    var axis: CGFloat = 10
    var from: HistoryPicture?
    var progress: Double = 1

    /// Values on scale `a` to the same values on scale `b`, in plot points.
    static func rescale(_ a: YDomain, _ b: YDomain, height: CGFloat) -> CGAffineTransform {
        guard a != b, a.span > 0, b.span > 0 else { return .identity }
        let aa = -height / CGFloat(a.span), ab = height * CGFloat(a.upper / a.span)
        let ba = -height / CGFloat(b.span), bb = height * CGFloat(b.upper / b.span)
        let d = ba / aa
        return CGAffineTransform(a: 1, b: 0, c: 0, d: d, tx: 0, ty: bb - d * ab)
    }

    func draw(in g: inout GraphicsContext, size: CGSize) {
        let plot = frame.plot(in: size)
        let px = 1 / max(g.environment.displayScale, 1)
        let dark = g.environment.colorScheme == .dark
        let primary = picture.layers.first?.key

        // A series added or taken away re-fits the scale: it moves as one
        // spring, the new series fades in and the old one out.
        let k = min(max(progress, 0), 1)
        var shown = picture.domain
        if let from, from.domain != picture.domain, k < 1 {
            shown = YDomain(lower: from.domain.lower + (picture.domain.lower - from.domain.lower) * k, upper: from.domain.upper + (picture.domain.upper - from.domain.upper) * k)
        }
        let toShown = Self.rescale(picture.domain, shown, height: plot.height)
        let base = YMap(domain: shown, height: plot.height).baseline

        ChartAxes.draw(in: &g, plot: plot, domain: picture.domain, px: px, axis: axis, look: primary.flatMap { looks[$0] }, shown: shown)

        var p = g
        p.clip(to: Path(CGRect(x: plot.minX, y: plot.minY - 2, width: plot.width, height: plot.height + 4)))
        p.translateBy(x: plot.minX, y: plot.minY)
        let above = Path(CGRect(x: -10, y: -10, width: plot.width + 20, height: base + 10))
        let below = Path(CGRect(x: -10, y: base, width: plot.width + 20, height: plot.height - base + 10))

        // A series taken away, fading out on the moving scale.
        if let from, k < 1 {
            for gone in from.layers where !picture.layers.contains(where: { $0.key == gone.key }) {
                let look = looks[gone.key] ?? TraceLook(up: Theme.ink2, down: Theme.ink2)
                let t = Self.rescale(from.domain, shown, height: plot.height)
                var s = p
                s.opacity = 1 - k
                s.stroke(Path(gone.series.line.cgPath).applying(t), with: .color(look.up), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }

        // The others first, the chart's own series last, on top.
        for layer in picture.layers.reversed() {
            let look = looks[layer.key] ?? TraceLook(up: Theme.ink, down: Theme.ink)
            let series = layer.series
            let own = layer.key == primary
            var line = Path(series.line.cgPath), body = Path(series.body.cgPath), band = Path(series.band.cgPath)
            let before = from?.layers.first(where: { $0.key == layer.key })?.series
            if let before, let mixed = series.blended(from: before, progress: progress) {
                line = Path(mixed.line.cgPath)
                body = Path(mixed.body.cgPath)
                band = Path(mixed.band.cgPath)
            }
            if toShown != .identity {
                line = line.applying(toShown)
                body = body.applying(toShown)
                band = band.applying(toShown)
            }
            var p = p
            // A series just added fades in.
            if from != nil, before == nil, k < 1 { p.opacity = k }
            for (side, color) in [(above, look.up), (below, look.down)] {
                var s = p
                s.clip(to: side)
                s.fill(band, with: .color(color.opacity(dark ? 0.16 : 0.12)))
                if own {
                    let edge = side == above ? CGFloat(0) : plot.height
                    s.fill(body, with: .linearGradient(Gradient(colors: [color.opacity(0), color.opacity(dark ? 0.24 : 0.16)]), startPoint: CGPoint(x: 0, y: base), endPoint: CGPoint(x: 0, y: edge)))
                }
            }
            // Holes: a hatch on its way with a dashed estimate, a dotted
            // baseline where the box has no record.
            if own {
                for r in series.fetching {
                    let x0 = series.grid.x(atMs: series.grid.startMs(r.lowerBound), width: plot.width)
                    let x1 = series.grid.x(atMs: series.grid.endMs(r.upperBound), width: plot.width)
                    let rect = CGRect(x: x0, y: 0, width: max(px, x1 - x0), height: plot.height)
                    var hatch = p
                    hatch.clip(to: Path(rect))
                    hatch.fill(Path(rect), with: .color(Theme.ink.opacity(0.04)))
                    hatch.stroke(Self.hatch(rect), with: .color(Theme.ink.opacity(0.10)), style: StrokeStyle(lineWidth: px, lineCap: .butt, lineJoin: .round))
                    let text = p.resolve(ChartText.label(words.fetching, size: axis))
                    p.draw(text, at: CGPoint(x: rect.midX, y: 4), anchor: .top)
                }
                var dotted = Path()
                for r in series.missing {
                    dotted.move(to: CGPoint(x: series.grid.x(atMs: series.grid.startMs(r.lowerBound), width: plot.width), y: base))
                    dotted.addLine(to: CGPoint(x: series.grid.x(atMs: series.grid.endMs(r.upperBound), width: plot.width), y: base))
                }
                p.stroke(dotted, with: .color(Theme.ink.opacity(0.35)), style: StrokeStyle(lineWidth: px, lineCap: .butt, lineJoin: .round, dash: [1, 3]))
            }
            p.stroke(Path(series.estimate.cgPath).applying(toShown), with: .color(look.up.opacity(0.6)), style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round, dash: [3, 4]))
            for (side, color) in [(above, look.up), (below, look.down)] {
                var s = p
                s.clip(to: side)
                s.stroke(line, with: .color(own ? color : color.opacity(0.85)), style: StrokeStyle(lineWidth: own ? 2.5 : 2, lineCap: .round, lineJoin: .round))
            }
        }

        // Now, and where old data ends.
        if let now = picture.nowMs, now > picture.grid.fromMs, now < picture.grid.toMs {
            let x = plot.minX + (picture.grid.x(atMs: now, width: plot.width) / px).rounded() * px + px / 2
            var rule = Path()
            rule.move(to: CGPoint(x: x, y: plot.minY))
            rule.addLine(to: CGPoint(x: x, y: plot.maxY))
            g.stroke(rule, with: .color(Theme.ink.opacity(0.5)), style: StrokeStyle(lineWidth: px, lineCap: .butt, lineJoin: .round))
        }
        if let asOf = picture.asOfMs, let text = words.asOf {
            let x = plot.minX + picture.grid.x(atMs: asOf, width: plot.width)
            let label = g.resolve(ChartText.label(text, size: axis))
            let w = label.measure(in: size).width
            g.draw(label, at: CGPoint(x: min(max(plot.minX, x - w / 2), plot.maxX - w), y: plot.minY + 2), anchor: .topLeading)
        }
        ChartAxes.time(in: &g, plot: plot, size: size, grid: picture.grid, ticks: picture.ticks.map { ($0.ms, $0.label) }, nowMs: picture.nowMs, nowWord: words.now, axis: axis)
    }

    /// Diagonal hairlines 4 pt apart across a rect.
    static func hatch(_ rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += 4
        }
        return path
    }
}

/// The hours ahead, in one Canvas: a plan's quarters as ghost bars (a
/// faint fill with a 1 px cap, equal neighbours merged), or a forecast's
/// dashed line, and the price under the same slots as block bars in ink by
/// thirds. The now rule sits at the left edge.
struct AheadDrawing: ChartDrawing {
    let picture: AheadPicture
    let look: TraceLook
    let frame: ChartFrame
    var axis: CGFloat = 10
    var nowWord = "NOW"
    /// The price strip's height inside the frame's bottom.
    var strip: CGFloat = 18

    func draw(in g: inout GraphicsContext, size: CGSize) {
        let plot = frame.plot(in: size)
        let scale = max(g.environment.displayScale, 1)
        let px = 1 / scale
        let map = YMap(domain: picture.domain, height: plot.height)

        ChartAxes.draw(in: &g, plot: plot, domain: picture.domain, px: px, axis: axis, look: look)

        var p = g
        p.translateBy(x: plot.minX, y: plot.minY)
        switch picture.kind {
        case .plan:
            for run in ChartPaths.runs(picture.values, grid: picture.grid, width: plot.width, map: map, scale: scale, maxRadius: 4) {
                let color = run.value >= 0 ? look.up : look.down
                let r = run.rect
                let radii = run.value > 0
                    ? RectangleCornerRadii(topLeading: run.radius, bottomLeading: 0, bottomTrailing: 0, topTrailing: run.radius)
                    : RectangleCornerRadii(topLeading: 0, bottomLeading: run.radius, bottomTrailing: run.radius, topTrailing: 0)
                p.fill(Path(roundedRect: r, cornerRadii: radii, style: .circular), with: .color(color.opacity(0.14)))
                var cap = Path()
                let y = run.value > 0 ? r.minY + px / 2 : r.maxY - px / 2
                cap.move(to: CGPoint(x: r.minX + run.radius, y: y))
                cap.addLine(to: CGPoint(x: r.maxX - run.radius, y: y))
                p.stroke(cap, with: .color(color.opacity(0.7)), style: StrokeStyle(lineWidth: px, lineCap: .round, lineJoin: .round))
            }
        case .forecast:
            p.stroke(Path(picture.line.cgPath), with: .color(look.up.opacity(0.5)), style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round, dash: [3, 4]))
        }

        // The price strip: block bars in eight steps, ink by thirds.
        let stripTop = plot.maxY + 6
        let w = plot.width / CGFloat(max(1, picture.grid.count))
        for i in 0..<picture.grid.count {
            guard let level = picture.priceLevels[i], let third = picture.priceThirds[i] else { continue }
            let h = strip * CGFloat(level) / 8
            let x = plot.minX + CGFloat(i) * w
            let rect = CGRect(x: (x * scale).rounded() / scale, y: stripTop + strip - h, width: max(px, ((w - px) * scale).rounded() / scale), height: h)
            g.fill(Path(rect), with: .color(Theme.ink.opacity(third == .cheap ? 0.32 : third == .middle ? 0.5 : 0.8)))
        }

        // Now at the left edge, through the plot and the strip.
        let x = plot.minX + (picture.grid.x(atMs: picture.nowMs, width: plot.width) / px).rounded() * px + px / 2
        var rule = Path()
        rule.move(to: CGPoint(x: x, y: plot.minY))
        rule.addLine(to: CGPoint(x: x, y: stripTop + strip))
        g.stroke(rule, with: .color(Theme.ink), style: StrokeStyle(lineWidth: px, lineCap: .butt, lineJoin: .round))
        ChartAxes.time(in: &g, plot: plot, size: size, grid: picture.grid, ticks: picture.ticks.map { ($0.ms, $0.label) }, nowMs: picture.nowMs, nowWord: nowWord, axis: axis)
    }
}

/// The axes every chart on the engine draws in its own Canvas.
enum ChartAxes {
    /// Zero as one device pixel; a dotted gridline and a magnitude in the
    /// right gutter at each end of the scale; the direction words, only
    /// when the scale holds both signs.
    static func draw(in g: inout GraphicsContext, plot: CGRect, domain: YDomain, px: CGFloat, axis: CGFloat, look: TraceLook?, shown: YDomain? = nil) {
        // Labels name the scale the chart is going to; zero sits where the
        // scale on its way puts it.
        let map = YMap(domain: domain, height: plot.height)
        let base = plot.minY + (YMap(domain: shown ?? domain, height: plot.height).baseline / px).rounded() * px + px / 2
        var zero = Path()
        zero.move(to: CGPoint(x: plot.minX, y: base))
        zero.addLine(to: CGPoint(x: plot.maxX, y: base))
        g.stroke(zero, with: .color(Theme.ink.opacity(0.35)), style: StrokeStyle(lineWidth: px, lineCap: .butt, lineJoin: .round))
        for v in [domain.upper, domain.lower] where v != 0 {
            let y = plot.minY + map.y(v)
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            g.stroke(line, with: .color(Theme.ink.opacity(0.12)), style: StrokeStyle(lineWidth: px, lineCap: .butt, lineJoin: .round, dash: [1, 3]))
            g.draw(g.resolve(ChartText.label(PowerFormat.scale(abs(v)), size: axis)), at: CGPoint(x: plot.maxX + 4, y: y), anchor: .leading)
        }
        if domain.lower < 0, domain.upper > 0, let look {
            if let up = look.upWord { g.draw(g.resolve(ChartText.label(up, size: axis)), at: CGPoint(x: plot.minX + 2, y: plot.minY + 2), anchor: .topLeading) }
            if let down = look.downWord { g.draw(g.resolve(ChartText.label(down, size: axis)), at: CGPoint(x: plot.minX + 2, y: plot.maxY - 2), anchor: .bottomLeading) }
        }
    }

    /// The hour labels on the bottom row, and NOW under the now rule; a
    /// label that would collide with one already placed is left out.
    static func time(in g: inout GraphicsContext, plot: CGRect, size: CGSize, grid: SlotGrid, ticks: [(Double, String)], nowMs: Double?, nowWord: String, axis: CGFloat) {
        var taken: [ClosedRange<CGFloat>] = []
        if let now = nowMs, now >= grid.fromMs, now < grid.toMs {
            let label = g.resolve(ChartText.label(nowWord, size: axis, weight: .semibold, color: Theme.ink2))
            let w = label.measure(in: size).width
            let x = plot.minX + grid.x(atMs: now, width: plot.width)
            let left = min(max(plot.minX, x - w / 2), plot.maxX - w)
            taken.append(left...(left + w))
            g.draw(label, at: CGPoint(x: left, y: size.height), anchor: .bottomLeading)
        }
        for (ms, text) in ticks {
            let label = g.resolve(ChartText.label(text, size: axis))
            let w = label.measure(in: size).width
            // Centred on its hour, but kept inside the chart at either end.
            let x = min(max(plot.minX + grid.x(atMs: ms, width: plot.width), plot.minX + w / 2), size.width - w / 2)
            let span = (x - w / 2 - 4)...(x + w / 2 + 4)
            guard !taken.contains(where: { $0.overlaps(span) }) else { continue }
            taken.append(span)
            g.draw(label, at: CGPoint(x: x, y: size.height), anchor: .bottom)
        }
    }
}

/// A history chart that moves between tiles: when a tile lands in the same
/// window, each slot slides from its old mean to its new one over 0.35 s,
/// critically damped, at the display's rate, and then the chart holds
/// still. Data from the cache starts settled.
struct HistorySurface: View {
    let picture: HistoryPicture
    let looks: [String: TraceLook]
    let frame: ChartFrame
    var words = ChartLabels()
    var axis: CGFloat = 10
    @State private var old: HistoryPicture?
    @State private var changedAt = Date.distantPast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let spring: TimeInterval = 0.35

    var body: some View {
        let moving = old != nil && !reduceMotion
        TimelineView(.animation(paused: !moving)) { tick in
            let k = LiveTraceSurface.ease(tick.date.timeIntervalSince(changedAt), Self.spring)
            ChartSurface(drawing: HistoryDrawing(picture: picture, looks: looks, frame: frame, words: words, axis: axis, from: moving && k < 1 ? old : nil, progress: k))
                .equatable()
        }
        .onChange(of: picture) { before, _ in
            old = before
            changedAt = .now
        }
        .task(id: changedAt) {
            try? await Task.sleep(for: .milliseconds(400))
            old = nil
        }
    }
}
