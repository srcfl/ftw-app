import FTWShared
import SwiftUI

/// The material every power trace is drawn in, live or past: the band, the
/// body, the line and its glow, and how a change of data moves. One place,
/// so a viewer who goes from Live to Today sees the time change and
/// nothing else.
enum TraceInk {
    /// The line's width.
    static let line: CGFloat = 2.5
    /// A second series on the same chart: thinner, under the node's own.
    static let otherLine: CGFloat = 2
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
                glow.stroke(line, with: .color(color.opacity(0.12)), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                glow.stroke(line, with: .color(color.opacity(0.25)), style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
            }
            s.stroke(line, with: .color(color.opacity(opacity)), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
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
