import Foundation

/// What to call the number on a price, from the box's price-units.js. Every
/// price is minor units per kWh; only the label and the decimals differ.
public enum PriceUnits {
    public struct Unit: Sendable {
        public let label: String
        public let perKwh: String
        public let scale: Double
        public let decimals: Int
    }

    static let units: [String: Unit] = [
        "SEK": Unit(label: "öre", perKwh: "öre/kWh", scale: 1, decimals: 1),
        "NOK": Unit(label: "øre", perKwh: "øre/kWh", scale: 1, decimals: 1),
        "DKK": Unit(label: "øre", perKwh: "øre/kWh", scale: 1, decimals: 1),
        "EUR": Unit(label: "cent", perKwh: "cent/kWh", scale: 1, decimals: 1),
        "PLN": Unit(label: "gr", perKwh: "gr/kWh", scale: 1, decimals: 1),
        "CHF": Unit(label: "Rp.", perKwh: "Rp./kWh", scale: 1, decimals: 1),
        "CZK": Unit(label: "Kč", perKwh: "Kč/kWh", scale: 0.01, decimals: 2),
        "HUF": Unit(label: "Ft", perKwh: "Ft/kWh", scale: 0.01, decimals: 1),
        "RON": Unit(label: "lei", perKwh: "lei/kWh", scale: 0.01, decimals: 2),
    ]

    public static func unit(_ currency: String?) -> Unit {
        let code = (currency ?? "SEK").isEmpty ? "SEK" : (currency ?? "SEK").uppercased()
        return units[code] ?? Unit(label: code, perKwh: "\(code)/kWh", scale: 0.01, decimals: 3)
    }

    public static func display(_ minor: Double, _ currency: String?) -> Double {
        minor * unit(currency).scale
    }

    /// "17.4", in the chart's unit and precision.
    public static func text(_ minor: Double?, _ currency: String?) -> String? {
        guard let minor, minor.isFinite else { return nil }
        return PowerFormat.fixed(display(minor, currency), unit(currency).decimals)
    }

    /// Whether a price window misses hours rather than ending early: a head
    /// that starts after the window asked for, or a hole in the middle.
    public static func hasHole(_ slots: [PriceSlot], fromMs: Double) -> Bool {
        guard let first = slots.first else { return false }
        if first.startMs > fromMs { return true }
        for i in slots.indices.dropFirst() where slots[i - 1].startMs + slots[i - 1].durationMs < slots[i].startMs {
            return true
        }
        return false
    }
}
