import FTWShared
import SwiftUI

/// The same history material and scale, with source observations at the
/// right edge. Stored means never glow. Only a fresh observed head can.
struct TimelineDrawing: ChartDrawing {
    let history: HistoryPicture
    let traces: [String: LiveSeries]
    let looks: [String: TraceLook]
    let frame: ChartFrame
    let liveKeys: Set<String>
    var axis: CGFloat = 10
    var words = ChartLabels()

    func draw(in g: inout GraphicsContext, size: CGSize) {
        let runs = traces.mapValues(\.observedRanges)
        HistoryDrawing(picture: history, looks: looks, frame: frame, words: words, axis: axis, live: false, observationRuns: runs, showsFetchingEstimate: false).draw(in: &g, size: size)
        let plot = frame.plot(in: size)
        let base = YMap(domain: history.domain, height: plot.height).baseline
        var p = g
        p.clip(to: Path(plot.insetBy(dx: 0, dy: -12)))
        p.translateBy(x: plot.minX, y: plot.minY)
        let above = Path(CGRect(x: -10, y: -40, width: plot.width + 20, height: base + 40))
        let below = Path(CGRect(x: -10, y: base, width: plot.width + 20, height: plot.height - base + 40))
        for layer in history.layers.reversed() {
            guard let trace = traces[layer.key] else { continue }
            let look = looks[layer.key] ?? TraceLook(up: Theme.ink, down: Theme.ink)
            let transform = TraceInk.rescale(trace.domain, history.domain, height: plot.height)
            let own = layer.key == history.layers.first?.key
            if own {
                var body = Path(trace.body.cgPath)
                body.addPath(Path(trace.bodyUnseen.cgPath))
                body = body.applying(transform)
                TraceInk.body(body, look: look, baseline: base, height: plot.height, above: above, below: below, in: p)
            }
            TraceInk.band(Path(trace.band.cgPath).applying(transform), look: look, above: above, below: below, in: p)
            TraceInk.line(Path(trace.wholeLine.cgPath).applying(transform), look: look, width: own ? TraceInk.line : TraceInk.otherLine, glows: false, above: above, below: below, in: p)
            if own, liveKeys.contains(layer.key), let last = trace.last, last.seen,
               let now = history.nowMs, now - last.t <= trace.gapMs {
                let point = CGPoint(x: trace.x(last.t), y: YMap(domain: history.domain, height: plot.height).y(last.v))
                let color = last.v >= 0 ? look.up : look.down
                if TraceInk.glows(live: true, in: g) {
                    p.fill(Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)), with: .color(color.opacity(0.25)))
                }
                p.fill(Path(ellipseIn: CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)), with: .color(color))
            }
        }
    }
}
