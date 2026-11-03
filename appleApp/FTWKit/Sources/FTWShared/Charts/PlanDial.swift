import Foundation

/// The plan dial, as the phone, its widget and the watch all draw it: a
/// clock. A face is half a day, midnight to noon or noon to midnight, with
/// 12 at the top and 6 at the bottom, so 18:00 sits straight down as on any
/// clock (Erik and Fredrik, 1 Nov 2026: the 24-hour face made people read
/// the figures at the edge and think). The first face is the half holding
/// now, with the hours already gone left on it; the next ones follow the
/// plan into tomorrow (xorath, 3 Nov 2026: a turn of the next twelve hours
/// put tonight's 01 and 02 where this noon's hours had been). Each quarter
/// hour is one tick. Its length is the battery's planned power, its colour
/// what the battery does then, and a dotted arc inside marks the car's
/// charging. The price has its own chart under the dial. The sun's arc on
/// the rim comes from the box's own forecast, never from astronomy.
///
/// Built without a `page`, it is the next twelve hours from now instead,
/// for the watch's strip. Each quarter still carries its price, in eight
/// steps from zero (`PriceScale`), for that strip and a finger's readout.
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
    /// An hour this close to now or to the turn's end is left off the
    /// twelve hours from now: closer, its figure would sit on the hand or
    /// the seam. A quarter of an hour is 7.5° of the turn, which clears two
    /// mono digits on the phone and the watch.
    static let hourClearMs: Double = 15 * 60_000

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
        /// The sun the box's forecast expects in the quarter, in watts. Nil
        /// where it expects none, or the quarter is gone.
        public var sunW: Double? = nil
    }

    /// A whole hour on the face: where it sits and its label, "18".
    public struct Hour: Equatable, Sendable {
        public let angle: Double
        public let label: String
        /// Gone by: on the face holding now, an hour before the hand.
        public var past = false
    }

    public let grid: SlotGrid
    public let quarters: [Quarter]
    /// Which half day this face is, 0 for the one holding now. Nil for the
    /// twelve hours from now.
    public let page: Int?
    /// The quarter holding now, before which this face has only hours; nil
    /// on a face after now's.
    public let nowIndex: Int?
    /// The face's span, "12–24", for a face after now's.
    public let span: String
    /// The power a full-length tick stands for: the most the battery moves
    /// in this turn, and at least `leastFullW`.
    public let fullW: Double
    /// The sun at the area's full depth: the most the forecast expects in
    /// all it covers, so a dull morning stands lower than a bright one on
    /// the next face, and at least `leastFullW`.
    public let sunFullW: Double
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
    /// The first quarter on the next day by the household's clock, where
    /// the middle names the day over the time; `count` when there is none.
    public let tomorrowFrom: Int
    public let prices: [String]
    public let doing: [String]

    /// The face `page` half days on from the one holding `nowMs`, or
    /// without a page the twelve hours from now. Prices come from the price
    /// record where it has them, else from the plan's own. `untilMs` runs
    /// the twelve hours on to that time, for the lanes.
    public init(plan: PlanEntry?, prices: PriceEntry?, nowMs: Double, page: Int? = nil, untilMs: Double? = nil) {
        let zoneID = plan?.timeZone ?? prices?.timeZone
        let zone = zoneID.flatMap(TimeZone.init(identifier:)) ?? .current
        let clock = ZoneClock.of(zone)
        let first: Double, count: Int
        if let page {
            let halves = Self.halves(nowMs: nowMs, clock: clock)
            let k = min(max(page, 0), halves.count - 2)
            first = halves[k]
            count = Int(((halves[k + 1] - first) / Self.quarterMs).rounded())
        } else {
            first = clock.alignDown(nowMs, stepMs: Self.quarterMs)
            count = untilMs.map { max(Self.count, Int((($0 - first) / Self.quarterMs).rounded(.up))) } ?? Self.count
        }
        let grid = SlotGrid(firstMs: first, stepMs: Self.quarterMs, count: count, fromMs: first, toMs: first + Double(count) * Self.quarterMs)
        let nowIndex = nowMs >= first && nowMs < grid.toMs ? grid.index(atMs: nowMs) : nil
        let from = nowIndex ?? 0

        let slots = (prices?.prices.slots.isEmpty == false ? prices!.prices.slots : plan?.prices ?? [])
            .filter { $0.totalMinor.isFinite }
            .sorted { $0.startMs < $1.startMs }
        let battery = (plan?.battery ?? []).sorted { $0.startMs < $1.startMs }
        let charges = plan?.charges ?? []
        let currency = prices?.prices.currency ?? plan?.currency ?? "SEK"

        // What holds in the part of quarter `q` still to come: the box
        // starts its plan the moment it makes it, so the first slot often
        // begins inside the quarter running now. A quarter gone by holds
        // nothing.
        func holding<T>(_ items: [T], _ q: Int, start: KeyPath<T, Double>, length: KeyPath<T, Double>) -> T? {
            guard q >= from else { return nil }
            let a = max(grid.startMs(q), nowMs), b = grid.endMs(q)
            let i = Self.last(items, atOrBefore: a, start: start)
            if let i, a < items[i][keyPath: start] + items[i][keyPath: length] { return items[i] }
            let next = (i ?? -1) + 1
            return next < items.count && items[next][keyPath: start] < b ? items[next] : nil
        }
        func price(_ q: Int) -> Double? { holding(slots, q, start: \.startMs, length: \.durationMs)?.totalMinor }
        let power = (plan?.daylight?.power ?? []).sorted { $0.fromMs < $1.fromMs }
        // The forecast's watts at the middle of the part of quarter `q` to
        // come.
        func sunW(_ q: Int) -> Double? {
            guard q >= from else { return nil }
            let mid = (max(grid.startMs(q), nowMs) + grid.endMs(q)) / 2
            guard let k = Self.last(power, atOrBefore: mid, start: \.fromMs), mid < power[k].toMs else { return nil }
            return power[k].w
        }
        func planned(_ q: Int) -> PlanEntry.Slot? { holding(battery, q, start: \.startMs, length: \.durationMs) }

        let minors = (0..<count).map { price($0) }
        let scale = PriceScale(minors.compactMap { $0 }, currency: currency)

        var goals = [Int: Double]()
        for c in charges where c.toMs > max(first, nowMs) && c.fromMs < grid.toMs && plan?.chargesAgain(after: c) != true {
            if let pct = c.targetPct, let i = grid.index(atMs: c.toMs - 1) { goals[i] = pct }
        }

        let quarters = (0..<count).map { i in
            let start = grid.startMs(i), end = grid.endMs(i)
            let slot = planned(i)
            let w = slot?.batteryW
            let action: Battery = w.map { $0 > PlanGlance.idleW ? .stores : ($0 < -PlanGlance.idleW ? .gives : .waits) } ?? .waits
            var q = Quarter(
                startMs: start,
                minor: minors[i],
                level: minors[i].map { scale.step($0) - 1 },
                battery: action,
                batteryW: w,
                car: i >= from && charges.contains { $0.fromMs < end && $0.toMs > max(start, nowMs) },
                carGoalPct: goals[i],
                levelPct: slot?.levelPct
            )
            q.sunW = sunW(i)
            return q
        }

        let unit = PriceUnits.unit(currency)
        func figure(_ minor: Double) -> String { Words.decimal(PriceStrip.text(abs(minor), currency)) }

        var cheapest: ClosedRange<Int>?
        var cheapestText: String?
        let open = max(nowMs, first)
        let ahead = slots.filter { $0.startMs + $0.durationMs > open && $0.startMs < grid.toMs }
        if ahead.count >= 2, let block = PriceStrip.bestBlock(ahead, hours: 2, cheapest: true) {
            let mean = ahead.map(\.totalMinor).reduce(0, +) / Double(ahead.count)
            if block.meanMinor < mean * PlanGlance.cheapShare || block.meanMinor < 0,
               let a = grid.index(atMs: max(block.startMs, open)), let b = grid.index(atMs: block.endMs - 1) {
                cheapest = a...b
                cheapestText = PriceWord.cheapest.format(clock.label(block.startMs) + "–" + clock.label(block.endMs), figure(block.meanMinor) + " " + unit.label.uppercased())
            }
        }

        var marks: Set<Int> = nowIndex.map { [$0] } ?? []
        if let cheapest { marks.formUnion([cheapest.lowerBound, cheapest.upperBound]) }
        marks.formUnion(goals.keys)

        let perKwh = unit.perKwh.uppercased()
        self.grid = grid
        self.quarters = quarters
        self.page = page
        self.nowIndex = nowIndex
        let turn = page == nil ? Self.count : count
        fullW = max(Self.leastFullW, quarters.prefix(turn).compactMap { $0.batteryW.map(abs) }.max() ?? 0)
        sunFullW = max(Self.leastFullW, power.map(\.w).max() ?? 0)
        var hours = [Hour]()
        let hourMs = 3_600_000.0, turnEnd = first + Double(turn) * Self.quarterMs
        if page != nil {
            // Every hour of the half, as a clock has them, the gone ones too.
            var t = first
            while t < turnEnd {
                if clock.minuteOfDay(t) % 60 == 0 {
                    hours.append(Hour(angle: Self.clockAngle(t, clock: clock), label: String(clock.label(t).prefix(2)), past: t + hourMs <= nowMs))
                }
                t += Self.quarterMs
            }
        } else {
            var t = clock.alignDown(nowMs, stepMs: hourMs) + hourMs
            while t < turnEnd {
                if t - nowMs >= Self.hourClearMs, turnEnd - t >= Self.hourClearMs, clock.minuteOfDay(t) % 60 == 0 {
                    hours.append(Hour(angle: Self.clockAngle(t, clock: clock), label: String(clock.label(t).prefix(2))))
                }
                t += hourMs
            }
        }
        self.hours = hours
        let startHour = clock.minuteOfDay(first) / 60
        span = String(clock.label(first).prefix(2)) + "–" + (startHour < 12 ? "12" : "24")
        self.nowMs = nowMs
        self.currency = currency
        self.zone = zone
        self.cheapest = cheapest
        self.cheapestText = cheapestText
        landmarks = marks
        hasPlan = !battery.isEmpty
        // The forecast from now on: a guess at the sun gone by says nothing.
        sun = (plan?.daylight?.sun ?? []).compactMap { s in
            let from = max(s.fromMs, first, nowMs), to = min(s.toMs, grid.toMs)
            return from < to ? from...to : nil
        }
        // A time from the next midnight on is tomorrow's, named apart from
        // the time so neither is cut to fit.
        let midnight = nowMs + Double(1440 - clock.minuteOfDay(nowMs)) * 60_000
        times = (0..<count).map { i in clock.label(i == nowIndex ? nowMs : grid.startMs(i)) }
        tomorrowFrom = (0..<count).first { grid.startMs($0) >= midnight } ?? count
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

    /// Where each half day starts, from the one holding `nowMs` to the end
    /// of the day after tomorrow: local midnight and noon, so a day the
    /// clocks go back or on keeps its hours.
    static func halves(nowMs: Double, clock: ZoneClock) -> [Double] {
        let cal = clock.calendar
        let day = cal.startOfDay(for: Date(timeIntervalSince1970: nowMs / 1000))
        var all = [Double]()
        for d in 0...3 {
            guard let start = cal.date(byAdding: .day, value: d, to: day) else { continue }
            all.append(start.timeIntervalSince1970 * 1000)
            if d < 3, let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: start) { all.append(noon.timeIntervalSince1970 * 1000) }
        }
        let k = all.lastIndex { $0 <= nowMs } ?? 0
        return Array(all[k...])
    }

    /// The faces the plan reaches, from the one holding now, at most to the
    /// end of tomorrow: where each starts, and where the last ends. A plan
    /// with nothing ahead still has now's face.
    public static func pages(plan: PlanEntry?, prices: PriceEntry?, nowMs: Double) -> [Double] {
        let zone = (plan?.timeZone ?? prices?.timeZone).flatMap(TimeZone.init(identifier:)) ?? .current
        let clock = ZoneClock.of(zone)
        let halves = halves(nowMs: nowMs, clock: clock)
        let ends = (plan?.battery ?? []).map { $0.startMs + $0.durationMs }
            + (plan?.charges ?? []).map(\.toMs)
            + (prices?.prices.slots ?? plan?.prices ?? []).map { $0.startMs + $0.durationMs }
        let last = ends.max() ?? nowMs
        // Past tomorrow a face would have to name the day after.
        let day = clock.calendar.startOfDay(for: Date(timeIntervalSince1970: nowMs / 1000))
        let tomorrowEnds = clock.calendar.date(byAdding: .day, value: 2, to: day).flatMap { d in halves.firstIndex(of: d.timeIntervalSince1970 * 1000) } ?? halves.count - 1
        var n = 1
        while n < tomorrowEnds, halves[n] < last { n += 1 }
        return Array(halves[0...n])
    }

    /// Where the Crown lands `q` quarters on from now, over the faces
    /// `pages` gave: which face, and the start of its quarter (now itself
    /// at 0).
    public static func step(_ q: Int, faces: [Double], nowMs: Double) -> (page: Int, atMs: Double) {
        let at = q <= 0 ? nowMs : ((nowMs / quarterMs).rounded(.down) + Double(q)) * quarterMs
        return (min(max(0, faces.lastIndex { $0 <= at } ?? 0), max(0, faces.count - 2)), at)
    }

    /// How many quarters the Crown steps through: from now's to the end of
    /// the last face.
    public static func steps(faces: [Double], nowMs: Double) -> Int {
        max(1, Int((((faces.last ?? nowMs) - (nowMs / quarterMs).rounded(.down) * quarterMs) / quarterMs).rounded()))
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

    /// How deep the sun's area is in quarter `i`, 0 to 1: the forecast's
    /// watts against `sunFullW`. Nil where it expects no sun.
    public func sunReach(_ i: Int) -> Double? {
        quarters[i].sunW.map { min(1, $0 / sunFullW) }
    }

    /// Where the middle of quarter `i` sits.
    public func angle(quarter i: Int) -> Double { angle(grid.startMs(i) + Self.quarterMs / 2) }

    /// Where the turn begins and ends: at the top on a half day's face, at
    /// now on the twelve hours from now.
    public var seam: Double { angle(grid.firstMs) }

    /// The quarters on the face: the half day's, or twelve hours'.
    public var turn: Int { page == nil ? Self.count : quarters.count }

    /// The first quarter a finger or the Crown reads: now's, or a later
    /// face's first.
    public var first: Int { nowIndex ?? 0 }

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
    public func along(_ ms: Double) -> Double {
        let a = (angle(ms) - seam).truncatingRemainder(dividingBy: 2 * .pi)
        return a < 0 ? a + 2 * .pi : a
    }

    /// Where the hand points: now, or the start of the quarter chosen. On a
    /// face after now's with nothing chosen there is no hand
    /// (`hasHand`), and this is the top.
    public func handAngle(selected: Int?) -> Double {
        let i = selected ?? first
        return i == nowIndex ? angle(nowMs) : angle(grid.startMs(i))
    }

    /// Whether a hand shows: at now on now's face, else only where a finger
    /// or the Crown has chosen a quarter.
    public func hasHand(selected: Int?) -> Bool { selected != nil || nowIndex != nil }

    /// The quarter under a finger `x` right of and `y` below the dial's
    /// centre. One turn holds each quarter once, so the angle alone finds
    /// it. On now's face the hours gone by read nothing: a finger there
    /// stays on now, or on the last quarter if the seam is nearer. A finger
    /// that crosses the seam winds no further: coming from the end it stays
    /// on the last quarter, from the first on the first, so turning back
    /// answers at once.
    public func index(x: Double, y: Double, from previous: Int?) -> Int {
        var a = atan2(x, -y)
        if a < 0 { a += 2 * .pi }
        var along = a - seam
        if along < 0 { along += 2 * .pi }
        let raw = Int(along / (2 * .pi) * Double(Self.count))
        let last = turn - 1
        let i = raw >= first ? min(last, raw) : (raw + 1 < first - raw ? last : first)
        guard let previous, abs(i - previous) > (last - first + 1) / 2 else { return i }
        return previous < (first + last + 1) / 2 ? first : last
    }

    // MARK: What a finger or the Crown reads

    /// "14:30"
    public func time(_ i: Int) -> String { times[i] }

    /// "TOMORROW" over a time on the next day, else nil.
    public func day(_ i: Int) -> String? { i >= tomorrowFrom ? PriceWord.tomorrow.text : nil }

    /// "TOMORROW 00–12", or "12–24": which half day the face is, for
    /// VoiceOver.
    public var faceName: String { day(0).map { $0 + " " + span } ?? span }

    /// "TOMORROW 04:30", or "14:30": the day and the time in one, for
    /// VoiceOver.
    public func when(_ i: Int) -> String { day(i).map { $0 + " " + times[i] } ?? times[i] }

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
    case summary = "Half a day as a clock: what the battery does and when the car charges."

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
