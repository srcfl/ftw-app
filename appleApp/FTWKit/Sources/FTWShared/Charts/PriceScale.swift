import Foundation

/// A price axis that stands on zero, as elklocka.se draws one: every bar
/// starts at 0 and the top is a round figure just over the dearest price,
/// so 440 against 550 öre looks a fifth dearer, not five times. Erik read
/// the old strip, which put the window's cheapest at the floor, as "five
/// times dearer tonight" (1 Nov 2026). A price below zero hangs under the
/// zero line, on a round figure of its own.
///
/// Now's strip, the plan's price chart, the watch and the widgets all
/// scale their bars with this, so the same price always has the same
/// height on one screen.
public struct PriceScale: Equatable, Sendable {
    /// The round price the top of the plot stands for, in minor units.
    public let top: Double
    /// Zero, or a round price under it when the window holds one below zero.
    public let bottom: Double
    /// The prices the grid lines mark: half the top and the top.
    public let lines: [Double]
    public let currency: String

    /// The scale for `values`, in minor units per kWh. With nothing priced
    /// it still has a top, so a strip keeps its shape. The currency names
    /// the figures; the round top is the same in any unit a power of ten
    /// apart.
    public init(_ values: [Double], currency: String = "") {
        let finite = values.filter(\.isFinite)
        let unit = PriceUnits.unit(currency).scale
        // Round in the unit drawn (öre, cent, Kč), then back to minor.
        let hi = max(finite.max() ?? 0, 0) * unit
        let lo = min(finite.min() ?? 0, 0) * unit
        let top = Self.round(max(hi, unit)) / unit
        self.top = top
        bottom = lo < 0 ? -Self.round(-lo) / unit : 0
        lines = [top / 2, top]
        self.currency = currency
    }

    /// Where `minor` sits: 0 at the bottom, 1 at the top.
    public func fraction(_ minor: Double) -> Double {
        guard top > bottom else { return 0 }
        return min(1, max(0, (minor - bottom) / (top - bottom)))
    }

    /// Where zero sits: 0 unless a price falls below it.
    public var zero: Double { fraction(0) }

    /// The block-glyph step, 1 to 8 (▁ to █), from zero to the top. Zero
    /// and anything under it is the lowest step.
    public func step(_ minor: Double) -> Int {
        guard top > 0, minor.isFinite else { return 1 }
        return max(1, min(8, Int((max(0, minor) / top * 8 - 1e-9).rounded(.up))))
    }

    /// A grid line's label in the unit drawn, with no trailing zero:
    /// "300", "2,5".
    public func label(_ minor: Double) -> String {
        let shown = PriceUnits.display(minor, currency)
        let decimals = (0...2).first { abs(shown * pow(10, Double($0)) - (shown * pow(10, Double($0))).rounded()) < 1e-6 } ?? 2
        return Words.decimal(PowerFormat.fixed(shown, decimals))
    }

    /// The first of 1, 1.5, 2, 2.5, 3, 4, 5, 6 or 8 times a power of ten at
    /// or over `v`: 556 gives 600, 182 gives 200, 142 gives 150.
    static func round(_ v: Double) -> Double {
        guard v.isFinite, v > 0 else { return 1 }
        let decade = pow(10, floor(log10(v)))
        for m in [1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10] where m * decade >= v * (1 - 1e-9) {
            return m * decade
        }
        return 10 * decade
    }
}
