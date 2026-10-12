import Foundation
import FTWShared

/// The box's compact savings card, from GET /api/savings/daily.
public enum Savings {
    public struct Day: Equatable, Sendable {
        public let day: String
        public let savedOre: Double
        public let resolution: String
    }

    public struct Period: Equatable, Sendable {
        public let savedMinor: Double
        public let pricedDays: Int
        public let totalDays: Int
        public var available: Bool { pricedDays > 0 }
        public var complete: Bool { totalDays > 0 && pricedDays == totalDays }
    }

    public struct Periods: Equatable, Sendable {
        public let today: Period
        public let week: Period
        public let month: Period
    }

    public static func day(_ row: JSON) -> Day? {
        guard let d = row["day"]?.string, d.count == 10, d.dropFirst(4).first == "-" else { return nil }
        return Day(day: d, savedOre: row["saved_ore"]?.number ?? 0, resolution: row["resolution"]?.string ?? "slot")
    }

    static func summarize(_ rows: [Day]) -> Period {
        let priced = rows.filter { $0.resolution != "no_prices" }
        return Period(savedMinor: priced.reduce(0) { $0 + $1.savedOre }, pricedDays: priced.count, totalDays: rows.count)
    }

    public static func periods(_ days: [Day]) -> Periods {
        let rows = days.sorted { $0.day < $1.day }
        let month = rows.last.map { String($0.day.prefix(7)) } ?? ""
        return Periods(
            today: summarize(Array(rows.suffix(1))),
            week: summarize(Array(rows.suffix(7))),
            month: summarize(month.isEmpty ? [] : rows.filter { $0.day.hasPrefix(month + "-") })
        )
    }

    /// Signed major units: "+12.4", "−3.10". The currency sits in the heading.
    public static func compact(_ minor: Double) -> String {
        let major = minor / 100
        let a = abs(major)
        let digits = a >= 100 ? 0 : a >= 10 ? 1 : 2
        return (major >= 0 ? "+" : "−") + PowerFormat.fixed(a, digits)
    }
}
