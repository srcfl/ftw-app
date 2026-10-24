import Foundation
import Testing
@testable import FTWShared

@Suite struct ScaleSpringTests {
    static func domain(_ upper: Double, _ lower: Double = 0) -> YDomain { YDomain(lower: lower, upper: upper) }

    /// The spring from rest at `from` to `to`, stepped at `hz`: the upper
    /// ends it showed and when it came to rest.
    static func run(from: YDomain, to: YDomain, hz: Double, limit: Double = 2) -> (uppers: [Double], restsAt: Double?) {
        var spring = ScaleSpring()
        spring.target(from, at: 0, still: false)
        let moves = spring.target(to, at: 0, still: false)
        #expect(moves)
        var uppers: [Double] = []
        var t = 0.0
        while t < limit {
            t += 1 / hz
            uppers.append(spring.shown(at: t)!.upper)
            if spring.resting { return (uppers, t) }
        }
        return (uppers, nil)
    }

    @Test func theFirstScaleAndOneUnderReduceMotionAreThereAtOnce() {
        var spring = ScaleSpring()
        let none = spring.shown(at: 0)
        #expect(none == nil)
        let first = spring.target(Self.domain(5_000), at: 0, still: false)
        #expect(!first && spring.resting)
        let shown = spring.shown(at: 0.01)
        #expect(shown == Self.domain(5_000))
        let still = spring.target(Self.domain(500), at: 0.02, still: true)
        #expect(!still && spring.resting)
        let night = spring.shown(at: 0.03)
        #expect(night == Self.domain(500))
    }

    /// A day peak of 11 kW falling to a night of 500 W, and the other way:
    /// the scale moves one way only, never past its target, and then rests
    /// exactly on it, whatever the display's rate.
    @Test func aBigChangeLandsWithoutOvershootAndRestsOnTheTarget() throws {
        for (from, to) in [(15_000.0, 750.0), (750, 15_000), (100_000, 1_000), (3_000, 2_000)] {
            for hz in [60.0, 120.0, 37.0] {
                let run = Self.run(from: Self.domain(from), to: Self.domain(to), hz: hz)
                let restsAt = try #require(run.restsAt)
                #expect(restsAt < 0.8)
                #expect(run.uppers.last == to)
                for (a, b) in zip([from] + run.uppers, run.uppers) {
                    #expect(to < from ? b <= a : b >= a)
                    #expect(to < from ? b >= to : b <= to)
                }
            }
        }
    }

    @Test func thePathIsTheSameAtAnyFrameRate() {
        func upper(at t: Double, steps: Int) -> Double {
            var spring = ScaleSpring()
            spring.target(Self.domain(15_000), at: 0, still: false)
            spring.target(Self.domain(750), at: 0, still: false)
            var shown = 0.0
            for i in 1...steps { shown = spring.shown(at: t * Double(i) / Double(steps))!.upper }
            return shown
        }
        #expect(abs(upper(at: 0.1, steps: 1) - upper(at: 0.1, steps: 12)) < 1e-6)
        #expect(abs(upper(at: 0.2, steps: 3) - upper(at: 0.2, steps: 48)) < 1e-6)
    }

    @Test func aClockThatStepsBackMovesNothingAndCountsTimeOnce() {
        var straight = ScaleSpring()
        straight.target(Self.domain(15_000), at: 0, still: false)
        straight.target(Self.domain(750), at: 0, still: false)
        var late = straight
        let before = late.shown(at: 0.05)
        let held = late.shown(at: 0.04)
        let again = late.shown(at: 0.05)
        #expect(held == before && again == before)
        let lateEnd = late.shown(at: 0.1)!.upper
        let straightEnd = straight.shown(at: 0.1)!.upper
        #expect(abs(lateEnd - straightEnd) < 1e-6)
    }

    /// A pinch through several steps of scale: the end keeps its speed
    /// into the next step, and a turn back stops it at once.
    @Test func aRetargetKeepsSpeedOnwardAndStopsOnATurn() {
        var spring = ScaleSpring()
        spring.target(Self.domain(5_000), at: 0, still: false)
        spring.target(Self.domain(10_000), at: 0, still: false)
        let a = spring.shown(at: 0.05)!.upper
        let b = spring.shown(at: 0.06)!.upper
        var onward = spring
        onward.target(Self.domain(15_000), at: 0.06, still: false)
        let speed = (b - a) / 0.01
        let next = (onward.shown(at: 0.061)!.upper - b) / 0.001
        #expect(abs(next - speed) / speed < 0.05)

        var back = spring
        back.target(Self.domain(5_000), at: 0.06, still: false)
        let turned = back.shown(at: 0.061)!.upper
        #expect(turned <= b)
    }

    /// Random retargets mid-flight: between two targets an end only ever
    /// closes on the one it has, and never passes it.
    @Test func noRetargetCarriesAnEndPastItsTarget() {
        var seed: UInt64 = 0x2026_1024
        func random() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(1 << 53)
        }
        let steps = [500.0, 750, 1_000, 1_500, 2_000, 3_000, 5_000, 7_500, 10_000, 15_000]
        for _ in 0..<300 {
            var spring = ScaleSpring()
            var index = Int(random() * 10)
            spring.target(Self.domain(steps[index]), at: 0, still: false)
            var t = 0.0
            for _ in 0..<6 {
                index = min(9, max(0, index + (random() < 0.5 ? -1 : 1)))
                let target = steps[index]
                spring.target(Self.domain(target), at: t, still: false)
                var gap = abs(spring.shown(at: t)!.upper - target)
                let side = (spring.shown(at: t)!.upper - target).sign
                let hold = 0.02 + random() * 0.3
                let end = t + hold
                while t < end {
                    t += 1 / 120
                    let upper = spring.shown(at: t)!.upper
                    #expect(abs(upper - target) <= gap + 1e-9)
                    #expect(upper == target || (upper - target).sign == side)
                    gap = abs(upper - target)
                }
            }
        }
    }
}
