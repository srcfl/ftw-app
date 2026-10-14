import Foundation

/// The plan dial as the watch draws it: one turn is the next 24 hours, on a
/// 24-hour face with 00 at the bottom and 12 at the top, so the day's
/// light sits in the upper half and morning on the left. Each quarter hour
/// is one tick. Its length is the price in eight levels, its colour what
/// the battery does then, and a dotted arc inside marks the car's charging.
///
/// Built on the chart engine in `Charts/` (`SlotGrid`, `ZoneClock`), and
/// worked out once per plan, so the Crown only reads a table. The phone's
/// own dial (WP11) is not on `main` yet; when it lands in FTWShared, the
/// watch draws that face and this type goes.
public struct WatchDial: Equatable, Sendable {
    public static let quarterMs: Double = 15 * 60_000
    /// One turn: 24 hours of quarters.
    public static let count = 96
    /// The block-glyph scale: ▁▂▃▄▅▆▇█.
    public static let levels = 8

    public enum Battery: Equatable, Sendable {
        case stores, gives, waits
    }

    public struct Quarter: Equatable, Sendable {
        public let startMs: Double
        /// Minor units per kWh, the consumer total. Nil before the market
        /// has priced it: the dial draws a stub, never a level.
        public let minor: Double?
        /// 0 to 7 within this face's prices.
        public let level: Int?
        public let battery: Battery
        /// The battery's planned power, site sign. Nil without a plan.
        public let batteryW: Double?
        public let car: Bool
        /// The goal, on the car's last quarter of a window.
        public let carGoalPct: Double?
    }

    public let grid: SlotGrid
    public let quarters: [Quarter]
    public let nowMs: Double
    public let currency: String
    public let zone: TimeZone
    /// The cheapest two hours ahead, as quarter indices, when they stand
    /// out from the rest.
    public let cheapest: ClosedRange<Int>?
    /// Where the Crown gives a light tap: now, the cheapest window's
    /// edges and each car goal.
    public let landmarks: Set<Int>
    /// The box sent a battery plan.
    public let hasPlan: Bool

    /// The face at `nowMs`. Prices come from the price record where it has
    /// them, else from the plan's own.
    public init(plan: PlanEntry?, prices: PriceEntry?, nowMs: Double) {
        let zoneID = plan?.timeZone ?? prices?.timeZone
        let zone = zoneID.flatMap(TimeZone.init(identifier:)) ?? .current
        let clock = ZoneClock.of(zone)
        let first = clock.alignDown(nowMs, stepMs: Self.quarterMs)
        let grid = SlotGrid(firstMs: first, stepMs: Self.quarterMs, count: Self.count, fromMs: first, toMs: first + Double(Self.count) * Self.quarterMs)

        let slots = (prices?.prices.slots.isEmpty == false ? prices!.prices.slots : plan?.prices ?? [])
            .filter { $0.totalMinor.isFinite }
            .sorted { $0.startMs < $1.startMs }
        let battery = (plan?.battery ?? []).sorted { $0.startMs < $1.startMs }
        let charges = plan?.charges ?? []

        func price(_ t: Double) -> Double? {
            // The last slot that starts at or before t, if it still covers t.
            guard let i = Self.last(slots, atOrBefore: t, start: \.startMs) else { return nil }
            return t < slots[i].startMs + slots[i].durationMs ? slots[i].totalMinor : nil
        }
        func batteryW(_ t: Double) -> Double? {
            guard let i = Self.last(battery, atOrBefore: t, start: \.startMs) else { return nil }
            return t < battery[i].startMs + battery[i].durationMs ? battery[i].batteryW : nil
        }

        let minors = (0..<Self.count).map { price(grid.startMs($0)) }
        let known = minors.compactMap { $0 }
        let lo = known.min() ?? 0, hi = known.max() ?? 0

        var goals = [Int: Double]()
        for c in charges where c.toMs > first && c.fromMs < grid.toMs {
            if let pct = c.targetPct, let i = grid.index(atMs: c.toMs - 1) { goals[i] = pct }
        }

        quarters = (0..<Self.count).map { i in
            let start = grid.startMs(i), end = grid.endMs(i)
            let w = batteryW(start)
            let action: Battery = w.map { $0 > PlanGlance.idleW ? .stores : ($0 < -PlanGlance.idleW ? .gives : .waits) } ?? .waits
            return Quarter(
                startMs: start,
                minor: minors[i],
                level: minors[i].map { Self.level($0, lo: lo, hi: hi) },
                battery: action,
                batteryW: w,
                car: charges.contains { $0.fromMs < end && $0.toMs > start },
                carGoalPct: goals[i]
            )
        }

        var cheapest: ClosedRange<Int>?
        let ahead = slots.filter { $0.startMs + $0.durationMs > nowMs && $0.startMs < grid.toMs }
        if ahead.count >= 2, let block = PriceStrip.bestBlock(ahead, hours: 2, cheapest: true) {
            let mean = ahead.map(\.totalMinor).reduce(0, +) / Double(ahead.count)
            if block.meanMinor < mean * PlanGlance.cheapShare || block.meanMinor < 0,
               let a = grid.index(atMs: max(block.startMs, nowMs)), let b = grid.index(atMs: block.endMs - 1) {
                cheapest = a...b
            }
        }

        var marks: Set<Int> = [0]
        if let cheapest { marks.formUnion([cheapest.lowerBound, cheapest.upperBound]) }
        marks.formUnion(goals.keys)

        self.grid = grid
        self.nowMs = nowMs
        self.currency = prices?.prices.currency ?? plan?.currency ?? "SEK"
        self.zone = zone
        self.cheapest = cheapest
        landmarks = marks
        hasPlan = !battery.isEmpty
    }

