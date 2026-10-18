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

    /// One slot as the box gave it.
    public struct Mark: Equatable, Sendable {
        public var startMs: Double
        public var endMs: Double
        public var watts: Double

        public init(startMs: Double, endMs: Double, watts: Double) {
            self.startMs = startMs
            self.endMs = endMs
            self.watts = watts
        }
    }

    public var kind: Kind
    public var grid: SlotGrid
    public var domain: YDomain
    public var size: CGSize
    /// Watts per slot, signed as the node shows them; nil where the box
    /// says nothing.
    public var values: [Double?]
    /// A forecast's own slots, which may be longer than the grid's: its
    /// line runs through their middles.
    public var marks: [Mark]
    /// A forecast's dashed line through its own slots' middles, one
    /// subpath per run; empty for a plan.
    public var line: ChartPath
    /// The price per slot by third of the window's range, and its height in
    /// eighths of the window's range: the block bars of the strip.
    public var priceThirds: [PriceChart.Third?]
    public var priceLevels: [Int?]
    public var nowMs: Double
    public var ticks: [Tick]

    /// `slots` and `prices` as they come; the window runs `spanMs` from the
    /// slot that holds `nowMs`. `top`, when known, fixes the scale's top
    /// (the car's charger at its most), so the scale never flips with
    /// what the plan holds.
    public static func build(
        kind: Kind,
        slots: [(startMs: Double, endMs: Double, watts: Double?)],
        prices: [(startMs: Double, endMs: Double, minor: Double)],
        nowMs: Double,
        spanMs: Double = 12 * 3_600_000,
        size: CGSize,
        previous: YDomain? = nil,
        floor: Double = 1,
        top: Double? = nil,
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
        let domain = Self.domain(low: min(0, known.min() ?? 0), high: max(0, known.max() ?? 0), previous: previous, floor: floor, top: top)

        let marks = kind == .forecast ? ahead.compactMap { s in s.watts.map { Mark(startMs: s.startMs, endMs: s.endMs, watts: $0) } } : []
        let line = forecastLine(marks, fromMs: grid.fromMs, toMs: grid.toMs, domain: domain, size: size)

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

        return AheadPicture(kind: kind, grid: grid, domain: domain, size: size, values: values, marks: marks, line: line, priceThirds: thirds, priceLevels: levels, nowMs: nowMs, ticks: ticks)
    }

    /// The scale for values from `low` to `high`: as `YDomain.stable`, or
    /// with its top fixed at `top` unless a value goes past it.
    public static func domain(low: Double, high: Double, previous: YDomain?, floor: Double, top: Double?) -> YDomain {
        let stable = YDomain.stable(low: low, high: high, previous: previous, floor: floor)
        guard let top, top.isFinite, top > 0 else { return stable }
        return YDomain(lower: stable.lower, upper: high > top ? YDomain.nice(high * 1.1) : top)
    }

    /// A forecast's line, Steffen through the middle of each of its own
    /// slots across a window from `fromMs` to `toMs`, so an hourly forecast
    /// on a grid of quarters bends instead of stepping. A slot that holds
    /// the window's start also gives it a point there, so the line starts
    /// at the left edge. One subpath per run: where the slots stop touching,
    /// the line breaks.
    public static func forecastLine(_ marks: [Mark], fromMs: Double, toMs: Double, domain: YDomain, size: CGSize, intervalMeans: Bool = false, notBeforeMs: Double? = nil) -> ChartPath {
        guard toMs > fromMs else { return ChartPath() }
        let map = YMap(domain: domain, height: size.height)
        func x(_ ms: Double) -> CGFloat { CGFloat((ms - fromMs) / (toMs - fromMs)) * size.width }
        var line = ChartPath()
        if intervalMeans {
            // A zoomed window can fit inside a single forecast interval.
            // Draw that interval's own value, clipped at now, rather than
            // losing it because its midpoint lies outside the viewport.
            for m in marks.sorted(by: { $0.startMs < $1.startMs }) {
                let a = max(m.startMs, fromMs, notBeforeMs ?? fromMs)
                let b = min(m.endMs, toMs)
                guard b > a, m.watts.isFinite else { continue }
                line.elements += [.move(CGPoint(x: x(a), y: map.y(m.watts))), .line(CGPoint(x: x(b), y: map.y(m.watts)))]
            }
            return line
        }
        var run: [CGPoint] = []
        var end = -Double.infinity
        for m in marks.sorted(by: { $0.startMs < $1.startMs }) where m.endMs > fromMs && m.startMs < toMs {
            if m.startMs > end + 1 {
                line.addMonotone(run)
                run = []
            }
            let mid = (m.startMs + m.endMs) / 2
            if run.isEmpty, m.startMs <= fromMs, mid > fromMs { run.append(CGPoint(x: 0, y: map.y(m.watts))) }
            run.append(CGPoint(x: x(mid), y: map.y(m.watts)))
            end = m.endMs
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
        guard progress < 1, old.kind == kind, old.grid == grid, old.size == size, old.values != values || old.marks != marks else { return nil }
        let k = max(0, progress)
        let mixed: [Double?] = zip(old.values, values).map { a, b in
            guard let b else { return nil }
            return (a ?? 0) + (b - (a ?? 0)) * k
        }
        guard kind == .forecast else { return (mixed, ChartPath()) }
        var before = [Double: Double](minimumCapacity: old.marks.count)
        for m in old.marks { before[m.startMs] = m.watts }
        let moving = marks.map { m in
            Mark(startMs: m.startMs, endMs: m.endMs, watts: (before[m.startMs] ?? 0) + (m.watts - (before[m.startMs] ?? 0)) * k)
        }
        return (mixed, Self.forecastLine(moving, fromMs: grid.fromMs, toMs: grid.toMs, domain: domain, size: size))
    }
}
