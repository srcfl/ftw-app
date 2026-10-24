import Foundation

/// An elapsed-time window, independent of the data that arrives in it. A
/// node opens on today, midnight to midnight on the household's clock,
/// which rolls to the next day at midnight. After a pan or a pinch the
/// window follows now while now is in it, so a view pinched in on the last
/// minutes is live, and holds still once now has left it, so yesterday
/// stays yesterday. A finger keeps its time through a pan or a zoom,
/// including across a daylight-saving turn.
public struct TimelineWindow: Equatable, Sendable {
    public static let historyMs: Double = 48 * 3_600_000
    public static let aheadMs: Double = 24 * 3_600_000
    public static let minimumSpanMs: Double = 5 * 60_000
    /// The whole reach, two days back and one ahead, at once.
    public static let maximumSpanMs = historyMs + aheadMs
    /// Where now sits in a window made around it.
    public static let nowPosition: Double = 0.85

    public private(set) var fromMs: Double
    public private(set) var toMs: Double
    /// Today's window, as a view opens: it rolls at midnight.
    public private(set) var isToday: Bool
    /// Where now sits while the window follows it; nil once now has left.
    public private(set) var nowFraction: Double?
    public var spanMs: Double { toMs - fromMs }
    /// Moves on its own: today at midnight, or with now.
    public var followsNow: Bool { isToday || nowFraction != nil }

    /// A window of `spanMs` around now, now at `nowAt` of it, following
    /// it: the car's view opens on the night ahead this way.
    public init(nowMs: Double, spanMs: Double = 3_600_000, nowAt: Double = TimelineWindow.nowPosition) {
        let span = min(max(spanMs, Self.minimumSpanMs), Self.maximumSpanMs)
        let at = min(max(nowAt, 0), 1)
        fromMs = nowMs - span * at
        toMs = fromMs + span
        isToday = false
        nowFraction = at
    }

    /// Today on `clock`: from its midnight to the next one, 23 or 25 hours
    /// on a day the clock turns.
    public static func today(nowMs: Double, clock: ZoneClock) -> Self {
        let calendar = clock.calendar
        let date = Date(timeIntervalSince1970: nowMs / 1000)
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        var w = Self(nowMs: nowMs)
        w.fromMs = start.timeIntervalSince1970 * 1000
        w.toMs = end.timeIntervalSince1970 * 1000
        w.isToday = true
        w.nowFraction = nil
        return w
    }

    /// A reading or a minute moves the window only as it follows: today
    /// rolls at midnight, a window with now in it keeps now where it was.
    public mutating func follow(nowMs: Double, clock: ZoneClock) {
        if isToday {
            let next = Self.today(nowMs: nowMs, clock: clock)
            if next.fromMs != fromMs { self = next }
        } else if let f = nowFraction {
            let span = spanMs
            fromMs = nowMs - f * span
            toMs = fromMs + span
        }
    }

    /// Back to today, as the view opened.
    public mutating func returnToToday(nowMs: Double, clock: ZoneClock) {
        self = Self.today(nowMs: nowMs, clock: clock)
    }

    public func time(at fraction: Double) -> Double {
        fromMs + min(max(fraction, 0), 1) * spanMs
    }

    /// Transform the window saved when the gesture started. `anchor` is
    /// the first finger/centroid's fraction, `destination` its new one.
    /// This is absolute from that saved window, never an accumulated delta.
    public func transformed(anchor: Double, destination: Double, magnification: Double, nowMs: Double) -> Self {
        guard anchor.isFinite, destination.isFinite, magnification.isFinite, magnification > 0 else { return self }
        let span = min(max(spanMs / magnification, Self.minimumSpanMs), Self.maximumSpanMs)
        let wanted = fromMs + anchor * spanMs - destination * span
        let lower = nowMs - Self.historyMs
        let upper = nowMs + Self.aheadMs - span
        let start = min(max(wanted, lower), upper)
        var next = self
        next.fromMs = start
        next.toMs = start + span
        // A gesture that leaves the window where it was keeps it today's.
        next.isToday = isToday && abs(start - fromMs) < 1 && abs(span - spanMs) < 1
        let f = (nowMs - start) / span
        next.nowFraction = next.isToday || f < 0 || f > 1 ? nil : f
        return next
    }
}

