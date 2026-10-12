import Foundation

/// The price card's reading of a window: the price now, the cheapest two
/// hours ahead, and a tone for every slot still to come. The box's
/// price-summary.js, price-strip.js and price-math.js, on the consumer
/// total the box already computed.
public enum PriceStrip {
    public enum Tone: Sendable { case dear, cheap, flat, negative }

    public struct Bar: Identifiable, Equatable, Sendable {
        public let startMs: Double
        public let endMs: Double
        /// Minor units per kWh, the consumer total.
        public let minor: Double
        public let tone: Tone
        public let current: Bool
        public var id: Double { startMs }
    }

    public struct Block: Equatable, Sendable {
        public let meanMinor: Double
        public let startMs: Double
        public let endMs: Double
    }

    public struct Summary: Equatable, Sendable {
        public let current: PriceSlot?
        /// Every slot not yet over, the current one included.
        public let bars: [Bar]
        public let meanMinor: Double?
        /// The cheapest two whole hours in a row, not the cheapest single
        /// slot: a dishwasher or a car top-up runs in blocks, not troughs.
        public let cheapest: Block?
    }

    public static func summary(_ prices: Prices, nowMs: Double) -> Summary {
        let slots = prices.slots.filter { $0.totalMinor.isFinite }.sorted { $0.startMs < $1.startMs }
        let current = slots.first { nowMs >= $0.startMs && nowMs < $0.startMs + $0.durationMs }
        let upcoming = slots.filter { $0.startMs + $0.durationMs > nowMs }
        guard upcoming.count >= 2 else {
            return Summary(current: current, bars: [], meanMinor: nil, cheapest: bestBlock(upcoming, hours: 2, cheapest: true))
        }
        let values = upcoming.map(\.totalMinor)
        let mean = values.reduce(0, +) / Double(values.count)
        let hi = values.max() ?? 0, lo = values.min() ?? 0
        let flat = max(hi - lo, 1) * 0.05
        let bars = upcoming.map { s -> Bar in
            let tone: Tone = s.totalMinor < 0 ? .negative : abs(s.totalMinor - mean) < flat ? .flat : s.totalMinor > mean ? .dear : .cheap
            return Bar(startMs: s.startMs, endMs: s.startMs + s.durationMs, minor: s.totalMinor, tone: tone, current: s.startMs == current?.startMs)
        }
        return Summary(current: current, bars: bars, meanMinor: mean, cheapest: bestBlock(upcoming, hours: 2, cheapest: true))
    }

    /// The contiguous run of `hours` with the lowest (or highest) mean.
    public static func bestBlock(_ slots: [PriceSlot], hours: Double, cheapest: Bool) -> Block? {
        let need = hours * 3_600_000
        var best: Block?
        for i in slots.indices {
            var span = 0.0, sum = 0.0, count = 0.0
            var j = i
            while j < slots.count, span < need {
                if j > i, slots[j].startMs != slots[j - 1].startMs + slots[j - 1].durationMs { break }
                span += slots[j].durationMs
                sum += slots[j].totalMinor
                count += 1
                j += 1
            }
            guard span >= need, count > 0 else { continue }
            let mean = sum / count
            if best == nil || (cheapest ? mean < best!.meanMinor : mean > best!.meanMinor) {
                best = Block(meanMinor: mean, startMs: slots[i].startMs, endMs: slots[i].startMs + span)
            }
        }
        return best
    }

    /// The card's figure: no decimals from a hundred up, else the unit's.
    public static func text(_ minor: Double?, _ currency: String?) -> String {
        guard let minor, minor.isFinite else { return "—" }
        let shown = PriceUnits.display(minor, currency)
        return PowerFormat.fixed(shown, abs(shown) >= 100 ? 0 : PriceUnits.unit(currency).decimals)
    }
}
