import CoreGraphics
import Foundation

/// Today or the last two days for one or more series on one chart, built
/// once per change of data off the main actor. Every series has its own
/// line, band, body and holes; they share the slots and one stable scale
/// that holds every band, so adding a series re-fits the scale by the same
/// rules and taking one away never changes what the others say.
///
/// Today sits on a fixed day from midnight to midnight: the line grows to
/// the right through the day and the hours ahead stay empty, so neither
/// the scale nor the slots move as the day goes on.
public struct HistoryPicture: Equatable, Sendable {
    /// One series on the chart, by the key its caller gave it.
    public struct Layer: Equatable, Sendable {
        public var key: String
        public var series: ChartSeries
    }

    /// A time label: "06", or a weekday at midnight on two days.
    public struct Tick: Equatable, Sendable {
        public var ms: Double
        public var label: String
    }

    /// In the order given; the first is the chart's own series.
    public var layers: [Layer]
    public var grid: SlotGrid
    public var domain: YDomain
    public var size: CGSize
    public var nowMs: Double?
    /// The last slot with data in any series: a finger stops there, since
    /// the slots after it have not happened.
    public var limit: Int?
    /// When the newest data is more than a slot old: where it ends.
    public var asOfMs: Double?
    public var ticks: [Tick]

    public var stepMs: Double { grid.stepMs }

    /// `inputs` in drawing order, the chart's own series first. `everyHours`
    /// spaces the time labels; `weekday` names a midnight on two days.
    public static func build(
        _ inputs: [(key: String, samples: [ChartSample])],
        fromMs: Double,
        toMs: Double,
        nowMs: Double?,
        size: CGSize,
        previous: YDomain? = nil,
        floor: Double = 1,
        clock: ZoneClock,
        everyHours: Int = 6,
        weekday: (@Sendable (Double) -> String)? = nil,
        words: ReadoutWords
    ) -> HistoryPicture {
        // One scale for every series: the union of their bands.
        let stepMs = DisplayBucket.stepMs(spanMs: toMs - fromMs, width: size.width)
        var low = 0.0, high = 0.0
        for input in inputs {
            let e = DisplayBucket.extent(DisplayBucket.buckets(input.samples, stepMs: stepMs, fromMs: fromMs, toMs: toMs, clock: clock))
            low = min(low, e.low)
            high = max(high, e.high)
        }
        let domain = YDomain.stable(low: low, high: high, previous: previous, floor: floor)
        let layers = inputs.map { input in
            Layer(key: input.key, series: ChartSeries.history(input.samples, fromMs: fromMs, toMs: toMs, nowMs: nowMs, size: size, clock: clock, domain: domain, words: words))
        }
        let grid = layers.first?.series.grid ?? SlotGrid(firstMs: fromMs, stepMs: stepMs, count: 0, fromMs: fromMs, toMs: toMs)
        let limit = layers.compactMap(\.series.lastData).max()

        // The newest data, and whether it is more than a slot behind now.
        var asOf: Double?
        if let nowMs, let limit {
            // A slot still filling ends where its five-minute means end.
            let newest = layers.compactMap { layer -> Double? in
                guard let i = layer.series.lastData else { return nil }
                let b = layer.series.buckets[i]
                return min(b.endMs, b.startMs + Double(b.count) * 300_000)
            }.max() ?? grid.endMs(limit)
            if nowMs - newest > stepMs { asOf = newest }
        }

        // Whole local hours a few apart, a weekday at midnight when asked,
        // and none within an hour of the right edge.
        var ticks: [Tick] = []
        let hour = 3_600_000.0
        var t = clock.alignDown(fromMs, stepMs: hour)
        if t < fromMs { t += hour }
        while t <= toMs - hour {
            let minute = clock.minuteOfDay(t)
            if minute % 60 == 0, (minute / 60) % max(1, everyHours) == 0 {
                let label = minute == 0 && weekday != nil ? weekday!(t) : String(clock.label(t).prefix(2))
                ticks.append(Tick(ms: t, label: label))
            }
            t += hour
        }

        return HistoryPicture(layers: layers, grid: grid, domain: domain, size: size, nowMs: nowMs, limit: limit, asOfMs: asOf, ticks: ticks)
    }

    /// Local midnight before `ms` and the next one, through any turn of the
    /// clocks: Today's fixed window.
    public static func day(_ ms: Double, clock: ZoneClock) -> (fromMs: Double, toMs: Double) {
        let date = Date(timeIntervalSince1970: ms / 1000)
        let start = clock.calendar.startOfDay(for: date)
        let next = clock.calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return (start.timeIntervalSince1970 * 1000, next.timeIntervalSince1970 * 1000)
    }

    /// The last two days to now, on the five-minute step, so the window
    /// changes once per tile and not every second.
    public static func twoDays(_ nowMs: Double) -> (fromMs: Double, toMs: Double) {
        let to = ((nowMs / 300_000).rounded(.up)) * 300_000
        return (to - 48 * 3_600_000, to)
    }
}