    /// The price in eight levels, the dearest at 7. A flat day sits in the
    /// middle rather than at either end.
    static func level(_ v: Double, lo: Double, hi: Double) -> Int {
        guard hi - lo >= 0.5 else { return levels / 2 - 1 }
        return min(levels - 1, max(0, Int(((v - lo) / (hi - lo) * Double(levels)).rounded(.down))))
    }

    /// The index of the last element starting at or before `t`, by one
    /// binary search over sorted starts.
    static func last<T>(_ items: [T], atOrBefore t: Double, start: KeyPath<T, Double>) -> Int? {
        var lo = 0, hi = items.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if items[mid][keyPath: start] <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : lo - 1
    }

    // MARK: Where things sit

    /// Radians clockwise from the top for a moment on the household clock:
    /// 00 at the bottom, 06 on the left, 12 at the top, 18 on the right.
    public func angle(_ ms: Double) -> Double {
        let clock = ZoneClock.of(zone)
        let day = 86_400_000.0
        var local = (ms + clock.offsetMs(ms)).truncatingRemainder(dividingBy: day)
        if local < 0 { local += day }
        return (local / day * 2 * .pi + .pi).truncatingRemainder(dividingBy: 2 * .pi)
    }

    /// Where the middle of quarter `i` sits.
    public func angle(quarter i: Int) -> Double { angle(grid.startMs(i) + Self.quarterMs / 2) }

    /// Where the hand points: now, or the start of the quarter the Crown
    /// chose.
    public func handAngle(selected: Int?) -> Double {
        guard let i = selected, i > 0 else { return angle(nowMs) }
        return angle(grid.startMs(i))
    }

    /// How faint quarter `i` is: full now, fading toward +24 h, so the
    /// seam where tomorrow meets now reads as the end of the turn.
    public func fade(_ i: Int) -> Double { 1 - 0.55 * Double(i) / Double(Self.count - 1) }

    // MARK: What the Crown reads

    /// "14:30"
    public func time(_ i: Int) -> String {
        ZoneClock.of(zone).label(i == 0 ? nowMs : grid.startMs(i))
    }

    /// "98 öre", or "—" before the price is known.
    public func price(_ i: Int) -> String {
        guard let minor = quarters[i].minor else { return "—" }
        return "\(Words.decimal(PriceStrip.text(minor, currency))) \(PriceUnits.unit(currency).label)"
    }

    /// What the plan does in quarter `i`: "Battery stores 3.0 kW · car
    /// charges", "Battery waits · cheapest".
    public func what(_ i: Int) -> String {
        let q = quarters[i]
        var parts = [String]()
        switch (q.battery, q.batteryW) {
        case (_, nil): parts.append(WatchWord.noPlan.text)
        case (.stores, let w?): parts.append("\(WatchWord.batteryStores.text) \(Words.decimal(PowerFormat.text(w)))")
        case (.gives, let w?): parts.append("\(WatchWord.batteryGives.text) \(Words.decimal(PowerFormat.text(w)))")
        case (.waits, _): parts.append(WatchWord.batteryWaits.text)
        }
        if let goal = q.carGoalPct {
            parts.append(WatchWord.carGoal.format(PlanGlance.percent(goal)))
        } else if q.car {
            parts.append(WatchWord.carCharges.text)
        }
        if let cheapest, cheapest.contains(i) { parts.append(WatchWord.cheapestMark.text) }
        if q.minor == nil { parts.append(WatchWord.noPriceYet.text.lowercased()) }
        return parts.joined(separator: " · ")
    }
}
