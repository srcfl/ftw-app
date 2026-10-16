import CoreGraphics
import Testing
@testable import FTWShared

@Suite struct EnergyPartitionTests {
    /// Measure the paths independently of the layout's reported areas.
    private func area(_ points: [CGPoint]) -> Double {
        guard points.count > 2 else { return 0 }
        return abs(points.indices.reduce(0) { value, i in
            let next = points[(i + 1) % points.count]
            return value + Double(points[i].x * next.y - next.x * points[i].y)
        }) / 2
    }

    @Test func powerSharesEqualPaintedAreasAcrossTransitions() {
        let profiles = [[2.5, 1.3, 0, 0.4], [1.2, 1, 0, 3.8], [2, 1.2, 2.4, 0.4], [0.5, 0.8, 0, 0], [0, 1.3, 0, 2.9], [0, 0, 0, 1], [1, 0, 0, 0]]
        for width in [280.0, 375, 430] {
            for pair in zip(profiles, profiles.dropFirst() + [profiles[0]]) {
                for step in 0...20 {
                    let t = Double(step) / 20, powers = zip(pair.0, pair.1).map { $0 * (1 - t) + $1 * t }
                    let layout = EnergyPartition(powers: powers, size: CGSize(width: width, height: 385))
                    let measured = layout.polygons.map(area)
                    let painted = [measured[0], measured[1], measured[2] - measured[1], measured[3] - measured[2]]
                    for i in 0..<4 {
                        #expect(abs(painted[i] / (width * 385) - powers[i] / powers.reduce(0, +)) < 0.00003)
                        #expect(painted[i] >= -0.001)
                        #expect(layout.centers[i].x.isFinite && layout.centers[i].y.isFinite)
                    }
                    #expect(abs(painted.reduce(0, +) - width * 385) < 0.01)
                }
            }
        }
    }

    @Test func emptyInvalidAndNegativeValuesDoNotInventPower() {
        for values in [[], [0, 0, 0, 0], [-1, .nan, .infinity, -4]] {
            let layout = EnergyPartition(powers: values, size: CGSize(width: 390, height: 385))
            #expect(layout.total == 0)
            let empty = layout.polygons.allSatisfy(\.isEmpty)
            #expect(empty)
        }
        let zeroSize = EnergyPartition(powers: [1, 1, 1, 1], size: .zero)
        let empty = zeroSize.polygons.allSatisfy(\.isEmpty)
        #expect(empty)
    }

    @Test func draggingAndMovingContoursKeepTheAmounts() {
        for phase in [0.0, 0.7, 2.8, 5.3] {
            for force in [CGSize(width: -1, height: 1), CGSize(width: 1, height: -1), CGSize(width: 0.3, height: 0.7)] {
                for touch in [CGPoint(x: 0.05, y: 0.1), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.95, y: 0.9)] {
                    let powers = [2.0, 1.2, 2.4, 0.4]
                    let layout = EnergyPartition(powers: powers, size: CGSize(width: 390, height: 385), phase: phase, drag: force, touch: touch)
                    let a = layout.polygons.map(area)
                    let actual = [a[0], a[1], a[2] - a[1], a[3] - a[2]]
                    for i in 0..<4 { #expect(abs(actual[i] / (390 * 385) - powers[i] / 6) < 0.00003) }
                    #expect(layout.percentages.reduce(0, +) == 100)
                    for polygon in layout.polygons {
                        for point in polygon { #expect(point.x >= -0.001 && point.x <= 390.001 && point.y >= -0.001 && point.y <= 385.001) }
                    }
                }
            }
        }
    }
}
