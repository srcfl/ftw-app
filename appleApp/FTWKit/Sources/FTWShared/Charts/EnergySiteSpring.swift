import CoreGraphics
import Foundation

/// An interruptible return to the flow's resting point. The first sample
/// preserves both position and release velocity; later samples settle at zero.
public struct EnergySiteSpring: Sendable {
    public let displacement, velocity: CGSize
    public init(displacement: CGSize = .zero, velocity: CGSize = .zero) {
        func finite(_ x: Double) -> Double { x.isFinite ? x : 0 }
        self.displacement = CGSize(width: finite(displacement.width), height: finite(displacement.height))
        self.velocity = CGSize(width: max(-1600, min(1600, finite(velocity.width))),
                               height: max(-1600, min(1600, finite(velocity.height))))
    }
    public func offset(after elapsed: Double) -> CGSize {
        guard elapsed.isFinite else { return .zero }
        let t = max(0, elapsed)
        guard t < 3 else { return .zero }
        let damping = 4.2, frequency = 8.5
        func axis(_ x: Double, _ v: Double) -> Double {
            exp(-damping * t) * (x * cos(frequency * t) + (v + damping * x) / frequency * sin(frequency * t))
        }
        return CGSize(width: axis(displacement.width, velocity.width), height: axis(displacement.height, velocity.height))
    }
}
