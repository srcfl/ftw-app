import Foundation

/// FTW's plan as a dial: today and tomorrow as one spiral, today the inner
/// turn and tomorrow the outer. A bar per quarter hour stands as tall as the
/// price, coloured by what the plan does with the battery; a dot marks a
/// quarter when the car charges.
///
/// The day runs the way the sun does when you face south: midnight at the
/// bottom, noon at the top, up on the left and down on the right. A clock
/// starts at the top and goes round twice a day; this cannot be read as one.
///
/// Everything here is worked out once per plan, from a `PlanEntry` alone,
/// so the app, its widgets and later the Watch draw the same dial.
public enum PlanDial {
    public static let quarterMs: Double = 900_000

    // MARK: The sun's path

    /// Radians clockwise on screen from straight down, for a time of day
    /// given as a share of the day.
    public static func angle(_ dayFraction: Double) -> Double { dayFraction * 2 * .pi }

    /// The point for a time of day on a circle of radius one around the
    /// centre, in screen axes: y grows downward.
    public static func unit(_ dayFraction: Double) -> (x: Double, y: Double) {
        let a = angle(dayFraction)
        return (-sin(a), cos(a))
    }

    /// The time of day under a point, measured from the centre in screen
    /// axes, as a share of the day.
    public static func dayFraction(x: Double, y: Double) -> Double {
        let a = atan2(-x, y)
        return (a < 0 ? a + 2 * .pi : a) / (2 * .pi)
    }

    /// Where things sit, in parts of the dial's radius.
    public enum Layout {
        /// Where today's turn starts, at midnight.
        public static let core = 0.385
        /// What one turn adds to the radius.
        public static let turn = 0.19
        /// The longest bar. Shorter than a turn, so a bar never reaches the
        /// turn outside it.
        public static let bar = 0.15
        /// How far a price below zero may reach inward.
        public static let barInward = 0.03
        /// The middle of the sky band on the rim, and its width.
        public static let rim = 0.945
        public static let band = 0.026
        /// The battery's ring, and its width.
        public static let battery = 0.315
        public static let batteryWidth = 0.036

        /// The radius of the spiral `progress` turns after today's midnight.
        public static func spiral(_ progress: Double) -> Double { core + turn * progress }
    }

    // MARK: The face

    /// What the plan does with the battery in a quarter.
    public enum Action: String, Sendable, Equatable {
        /// The battery charges.
        case store
        /// The battery gives power.
        case use
        /// The battery rests.
        case wait
        /// No plan covers the quarter: it is before the plan, or after it.
        case unplanned
    }

    /// One quarter hour of today or tomorrow.
    public struct Quarter: Equatable, Sendable, Identifiable {
        public let startMs: Double
        /// 0 today, 1 tomorrow.
        public let turn: Int
        /// The wall clock at its start, in minutes after midnight.
        public let minuteOfDay: Int
        /// What the household pays, in minor units per kWh. Nil while the
        /// box has no price for it: then no bar is drawn.
        public let priceMinor: Double?
        public let action: Action
        /// The box's reason code for the plan's slot.
        public let reason: String?
        public let car: Bool

        public var id: Double { startMs }
        public var endMs: Double { startMs + PlanDial.quarterMs }
        /// The time of day at its middle, as a share of the day: its angle.
        public var dayFraction: Double { (Double(minuteOfDay) + 7.5) / 1440 }
        /// How far along the spiral its middle lies, in turns.
        public var progress: Double { Double(turn) + dayFraction }
    }

    public struct Face: Equatable, Sendable {
        public let dayStartMs: Double
        public let tomorrowStartMs: Double
        public let endMs: Double
        /// Every quarter from today's midnight to tomorrow's end, in order.
        public let quarters: [Quarter]
        /// Whether the box has tomorrow's prices. The outer turn holds bars
        /// only then.
        public let tomorrowPriced: Bool
        /// The price a full bar stands for: the largest, either side of zero.
        public let scale: Double
        /// The cheapest stretch ahead, as Now and the plan card name it.
        public let cheapest: PlanEntry.Span?
        public let daylight: PlanEntry.Daylight?
        public let currency: String
        public let timeZoneID: String
        /// The quarter at each of the two days' 192 quarter hours on the
        /// clock, so a place on the spiral is one lookup.
        let slots: [Int]

        public var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .current }

        /// The quarter `ms` falls in. Quarters lie on a fixed grid from
        /// midnight, so this is a division.
        public func index(at ms: Double) -> Int? {
            guard ms >= dayStartMs, ms < endMs, !quarters.isEmpty else { return nil }
            return min(quarters.count - 1, Int((ms - dayStartMs) / PlanDial.quarterMs))
        }

        /// The quarters a finger can reach: from the first one with a price
        /// or a plan to the last.
        public var reach: ClosedRange<Int>? {
            guard let a = quarters.firstIndex(where: Self.known), let b = quarters.lastIndex(where: Self.known) else { return nil }
            return a...b
        }

