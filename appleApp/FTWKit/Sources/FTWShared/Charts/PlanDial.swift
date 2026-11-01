import Foundation

/// The plan dial, as the phone, its widget and the watch all draw it: a
/// clock. One turn is the next twelve hours, with 12 at the top and 6 at
/// the bottom, so 18:00 sits straight down as on any clock (Erik and
/// Fredrik, 1 Nov 2026: the 24-hour face made people read the figures at
/// the edge and think). Each quarter hour is one tick. Its length is the
/// battery's planned power, its colour what the battery does then, and a
/// dotted arc inside marks the car's charging. The price has its own chart
/// under the dial. The sun's arc on the rim comes from the box's own
/// forecast, never from astronomy.
///
/// Each quarter still carries its price, in eight steps from zero
/// (`PriceScale`), for the watch's strip and a finger's readout.
///
/// Built on the chart engine (`SlotGrid`, `ZoneClock`) and worked out once
/// per plan and minute, so a finger or the Crown only reads a table.
public struct PlanDial: Equatable, Sendable {
    public static let quarterMs: Double = 15 * 60_000
    /// One turn: 12 hours of quarters, as on a clock.
    public static let count = 48
    /// A tick at full length stands for at least this much power, so a
    /// trickle never looks like the battery's most.
    static let leastFullW: Double = 1_000
    /// The block-glyph scale: ▁▂▃▄▅▆▇█.
    public static let levels = 8
    /// The box's forecast counts as sun from this many watts up.
    static let sunW: Double = 10

    public enum Battery: Equatable, Sendable {
        case stores, gives, waits
    }

    public struct Quarter: Equatable, Sendable {
        public let startMs: Double
        /// Minor units per kWh, the consumer total. Nil before the market
        /// has priced it: the dial draws a stub, never a level.
        public let minor: Double?
        /// 0 to 7, from zero to the round top over this face's prices.
        public let level: Int?
        public let battery: Battery
        /// The battery's planned power, site sign. Nil without a plan.
        public let batteryW: Double?
        public let car: Bool
        /// The goal, on the last quarter of the car's last window: the one
        /// that ends at it. Said once, not at every window on the way.
        public let carGoalPct: Double?
        /// Where the plan leaves the battery by the quarter's end, in
        /// percent. Nil when the box did not say.
        public let levelPct: Double?
    }

    /// A whole hour on the face: where it sits and its label, "18".
    public struct Hour: Equatable, Sendable {
        public let angle: Double
        public let label: String
    }

    public let grid: SlotGrid
    public let quarters: [Quarter]
    /// The power a full-length tick stands for: the most the battery moves
    /// in this turn, and at least `leastFullW`.
    public let fullW: Double
    /// Each whole hour in the turn, by the household's clock, except the
    /// ones too close to the hand or the seam to read.
    public let hours: [Hour]
    public let nowMs: Double
    public let currency: String
    public let zone: TimeZone
    /// The cheapest two hours ahead, as quarter indices, when they stand
    /// out from the rest.
    public let cheapest: ClosedRange<Int>?
    /// "CHEAPEST 00:00–02:00 · 28,5 ÖRE", when `cheapest` is set.
    public let cheapestText: String?
    /// Where a finger or the Crown gives a light tap: now, the cheapest
    /// window's edges and each car goal.
    public let landmarks: Set<Int>
    /// The box sent a battery plan.
    public let hasPlan: Bool
    /// Where the box's forecast expects the sun inside the turn, from
    /// sunrise to sunset. Empty without a forecast: no sky is drawn rather
    /// than one worked out from the calendar.
    public let sun: [ClosedRange<Double>]
    /// Per quarter, read by a finger: "14:30", "98 ÖRE/KWH", "STORES ·
    /// 3,0 KW · CAR". Made once, so a drag costs a subscript.
    public let times: [String]
    public let prices: [String]
    public let doing: [String]

