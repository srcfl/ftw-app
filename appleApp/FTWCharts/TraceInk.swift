import FTWShared
import SwiftUI

/// The material every power trace is drawn in, live or past: the band, the
/// body, the line and its glow, and how a change of data moves. One place,
/// so a viewer who goes from Live to Today sees the time change and
/// nothing else.
enum TraceInk {
    /// One width scale for every line a chart draws: readings, the plan and
    /// forecast after now, the History tab and the plan's battery level, so
    /// each chart keeps the same grammar (Fredrik, 24 October 2026: the
    /// lines looked a little thin). Hairlines and axes stay one pixel.
    static let weight: CGFloat = 1.3
    /// The line's width.
    static let line: CGFloat = 2.5 * weight
    /// The glow: two strokes under the line, as wide as these times the
    /// line and as strong as these, with no blur.
    static let glowWide: (width: CGFloat, alpha: Double) = (2.8, 0.12)
    static let glowNear: (width: CGFloat, alpha: Double) = (1.8, 0.25)
    /// A second series on the same chart: thinner, under the node's own.
    static let otherLine: CGFloat = 2 * weight
    /// A plan or a forecast: thinner than a reading, and dashed, with gaps
    /// that grow with it so its round caps never close them.
    static let ghost: CGFloat = 1.75 * weight
    static let ghostDash: [CGFloat] = [3 * weight, 4 * weight]
    /// The edge a plan's ghost bar draws at its value.
    static let planEdge: CGFloat = 1 * weight
    /// A line on a small chart, as on the History tab.
    static let smallLine: CGFloat = 1.5 * weight
    /// A new value slides in over this long.
    static let slide: TimeInterval = 0.25
    /// A new scale, a series coming or going, moves as one spring over this.
    static let spring: TimeInterval = 0.35

    /// A critically damped ease from 0 to 1 over `duration`.
    static func ease(_ elapsed: TimeInterval, _ duration: TimeInterval) -> Double {
        guard elapsed < duration else { return 1 }
        let w = 6.0 / duration, t = max(0, elapsed)
        return min(1, 1 - (1 + w * t) * exp(-w * t))
    }

    /// Glow means live: only while the reading is live, only in the dark,
    /// and never with Reduce Transparency.
    static func glows(live: Bool, in g: GraphicsContext) -> Bool {
        live && g.environment.colorScheme == .dark && !g.environment.accessibilityReduceTransparency
    }

    /// How far the readings swung, under everything, in each direction's
    /// colour.
    static func band(_ band: Path, look: TraceLook, above: Path, below: Path, in g: GraphicsContext) {
        let dark = g.environment.colorScheme == .dark
        for (side, color) in [(above, look.up), (below, look.down)] {
            var s = g
            s.clip(to: side)
            s.fill(band, with: .color(color.opacity(dark ? 0.14 : 0.10)))
        }
    }

    /// The body: one gradient from nothing at zero to the scale's edge, in
    /// each direction's colour, or in ink at half strength.
    static func body(_ body: Path, look: TraceLook, ink: Bool = false, baseline: CGFloat, height: CGFloat, above: Path, below: Path, in g: GraphicsContext) {
        let peak = g.environment.colorScheme == .dark ? 0.30 : 0.18
        for (side, color, edge) in [(above, look.up, CGFloat(0)), (below, look.down, height)] {
            var s = g
            s.clip(to: side)
            let c = ink ? Theme.ink : color
            let top = ink ? peak * 0.5 : peak
            s.fill(body, with: .linearGradient(Gradient(colors: [c.opacity(0), c.opacity(top)]), startPoint: CGPoint(x: 0, y: baseline), endPoint: CGPoint(x: 0, y: edge)))
        }
    }

    /// The line, each side of zero in its colour, with the glow under it
    /// when `glows`. `glowClip` limits the glow, say to the slot still
    /// filling.
    static func line(_ line: Path, look: TraceLook, width: CGFloat = TraceInk.line, opacity: Double = 1, glows: Bool, glowClip: Path? = nil, above: Path, below: Path, in g: GraphicsContext) {
        for (side, color) in [(above, look.up), (below, look.down)] {
            var s = g
            s.clip(to: side)
            if glows {
                var glow = s
                if let glowClip { glow.clip(to: glowClip) }
                Self.glow(line, color: color, width: width, in: glow)
            }
            s.stroke(line, with: .color(color.opacity(opacity)), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
    }

    /// The glow under a line of `width`, at `strength` (1 while live; less
    /// as it decays). Callers check `glows` first.
    static func glow(_ line: Path, color: Color, width: CGFloat, strength: Double = 1, in g: GraphicsContext) {
        for (k, alpha) in [glowWide, glowNear] {
            g.stroke(line, with: .color(color.opacity(alpha * strength)), style: StrokeStyle(lineWidth: width * k, lineCap: .round, lineJoin: .round))
        }
    }

    /// The dotted baseline: the box confirms nothing was there. A silence
    /// on a trace, a node at rest on Now.
    static func dotted(_ path: Path, px: CGFloat, opacity: Double = 1, in g: GraphicsContext) {
        g.stroke(path, with: .color(Theme.ink.opacity(0.35 * opacity)), style: StrokeStyle(lineWidth: px, lineCap: .butt, lineJoin: .round, dash: [1, 3]))
    }

    /// Values on scale `a` to the same values on scale `b`, in plot points.
    static func rescale(_ a: YDomain, _ b: YDomain, height: CGFloat) -> CGAffineTransform {
        guard a != b, a.span > 0, b.span > 0 else { return .identity }
        let aa = -height / CGFloat(a.span), ab = height * CGFloat(a.upper / a.span)
        let ba = -height / CGFloat(b.span), bb = height * CGFloat(b.upper / b.span)
        let d = ba / aa
        return CGAffineTransform(a: 1, b: 0, c: 0, d: d, tx: 0, ty: bb - d * ab)
    }

    /// The scale on its way from `a` to `b`.
    static func between(_ a: YDomain, _ b: YDomain, _ k: Double) -> YDomain {
        guard a != b, k < 1 else { return b }
        return YDomain(lower: a.lower + (b.lower - a.lower) * k, upper: a.upper + (b.upper - a.upper) * k)
    }
}
