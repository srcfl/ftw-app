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

/// Today or the last two days, in one Canvas, in the live trace's
/// material (`TraceInk`): per series its band of the five-minute means,
/// the chart's own series' body, and the line through the exact slot
/// means. Glow means live, so only the slot still filling glows, and only
/// while the node is live. A hole on its way is a hatch with a dashed
/// estimate across it; a hole the box has no record for is a dotted
/// baseline. Axes are drawn here too, so they never reflow: zero as one
/// device pixel, the scale's ends in the right gutter, the direction words
/// when both signs show, the hours, and NOW.
///
/// When a tile lands in the same window, each slot slides from its old
/// mean to its new one (`from`, `slide`), as a new reading slides into the
/// live trace; a new scale and a series coming or going move as one spring
/// (`spring`). A new window draws at once, on the scale's spring.
struct HistoryDrawing: ChartDrawing {
    let picture: HistoryPicture
    /// The colours per series key, each side of zero.
    let looks: [String: TraceLook]
    let frame: ChartFrame
    var words = ChartLabels()
    var axis: CGFloat = 10
    /// Whether the node's reading is live now: the slot still filling glows.
    var live = false
    var from: HistoryPicture?
    var slide: Double = 1
    var spring: Double = 1
    /// The scale on screen when the caller moves it itself, as the
    /// timeline does between two scales; otherwise `from` and `spring`.
    var shownDomain: YDomain? = nil
    /// Source runs can cover the stored means without changing them.
    /// A lone point hides no history, and a silence hides no later mean.
    var observationRuns: [String: [ClosedRange<Double>]] = [:]
    var showsFetchingEstimate = true

