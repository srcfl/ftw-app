import CoreGraphics
import Foundation

/// One site, with one grid boundary and four things inside it.
/// A positive signed flow goes from the site into the named part.
public struct EnergySiteLayout: Sendable {
    public enum Part: Int, CaseIterable, Sendable {
        case solar, home, car, battery, grid
    }

    public let size: CGSize
    public let flow: EnergyFlowBalance
    public var junction: CGPoint { point(0.49, 0.39) }

    public init(size: CGSize, flow: EnergyFlowBalance) {
        self.size = CGSize(width: max(1, size.width.isFinite ? size.width : 1),
                           height: max(1, size.height.isFinite ? size.height : 1))
        self.flow = flow
    }

    public func signedPower(_ part: Part) -> Double {
        switch part {
        case .solar: -flow.solar
        case .home: flow.home
        case .car: flow.car
        case .battery: flow.battery
        case .grid: -flow.grid
        }
    }

    public func center(_ part: Part) -> CGPoint {
        switch part {
        case .solar: point(0.23, 0.175)
        case .home: point(0.79, 0.30)
        case .car: point(0.22, 0.53)
        case .battery: point(0.76, 0.665)
        case .grid: point(0.48, 0.90)
        }
    }

    /// The same connection reverses when the site buys instead of selling.
    public func stream(_ part: Part, finger: CGPoint? = nil, origin: CGPoint? = nil,
                       grip: Double = 0, time: Double = 0) -> [CGPoint] {
        let end = part == .grid ? point(0.48, 1.12) : center(part)
        let c1: CGPoint, c2: CGPoint
        switch part {
        case .solar: c1 = point(0.36, 0.30); c2 = point(0.16, 0.23)
        case .home: c1 = point(0.62, 0.43); c2 = point(0.74, 0.30)
        case .car: c1 = point(0.42, 0.52); c2 = point(0.25, 0.40)
        case .battery: c1 = point(0.54, 0.56); c2 = point(0.79, 0.51)
        case .grid: c1 = point(0.40, 0.63); c2 = point(0.36, 0.78)
        }
        let drift = time > 0 ? sin(time * 0.65 + Double(part.rawValue)) * 9 : 0
        let points = EnergyStreamline(from: junction,
                                     control1: CGPoint(x: c1.x + drift, y: c1.y),
                                     control2: CGPoint(x: c2.x - drift, y: c2.y), to: end,
                                     finger: finger, origin: origin, strength: grip, radius: 39,
                                     side: part == .car || part == .solar ? -1 : 1).points
        return part == .solar || signedPower(part) < 0 ? Array(points.reversed()) : points
    }

    /// Idle parts retain a resting volume. Area grows with absolute power;
    /// it is a visual cue, not an area chart or a stored-energy reading.
    public func radii(_ part: Part) -> CGSize {
        let power = abs(signedPower(part))
        let growth = min(0.13, sqrt(power) * 0.047)
        switch part {
        case .solar: return CGSize(width: size.width * (0.36 + growth), height: size.height * (0.13 + growth * 0.32))
        case .home: return CGSize(width: size.width * (0.27 + growth), height: size.height * (0.17 + growth * 0.35))
        case .car: return CGSize(width: size.width * (0.30 + growth), height: size.height * (0.19 + growth * 0.38))
        case .battery: return CGSize(width: size.width * (0.30 + growth), height: size.height * (0.19 + growth * 0.38))
        case .grid: return CGSize(width: 17 + sqrt(power) * 8, height: size.height * 0.12)
        }
    }

    public func contour(_ part: Part, time: Double = 0, finger: CGPoint? = nil,
                        origin: CGPoint? = nil, grip: Double = 0) -> [CGPoint] {
        let c = center(part), r = radii(part)
        return (0..<72).map { i in
            let angle = Double(i) / 72 * .pi * 2
            let wave = 1 + sin(angle * 3 + time * 0.55 + Double(part.rawValue)) * 0.045
                + cos(angle * 2 - time * 0.42) * 0.035
            var p = CGPoint(x: c.x + cos(angle) * r.width * wave, y: c.y + sin(angle) * r.height * wave)
            if let finger, let origin, grip.isFinite, grip > 0,
               finger.x.isFinite, finger.y.isFinite, origin.x.isFinite, origin.y.isFinite {
                let amount = min(1, grip)
                let weight = exp(-pow(hypot(p.x - origin.x, p.y - origin.y) / 125, 2)) * amount
                p.x += tanh((finger.x - origin.x) / 160) * 148 * weight
                p.y += tanh((finger.y - origin.y) / 160) * 148 * weight
                let dx = p.x - finger.x, dy = p.y - finger.y, distance = max(0.01, hypot(dx, dy))
                let push = max(0, 38 - distance) * amount
                p.x += dx / distance * push; p.y += dy / distance * push
            }
            return p
        }
    }

    private func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: size.width * x, y: size.height * y) }
}
