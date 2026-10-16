import CoreGraphics
import Foundation

/// Soft adjoining regions sized by each part's absolute power. Small resting
/// areas keep idle equipment discoverable. The grid remains one endpoint.
public struct EnergySiteMix: Sendable {
    public let biases: [Double]
    public let shares: [Double]
    public static let centers = [CGPoint(x: 0.23, y: 0.175), CGPoint(x: 0.79, y: 0.30),
                                 CGPoint(x: 0.22, y: 0.53), CGPoint(x: 0.76, y: 0.665), CGPoint(x: 0.48, y: 0.90)]

    public init(powers: [Double]) {
        let values = (0..<5).map { i -> Double in
            guard i < powers.count, powers[i].isFinite else { return 0 }
            return abs(powers[i])
        }
        let peak = values.max() ?? 0
        let normalized = values.map { peak > 0 ? $0 / peak : 1 }
        let total = normalized.reduce(0, +)
        let rest = [0.01, 0.018, 0.018, 0.035, 0.01]
        let available = 1 - rest.reduce(0, +)
        shares = (0..<5).map { rest[$0] + available * normalized[$0] / total }
        var offsets = Array(repeating: 0.0, count: 5)
        let samples = (0..<30).flatMap { y in
            (0..<18).map { x in Self.scores(CGPoint(x: (Double(x) + 0.5) / 18, y: (Double(y) + 0.5) / 30)) }
        }
        for _ in 0..<70 {
            var measured = Array(repeating: 0.0, count: 5)
            for score in samples {
                let weights = Self.weights(scores: score, biases: offsets)
                for i in 0..<5 { measured[i] += weights[i] / Double(samples.count) }
            }
            for i in 0..<5 { offsets[i] += 0.85 * log(shares[i] / max(0.000001, measured[i])) }
            let mean = offsets.reduce(0, +) / 5
            for i in 0..<5 { offsets[i] -= mean }
        }
        biases = offsets
    }

    public func weights(at point: CGPoint) -> [Double] { Self.weights(scores: Self.scores(point), biases: biases) }

    private static func scores(_ p: CGPoint) -> [Double] {
        centers.map { -(pow(p.x - $0.x, 2) + pow(p.y - $0.y, 2)) / 0.026 }
    }
    private static func weights(scores: [Double], biases: [Double]) -> [Double] {
        let adjusted = (0..<5).map { scores[$0] + biases[$0] }
        let peak = adjusted.max() ?? 0
        let mass = adjusted.map { exp($0 - peak) }
        let total = mass.reduce(0, +)
        return mass.map { $0 / total }
    }
}