    func draw(in g: inout GraphicsContext, size: CGSize) {
        let plot = frame.plot(in: size)
        let px = 1 / max(g.environment.displayScale, 1)
        let primary = picture.layers.first?.key

        let k = min(max(spring, 0), 1)
        let shown = shownDomain ?? from.map { TraceInk.between($0.domain, picture.domain, k) } ?? picture.domain
        let toShown = TraceInk.rescale(picture.domain, shown, height: plot.height)
        let base = YMap(domain: shown, height: plot.height).baseline

        ChartAxes.draw(in: &g, plot: plot, domain: picture.domain, px: px, axis: axis, look: primary.flatMap { looks[$0] }, shown: shown, reach: picture.reach(width: plot.width))

        var p = g
        p.clip(to: Path(CGRect(x: plot.minX, y: plot.minY - 12, width: plot.width, height: plot.height + 24)))
        p.translateBy(x: plot.minX, y: plot.minY)
        let above = Path(CGRect(x: -10, y: -40, width: plot.width + 20, height: base + 40))
        let below = Path(CGRect(x: -10, y: base, width: plot.width + 20, height: plot.height - base + 40))

        // The slot still filling, the only part of the day that is live.
        var filling: Path?
        if TraceInk.glows(live: live, in: g), let now = picture.nowMs, let i = picture.grid.index(atMs: now) {
            let x = picture.grid.x(atMs: max(picture.grid.startMs(i), picture.grid.fromMs), width: plot.width)
            filling = Path(CGRect(x: x, y: -40, width: plot.width - x + 20, height: plot.height + 80))
        }

        // A series taken away, fading out on the moving scale.
        if let from, k < 1 {
            for gone in from.layers where !picture.layers.contains(where: { $0.key == gone.key }) {
                let look = looks[gone.key] ?? TraceLook(up: Theme.ink2, down: Theme.ink2)
                var s = p
                s.opacity = 1 - k
                TraceInk.line(Path(gone.series.line.cgPath).applying(TraceInk.rescale(from.domain, shown, height: plot.height)), look: look, width: TraceInk.otherLine, glows: false, above: above, below: below, in: s)
            }
        }

        // The rest of the day: the plan's or the forecast's ghost, as Ahead
        // draws it, from now on.
        if let now = picture.nowMs {
            let x = picture.grid.x(atMs: now, width: plot.width)
            var ahead = p
            ahead.clip(to: Path(CGRect(x: x, y: -40, width: plot.width - x + 20, height: plot.height + 80)))
            for layer in picture.layers.reversed() {
                guard let ghost = layer.ghost else { continue }
                let look = looks[layer.key] ?? TraceLook(up: Theme.ink2, down: Theme.ink2)
                var faded = ahead
                if from != nil, from?.layers.first(where: { $0.key == layer.key })?.ghost == nil, k < 1 { faded.opacity = k }
                switch ghost.kind {
                case .plan:
                    Ghost.bars(ghost.values, grid: ghost.grid, look: look, width: plot.width, map: YMap(domain: shown, height: plot.height), scale: 1 / px, px: px, in: faded)
                case .forecast:
                    Ghost.forecast(Path(ghost.line.cgPath).applying(toShown), look: look, in: faded)
                }
            }
        }

        // The others first, the chart's own series last, on top.
        for layer in picture.layers.reversed() {
            let look = looks[layer.key] ?? TraceLook(up: Theme.ink, down: Theme.ink)
            let series = layer.series
            let own = layer.key == primary
            var line = Path(series.line.cgPath), body = Path(series.body.cgPath), band = Path(series.band.cgPath)
            let before = from?.layers.first(where: { $0.key == layer.key })?.series
            if let before, let mixed = series.blended(from: before, progress: slide) {
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
            if let runs = observationRuns[layer.key], !runs.isEmpty {
                var visible = Path()
                var cursor: CGFloat = 0
                for run in runs {
                    let a = min(max(series.grid.x(atMs: run.lowerBound, width: plot.width), 0), plot.width)
                    let b = min(max(series.grid.x(atMs: run.upperBound, width: plot.width), 0), plot.width)
                    if a > cursor { visible.addRect(CGRect(x: cursor, y: -40, width: a - cursor, height: plot.height + 80)) }
                    cursor = max(cursor, b)
                }
                if cursor < plot.width { visible.addRect(CGRect(x: cursor, y: -40, width: plot.width - cursor, height: plot.height + 80)) }
                p.clip(to: visible)
            }
            // A series just added fades in.
            if from != nil, before == nil, k < 1 { p.opacity = k }
            TraceInk.band(band, look: look, above: above, below: below, in: p)
            if own {
                TraceInk.body(body, look: look, baseline: base, height: plot.height, above: above, below: below, in: p)
            }
            // Holes: a hatch on its way with a dashed estimate, a dotted
            // baseline where the box has no record.
            if own {
                for r in series.fetching {
                    let x0 = series.grid.x(atMs: series.grid.startMs(r.lowerBound), width: plot.width)
                    let end = min(series.grid.endMs(r.upperBound), picture.nowMs ?? series.grid.toMs)
                    let x1 = series.grid.x(atMs: end, width: plot.width)
                    guard x1 > x0 else { continue }
                    let rect = CGRect(x: x0, y: 0, width: max(px, x1 - x0), height: plot.height)
                    var hatch = p
                    hatch.clip(to: Path(rect))
                    hatch.fill(Path(rect), with: .color(Theme.ink.opacity(0.04)))
                    hatch.stroke(Self.hatch(rect), with: .color(Theme.ink.opacity(0.10)), style: StrokeStyle(lineWidth: px, lineCap: .butt, lineJoin: .round))
                    // Named only where it shows: the live readings drawn
                    // over the interval still filling leave no gap to name.
                    let text = g.resolve(ChartText.label(words.fetching, size: axis))
                    let width = text.measure(in: size).width
                    guard Self.uncovered(x0...x1, by: observationRuns[layer.key] ?? [], grid: series.grid, width: plot.width) >= width + 8 else { continue }
                    let x = min(max(0, rect.midX - width / 2), max(0, plot.width - width))
                    g.draw(text, at: CGPoint(x: plot.minX + x, y: plot.minY + 4), anchor: .topLeading)
                }
                var dotted = Path()
                for r in series.missing {
                    dotted.move(to: CGPoint(x: series.grid.x(atMs: series.grid.startMs(r.lowerBound), width: plot.width), y: base))
                    dotted.addLine(to: CGPoint(x: series.grid.x(atMs: series.grid.endMs(r.upperBound), width: plot.width), y: base))
                }
                TraceInk.dotted(dotted, px: px, in: p)
            }
            if showsFetchingEstimate {
                p.stroke(Path(series.estimate.cgPath).applying(toShown), with: .color(look.up.opacity(0.6)), style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round, dash: [3, 4]))
            }
            TraceInk.line(line, look: look, width: own ? TraceInk.line : TraceInk.otherLine, opacity: own ? 1 : 0.85, glows: own && filling != nil, glowClip: filling, above: above, below: below, in: p)
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

    /// How wide a stretch of the plot is once the observed runs are taken
    /// out of it.
    static func uncovered(_ span: ClosedRange<CGFloat>, by runs: [ClosedRange<Double>], grid: SlotGrid, width: CGFloat) -> CGFloat {
        var left = span.upperBound - span.lowerBound
        for run in runs {
            let a = max(span.lowerBound, grid.x(atMs: run.lowerBound, width: width))
            let b = min(span.upperBound, grid.x(atMs: run.upperBound, width: width))
            if b > a { left -= b - a }
        }
        return max(0, left)
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

/// What the box plans or forecasts, drawn after now on the timeline.
enum Ghost {
    /// A plan's slots as ghost bars: a faint fill in each direction's
    /// colour with a 1 px cap, equal neighbours merged, on `g` translated
    /// to the plot.
    static func bars(_ values: [Double?], grid: SlotGrid, look: TraceLook, width: CGFloat, map: YMap, scale: CGFloat, px: CGFloat, in g: GraphicsContext) {
        for run in ChartPaths.runs(values, grid: grid, width: width, map: map, scale: scale, maxRadius: 4) {
            let color = run.value >= 0 ? look.up : look.down
            let r = run.rect
            let radii = run.value > 0
                ? RectangleCornerRadii(topLeading: run.radius, bottomLeading: 0, bottomTrailing: 0, topTrailing: run.radius)
                : RectangleCornerRadii(topLeading: 0, bottomLeading: run.radius, bottomTrailing: run.radius, topTrailing: 0)
            g.fill(Path(roundedRect: r, cornerRadii: radii, style: .circular), with: .color(color.opacity(0.14)))
            var cap = Path()
            let y = run.value > 0 ? r.minY + px / 2 : r.maxY - px / 2
            cap.move(to: CGPoint(x: r.minX + run.radius, y: y))
            cap.addLine(to: CGPoint(x: r.maxX - run.radius, y: y))
            g.stroke(cap, with: .color(color.opacity(0.7)), style: StrokeStyle(lineWidth: px, lineCap: .round, lineJoin: .round))
        }
    }

    /// A forecast: an estimate, so a dashed line, at half strength.
    static func forecast(_ line: Path, look: TraceLook, in g: GraphicsContext) {
        g.stroke(line, with: .color(look.up.opacity(0.5)), style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round, dash: [3, 4]))
    }
}

/// The axes every chart on the engine draws in its own Canvas.
enum ChartAxes {
    /// Zero as one device pixel; a dotted gridline and a magnitude in the
    /// right gutter at each end of the scale; the direction words, only
    /// when the scale holds both signs and, given `reach`, only in a corner
    /// no data runs through (`CornerWords`). `zero` false leaves zero to
    /// the chart: a source at rest draws it dotted.
    static func draw(in g: inout GraphicsContext, plot: CGRect, domain: YDomain, px: CGFloat, axis: CGFloat, look: TraceLook?, shown: YDomain? = nil, reach: [ChartReach]? = nil, zero drawsZero: Bool = true) {
        // Labels name the scale the chart is going to; zero sits where the
        // scale on its way puts it.
        let map = YMap(domain: domain, height: plot.height)
        let base = plot.minY + (YMap(domain: shown ?? domain, height: plot.height).baseline / px).rounded() * px + px / 2
        if drawsZero {
            var zero = Path()
            zero.move(to: CGPoint(x: plot.minX, y: base))
            zero.addLine(to: CGPoint(x: plot.maxX, y: base))
            g.stroke(zero, with: .color(Theme.ink.opacity(0.35)), style: StrokeStyle(lineWidth: px, lineCap: .butt, lineJoin: .round))
        }
        for v in [domain.upper, domain.lower] where v != 0 {
            let y = plot.minY + map.y(v)
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            g.stroke(line, with: .color(Theme.ink.opacity(0.12)), style: StrokeStyle(lineWidth: px, lineCap: .butt, lineJoin: .round, dash: [1, 3]))
            g.draw(g.resolve(ChartText.label(PowerFormat.scale(abs(v)), size: axis)), at: CGPoint(x: plot.maxX + 4, y: y), anchor: .leading)
        }
        if domain.lower < 0, domain.upper > 0, let look {
            let on = YMap(domain: shown ?? domain, height: plot.height)
            func clear(_ word: String, top: Bool) -> Bool {
                reach.map { CornerWords.clear(word, size: axis, top: top, data: $0, map: on) } ?? true
            }
            let inset = CornerWords.inset
            if let up = look.upWord, clear(up, top: true) {
                g.draw(g.resolve(ChartText.label(up, size: axis)), at: CGPoint(x: plot.minX + inset, y: plot.minY + inset), anchor: .topLeading)
            }
            if let down = look.downWord, clear(down, top: false) {
                g.draw(g.resolve(ChartText.label(down, size: axis)), at: CGPoint(x: plot.minX + inset, y: plot.maxY - inset), anchor: .bottomLeading)
            }
        }
    }

    /// The right gutter for a power scale's labels at `axis`.
    static func gutter(_ domain: YDomain?, axis: CGFloat) -> CGFloat {
        ChartGutter.trailing(domain.map(ChartGutter.scaleLabels) ?? ["0 W"], size: axis)
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
