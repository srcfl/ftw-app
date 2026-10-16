import Foundation
import CoreGraphics

/// A proportional field for the distribution design study. The right-hand
/// paths are nested prefixes, painted grid, battery, home, then car.
/// Inputs are destination powers, never signed meter readings.
public struct EnergyPartition: Sendable {
    public enum Part: Int, CaseIterable, Sendable { case car, home, battery, grid }
    public let polygons: [[CGPoint]]
    public let centers: [CGPoint]
    public let areas: [Double]
    public let shares: [Double]
    public let junction: CGPoint
    public let total: Double

    /// Whole labels add to 100; zero-power fields never receive a remainder.
    public var percentages: [Int] {
        guard total > 0 else { return [0, 0, 0, 0] }
        var result = shares.map { Int(floor($0 * 100)) }
        let ordered = shares.indices.sorted {
            let a = shares[$0] * 100 - Double(result[$0]), b = shares[$1] * 100 - Double(result[$1])
            return a == b ? $0 < $1 : a > b
        }
        for i in 0..<max(0, 100 - result.reduce(0, +)) { result[ordered[i % 4]] += 1 }
        return result
    }

    public init(powers: [Double], size: CGSize, phase: Double = 0, drag: CGSize = .zero, touch: CGPoint = CGPoint(x: 0.5, y: 0.5), ripple: Double = 0) {
        let values = (0..<4).map { i in
            i < powers.count && powers[i].isFinite ? max(0, powers[i]) : 0
        }
        let sum = values.reduce(0, +)
        total = sum
        let w = max(0, Double(size.width)), h = max(0, Double(size.height))
        guard total > 0, w > 0, h > 0 else {
            polygons = Array(repeating: [], count: 4)
            centers = Array(repeating: .zero, count: 4)
            areas = Array(repeating: 0, count: 4)
            shares = Array(repeating: 0, count: 4)
            junction = .zero
            return
        }
        let f = values.map { $0 / sum }, area = w * h
        shares = f
        let c = f[0] * w, room = min(c, w - c)
        let phase = phase.isFinite ? phase : 0
        let dx = drag.width.isFinite ? max(-1, min(1, Double(drag.width))) : 0
        let dy = drag.height.isFinite ? max(-1, min(1, Double(drag.height))) : 0
        let touchX = touch.x.isFinite ? max(0, min(1, Double(touch.x))) : 0.5
        let touchY = touch.y.isFinite ? max(0, min(1, Double(touch.y))) : 0.5
        let ripple = ripple.isFinite ? max(-1, min(1, ripple)) : 0
        let gripY = max(0, min(1, touchY + dy * 0.23))
        let spread = 0.15 + abs(dy) * 0.08
        func rawWave(_ u: Double) -> Double {
            let distance = (u - gripY) / spread
            let grip = (dx * 4.8 + dy * 1.4 * distance) * exp(-distance * distance)
            return -0.25 * cos(2 * .pi * u + phase) + 0.06 * sin(4 * .pi * u - phase * 0.7)
                + grip + ripple * 0.22 * cos(4 * .pi * u - phase)
        }
        // A moving grip and its wake change the contour, never the amount.
        let mean = ((rawWave(0) + rawWave(1)) / 2 + (1..<96).reduce(0) { $0 + rawWave(Double($1) / 96) }) / 96
        func wave(_ u: Double) -> Double { rawWave(u) - mean }
        let peak = (0...96).map { abs(wave(Double($0) / 96)) }.max() ?? 1
        let limit = peak > 0.96 ? 0.96 / peak : 1
        func seam(_ y: Double) -> Double { c + room * wave(y / h) * limit }
        var left = [CGPoint.zero]
        for i in 0...96 { let y = h * Double(i) / 96; left.append(CGPoint(x: seam(y), y: y)) }
        left.append(CGPoint(x: 0, y: h))
        var rest = [CGPoint(x: seam(0), y: 0), CGPoint(x: w, y: 0), CGPoint(x: w, y: h)]
        for i in stride(from: 96, through: 0, by: -1) {
            let y = h * Double(i) / 96
            rest.append(CGPoint(x: seam(y), y: y))
        }
        func prefix(_ b: Double) -> [CGPoint] {
            let cross = (0...64).map { i -> CGPoint in
                let u = Double(i) / 64
                let gripX = max(0, min(1, touchX + dx * 0.2))
                let finger = exp(-pow((u - gripX) / 0.21, 2))
                let bend = 0.03 * cos(phase * 0.65) + dy * 0.25 * finger + ripple * 0.025 * cos(3 * .pi * u)
                let y = h * (b + bend * sin(.pi * u) * sin(.pi * b))
                return CGPoint(x: seam(y) + (w - seam(y)) * u, y: y)
            }
            var p = [CGPoint(x: seam(0), y: 0), CGPoint(x: w, y: 0)] + cross.reversed()
            for i in stride(from: 96, through: 0, by: -1) {
                let y = h * b * Double(i) / 96
                p.append(CGPoint(x: seam(y), y: y))
            }
            return p
        }
        func solve(_ amount: Double) -> (points: [CGPoint], b: Double) {
            if amount < 1e-12 { return (prefix(0), 0) }
            if amount >= 1 - f[0] - 1e-12 { return (prefix(1), 1) }
            var lo = 0.0, hi = 1.0, b = 0.5
            for _ in 0..<19 {
                b = (lo + hi) / 2
                if Self.area(prefix(b)) < amount * area { lo = b } else { hi = b }
            }
            return (prefix(b), b)
        }
        let a = solve(f[1]), b = solve(f[1] + f[2])
        let la = Self.area(left), ra = Self.area(rest), ha = Self.area(a.points), hba = Self.area(b.points)
        let lc = Self.centroid(left), rc = Self.centroid(rest), hc = Self.centroid(a.points), hbc = Self.centroid(b.points)
        func subtract(_ ca: CGPoint, _ aa: Double, _ cb: CGPoint, _ ab: Double) -> CGPoint {
            guard aa - ab > 1e-7 else { return ca }
            return CGPoint(x: (ca.x * aa - cb.x * ab) / (aa - ab), y: (ca.y * aa - cb.y * ab) / (aa - ab))
        }
        polygons = [left, a.points, b.points, rest]
        areas = [la, ha, max(0, hba - ha), max(0, ra - hba)]
        centers = [lc, hc, subtract(hbc, hba, hc, ha), subtract(rc, ra, hbc, hba)]
        let y = h * a.b
        junction = CGPoint(x: seam(y), y: y)
    }

    public static func area(_ p: [CGPoint]) -> Double {
        guard p.count > 2 else { return 0 }
        var a = 0.0
        for i in p.indices { let q = p[(i + 1) % p.count]; a += p[i].x * q.y - q.x * p[i].y }
        return abs(a / 2)
    }

    private static func centroid(_ p: [CGPoint]) -> CGPoint {
        guard p.count > 2 else { return .zero }
        var a = 0.0, x = 0.0, y = 0.0
        for i in p.indices {
            let q = p[(i + 1) % p.count], v = p[i].x * q.y - q.x * p[i].y
            a += v; x += (p[i].x + q.x) * v; y += (p[i].y + q.y) * v
        }
        guard abs(a) > 1e-7 else { return .zero }
        return CGPoint(x: x / (3 * a), y: y / (3 * a))
    }
}