        private static func known(_ q: Quarter) -> Bool { q.priceMinor != nil || q.action != .unplanned }

        /// How far along the spiral `ms` lies, in turns, for the hand.
        public func progress(at ms: Double) -> Double {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let c = calendar.dateComponents([.hour, .minute, .second], from: Date(timeIntervalSince1970: ms / 1000))
            let fraction = (Double(c.hour ?? 0) * 3600 + Double(c.minute ?? 0) * 60 + Double(c.second ?? 0)) / 86_400
            return (ms >= tomorrowStartMs ? 1 : 0) + fraction
        }

        /// The quarter at a place on the spiral, kept within `reach`: one
        /// lookup, cheap enough for every move of a finger.
        public func index(atProgress p: Double) -> Int? {
            guard let reach, !slots.isEmpty else { return nil }
            let k = min(slots.count - 1, max(0, Int((p * 96).rounded(.down))))
            return min(reach.upperBound, max(reach.lowerBound, slots[k]))
        }

        /// The quarters VoiceOver steps through: the one now and every whole
        /// hour a finger can reach, in order.
        public func hourStops(nowMs: Double) -> [Int] {
            guard let reach else { return [] }
            var stops = reach.filter { quarters[$0].minuteOfDay % 60 == 0 }
            if let now = index(at: nowMs), reach.contains(now), !stops.contains(now) {
                stops.append(now)
                stops.sort()
            }
            return stops
        }

        /// VoiceOver's next stop from `index` (now when nil), an hour on or
        /// back. Nil at either end.
        public func step(from index: Int?, forward: Bool, nowMs: Double) -> Int? {
            let stops = hourStops(nowMs: nowMs)
            guard let at = index ?? self.index(at: nowMs) ?? stops.first else { return nil }
            return forward ? stops.first { $0 > at } : stops.last { $0 < at }
        }

        /// Whether a quarter starts or ends the cheapest stretch: a firmer
        /// tick under the finger.
        public func edgesCheapest(_ i: Int) -> Bool {
            guard let cheapest, quarters.indices.contains(i) else { return false }
            let q = quarters[i]
            return abs(q.startMs - cheapest.fromMs) < 1 || abs(q.endMs - cheapest.toMs) < 1
        }

        /// The sky's runs as arcs on the rim, over the 24 hours from `nowMs`:
        /// each place on the rim shows the next time that hour comes round.
        /// `covered` is where the forecast speaks, `sun` where it expects
        /// the panels to make power. Both empty without a forecast.
        public func sky(nowMs: Double) -> (covered: [ClosedRange<Double>], sun: [ClosedRange<Double>]) {
            guard let daylight else { return ([], []) }
            let window = PlanEntry.Span(fromMs: nowMs, toMs: nowMs + 86_400_000)
            return (arcs([daylight.covered], within: window), arcs(daylight.sun, within: window))
        }

