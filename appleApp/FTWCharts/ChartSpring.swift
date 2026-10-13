import Foundation

/// How a chart's points move when its data changes: each point that
/// changed springs from where it was drawn to its new value, a few
/// milliseconds after the point before it, so a curve grows into shape
/// rather than jumping. An estimate the data replaces, or a hole the box
/// confirms, fades as the line settles. Under Reduce Motion the new data
/// shows at once and only the fade remains.
///
/// The points are computed once per change of data; the motion only
/// interpolates between two lists it already has. The app's charts and the
/// plan dial share this spring.
enum ChartMotion {
    /// The spring Fredrik's brief names: response 0.55 s, damping 0.72.
    static let response = 0.55
    static let damping = 0.72
    /// Between one changed point and the next.
    static let stagger = 0.008
    /// The whole stagger never takes longer than this, however many points.
    static let staggerCap = 0.35
    /// How long a fading estimate takes to go.
    static let fade = 0.3

    /// A damped spring's step from 0 to 1 at `t` seconds, as
    /// `.spring(response:dampingFraction:)` moves a value. It overshoots a
    /// little and settles.
    static func spring(_ t: Double) -> Double {
        guard t > 0 else { return 0 }
        let omega = 2 * Double.pi / response
        let zeta = damping
        let wd = omega * (1 - zeta * zeta).squareRoot()
        let decay = exp(-zeta * omega * t)
        return 1 - decay * (cos(wd * t) + zeta * omega / wd * sin(wd * t))
    }

    /// When a spring has settled to within a hair of its value.
    static var settle: Double { response * 2 }
}
