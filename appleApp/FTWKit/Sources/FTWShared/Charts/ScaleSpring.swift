import Foundation

/// A chart's scale on its way to a new one: a pan or a pinch that brings
/// a higher peak into view moves the lines on a critically damped spring
/// that settles in about `settle` seconds. A new target mid-way keeps each
/// end's speed toward it, but never more than lands on it, so a pinch
/// through several steps of scale glides on, a turn back stops at once,
/// and an end never passes its target. Each call moves the ends along the
/// spring's exact path, so the motion is the same at any frame rate. The
/// first scale, and any under Reduce Motion, is there at once.
public struct ScaleSpring: Sendable {
    private var lower = End()
    private var upper = End()
    public private(set) var to: YDomain?
    private var last: Double?
    private let omega: Double

    public init(settle: Double = 0.35) {
        omega = 7.5 / settle
    }

    /// Both ends on the target and still, or no scale yet.
    public var resting: Bool {
        guard let to else { return true }
        return lower == End(x: to.lower) && upper == End(x: to.upper)
    }

    /// A new scale at `t` seconds. True when the scale will move to it.
    @discardableResult
    public mutating func target(_ domain: YDomain, at t: Double, still: Bool) -> Bool {
        guard domain != to else { return false }
        guard to != nil, !still else {
            to = domain
            lower = End(x: domain.lower)
            upper = End(x: domain.upper)
            last = t
            return false
        }
        // On from where the ends are now.
        _ = shown(at: t)
        to = domain
        lower.aim(at: domain.lower, omega: omega)
        upper.aim(at: domain.upper, omega: omega)
        return true
    }

    /// The scale on screen at `t` seconds; nil before the first. A time
    /// earlier than one seen before moves nothing.
    public mutating func shown(at t: Double) -> YDomain? {
        guard let to else { return nil }
        let dt = max(0, t - (last ?? t))
        last = max(last ?? t, t)
        guard !resting else { return to }
        lower.advance(toward: to.lower, by: dt, omega: omega)
        upper.advance(toward: to.upper, by: dt, omega: omega)
        // Within a thousandth of the scale and nearly still: there.
        let span = max(1, abs(to.span))
        if lower.near(to.lower, span: span), upper.near(to.upper, span: span) {
            lower = End(x: to.lower)
            upper = End(x: to.upper)
            return to
        }
        return YDomain(lower: lower.x, upper: upper.x)
    }

    private struct End: Equatable, Sendable {
        var x = 0.0
        var v = 0.0

        /// `dt` seconds on toward `target`, on the path
        /// x = target + (a + b·t)·e^(−ω·t).
        mutating func advance(toward target: Double, by dt: Double, omega w: Double) {
            let a = x - target
            let b = v + w * a
            let e = exp(-w * dt)
            x = target + (a + b * dt) * e
            v = (b - w * (a + b * dt)) * e
        }

        /// Keeps only speed toward `target`, and at most the speed that
        /// comes to rest on it: then the path cannot cross it.
        mutating func aim(at target: Double, omega w: Double) {
            let lands = -w * (x - target)
            v = min(max(v, min(0, lands)), max(0, lands))
        }

        func near(_ target: Double, span: Double) -> Bool {
            abs(x - target) <= span * 0.001 && abs(v) <= span * 0.01
        }
    }
}