        private func arcs(_ spans: [PlanEntry.Span], within window: PlanEntry.Span) -> [ClosedRange<Double>] {
            var out = [ClosedRange<Double>]()
            for s in spans {
                let a = max(s.fromMs, window.fromMs), b = min(s.toMs, window.toMs)
                guard b > a else { continue }
                let from = progress(at: a).truncatingRemainder(dividingBy: 1)
                let length = (b - a) / 86_400_000
                let to = from + length
                if to <= 1 {
                    out.append(from...to)
                } else {
                    out.append(from...1)
                    out.append(0...(to - 1))
                }
            }
            return out
        }
    }

    /// The dial for `entry` on the day of `nowMs`, in the household's clock.
    public static func face(_ entry: PlanEntry, nowMs: Double, calendar given: Calendar? = nil) -> Face {
        let calendar = given ?? .household(entry.timeZone)
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: nowMs / 1000))
        let start = ms(today)
        let middle = calendar.date(byAdding: .day, value: 1, to: today).map(ms) ?? start + 86_400_000
        let end = calendar.date(byAdding: .day, value: 2, to: today).map(ms) ?? middle + 86_400_000

        let prices = entry.prices.filter { $0.totalMinor.isFinite && $0.startMs < end && $0.startMs + $0.durationMs > start }.sorted { $0.startMs < $1.startMs }
        let battery = (entry.battery ?? []).sorted { $0.startMs < $1.startMs }
        var quarters = [Quarter]()
        quarters.reserveCapacity(200)
        var p = 0, b = 0
        var t = start
        while t < end {
            let qEnd = t + quarterMs
            let mid = t + quarterMs / 2
            while p < prices.count, prices[p].startMs + prices[p].durationMs <= mid { p += 1 }
            let price = p < prices.count && prices[p].startMs <= mid ? prices[p].totalMinor : nil
            // The plan's first slot starts the minute the box made it, so a
            // slot that reaches into the quarter at all speaks for it.
            while b < battery.count, battery[b].startMs + battery[b].durationMs <= t { b += 1 }
            let slot = b < battery.count && battery[b].startMs < qEnd ? battery[b] : nil
            let car = entry.charges.contains { min($0.toMs, qEnd) - max($0.fromMs, t) >= 60_000 }
            let wall = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: t / 1000))
            quarters.append(Quarter(
                startMs: t,
                turn: t < middle ? 0 : 1,
                minuteOfDay: (wall.hour ?? 0) * 60 + (wall.minute ?? 0),
                priceMinor: price,
                action: slot.map { action($0.batteryW) } ?? .unplanned,
                reason: slot?.reason,
                car: car
            ))
            t = qEnd
        }
        // The night the clocks go back, an hour's quarters come twice; a
        // finger gets the first. The night they go forward, the skipped
        // hour takes the quarter before it.
        var slots = [Int](repeating: -1, count: 192)
        for (i, q) in quarters.enumerated() {
            let k = q.turn * 96 + q.minuteOfDay / 15
            if slots[k] < 0 { slots[k] = i }
        }
        var last = 0
        for k in slots.indices {
            if slots[k] < 0 { slots[k] = last } else { last = slots[k] }
        }
        let scale = max(1, quarters.compactMap { $0.priceMinor.map(abs) }.max() ?? 1)
        let cheapest = PlanGlance.cheapest(entry, fromMs: nowMs, toMs: nowMs + PlanGlance.horizonMs).map { PlanEntry.Span(fromMs: $0.startMs, toMs: $0.endMs) }
        return Face(
            dayStartMs: start,
            tomorrowStartMs: middle,
            endMs: end,
            quarters: quarters,
            tomorrowPriced: quarters.contains { $0.turn == 1 && $0.priceMinor != nil },
            scale: scale,
            cheapest: cheapest,
            daylight: entry.daylight,
            currency: entry.currency,
            timeZoneID: calendar.timeZone.identifier,
            slots: slots
        )
    }

    public static func action(_ batteryW: Double) -> Action {
        batteryW > PlanGlance.idleW ? .store : (batteryW < -PlanGlance.idleW ? .use : .wait)
    }

    // MARK: A finger on the dial

    /// Where a finger is on the spiral, in turns after today's midnight.
    /// `x` and `y` run from the centre in parts of the radius, screen axes.
    /// A finger coming down picks the turn whose bars it is nearest; one that
    /// moves goes on round, onto tomorrow past midnight or back to today.
    public static func progress(x: Double, y: Double, from previous: Double?) -> Double {
        let f = dayFraction(x: x, y: y)
        if let previous {
            return [f - 1, f, f + 1, f + 2].min { abs($0 - previous) < abs($1 - previous) } ?? f
        }
        let r = (x * x + y * y).squareRoot()
        func bars(_ p: Double) -> Double { abs(r - (Layout.spiral(p) + Layout.bar / 2)) }
        return bars(f) <= bars(1 + f) ? f : 1 + f
    }

    // MARK: Words

    /// Under an empty outer turn: when tomorrow's prices come, or that they
    /// are late. Nil once they are in.
    /// `short` for a widget, where two words is all there is room for.
    public static func tomorrowNote(_ face: Face, nowMs: Double, short: Bool = false) -> String? {
        // Before any price is known there is nothing to say about tomorrow's.
        guard !face.tomorrowPriced, face.quarters.contains(where: { $0.turn == 0 && $0.priceMinor != nil }) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = face.timeZone
        let early = calendar.component(.hour, from: Date(timeIntervalSince1970: nowMs / 1000)) < 13
        switch (early, short) {
        case (true, false): return PlanWord.pricesAt13.text
        case (false, false): return PlanWord.pricesLate.text
        case (true, true): return PlanWord.pricesAt13Short.text
        case (false, true): return PlanWord.pricesLateShort.text
        }
    }

    /// "64 %"
    public static func percent(_ v: Double) -> String { PlanGlance.percent(v) }

    /// The figures in the middle of the dial.
    public struct Centre: Equatable, Sendable {
        /// "14:15"
        public let time: String
        /// "65,5", nil where the box has no price.
        public let price: String?
        /// "öre/kWh"
        public let unit: String
        /// "Tomorrow", when the quarter is tomorrow's.
        public let day: String?
    }

    /// The clock and the price now, or at the quarter under a finger.
    public static func centre(_ face: Face, nowMs: Double, selected: Int? = nil) -> Centre {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = face.timeZone
        let i = selected.flatMap { face.quarters.indices.contains($0) ? $0 : nil }
        let at = i.map { face.quarters[$0].startMs } ?? nowMs
        let c = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: at / 1000))
        let quarter = i.map { face.quarters[$0] } ?? face.index(at: nowMs).map { face.quarters[$0] }
        return Centre(
            time: String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0),
            price: quarter?.priceMinor.map { Words.decimal(PriceStrip.text($0, face.currency)) },
            unit: PriceUnits.unit(face.currency).perKwh,
            day: quarter.flatMap { $0.turn == 1 ? PlanWord.tomorrow.text : nil }
        )
    }

    private static func ms(_ d: Date) -> Double { d.timeIntervalSince1970 * 1000 }
}
