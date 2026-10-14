import Foundation
import Synchronization

/// The clock of one time zone: one Calendar, made once and kept, and
/// "07:00" labels from minute-of-day arithmetic over a table. Nothing that
/// runs per touch or per slot builds a Calendar or calls
/// `String(format:)`.
public struct ZoneClock: Sendable {
    public let zone: TimeZone
    /// For what arithmetic cannot do, such as the start of a day or a
    /// weekday. Made once per zone.
    public let calendar: Calendar

    init(zone: TimeZone) {
        self.zone = zone
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        calendar = c
    }

    private static let clocks = Mutex<[String: ZoneClock]>([:])

    /// The clock of a zone, made the first time anyone asks for it.
    public static func of(_ zone: TimeZone) -> ZoneClock {
        clocks.withLock { made in
            if let c = made[zone.identifier] { return c }
            let c = ZoneClock(zone: zone)
            made[zone.identifier] = c
            return c
        }
    }

    /// How far the zone's clock is ahead of UTC at a moment.
    public func offsetMs(_ ms: Double) -> Double {
        Double(zone.secondsFromGMT(for: Date(timeIntervalSince1970: ms / 1000))) * 1000
    }

    /// The local minute of the day, 0 to 1439.
    public func minuteOfDay(_ ms: Double) -> Int {
        Self.wrap(Int(((ms + offsetMs(ms)) / 60_000).rounded(.down)), 1440)
    }

    /// "07:00".
    public func label(_ ms: Double) -> String { Self.label(minute: minuteOfDay(ms)) }

    /// "07:00:42", for the live curve's seconds.
    public func seconds(_ ms: Double) -> String {
        let local = ms + offsetMs(ms)
        let s = Self.wrap(Int((local / 1000).rounded(.down)), 60)
        return Self.label(minute: Self.wrap(Int((local / 60_000).rounded(.down)), 1440)) + ":" + Self.twoDigits[s]
    }

    /// The start of the local slot `stepMs` long that holds `ms`, so a
    /// half hour starts at :00 or :30 on the wall clock in every zone.
    public func alignDown(_ ms: Double, stepMs: Double) -> Double {
        let off = offsetMs(ms)
        return ((ms + off) / stepMs).rounded(.down) * stepMs - off
    }

    /// "07:00" for a minute of the day, wrapping past midnight.
    public static func label(minute: Int) -> String { labels[wrap(minute, 1440)] }

    private static func wrap(_ v: Int, _ n: Int) -> Int {
        let r = v % n
        return r < 0 ? r + n : r
    }

    private static let twoDigits: [String] = (0..<60).map { $0 < 10 ? "0\($0)" : "\($0)" }
    private static let labels: [String] = (0..<1440).map { twoDigits[$0 / 60] + ":" + twoDigits[$0 % 60] }
}
