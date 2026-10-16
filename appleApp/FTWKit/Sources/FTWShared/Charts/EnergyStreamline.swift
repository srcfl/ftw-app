import CoreGraphics
import Foundation

/// A stream held at its ends. A grip carries nearby material with the
/// finger, then diverts it around the contact patch on a stable side.
public struct EnergyStreamline: Sendable {
    public let points: [CGPoint]

    public init(from start: CGPoint, control1: CGPoint, control2: CGPoint, to end: CGPoint,
                finger: CGPoint? = nil, origin: CGPoint? = nil, strength: Double = 0,
                radius: Double = 34, side: Double = 1) {
        let base = (0...96).map { i -> CGPoint in
            let t = Double(i) / 96, u = 1 - t
            return CGPoint(x: u * u * u * start.x + 3 * u * u * t * control1.x + 3 * u * t * t * control2.x + t * t * t * end.x,
                           y: u * u * u * start.y + 3 * u * u * t * control1.y + 3 * u * t * t * control2.y + t * t * t * end.y)
        }
        guard let finger, let origin, finger.x.isFinite, finger.y.isFinite, origin.x.isFinite, origin.y.isFinite,
              strength.isFinite, strength > 0, radius.isFinite, radius > 0 else { points = base; return }
        let amount = min(1, strength), r = max(12, radius)
        func pin(_ i: Int) -> Double { min(1, Double(i) / 10, Double(96 - i) / 10) }
        func distance2(_ a: CGPoint, _ b: CGPoint) -> Double { pow(a.x - b.x, 2) + pow(a.y - b.y, 2) }
        let carried = base.enumerated().map { i, p -> CGPoint in
            let weight = exp(-distance2(p, origin) / pow(r * 2.3, 2)) * pin(i) * amount * 0.92
            return CGPoint(x: p.x + (finger.x - origin.x) * weight, y: p.y + (finger.y - origin.y) * weight)
        }
        let nearest = carried.indices.min { distance2(carried[$0], finger) < distance2(carried[$1], finger) }!
        guard distance2(carried[nearest], finger) < pow(r * 3.5, 2) else { points = carried; return }
        let before = carried[max(0, nearest - 2)], after = carried[min(96, nearest + 2)]
        let length = max(0.001, hypot(after.x - before.x, after.y - before.y))
        let tangent = CGPoint(x: (after.x - before.x) / length, y: (after.y - before.y) / length)
        let normal = CGPoint(x: -tangent.y, y: tangent.x), direction = side < 0 ? -1.0 : 1.0
        points = carried.enumerated().map { i, p in
            let dx = p.x - finger.x, dy = p.y - finger.y
            let along = dx * tangent.x + dy * tangent.y
            let across = dx * normal.x + dy * normal.y
            let skirt = r * 1.18 * exp(-pow(along / (r * 1.6), 2))
            let nearby = max(0, min(1, (r * 3.5 - abs(across)) / r))
            let lift = max(0, skirt - direction * across) * nearby * pin(i) * amount
            return CGPoint(x: p.x + normal.x * lift * direction, y: p.y + normal.y * lift * direction)
        }
    }
}
