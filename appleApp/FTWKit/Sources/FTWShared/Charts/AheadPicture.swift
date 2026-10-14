import CoreGraphics
import Foundation

/// The hours ahead on one chart: what the box plans for each slot, or what
/// it forecasts, with the price under the same slots. A plan quarter is a
/// command that holds across its slot, so it is a ghost bar; a forecast is
/// an estimate, so it is a dashed line. Both start at the slot running now.
public struct AheadPicture: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case plan
        case forecast
    }

    public struct Tick: Equatable, Sendable {
        public var ms: Double
        public var label: String
    }

    public var kind: Kind
    public var grid: SlotGrid
    public var domain: YDomain
    public var size: CGSize
    /// Watts per slot, signed as the node shows them; nil where the box
    /// says nothing.
    public var values: [Double?]
    /// A forecast's dashed line through each slot's middle, one subpath per
    /// run; empty for a plan.
    public var line: ChartPath
    /// The price per slot by third of the window's range, and its height in
    /// eighths of the window's range: the block bars of the strip.
    public var priceThirds: [PriceChart.Third?]
    public var priceLevels: [Int?]
    public var nowMs: Double
    public var ticks: [Tick]

    /// `slots` and `prices` as they come; the window runs `spanMs` from the
    /// slot that holds `nowMs`.
    public static func build(
        kind: Kind,
        slots: [(startMs: Double, endMs: Double, watts: Double?)],
        prices: [(startMs: Double, endMs: Double, minor: Double)],
        nowMs: Double,
        spanMs: Double = 12 * 3_600_000,
        size: CGSize,
        previous: YDomain? = nil,
        floor: Double = 1,
        clock: ZoneClock,
        everyHours: Int = 3
    ) -> AheadPicture {
        let ahead = slots.filter { $0.endMs > nowMs }
        let stepMs = max(60_000, (ahead.map { $0.endMs - $0.startMs } + prices.filter { $0.startMs + ($0.endMs - $0.startMs) > nowMs }.map { $0.endMs - $0.startMs }).min() ?? 900_000)
        let fromMs = ahead.first { $0.startMs <= nowMs }?.startMs ?? clock.alignDown(nowMs, stepMs: stepMs)
        let count = max(1, Int((spanMs / stepMs).rounded(.up)))
        let grid = SlotGrid(firstMs: fromMs, stepMs: stepMs, count: count, fromMs: fromMs, toMs: fromMs + Double(count) * stepMs)

        func value<T>(_ items: [T], _ start: (T) -> Double, _ end: (T) -> Double, at ms: Double) -> T? {
            items.first { start($0) <= ms && ms < end($0) }
        }
        var values = [Double?](repeating: nil, count: count)
        var minor = [Double?](repeating: nil, count: count)
        for i in 0..<count {
            let ms = grid.startMs(i) + stepMs / 2
            values[i] = value(ahead, { $0.startMs }, { $0.endMs }, at: ms)?.watts
            minor[i] = value(prices, { $0.startMs }, { $0.endMs }, at: ms)?.minor
        }
        let known = values.compactMap { $0 }
        let domain = YDomain.stable(low: min(0, known.min() ?? 0), high: max(0, known.max() ?? 0), previous: previous, floor: floor)

        let line = kind == .forecast ? forecastLine(values, grid: grid, domain: domain, size: size) : ChartPath()

        let prices = minor.compactMap { $0 }
        let lo = prices.min() ?? 0, hi = prices.max() ?? 0
        let thirds: [PriceChart.Third?] = minor.map { m in
            guard let m else { return nil }
            guard hi > lo else { return .middle }
            return m < lo + (hi - lo) / 3 ? .cheap : m >= lo + 2 * (hi - lo) / 3 ? .dear : .middle
        }
        let levels: [Int?] = minor.map { m in
            guard let m else { return nil }
            guard hi > lo else { return 4 }
            return 1 + min(7, Int(((m - lo) / (hi - lo) * 8).rounded(.down)))
        }

        var ticks: [Tick] = []
        let hour = 3_600_000.0
        var t = clock.alignDown(fromMs, stepMs: hour) + hour
        while t <= grid.toMs - hour {
            let minute = clock.minuteOfDay(t)
            if minute % 60 == 0, (minute / 60) % max(1, everyHours) == 0, t - nowMs >= 1.5 * hour {
                ticks.append(Tick(ms: t, label: String(clock.label(t).prefix(2))))
            }
            t += hour
        }

        return AheadPicture(kind: kind, grid: grid, domain: domain, size: size, values: values, line: line, priceThirds: thirds, priceLevels: levels, nowMs: nowMs, ticks: ticks)
    }

    /// A forecast's line through each slot's middle, one monotone subpath
    /// per run of values.
    public static func forecastLine(_ values: [Double?], grid: SlotGrid, domain: YDomain, size: CGSize) -> ChartPath {
        let map = YMap(domain: domain, height: size.height)
        var line = ChartPath()
        var run: [CGPoint] = []
        for i in values.indices {
            guard let v = values[i] else {
                line.addMonotone(run)
                run = []
                continue
            }
            run.append(CGPoint(x: grid.midX(i, width: size.width), y: map.y(v)))
        }
        line.addMonotone(run)
        return line
    }

    /// A new plan or forecast for the same slots, on its way from `old`:
    /// each slot moves from its old value to its new one as `progress`
    /// runs from 0 to 1, drawn on this picture's scale. A slot new to the
    /// picture starts at zero; one gone is not drawn. Nil when the slots
    /// differ (a new window draws at once) or the move is over.
    public func blended(from old: AheadPicture, progress: Double) -> (values: [Double?], line: ChartPath)? {
        guard progress < 1, old.kind == kind, old.grid == grid, old.size == size, old.values != values else { return nil }
        let k = max(0, progress)
        let mixed: [Double?] = zip(old.values, values).map { a, b in
            guard let b else { return nil }
            return (a ?? 0) + (b - (a ?? 0)) * k
        }
        return (mixed, kind == .forecast ? Self.forecastLine(mixed, grid: grid, domain: domain, size: size) : ChartPath())
    }
}
