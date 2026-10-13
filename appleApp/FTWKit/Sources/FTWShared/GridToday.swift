import Foundation

/// Today over the grid, as the app leaves it for the grid widget: what the
/// home bought and sold since midnight and what that cost, as the box
/// counted and priced it, and the grid's power a quarter hour at a time.
///
/// Every number here is the box's. The app computes no cost: the totals are
/// `GET /api/savings/daily` as the box answered it, and the quarters are the
/// box's own five-minute history of `grid_w`, the series the grid's node
/// view draws.
public struct GridTodayEntry: CacheValue {
    public static let name = "grid-today"
    public static let version = 1
    /// The chart's step.
    public static let quarterMs: Double = 900_000

    /// One quarter hour of the grid. Both are magnitudes in watts, each the
    /// mean over the part of the quarter the box has a record for, so a
    /// quarter can hold some of each. Both nil: the box has no record.
    public struct Quarter: Codable, Sendable, Equatable {
        public var startMs: Double
        /// Mean power bought, never negative.
        public var importW: Double?
        /// Mean power sold, never negative.
        public var exportW: Double?

        public init(startMs: Double, importW: Double?, exportW: Double?) {
            self.startMs = startMs
            self.importW = importW
            self.exportW = exportW
        }

        public var measured: Bool { importW != nil || exportW != nil }
    }

    /// The box's own name for the day, "2026-10-13", on its clock.
    public var day: String
    /// Local midnight the day starts at, and the next one.
    public var dayStartMs: Double
    public var dayEndMs: Double
    public var importWh: Double
    public var exportWh: Double
    /// Import cost less export revenue, in minor units (öre, cents), as the
    /// box priced it quarter by quarter. Nil when the box had no prices.
    public var costMinor: Double?
    /// The share of the day so far the box had a price for, 0 to 1.
    public var pricedCoverage: Double
    public var currency: String
    /// The household's time zone, as the box names it.
    public var timeZone: String?
    /// From midnight to the moment of the read, in order. Quarters after it
    /// are not here: the rest of the day has not happened.
    public var quarters: [Quarter]

    public init(day: String, dayStartMs: Double, dayEndMs: Double, importWh: Double, exportWh: Double, costMinor: Double?, pricedCoverage: Double, currency: String, timeZone: String?, quarters: [Quarter]) {
        self.day = day
        self.dayStartMs = dayStartMs
        self.dayEndMs = dayEndMs
        self.importWh = importWh
        self.exportWh = exportWh
        self.costMinor = costMinor
        self.pricedCoverage = pricedCoverage
        self.currency = currency
        self.timeZone = timeZone
        self.quarters = quarters
    }

    /// Quarter hours from history steps of any length, weighted by how much
    /// of each step falls in each quarter. A step without a value is a hole
    /// and adds nothing, so a quarter the box has no record for stays empty;
    /// nothing is bridged. Watts are site-signed: positive is bought.
    public static func quarters(_ steps: [(startMs: Double, stepMs: Double, watts: Double?)], dayStartMs: Double, untilMs: Double) -> [Quarter] {
        let count = max(0, Int(((untilMs - dayStartMs) / quarterMs).rounded(.up)))
        guard count > 0 else { return [] }
        var bought = [Double](repeating: 0, count: count)
        var sold = [Double](repeating: 0, count: count)
        var covered = [Double](repeating: 0, count: count)
        for s in steps {
            guard let w = s.watts, w.isFinite, s.stepMs > 0 else { continue }
            let a = max(s.startMs, dayStartMs)
            let b = min(s.startMs + s.stepMs, untilMs)
            guard b > a else { continue }
            var q = Int(((a - dayStartMs) / quarterMs).rounded(.down))
            while q < count {
                let qa = dayStartMs + Double(q) * quarterMs
                let overlap = min(b, qa + quarterMs) - max(a, qa)
                if overlap <= 0 { break }
                bought[q] += max(0, w) * overlap
                sold[q] += max(0, -w) * overlap
                covered[q] += overlap
                q += 1
            }
        }
        return (0..<count).map { q in
            let start = dayStartMs + Double(q) * quarterMs
            guard covered[q] > 0 else { return Quarter(startMs: start, importW: nil, exportW: nil) }
            return Quarter(startMs: start, importW: (bought[q] / covered[q]).rounded(), exportW: (sold[q] / covered[q]).rounded())
        }
    }

    /// The box's "2026-10-13" as local midnight and the next one, on the
    /// household's calendar. Nil for a day that does not parse.
    public static func bounds(day: String, calendar: Calendar) -> (startMs: Double, endMs: Double)? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let start = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return (start.timeIntervalSince1970 * 1000, end.timeIntervalSince1970 * 1000)
    }

    /// "2026-10-13" for the day `ms` falls on, on the household's calendar.
    public static func dayName(_ ms: Double, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: ms / 1000))
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }
}
