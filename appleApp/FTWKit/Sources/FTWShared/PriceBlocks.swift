import Foundation

/// The block-glyph scale, ▁▂▃▄▅▆▇█: a price as one of eight levels between
/// the lowest and the highest in view, and its ink by thirds of that range.
/// The small price widget draws it as bars and the lock screen writes it in
/// SF Mono, from the same hours, so the two always agree.
public enum PriceBlocks {
    public static let glyphs: [Character] = Array("▁▂▃▄▅▆▇█")
    public static let hourMs: Double = 3_600_000

    /// One hour of the strip: its mean price, its level and its third.
    public struct Hour: Equatable, Sendable {
        public let startMs: Double
        /// The mean of the slots that fall in this hour, minor units per kWh.
        public let minor: Double
        /// 1 to 8.
        public let level: Int
        public let third: PriceChart.Third
        /// The hour that holds now.
        public let current: Bool
    }

    /// The next `count` hours on the household's clock, from the one that
    /// holds `nowMs`, each the mean of the slots in it. An hour with no slot
    /// ends the strip: nothing is drawn where the market has not priced.
    public static func hours(_ bars: [PriceStrip.Bar], nowMs: Double, count: Int, clock: ZoneClock) -> [Hour] {
        let first = clock.alignDown(nowMs, stepMs: hourMs)
        var sums = [Double](repeating: 0, count: count), held = [Int](repeating: 0, count: count)
        for b in bars where b.endMs > nowMs {
            let k = Int(((max(b.startMs, first) - first) / hourMs).rounded(.down))
            guard k >= 0, k < count else { continue }
            sums[k] += b.minor
            held[k] += 1
        }
        let n = held.firstIndex(of: 0) ?? count
        let means = (0..<n).map { sums[$0] / Double(held[$0]) }
        let levels = levels(means)
        let thirds = thirds(means)
        return (0..<n).map { Hour(startMs: first + Double($0) * hourMs, minor: means[$0], level: levels[$0], third: thirds[$0], current: $0 == 0) }
    }

    /// 1 to 8 between the lowest and highest value; 4 when they are equal.
    public static func levels(_ values: [Double]) -> [Int] {
        let lo = values.min() ?? 0, hi = values.max() ?? 0
        return values.map { v in hi > lo ? 1 + min(7, Int(((v - lo) / (hi - lo) * 8).rounded(.down))) : 4 }
    }

    /// The cheap, middle or dear third of the range; middle when flat.
    public static func thirds(_ values: [Double]) -> [PriceChart.Third] {
        let lo = values.min() ?? 0, hi = values.max() ?? 0
        let third = (hi - lo) / 3
        return values.map { v in hi > lo ? (v < lo + third ? .cheap : v >= lo + 2 * third ? .dear : .middle) : .middle }
    }

    /// "▃▃▂▁▁▂▅▇█▆▅▄": one glyph per hour.
    public static func text(_ hours: [Hour]) -> String {
        String(hours.map { glyphs[max(0, min(glyphs.count - 1, $0.level - 1))] })
    }
}
