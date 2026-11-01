import Foundation
import Testing
@testable import FTWKit
@testable import FTWWire

/// The box's answer to `price.get`, as srcfl/ftw#1949 sends it: the slots,
/// and the VAT rate the box taxed the totals at, in permille.
@Suite struct PriceWireTests {
    func answer(_ extra: [(String, CBOR)]) -> CBOR {
        .map([
            ("zone", .text("SE3")), ("currency", .text("SEK")), ("stale", .bool(false)),
            ("slots", .array([.map([("startMs", .int(1_800_000_000_000)), ("durationMs", .int(900_000)), ("spotMinor", .int(249)), ("totalMinor", .int(462))])])),
        ] + extra)
    }

    @Test func theAnswerCarriesTheBoxsVATRate() {
        let p = Prices(answer([("vatPermille", .int(255))]))
        #expect(p.vatPermille == 255)
        #expect(p.slots.first?.spotMinor == 249 && p.slots.first?.totalMinor == 462)
        // Zero is a rate.
        #expect(Prices(answer([("vatPermille", .int(0))])).vatPermille == 0)
    }

    /// An older box leaves it out: the rate is unknown, not zero.
    @Test func anOlderBoxSaysNoRate() {
        #expect(Prices(answer([])).vatPermille == nil)
    }
}
