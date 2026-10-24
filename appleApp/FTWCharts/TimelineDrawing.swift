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

/// The timeline's scale on its way to a new one: a pan or a pinch that
/// brings a higher peak into view moves the lines, the plan and the live
/// trace on a critically damped spring that settles in about
/// `TraceInk.spring`. Its ends keep their speed when the target moves
/// again mid-way, so a pinch through several steps of scale glides on
/// rather than slowing at each, and it lands on the target without a
/// last step. Under Reduce Motion it changes at once. Not observed: the
/// timeline steps it and nothing else reads it.
@MainActor
final class ScaleMotion {
    private var lower = Spring()
    private var upper = Spring()
    private(set) var to: YDomain?
    private var last: Double?

    private struct Spring {
        var x = 0.0
        var v = 0.0
        /// One step of a critically damped spring toward `target`.
        mutating func step(toward target: Double, dt: Double, omega: Double) {
            let a = -omega * omega * (x - target) - 2 * omega * v
            v += a * dt
            x += v * dt
        }
        /// Within a thousandth of the scale and nearly still: done.
        func near(_ target: Double, span: Double) -> Bool { abs(x - target) <= span * 0.001 && abs(v) <= span * 0.01 }
    }

    private static let omega = 7.5 / TraceInk.spring

    /// A new scale at `t`. True when the scale will move to it.
    @discardableResult
    func target(_ domain: YDomain, at t: Double, still: Bool) -> Bool {
        guard domain != to else { return false }
        guard to != nil, !still else {
            to = domain
            lower = Spring(x: domain.lower)
            upper = Spring(x: domain.upper)
            last = t
            return false
        }
        // On from where the ends are now, at the speed they have.
        _ = shown(at: t)
        to = domain
        return true
    }

    /// The scale on screen at `t`; nil before the first.
    func shown(at t: Double) -> YDomain? {
        guard let to else { return nil }
        var left = min(max(0, t - (last ?? t)), 1)
        last = t
        while left > 0 {
            let dt = min(left, 1.0 / 240)
            lower.step(toward: to.lower, dt: dt, omega: Self.omega)
            upper.step(toward: to.upper, dt: dt, omega: Self.omega)
            left -= dt
        }
        let span = max(1, abs(to.upper - to.lower))
        if lower.near(to.lower, span: span), upper.near(to.upper, span: span) {
            lower = Spring(x: to.lower)
            upper = Spring(x: to.upper)
            return to
        }
        return YDomain(lower: lower.x, upper: upper.x)
    }

}
