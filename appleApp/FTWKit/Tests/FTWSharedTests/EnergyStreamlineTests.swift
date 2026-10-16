import CoreGraphics
import Testing
@testable import FTWShared

@Suite struct EnergyStreamlineTests {
    @Test func aHeldStreamPassesAroundBothSidesOfTheContactPatch() {
        for side in [-1.0, 1] {
            let finger = CGPoint(x: 100, y: 200)
            let line = EnergyStreamline(from: CGPoint(x: 100, y: 0), control1: CGPoint(x: 100, y: 130),
                                        control2: CGPoint(x: 100, y: 270), to: CGPoint(x: 100, y: 400),
                                        finger: finger, origin: finger, strength: 1, radius: 35, side: side)
            #expect(line.points.first == CGPoint(x: 100, y: 0))
            #expect(line.points.last == CGPoint(x: 100, y: 400))
            for p in line.points { #expect(hypot(p.x - finger.x, p.y - finger.y) >= 35) }
            #expect(line.points[48].x * side < 100 * side)
        }
    }

    @Test func theGripCarriesEnergyToTheActualFingerAndLetsGoWithoutMovingThePorts() {
        let start = CGPoint(x: 100, y: 0), end = CGPoint(x: 100, y: 400)
        let finger = CGPoint(x: 230, y: 190), origin = CGPoint(x: 100, y: 200)
        let held = EnergyStreamline(from: start, control1: CGPoint(x: 100, y: 130), control2: CGPoint(x: 100, y: 270), to: end,
                                    finger: finger, origin: origin, strength: 1)
        #expect(held.points.contains { hypot($0.x - finger.x, $0.y - finger.y) < 55 })
        #expect(held.points.first == start && held.points.last == end)
        let released = EnergyStreamline(from: start, control1: CGPoint(x: 100, y: 130), control2: CGPoint(x: 100, y: 270), to: end,
                                        finger: finger, origin: origin, strength: 0)
        #expect(released.points.allSatisfy { abs($0.x - 100) < 0.000001 })
    }
}
