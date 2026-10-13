import Testing
@testable import FTWShared

/// The slot under a finger, which the price chart's marker and haptic
/// read. It must exist for every place a finger can be.
@Suite struct SlotLookupTests {
    // Slots at 0, 10 and 30: a gap from 20 to 30.
    let starts: [Double] = [0, 10, 30]

    func slot(_ ms: Double) -> Int? { SlotLookup.clamped(starts, at: ms, start: { $0 }) }

    @Test func aMomentFallsInTheSlotThatHoldsIt() {
        #expect(slot(0) == 0)
        #expect(slot(9.9) == 0)
        #expect(slot(10) == 1)
        #expect(slot(30) == 2)
    }

    @Test func aFingerPastEitherEdgeStaysOnTheEdgesSlot() {
        #expect(slot(-1_000) == 0)
        #expect(slot(40) == 2)
        #expect(slot(1e15) == 2)
    }

    @Test func aGapReadsAsTheSlotBeforeIt() {
        #expect(slot(25) == 1)
    }

    @Test func onlyNoSlotsGiveNoSlot() {
        #expect(SlotLookup.clamped([Double](), at: 5, start: { $0 }) == nil)
        #expect(SlotLookup.clamped([7.0], at: .nan, start: { $0 }) == 0)
    }
}
