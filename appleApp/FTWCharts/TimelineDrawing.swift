import FTWShared
import SwiftUI

/// The same history material and scale, with source observations at the
/// right edge. Stored means never glow. Only a fresh observed head can.
/// Light means live: readings this phone saw live take the node's colour,
/// readings kept from before this launch are ink, and a node that is not
/// live now is ink throughout.
struct TimelineDrawing: ChartDrawing {
    let history: HistoryPicture
    let traces: [String: LiveSeries]
    let looks: [String: TraceLook]
    let frame: ChartFrame
    let liveKeys: Set<String>
    /// The clock, for the head's freshness; the picture's now steps by a
    /// point of the plot.
    var nowMs: Double? = nil
    /// The scale on screen while it moves to the picture's (`ScaleMotion`).
    var shown: YDomain? = nil
    var axis: CGFloat = 10
    var words = ChartLabels()

    func draw(in g: inout GraphicsContext, size: CGSize) {
        let runs = traces.mapValues(\.observedRanges)
        HistoryDrawing(picture: history, looks: looks, frame: frame, words: words, axis: axis, live: false, shownDomain: shown, observationRuns: runs, showsFetchingEstimate: false).draw(in: &g, size: size)
        let plot = frame.plot(in: size)
        let domain = shown ?? history.domain
        let base = YMap(domain: domain, height: plot.height).baseline
        var p = g
        p.clip(to: Path(plot.insetBy(dx: 0, dy: -12)))
        p.translateBy(x: plot.minX, y: plot.minY)
        let above = Path(CGRect(x: -10, y: -40, width: plot.width + 20, height: base + 40))
        let below = Path(CGRect(x: -10, y: base, width: plot.width + 20, height: plot.height - base + 40))
        let ink = TraceLook(up: Theme.ink2, down: Theme.ink2)
        for layer in history.layers.reversed() {
            guard let trace = traces[layer.key] else { continue }
            let live = liveKeys.contains(layer.key)
            let look = live ? (looks[layer.key] ?? TraceLook(up: Theme.ink, down: Theme.ink)) : ink
            let transform = TraceInk.rescale(trace.domain, domain, height: plot.height)
            let own = layer.key == history.layers.first?.key
            let width = own ? TraceInk.line : TraceInk.otherLine
            if own {
                TraceInk.body(Path(trace.body.cgPath).applying(transform), look: look, ink: !live, baseline: base, height: plot.height, above: above, below: below, in: p)
                TraceInk.body(Path(trace.bodyUnseen.cgPath).applying(transform), look: look, ink: true, baseline: base, height: plot.height, above: above, below: below, in: p)
            }
            // The band spans the whole run; it takes colour only when every
            // reading in it was seen live.
            let bandLook = trace.readings.allSatisfy(\.seen) ? look : ink
            TraceInk.band(Path(trace.band.cgPath).applying(transform), look: bandLook, above: above, below: below, in: p)
            TraceInk.line(Path(trace.line.cgPath).applying(transform), look: look, width: width, glows: false, above: above, below: below, in: p)
            TraceInk.line(Path(trace.lineUnseen.cgPath).applying(transform), look: ink, width: width, glows: false, above: above, below: below, in: p)
            if own, liveKeys.contains(layer.key), let last = trace.last, last.seen,
               let now = nowMs ?? history.nowMs, now - last.t <= trace.gapMs {
                let point = CGPoint(x: trace.x(last.t), y: YMap(domain: domain, height: plot.height).y(last.v))
                let color = last.v >= 0 ? look.up : look.down
                if TraceInk.glows(live: true, in: g) {
                    p.fill(Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)), with: .color(color.opacity(0.25)))
                }
                p.fill(Path(ellipseIn: CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)), with: .color(color))
            }
        }
    }
}

/// The timeline's scale on its way to a new one (`ScaleSpring`, settling
/// in about `TraceInk.spring`). Not observed: the timeline steps it while
/// it moves and nothing else reads it, so a step redraws no other view.
@MainActor
final class ScaleMotion {
    private var spring = ScaleSpring(settle: TraceInk.spring)

    var resting: Bool { spring.resting }

    /// A new scale at `t`. True when the scale will move to it.
    @discardableResult
    func target(_ domain: YDomain, at t: Double, still: Bool) -> Bool {
        spring.target(domain, at: t, still: still)
    }

    /// The scale on screen at `t`; nil before the first.
    func shown(at t: Double) -> YDomain? { spring.shown(at: t) }
}
