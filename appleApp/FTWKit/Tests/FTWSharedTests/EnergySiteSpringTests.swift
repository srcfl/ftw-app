import CoreGraphics
import Testing
@testable import FTWShared

@Suite("Site spring")
struct EnergySiteSpringTests {
    @Test func aThrowPreservesItsPositionAndVelocityThenSettles() {
        let spring = EnergySiteSpring(displacement: CGSize(width: 100, height: -65), velocity: CGSize(width: 240, height: -80))
        #expect(spring.offset(after: 0) == CGSize(width: 100, height: -65))
        let dt = 0.00001, next = spring.offset(after: dt)
        #expect(abs((next.width - 100) / dt - 240) < 0.1)
        #expect(abs((next.height + 65) / dt + 80) < 0.1)
        #expect(spring.offset(after: 0.3).width < 0)
        #expect(hypot(spring.offset(after: 2).width, spring.offset(after: 2).height) < 0.1)
        #expect(spring.offset(after: 3) == .zero)
    }

    @Test func aNewGripCanStartFromTheCurrentReturnWithoutAJump() {
        let first = EnergySiteSpring(displacement: CGSize(width: -120, height: 95))
        let interrupted = first.offset(after: 0.23)
        let second = EnergySiteSpring(displacement: interrupted, velocity: CGSize(width: -90, height: 20))
        #expect(second.offset(after: 0) == interrupted)
        let invalid = EnergySiteSpring(displacement: CGSize(width: Double.nan, height: Double.infinity))
        #expect(invalid.offset(after: 0) == .zero)
        #expect(invalid.offset(after: .infinity) == .zero)
    }
}
