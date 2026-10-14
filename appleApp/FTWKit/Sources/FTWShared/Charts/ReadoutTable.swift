import Foundation

/// What a chart says under the finger, worked out once per change of data,
/// so a slot change costs a subscript: the readout's two parts per slot,
/// prefix sums of energy for "so far" and for a span, and the slots that
/// earn a firmer haptic.
public struct ReadoutTable: Equatable, Sendable {
    /// "14:30–14:45", per slot.
    public var when: [String]
    /// "0,6 kW · 0,0–1,1", per slot; the gap word where a slot has no data.
    public var what: [String]
    /// Watt-hours into the site through the end of each slot: entry `i + 1`
    /// holds slots 0 through `i`.
    public var inWh: [Double]
    /// Watt-hours out of the site, the same way.
    public var outWh: [Double]
    /// Slots that give a light impact under the finger.
    public var landmarks: Set<Int>

    public init(when: [String], what: [String], inWh: [Double] = [], outWh: [Double] = [], landmarks: Set<Int> = []) {
        self.when = when
        self.what = what
        self.inWh = inWh
        self.outWh = outWh
        self.landmarks = landmarks
    }

    /// Energy from the window's start through slot `i`.
    public func soFar(_ i: Int) -> (inWh: Double, outWh: Double) {
        between(0, i)
    }

    /// Energy over slots `a` through `b`, both included, in either order.
    public func between(_ a: Int, _ b: Int) -> (inWh: Double, outWh: Double) {
        guard inWh.count > 1 else { return (0, 0) }
        let lo = min(max(min(a, b), 0), inWh.count - 2)
        let hi = min(max(max(a, b), 0), inWh.count - 2)
        return (inWh[hi + 1] - inWh[lo], outWh[hi + 1] - outWh[lo])
    }
}

/// How a readout words its numbers. The table keeps the strings it made,
/// not these.
public struct ReadoutWords: Sendable {
    /// "0,6 kW"
    public var value: @Sendable (Double) -> String
    /// "0,0–1,1", the lowest and highest five-minute mean in a slot.
    public var range: @Sendable (Double, Double) -> String
    /// "no data"
    public var none: String

    public init(value: @escaping @Sendable (Double) -> String, range: @escaping @Sendable (Double, Double) -> String, none: String) {
        self.value = value
        self.range = range
        self.none = none
    }
}
