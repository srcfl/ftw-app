import Foundation
import Testing
@testable import FTWShared

/// The price this phone shows. The box's numbers are Erik's morning: a
/// 462 öre total is 249 öre spot, 121 öre grid fee and tax, and 25 % VAT.
@Suite struct PriceShownTests {
    let slot = PriceSlot(startMs: 0, durationMs: 900_000, spotMinor: 249, totalMinor: 462)

    @Test func eachChoiceAtTheBoxsRate() {
        func shown(_ fees: Bool, _ vat: Bool) -> Double { PriceShown(fees: fees, vat: vat).minor(slot, vatPermille: 250) }
        #expect(shown(true, true) == 462)
        #expect(abs(shown(true, false) - 369.6) < 1e-9)
        #expect(abs(shown(false, true) - 311.25) < 1e-9)
        #expect(shown(false, false) == 249)
    }

    /// A box that does not say its rate: the total keeps its VAT and the
    /// spot price goes without, and the label says so.
    @Test func withoutTheRateTheLabelSaysWhatIsShown() {
        #expect(PriceShown(fees: true, vat: false).kind(vatPermille: nil) == .totalWithVAT)
        #expect(PriceShown(fees: false, vat: true).kind(vatPermille: nil) == .spotWithoutVAT)
        #expect(PriceShown(fees: false, vat: true).minor(slot, vatPermille: nil) == 249)
        #expect(PriceShown.label(.spotWithoutVAT) == "SPOT EXCL. VAT")
        // Zero VAT is a rate, not a missing one.
        #expect(PriceShown(fees: false, vat: true).kind(vatPermille: 0) == .spotWithVAT)
    }

    /// The charts draw the total, so the choice goes into it; the default
    /// leaves the answer as the box sent it.
    @Test func theChoiceGoesIntoTheTotal() {
        let prices = Prices(zone: "SE3", currency: "SEK", slots: [slot], stale: false, vatPermille: 250)
        #expect(PriceShown().apply(prices) == prices)
        #expect(PriceShown(fees: false, vat: false).apply(prices).slots[0].totalMinor == 249)
        #expect(PriceShown(fees: false, vat: false).apply(prices).slots[0].spotMinor == 249)
    }

    /// An answer kept from before the rate was on the wire still reads.
    @Test func aRecordWithoutTheRateStillReads() throws {
        let prices = Prices(zone: "SE3", currency: "SEK", slots: [slot], stale: false, vatPermille: 250)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(prices)) as? [String: Any])
        #expect(json["vatPermille"] as? Int == 250)
        json["vatPermille"] = nil
        let old = try JSONDecoder().decode(Prices.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.vatPermille == nil && old.slots == prices.slots)
    }
}
