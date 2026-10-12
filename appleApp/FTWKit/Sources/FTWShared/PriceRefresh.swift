import Foundation

/// When the app asks iOS to wake it for tomorrow's prices.
///
/// The day-ahead market publishes tomorrow around 12:45, and the box asks
/// it once an hour, so the box holds tomorrow some time between then and
/// about 13:45. The app asks to run just after 13:05, and again every half
/// hour until the box has tomorrow. iOS decides when, or whether, it runs:
/// this is the earliest, never a promise.
public enum PriceRefresh {
    public static let hour = 13
    public static let minute = 5
    /// How soon to ask again when the box did not have tomorrow yet.
    public static let retryMs: Double = 30 * 60_000
    /// No retries after this hour; the next try is tomorrow's.
    public static let lastRetryHour = 20

    /// The earliest the next refresh should run, given when the prices the
    /// widgets hold run out.
    public static func next(afterMs nowMs: Double, pricesEndMs: Double?, calendar: Calendar = .current) -> Double {
        let now = Date(timeIntervalSince1970: nowMs / 1000)
        let today = calendar.startOfDay(for: now)
        func at(_ day: Int, _ h: Int, _ m: Int) -> Double {
            let d = calendar.date(byAdding: .day, value: day, to: today) ?? today
            let t = calendar.date(bySettingHour: h, minute: m, second: 0, of: d) ?? d
            return t.timeIntervalSince1970 * 1000
        }
        let publish = at(0, hour, minute)
        if nowMs < publish { return publish }
        let endOfTomorrow = at(2, 0, 0)
        if let end = pricesEndMs, end >= endOfTomorrow { return at(1, hour, minute) }
        let retry = nowMs + retryMs
        return retry <= at(0, lastRetryHour, 0) ? retry : at(1, hour, minute)
    }
}