/// A stored interval mean and a source observation remain different kinds
/// of evidence even when they share one chart. A history mean is never
/// resampled into seconds or added to live energy a second time.
public enum TimelineReading: Equatable, Sendable {
    case mean(startMs: Double, endMs: Double, watts: Double)
    case observation(atMs: Double, watts: Double, seen: Bool)
    case fetching
    case missing
    case forecast(startMs: Double, endMs: Double, watts: Double)
    case plan(startMs: Double, endMs: Double, watts: Double)

    public var watts: Double? {
        switch self {
        case let .mean(_, _, watts), let .observation(_, watts, _), let .forecast(_, _, watts), let .plan(_, _, watts): watts
        case .fetching, .missing: nil
        }
    }

    /// A nearby observation wins over an overlapping interval mean. Across
    /// a source silence the stored mean can still be read as a mean, but
    /// never as a fresh observation. A confirmed history hole stays empty.
    public static func at(
        _ ms: Double,
        history: [ChartSample],
        sampleMs: Double = 300_000,
        observations: [LiveSample],
        gapMs: Double,
        nowMs: Double,
        ahead: (kind: AheadPicture.Kind, slots: [AheadPicture.Mark])? = nil
    ) -> Self {
        if ms > nowMs {
            guard let ahead, let mark = ahead.slots.first(where: { $0.startMs <= ms && ms < $0.endMs }) else { return .missing }
            return ahead.kind == .plan
                ? .plan(startMs: max(nowMs, mark.startMs), endMs: mark.endMs, watts: mark.watts)
                : .forecast(startMs: max(nowMs, mark.startMs), endMs: mark.endMs, watts: mark.watts)
        }
        let seen = observations.filter { $0.t <= nowMs && $0.v.isFinite }
        if let i = SlotGrid.nearest(seen.map(\.t), to: ms), abs(seen[i].t - ms) <= gapMs / 2 {
            let point = seen[i]
            return .observation(atMs: point.t, watts: point.v, seen: point.seen)
        }
        guard let sample = history.first(where: { $0.startMs <= ms && ms < $0.startMs + sampleMs }) else { return .missing }
        // An open bucket is energy so far divided by its whole length,
        // not the mean power over the seconds that have elapsed.
        guard sample.startMs + sampleMs <= nowMs else { return .fetching }
        guard let watts = sample.value, watts.isFinite else { return sample.fetching ? .fetching : .missing }
        return .mean(startMs: sample.startMs, endMs: sample.startMs + sampleMs, watts: watts)
    }
}

/// Recorded energy inside the visible past only. Source observations and
/// projections are deliberately not inputs, so neither can count twice.
public struct TimelineEnergy: Equatable, Sendable {
    public var inWh: Double = 0
    public var outWh: Double = 0
    public var knownMs: Double = 0
    public var fetchingMs: Double = 0
    public var missingMs: Double = 0
    /// A boundary cuts a stored interval: its share uses that interval's
    /// mean, so the UI marks the energy as an estimate.
    public var prorated = false

    public static func recorded(_ samples: [ChartSample], sampleMs: Double = 300_000, fromMs: Double, toMs: Double, nowMs: Double) -> Self {
        var result = Self()
        let pastEnd = min(toMs, nowMs)
        guard pastEnd > fromMs else { return result }
        let closedUntil = (nowMs / sampleMs).rounded(.down) * sampleMs
        let until = min(pastEnd, closedUntil)
        result.fetchingMs = max(0, pastEnd - max(fromMs, closedUntil))
        for sample in samples {
            guard sample.startMs + sampleMs <= nowMs else { continue }
            let duration = max(0, min(sample.startMs + sampleMs, until) - max(sample.startMs, fromMs))
            guard duration > 0 else { continue }
            if let watts = sample.value, watts.isFinite {
                if duration < sampleMs { result.prorated = true }
                result.knownMs += duration
                if watts >= 0 { result.inWh += watts * duration / 3_600_000 }
                else { result.outWh -= watts * duration / 3_600_000 }
            } else if sample.fetching { result.fetchingMs += duration }
        }
        result.missingMs = max(0, pastEnd - fromMs - result.knownMs - result.fetchingMs)
        return result
    }
}
