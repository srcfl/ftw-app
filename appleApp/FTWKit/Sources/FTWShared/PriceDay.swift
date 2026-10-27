import Foundation

/// One day of prices, as History's price row tells it: what the day
/// averaged, what its cheapest slot cost and when, and the day drawn
/// midnight to midnight beside the nodes' own days.
///
/// The figure is the total — what the household pays, tariff and tax
/// included — as every other price in the app is. One day's row and the
/// price screen it opens must not disagree about what a price is, and the
/// screen already says what the total holds.
///
/// Holes are holes. A slot the box has no price for draws nothing, counts
/// for nothing in the average and is said in words, so a day the box never
/// fetched never reads as a day that cost nothing.
public struct PriceDay: Equatable, Sendable {
    /// One priced slot, as a share of the day, so a row of any width draws
    /// it without knowing the clock.
    public struct Bar: Equatable, Sendable {
        /// Where the slot starts in the day, 0 to 1.
        public var at: Double
        /// How much of the day it covers.
        public var width: Double
        /// Minor units per kWh, the total.
        public var minor: Double
        /// Which third of this day's own range, for the ink.
        public var third: PriceChart.Third

        public init(at: Double, width: Double, minor: Double, third: PriceChart.Third) {
            self.at = at
            self.width = width
            self.minor = minor
            self.third = third
        }
    }

    public var bars: [Bar]
    /// The day's mean, weighted by how long each price held. Nil when the
    /// box has no price for any of the day.
    public var meanMinor: Double?
    public var lowMinor: Double?
    /// When the cheapest slot starts.
    public var lowAtMs: Double?
    public var highMinor: Double?
    /// How much of the day the box has a price for, 0 to 1.
    public var covered: Double
    public var currency: String
    /// "Average 94 öre · lowest 31 at 03:00", or why there is nothing.
    public var line: String
    /// "6 h with no price", once a tenth of the day is missing.
    public var note: String?

    /// The box said something about this day.
    public var known: Bool { meanMinor != nil }

    /// The day from `fromMs` to `toMs` out of every slot the phone holds.
    /// A 23- or 25-hour day is the window it is given.
    public static func make(_ slots: [PriceSlot], fromMs: Double, toMs: Double, currency: String, clock: ZoneClock) -> PriceDay {
        let length = toMs - fromMs
        guard length > 0 else { return empty(currency: currency) }
        // Each slot clipped to the day, so a slot that straddles midnight
        // weighs only the part inside it.
        let inside = slots
            .filter { $0.totalMinor.isFinite && $0.durationMs > 0 && $0.startMs < toMs && $0.startMs + $0.durationMs > fromMs }
            .sorted { $0.startMs < $1.startMs }
            .map { (startMs: max($0.startMs, fromMs), endMs: min($0.startMs + $0.durationMs, toMs), minor: $0.totalMinor) }
        guard !inside.isEmpty else { return empty(currency: currency) }

        let held = inside.reduce(0.0) { $0 + ($1.endMs - $1.startMs) }
        let mean = held > 0 ? inside.reduce(0.0) { $0 + $1.minor * ($1.endMs - $1.startMs) } / held : nil
        let low = inside.min { $0.minor < $1.minor }
        let high = inside.max { $0.minor < $1.minor }
        let lo = low?.minor ?? 0, hi = high?.minor ?? 0
        let third = (hi - lo) / 3
        let bars = inside.map { slot in
            Bar(
                at: (slot.startMs - fromMs) / length,
                width: (slot.endMs - slot.startMs) / length,
                minor: slot.minor,
                third: hi <= lo ? .middle : slot.minor < lo + third ? .cheap : slot.minor >= lo + 2 * third ? .dear : .middle
            )
        }

        let unit = PriceUnits.unit(currency)
        func figure(_ minor: Double) -> String { Words.decimal(PriceStrip.text(abs(minor), currency)) }
        let line = mean.map { mean in
            PriceWord.dayAverage.format(figure(mean) + " " + unit.label, figure(lo), clock.label(low?.startMs ?? fromMs))
        } ?? PriceWord.noPriceThatDay.text
        let covered = min(1, held / length)

        return PriceDay(
            bars: bars,
            meanMinor: mean,
            lowMinor: low?.minor,
            lowAtMs: low?.startMs,
            highMinor: high?.minor,
            covered: covered,
            currency: currency,
            line: line,
            note: note(missingMs: length - held)
        )
    }

    /// The row's words before the box has said anything, so it holds its
    /// shape redacted rather than reading as a day that cost nothing.
    public static func shape(currency: String) -> String {
        let unit = PriceUnits.unit(currency)
        return PriceWord.dayAverage.format("0 " + unit.label, "0", "00:00")
    }

    static func empty(currency: String) -> PriceDay {
        PriceDay(bars: [], meanMinor: nil, lowMinor: nil, lowAtMs: nil, highMinor: nil, covered: 0,
                 currency: currency, line: PriceWord.noPriceThatDay.text, note: nil)
    }

    /// Said once a tenth of the day has no price; below that a quarter hour
    /// either side of a market's own rounding is not news.
    static func note(missingMs: Double) -> String? {
        guard missingMs >= 8_640_000 else { return nil }
        let minutes = Int((missingMs / 60_000).rounded())
        return PriceWord.someMissing.format(minutes < 120 ? "\(minutes) min" : "\(minutes / 60) h")
    }
}