    /// The face at `nowMs`. Prices come from the price record where it has
    /// them, else from the plan's own. `untilMs` runs the quarters on past
    /// one turn to that time, for the lanes, which show the whole plan; the
    /// face is always one turn.
    public init(plan: PlanEntry?, prices: PriceEntry?, nowMs: Double, untilMs: Double? = nil) {
        let zoneID = plan?.timeZone ?? prices?.timeZone
        let zone = zoneID.flatMap(TimeZone.init(identifier:)) ?? .current
        let clock = ZoneClock.of(zone)
        let first = clock.alignDown(nowMs, stepMs: Self.quarterMs)
        let count = untilMs.map { max(Self.count, Int((($0 - first) / Self.quarterMs).rounded(.up))) } ?? Self.count
        let grid = SlotGrid(firstMs: first, stepMs: Self.quarterMs, count: count, fromMs: first, toMs: first + Double(count) * Self.quarterMs)

        let slots = (prices?.prices.slots.isEmpty == false ? prices!.prices.slots : plan?.prices ?? [])
            .filter { $0.totalMinor.isFinite }
            .sorted { $0.startMs < $1.startMs }
        let battery = (plan?.battery ?? []).sorted { $0.startMs < $1.startMs }
        let charges = plan?.charges ?? []
        let currency = prices?.prices.currency ?? plan?.currency ?? "SEK"

        // What holds in the part of quarter `q` still to come: the box
        // starts its plan the moment it makes it, so the first slot often
        // begins inside the quarter running now.
        func holding<T>(_ items: [T], _ q: Int, start: KeyPath<T, Double>, length: KeyPath<T, Double>) -> T? {
            let a = max(grid.startMs(q), nowMs), b = grid.endMs(q)
            let i = Self.last(items, atOrBefore: a, start: start)
            if let i, a < items[i][keyPath: start] + items[i][keyPath: length] { return items[i] }
            let next = (i ?? -1) + 1
            return next < items.count && items[next][keyPath: start] < b ? items[next] : nil
        }
        func price(_ q: Int) -> Double? { holding(slots, q, start: \.startMs, length: \.durationMs)?.totalMinor }
        func planned(_ q: Int) -> PlanEntry.Slot? { holding(battery, q, start: \.startMs, length: \.durationMs) }

        let minors = (0..<count).map { price($0) }
        let scale = PriceScale(minors.compactMap { $0 }, currency: currency)

        var goals = [Int: Double]()
        for c in charges where c.toMs > first && c.fromMs < grid.toMs && plan?.chargesAgain(after: c) != true {
            if let pct = c.targetPct, let i = grid.index(atMs: c.toMs - 1) { goals[i] = pct }
        }

        let quarters = (0..<count).map { i in
            let start = grid.startMs(i), end = grid.endMs(i)
            let slot = planned(i)
            let w = slot?.batteryW
            let action: Battery = w.map { $0 > PlanGlance.idleW ? .stores : ($0 < -PlanGlance.idleW ? .gives : .waits) } ?? .waits
            return Quarter(
                startMs: start,
                minor: minors[i],
                level: minors[i].map { scale.step($0) - 1 },
                battery: action,
                batteryW: w,
                car: charges.contains { $0.fromMs < end && $0.toMs > start },
                carGoalPct: goals[i],
                levelPct: slot?.levelPct
            )
        }

        let unit = PriceUnits.unit(currency)
        func figure(_ minor: Double) -> String { Words.decimal(PriceStrip.text(abs(minor), currency)) }

        var cheapest: ClosedRange<Int>?
        var cheapestText: String?
        let ahead = slots.filter { $0.startMs + $0.durationMs > nowMs && $0.startMs < grid.toMs }
        if ahead.count >= 2, let block = PriceStrip.bestBlock(ahead, hours: 2, cheapest: true) {
            let mean = ahead.map(\.totalMinor).reduce(0, +) / Double(ahead.count)
            if block.meanMinor < mean * PlanGlance.cheapShare || block.meanMinor < 0,
               let a = grid.index(atMs: max(block.startMs, nowMs)), let b = grid.index(atMs: block.endMs - 1) {
                cheapest = a...b
                cheapestText = PriceWord.cheapest.format(clock.label(block.startMs) + "–" + clock.label(block.endMs), figure(block.meanMinor) + " " + unit.label.uppercased())
            }
        }

        var marks: Set<Int> = [0]
        if let cheapest { marks.formUnion([cheapest.lowerBound, cheapest.upperBound]) }
        marks.formUnion(goals.keys)

        let perKwh = unit.perKwh.uppercased()
        self.grid = grid
        self.quarters = quarters
        fullW = max(Self.leastFullW, quarters.prefix(Self.count).compactMap { $0.batteryW.map(abs) }.max() ?? 0)
        var hours = [Hour]()
        let hourMs = 3_600_000.0, turnEnd = first + Double(Self.count) * Self.quarterMs
        var t = clock.alignDown(nowMs, stepMs: hourMs) + hourMs
        while t < turnEnd {
            if t - nowMs >= 0.8 * hourMs, turnEnd - t >= 0.8 * hourMs, clock.minuteOfDay(t) % 60 == 0 {
                hours.append(Hour(angle: Self.clockAngle(t, clock: clock), label: String(clock.label(t).prefix(2))))
            }
            t += hourMs
        }
        self.hours = hours
        self.nowMs = nowMs
        self.currency = currency
        self.zone = zone
        self.cheapest = cheapest
        self.cheapestText = cheapestText
        landmarks = marks
        hasPlan = !battery.isEmpty
        sun = (plan?.daylight?.sun ?? []).compactMap { s in
            let from = max(s.fromMs, first), to = min(s.toMs, grid.toMs)
            return from < to ? from...to : nil
        }
        // A time from the next midnight on says the day first.
        let midnight = nowMs + Double(1440 - clock.minuteOfDay(nowMs)) * 60_000
        times = (0..<count).map { i in
            let label = clock.label(i == 0 ? nowMs : grid.startMs(i))
            return grid.startMs(i) < midnight ? label : PriceWord.tomorrow.text + " " + label
        }
        self.prices = minors.map { m in m.map { figure($0) + " " + perKwh } ?? DialWord.noPrice.text }
        doing = quarters.map { q in
            var parts = [String]()
            switch (q.battery, q.batteryW) {
            case (_, nil): parts.append(DialWord.noPlan.text)
            case (.stores, let w?): parts.append(DialWord.stores.format(Words.decimal(PowerFormat.text(w)).uppercased()))
            case (.gives, let w?): parts.append(DialWord.gives.format(Words.decimal(PowerFormat.text(w)).uppercased()))
            case (.waits, _): parts.append(DialWord.waits.text)
            }
            if let level = q.levelPct { parts.append(PlanGlance.percent(level)) }
            if let goal = q.carGoalPct {
                parts.append(DialWord.carTo.format(PlanGlance.percent(goal)))
            } else if q.car {
                parts.append(DialWord.car.text)
            }
            return parts.joined(separator: " · ")
        }
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

    /// The quarters whose battery or car a new plan changed, on the same
    /// turn. A dial that moved on by a quarter compares nothing.
    public func moved(from old: PlanDial) -> [Int] {
        guard old.grid == grid, old.quarters.count == quarters.count else { return [] }
        return quarters.indices.filter { old.quarters[$0].battery != quarters[$0].battery || old.quarters[$0].car != quarters[$0].car }
    }

    // MARK: Where things sit

    /// Radians clockwise from the top for a moment on the household clock,
    /// as on a clock's face: 12 and 00 at the top, 15 and 03 on the right,
    /// 18 and 06 at the bottom, 21 and 09 on the left.
    public func angle(_ ms: Double) -> Double { Self.clockAngle(ms, clock: ZoneClock.of(zone)) }

    static func clockAngle(_ ms: Double, clock: ZoneClock) -> Double {
        let half = 43_200_000.0
        var local = (ms + clock.offsetMs(ms)).truncatingRemainder(dividingBy: half)
        if local < 0 { local += half }
        return local / half * 2 * .pi
    }

    /// How long quarter `i`'s tick is, 0 to 1 of the ring: the battery's
    /// planned power against `fullW`. Nil while it waits or with no plan.
    public func reach(_ i: Int) -> Double? {
        let q = quarters[i]
        guard q.battery != .waits, let w = q.batteryW else { return nil }
        return min(1, abs(w) / fullW)
    }

    /// Where the middle of quarter `i` sits.
    public func angle(quarter i: Int) -> Double { angle(grid.startMs(i) + Self.quarterMs / 2) }

    /// Where the turn begins and ends: +12 h meets now.
    public var seam: Double { angle(grid.firstMs) }

    /// The sun's spans as distances round the turn from the seam, 0 to 2π.
    /// A span under way now starts at 0, never a whole turn on, and one
    /// that runs to the end of the turn ends at 2π. Like the ticks, the
    /// ends follow the household's clock.
    public var sunAlong: [ClosedRange<Double>] {
        sun.map { span in
            let a = along(span.lowerBound)
            var b = along(span.upperBound)
            if b <= a { b += 2 * .pi }
            return a...b
        }
    }

    /// How far round the turn from the seam `ms` sits, 0 up to 2π.
    private func along(_ ms: Double) -> Double {
        let a = (angle(ms) - seam).truncatingRemainder(dividingBy: 2 * .pi)
        return a < 0 ? a + 2 * .pi : a
    }

    /// Where the hand points: now, or the start of the quarter chosen.
    public func handAngle(selected: Int?) -> Double {
        guard let i = selected, i > 0 else { return angle(nowMs) }
        return angle(grid.startMs(i))
    }

    /// How faint quarter `i` is: full now, fading toward +12 h, so the
    /// seam where the turn meets now reads as its end.
    public func fade(_ i: Int) -> Double { 1 - 0.55 * Double(i) / Double(Self.count - 1) }

    /// The quarter under a finger `x` right of and `y` below the dial's
    /// centre. One turn holds each quarter once, so the angle alone finds
    /// it. A finger that crosses the seam winds no further: coming from the
    /// end it stays on the last quarter, from now on the first, so turning
    /// back answers at once.
    public func index(x: Double, y: Double, from previous: Int?) -> Int {
        var a = atan2(x, -y)
        if a < 0 { a += 2 * .pi }
        var along = a - seam
        if along < 0 { along += 2 * .pi }
        let i = min(Self.count - 1, max(0, Int(along / (2 * .pi) * Double(Self.count))))
        guard let previous, abs(i - previous) > Self.count / 2 else { return i }
        return previous < Self.count / 2 ? 0 : Self.count - 1
    }

    // MARK: What a finger or the Crown reads

    /// "14:30"
    public func time(_ i: Int) -> String { times[i] }

    /// "98", or "–" before the price is known: the widget's middle.
    public func figure(_ i: Int) -> String {
        quarters[i].minor.map { Words.decimal(PriceStrip.text($0, currency)) } ?? "–"
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
        if let level = q.levelPct { parts.append(PlanGlance.percent(level)) }
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

/// The dial's mono words, on the phone and the watch. The English is the
/// key; the Swedish lives in `Resources/sv.lproj/Dial.strings`, and a test
/// checks each one has it.
enum DialWord: String, CaseIterable {
    case stores = "STORES · %@"
    case gives = "GIVES · %@"
    case waits = "WAITS"
    case noPlan = "NO PLAN"
    case car = "CAR"
    case carTo = "CAR TO %@"
    case noPrice = "NO PRICE YET"
    case planned = "PLANNED %@ · REPLANS EVERY 15 MIN"
    case plannedOld = "PLAN FROM %@ · OLD"
    case saving = "ABOUT %@ LESS THAN NO BATTERY · TO %@"
    case title = "Plan dial"
    case summary = "The next 24 hours round a dial: the price, what the battery does and when the car charges."

    var text: String { Words.bundle.localizedString(forKey: rawValue, value: rawValue, table: "Dial") }

    func format(_ args: String...) -> String {
        var out = text
        for a in args {
            guard let r = out.range(of: "%@") else { break }
            out.replaceSubrange(r, with: a)
        }
        return out
    }
}

extension PlanDial {
    /// "Plan dial", for the widget gallery and VoiceOver.
    public static var title: String { DialWord.title.text }
    public static var summary: String { DialWord.summary.text }

    /// "PLANNED 16:51 · REPLANS EVERY 15 MIN", or once old, "PLAN FROM
    /// 14:05 · OLD".
    public static func planned(atMs: Double, old: Bool, zone: TimeZone) -> String {
        (old ? DialWord.plannedOld : DialWord.planned).format(ZoneClock.of(zone).label(atMs))
    }
}
