import Foundation

/// Which price the app shows, a choice on this phone. Fredrik, 1 Nov 2026:
/// he wants it without grid fees, and wants to know whether it is with or
/// without VAT. The box sends the spot price (no fee, no VAT) and the
/// total it bills (fee, tax and VAT), and since `vatPermille` the rate it
/// taxed at, so the phone can show either with or without VAT. A box that
/// does not say its rate gets the price the phone has, and the label says
/// which that is: a price is never shown under the wrong name.
public struct PriceShown: Equatable, Sendable {
    /// With the grid fee and energy tax: the total, not the spot price.
    public var fees: Bool
    public var vat: Bool

    /// Where the two choices are kept, on this phone.
    public static let feesKey = "FTWPriceFees"
    public static let vatKey = "FTWPriceVAT"

    public init(fees: Bool = true, vat: Bool = true) {
        self.fees = fees
        self.vat = vat
    }

    /// What is shown, which the label names.
    public enum Kind: Equatable, Sendable {
        case totalWithVAT, totalWithoutVAT, spotWithVAT, spotWithoutVAT
    }

    /// What this choice can show at the box's rate: without it, the total
    /// keeps its VAT and the spot price goes without.
    public func kind(vatPermille: Int?) -> Kind {
        switch (fees, vat, vatPermille) {
        case (true, true, _), (true, false, nil): return .totalWithVAT
        case (true, false, _?): return .totalWithoutVAT
        case (false, true, _?): return .spotWithVAT
        case (false, _, _): return .spotWithoutVAT
        }
    }

    /// The price shown for one slot, in minor units per kWh.
    public func minor(_ slot: PriceSlot, vatPermille: Int?) -> Double {
        let rate = 1 + Double(vatPermille ?? 0) / 1000
        switch kind(vatPermille: vatPermille) {
        case .totalWithVAT: return slot.totalMinor
        case .totalWithoutVAT: return slot.totalMinor / rate
        case .spotWithVAT: return slot.spotMinor * rate
        case .spotWithoutVAT: return slot.spotMinor
        }
    }

    /// The slots with the shown price in `totalMinor`, so every chart that
    /// draws the total draws what this phone chose.
    public func apply(_ slots: [PriceSlot], vatPermille: Int?) -> [PriceSlot] {
        guard kind(vatPermille: vatPermille) != .totalWithVAT else { return slots }
        return slots.map { s in
            var out = s
            out.totalMinor = minor(s, vatPermille: vatPermille)
            return out
        }
    }

    /// The same for a whole answer.
    public func apply(_ prices: Prices) -> Prices {
        var out = prices
        out.slots = apply(prices.slots, vatPermille: prices.vatPermille)
        return out
    }

    /// The same in a line's words: "spot price only", "incl. VAT".
    public static func words(_ kind: Kind) -> String {
        switch kind {
        case .totalWithVAT: return GlanceWord.inclGridFeeAndVAT.text
        case .totalWithoutVAT: return GlanceWord.inclGridFee.text
        case .spotWithVAT: return GlanceWord.inclVAT.text
        case .spotWithoutVAT: return GlanceWord.spotOnly.text
        }
    }

    /// "SPOT INCL. VAT", over a chart.
    public static func label(_ kind: Kind) -> String {
        switch kind {
        case .totalWithVAT: return PriceWord.totalWithVAT.text
        case .totalWithoutVAT: return PriceWord.totalWithoutVAT.text
        case .spotWithVAT: return PriceWord.spotWithVAT.text
        case .spotWithoutVAT: return PriceWord.spotWithoutVAT.text
        }
    }
}
