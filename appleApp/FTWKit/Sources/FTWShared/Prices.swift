import Foundation

public struct PriceSlot: Equatable, Sendable, Identifiable, Codable {
    public var startMs: Double
    public var durationMs: Double
    /// Integer minor units per kWh. Money never crosses as a float.
    public var spotMinor: Double
    /// What the household pays, tariff and tax included, computed by the box.
    public var totalMinor: Double
    public var id: Double { startMs }

    public init(startMs: Double, durationMs: Double, spotMinor: Double, totalMinor: Double) {
        self.startMs = startMs
        self.durationMs = durationMs
        self.spotMinor = spotMinor
        self.totalMinor = totalMinor
    }
}

public struct Prices: Equatable, Sendable, Codable {
    public var zone: String
    public var currency: String
    public var slots: [PriceSlot]
    /// The answer does not cover the window asked for. Which of the three
    /// shapes it is has to be read off the slots.
    public var stale: Bool

    public init(zone: String, currency: String, slots: [PriceSlot], stale: Bool) {
        self.zone = zone
        self.currency = currency
        self.slots = slots
        self.stale = stale
    }
}
