import Foundation

/// Now's plan strip: the next twelve hours as 48 quarters from the one
/// running now. Per quarter, what the battery does, whether the car
/// charges and the price in eight levels; the runs the lanes and bars draw,
/// the hour labels, the quarters a finger bumps on and the line it reads.
/// Worked out once per minute or per plan, so a finger costs a subscript.
/// A view only maps it to its size.
public struct PlanStrip: Equatable, Sendable {
    public static let quarterMs: Double = 15 * 60_000
    public static let count = 48
    /// The block-glyph scale: ▁▂▃▄▅▆▇█.
    public static let levels = 8
    /// The price row's height: eight levels of 2.5 pt at its least, and
    /// the most it grows to when Now has room. Now's layout and the strip's
    /// drawing read the same two.
    public static let leastPrice: CGFloat = 20
    public static let mostPrice: CGFloat = 72

    public enum Battery: Equatable, Sendable {
        case stores, gives
    }

    /// Equal neighbours, drawn as one shape so a flat stretch has no seams.
    public struct Run<Value: Equatable & Sendable>: Equatable, Sendable {
        public let first: Int
        public let count: Int
        public let value: Value
        public var last: Int { first + count - 1 }
    }

    public struct Tick: Equatable, Sendable {
        public let ms: Double
        public let label: String
    }

    public let grid: SlotGrid
    public let nowMs: Double
    /// What the battery does per quarter; nil while it waits or without a
    /// plan.
    public let battery: [Battery?]
    public let car: [Bool]
    /// The quarter in which a car's charge ends, and the level it charges
    /// toward.
    public let goals: [Int: Double]
    /// The price per quarter, 0 for the cheapest in the window to 7 for the
    /// dearest; nil before the market has priced it.
    public let levels: [Int?]
    public let batteryRuns: [Run<Battery>]
    public let carRuns: [Run<Bool>]
    public let priceRuns: [Run<Int>]
    /// Stretches the market has not priced yet: drawn as hatched stubs,
    /// never as a level.
    public let pending: [Run<Bool>]
    /// Local three-hour marks: "18", "21", "00".
    public let hours: [Tick]
    /// Quarters that give a light impact under a finger: now, either end,
    /// the cheapest two hours' edges and each car goal.
    public let landmarks: Set<Int>
    /// What a finger reads per quarter: "02:15 · 31 öre · stores · 58 % ·
    /// car charges".
    public let readouts: [String]
    /// The quarter's start and price for the strip's header under a
    /// finger: "02:15" and "31", in whole öre as the readout.
    public let quarters: [Quarter]
    /// The `quarters` names: nil price before the market has priced it.
    public struct Quarter: Equatable, Sendable {
        public let time: String
        public let price: String?
    }
    /// "NEXT 12 H", "PLANNED 14:05" from the cache, "OLD PLAN · 14:05".
    public let kicker: String
    /// The plan is old, the box could not plan, or it has not answered:
    /// every mark in ink3.
    public let grey: Bool
    /// The home has a charger, so the car's lane keeps its idle line.
    public let hasCar: Bool

    /// The ink a price bar takes, from its level: the same height always
    /// has the same ink. Levels 0–2 are the cheap third, 5–7 the dear.
    public static func third(_ level: Int) -> PriceChart.Third {
        level <= 2 ? .cheap : level <= 4 ? .middle : .dear
    }

    /// The strip at the moment's minute, from the plan the moment was read
    /// from.
    public static func build(_ entry: PlanEntry?, moment: PlanGlance.Moment, hasCar: Bool) -> PlanStrip {
        let clock = ZoneClock.of(moment.timeZone)
        let nowMs = moment.atMs
        let first = clock.alignDown(nowMs, stepMs: quarterMs)
        let grid = SlotGrid(firstMs: first, stepMs: quarterMs, count: count, fromMs: first, toMs: first + Double(count) * quarterMs)

        let prices = (entry?.prices ?? []).filter { $0.totalMinor.isFinite && $0.durationMs > 0 }.sorted { $0.startMs < $1.startMs }
        let slots = (entry?.battery ?? []).sorted { $0.startMs < $1.startMs }
        let charges = entry?.charges ?? []
        let currency = entry?.currency ?? "SEK"

        // What holds in the part of a quarter still to come: the box starts
        // its plan the moment it makes it, so the first slot often begins
        // inside the quarter running now.
        func covering<T>(_ items: [T], from a: Double, to b: Double, start: KeyPath<T, Double>, length: KeyPath<T, Double>) -> T? {
            guard let i = SlotLookup.clamped(items, at: a, start: { $0[keyPath: start] }) else { return nil }
            let item = items[i]
            if item[keyPath: start] <= a, a < item[keyPath: start] + item[keyPath: length] { return item }
            let next = item[keyPath: start] > a ? i : i + 1
            return next < items.count && items[next][keyPath: start] < b ? items[next] : nil
        }

        var minor = [Double?](repeating: nil, count: count)
        var planned = [PlanEntry.Slot?](repeating: nil, count: count)
        var battery = [Battery?](repeating: nil, count: count)
        var car = [Bool](repeating: false, count: count)
        for i in 0..<count {
            let start = grid.startMs(i), end = grid.endMs(i), from = max(start, nowMs)
            minor[i] = covering(prices, from: from, to: end, start: \.startMs, length: \.durationMs)?.totalMinor
            planned[i] = covering(slots, from: from, to: end, start: \.startMs, length: \.durationMs)
            battery[i] = planned[i].flatMap { $0.batteryW > PlanGlance.idleW ? .stores : ($0.batteryW < -PlanGlance.idleW ? .gives : nil) }
            car[i] = charges.contains { $0.fromMs < end && $0.toMs > start }
        }

        var goals = [Int: Double]()
        for c in charges where c.toMs > first && c.toMs <= grid.toMs {
            if let pct = c.targetPct, let i = grid.index(atMs: c.toMs - 1) { goals[i] = pct }
        }

        let known = minor.compactMap { $0 }
        let lo = known.min() ?? 0, hi = known.max() ?? 0
        let levels = minor.map { $0.map { level($0, lo: lo, hi: hi) } }

        var landmarks: Set<Int> = [0, count - 1]
        let inside = prices.filter { $0.startMs + $0.durationMs > nowMs && $0.startMs < grid.toMs }
        if inside.count >= 2, let block = PriceStrip.bestBlock(inside, hours: 2, cheapest: true) {
            let mean = inside.map(\.totalMinor).reduce(0, +) / Double(inside.count)
            if block.meanMinor < mean * PlanGlance.cheapShare || block.meanMinor < 0,
               let a = grid.index(atMs: max(block.startMs, nowMs)), let b = grid.index(atMs: min(block.endMs, grid.toMs) - 1) {
                landmarks.formUnion([a, b])
            }
        }
        landmarks.formUnion(goals.keys)

        // Whole local hours every three, by the wall clock, so a day that
        // changes its clock still reads 00, 03, 06.
        var hours = [Tick]()
        var t = clock.alignDown(first, stepMs: 3_600_000) + 3_600_000
        while t < grid.toMs - quarterMs {
            if clock.minuteOfDay(t) % 180 == 0 { hours.append(Tick(ms: t, label: String(clock.label(t).prefix(2)))) }
            t += 3_600_000
        }

        let unit = PriceUnits.unit(currency).label
        let readouts = (0..<count).map { i -> String in
            var parts = [clock.label(grid.startMs(i))]
            if let m = minor[i] {
                let figure = Words.decimal(PriceStrip.whole(abs(m), currency)) + " " + unit
                parts.append(m < 0 ? figure + " " + PlanWord.belowZero.text : figure)
            } else {
                parts.append(PlanWord.noPrice.text)
            }
            if let slot = planned[i] {
                switch battery[i] {
                case .stores?: parts.append(PlanWord.stores.text)
                case .gives?: parts.append(PlanWord.gives.text)
                case nil: parts.append(PlanWord.waits.text)
                }
                // Where the plan leaves the battery by the quarter's end.
                if let level = slot.levelPct { parts.append(PlanGlance.percent(level)) }
            }
            if let goal = goals[i] {
                parts.append(PlanWord.carGoal.format(PlanGlance.percent(goal)))
            } else if car[i] {
                parts.append(PlanWord.carChargesWord.text)
            }
            return parts.joined(separator: " · ")
        }

        // A plan kept from an earlier launch says when the box made it.
        let kicker: String
        switch (moment.state, moment.readAtMs) {
        case let (.plan, at?): kicker = PlanWord.plannedAt.format(clock.label(at))
        case let (.old, at?): kicker = PlanWord.oldPlan.format(clock.label(at))
        default: kicker = PlanWord.next12h.text
        }

        return PlanStrip(
            grid: grid,
            nowMs: nowMs,
            battery: battery,
            car: car,
            goals: goals,
            levels: levels,
            batteryRuns: runs(battery),
            carRuns: runs(car.map { $0 ? true : nil }),
            priceRuns: runs(levels),
            pending: runs(levels.map { $0 == nil ? true : nil }),
            hours: hours,
            landmarks: landmarks,
            readouts: readouts,
            quarters: (0..<count).map { i in
                Quarter(time: clock.label(grid.startMs(i)), price: minor[i].map { Words.decimal(PriceStrip.whole($0, currency)) })
            },
            kicker: kicker,
            grey: moment.isGrey,
            hasCar: hasCar || !charges.isEmpty
        )
    }

    /// The quarters whose battery or car a new plan changed, on the same
    /// quarters. A strip that moved on by a quarter compares nothing: that
    /// is the clock, not a new plan.
    public func moved(from old: PlanStrip) -> [Int] {
        guard old.grid == grid else { return [] }
        return (0..<min(count, Self.count)).filter { old.battery[$0] != battery[$0] || old.car[$0] != car[$0] }
    }

    private var count: Int { battery.count }

    /// The price in eight levels within the window, the dearest at 7. A flat
    /// window sits in the middle rather than at either end.
    static func level(_ v: Double, lo: Double, hi: Double) -> Int {
        guard hi - lo >= 0.5 else { return levels / 2 - 1 }
        return min(levels - 1, max(0, Int(((v - lo) / (hi - lo) * Double(levels)).rounded(.down))))
    }

    /// Stretches of equal values; nil ends a stretch and starts none.
    static func runs<Value: Equatable & Sendable>(_ values: [Value?]) -> [Run<Value>] {
        var out = [Run<Value>]()
        var i = 0
        while i < values.count {
            guard let v = values[i] else {
                i += 1
                continue
            }
            var j = i + 1
            while j < values.count, values[j] == v { j += 1 }
            out.append(Run(first: i, count: j - i, value: v))
            i = j
        }
        return out
    }
}
