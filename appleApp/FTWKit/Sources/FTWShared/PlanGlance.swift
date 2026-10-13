import Foundation

/// The plan ahead as the app leaves it for its widgets: what the box means
/// to do with the battery, when each car charges and to what level, and
/// the prices underneath. Written when a new plan arrives, read by the plan
/// widget and by Now.
public struct PlanEntry: CacheValue {
    public static let name = "plan"
    public static let version = 1

    /// One slot of the box's plan for the battery.
    public struct Slot: Codable, Sendable, Equatable {
        public var startMs: Double
        public var durationMs: Double
        /// Site sign: positive while the battery charges.
        public var batteryW: Double
        /// The box's reason code, never prose.
        public var reason: String

        public init(startMs: Double, durationMs: Double, batteryW: Double, reason: String) {
            self.startMs = startMs
            self.durationMs = durationMs
            self.batteryW = batteryW
            self.reason = reason
        }
    }

    /// One window in which a car is planned to charge.
    public struct Charge: Codable, Sendable, Equatable {
        public var loadpointID: String
        public var fromMs: Double
        public var toMs: Double
        public var energyWh: Double?
        /// The level the car charges toward, whole percent.
        public var targetPct: Double?

        public init(loadpointID: String, fromMs: Double, toMs: Double, energyWh: Double?, targetPct: Double?) {
            self.loadpointID = loadpointID
            self.fromMs = fromMs
            self.toMs = toMs
            self.energyWh = energyWh
            self.targetPct = targetPct
        }
    }

    /// The battery's plan. Nil when the box has sent none: "no plan yet" is
    /// not "the battery rests".
    public var battery: [Slot]?
    public var charges: [Charge]
    /// The prices under the plan, for the background.
    public var prices: [PriceSlot]
    public var currency: String
    /// The box said it could not plan and runs on safe defaults.
    public var boxStale: Bool

    public init(battery: [Slot]?, charges: [Charge], prices: [PriceSlot], currency: String, boxStale: Bool) {
        self.battery = battery
        self.charges = charges
        self.prices = prices
        self.currency = currency
        self.boxStale = boxStale
    }
}

/// The plan at a glance: what happens over the next hours, in one line and
/// as a few events, worked out from a `PlanEntry` alone so Now and the
/// widget say the same thing.
///
/// A plan is intent, not prophecy: the box replans every quarter of an hour.
/// So a plan read from the cache goes grey after `staleAfterMs`, says how
/// old it is, and stops saying "now".
public enum PlanGlance {
    public static let horizonMs: Double = 12 * 3_600_000
    /// Past this, a cached plan is old. The box replans every quarter hour;
    /// an hour is four plans ago.
    public static let staleAfterMs: Double = 60 * 60_000
    /// Below this the battery rests, as the box's own plan reads it.
    static let idleW: Double = 100
    /// A cheapest block worth naming is this much below the average ahead.
    static let cheapShare = 0.85
    /// A screen marks the minute, and the box starts its plan at the second
    /// it made it: something starting within the minute is happening now.
    static let graceMs: Double = 60_000

    public enum Kind: String, Equatable, Sendable {
        case car, charge, discharge, cheap
    }

    public struct Event: Equatable, Sendable, Identifiable {
        public let kind: Kind
        public let startMs: Double
        public let endMs: Double
        /// The most the battery or car moves in it, never signed.
        public let peakW: Double?
        public let targetPct: Double?
        public let energyWh: Double?
        /// The box's reason code for the battery's first slot in it.
        public let reason: String?
        public var id: String { "\(kind.rawValue)-\(Int64(startMs))" }

        public init(kind: Kind, startMs: Double, endMs: Double, peakW: Double? = nil, targetPct: Double? = nil, energyWh: Double? = nil, reason: String? = nil) {
            self.kind = kind
            self.startMs = startMs
            self.endMs = endMs
            self.peakW = peakW
            self.targetPct = targetPct
            self.energyWh = energyWh
            self.reason = reason
        }
    }

    /// What happens between `fromMs` and `toMs`, in order: the battery's
    /// runs of charging and giving power, each car's windows, and the
    /// cheapest two hours when they stand out. Runs are cut to the window.
    public static func events(_ entry: PlanEntry, fromMs t: Double, toMs end: Double) -> [Event] {
        var out = [Event]()
        let slots = (entry.battery ?? []).filter { $0.startMs + $0.durationMs > t && $0.startMs < end }.sorted { $0.startMs < $1.startMs }
        var i = 0
        while i < slots.count {
            let kind = action(slots[i].batteryW)
            var j = i
            var peak = abs(slots[i].batteryW)
            while j + 1 < slots.count, action(slots[j + 1].batteryW) == kind, slots[j + 1].startMs <= slots[j].startMs + slots[j].durationMs + 1 {
                j += 1
                peak = max(peak, abs(slots[j].batteryW))
            }
            if let kind {
                out.append(Event(kind: kind, startMs: max(t, slots[i].startMs), endMs: min(end, slots[j].startMs + slots[j].durationMs), peakW: peak, reason: slots[i].reason))
            }
            i = j + 1
        }
        for c in entry.charges where c.toMs > t && c.fromMs < end {
            let watts = c.energyWh.map { $0 * 3_600_000 / max(1, c.toMs - c.fromMs) }
            out.append(Event(kind: .car, startMs: max(t, c.fromMs), endMs: min(end, c.toMs), peakW: watts, targetPct: c.targetPct, energyWh: c.energyWh))
        }
        if let cheap = cheapest(entry, fromMs: t, toMs: end) { out.append(cheap) }
        return out.sorted { ($0.startMs, $0.kind.rawValue) < ($1.startMs, $1.kind.rawValue) }
    }

    static func action(_ w: Double) -> Kind? {
        w > idleW ? .charge : (w < -idleW ? .discharge : nil)
    }

    /// The cheapest two hours ahead, when they stand out from the rest.
    static func cheapest(_ entry: PlanEntry, fromMs t: Double, toMs end: Double) -> Event? {
        let ahead = entry.prices.filter { $0.startMs + $0.durationMs > t && $0.startMs < end && $0.totalMinor.isFinite }.sorted { $0.startMs < $1.startMs }
        guard ahead.count >= 2, let block = PriceStrip.bestBlock(ahead, hours: 2, cheapest: true) else { return nil }
        let mean = ahead.map(\.totalMinor).reduce(0, +) / Double(ahead.count)
        guard block.meanMinor < mean * cheapShare || block.meanMinor < 0 else { return nil }
        return Event(kind: .cheap, startMs: max(t, block.startMs), endMs: block.endMs)
    }

    // MARK: What a screen shows

    public enum State: Equatable, Sendable {
        /// The app has left no plan: not paired, or signed out.
        case nothing
        /// A plan this recent says what happens now.
        case plan
        /// The plan is older than `staleAfterMs`: grey, dated, no "now".
        case old
        /// The box itself could not plan.
        case boxStale
    }

    public struct Moment: Equatable, Sendable {
        public let atMs: Double
        public let state: State
        public let readAtMs: Double?
        /// Everything over the next `horizonMs`, in order.
        public let events: [Event]
        /// The prices under the plan, as bars from `atMs` on.
        public let backdrop: [PriceStrip.Bar]
        public let currency: String
        /// The plan in one line: "02–05 car charges to 80 % · cheapest 02–04".
        public let summary: String
        /// The first thing the box will do, or is doing.
        public let next: Event?
        /// "Now", or the clock it starts at.
        public let nextWhen: String?
        /// "Car charges to 80 %"
        public let nextWhat: String?
        /// "until 04:47"
        public let nextUntil: String?
        /// "cheapest 02–04", when the hours ahead have a cheap stretch.
        public let cheapText: String?
        /// The one thing that comes after `next`, the car first, and the
        /// cheap hours. Nil when nothing does.
        public let laterText: String?
        /// "Planned 14:05", or "Plan from 14:05 · open FTW" once old.
        public let ageText: String?

        public var isGrey: Bool { state != .plan }
    }

    /// The widget's timeline: one moment now, one at every start and end
    /// ahead, and one where the plan turns old.
    public static func moments(_ read: CacheRead<PlanEntry>?, nowMs: Double, calendar: Calendar = .current) -> [Moment] {
        guard let read else { return [moment(nil, atMs: nowMs, calendar: calendar)] }
        var edges = Set<Double>()
        for e in events(read.value, fromMs: nowMs, toMs: nowMs + horizonMs) {
            edges.insert(e.startMs)
            edges.insert(e.endMs)
        }
        edges.insert(read.record.readAtMs + staleAfterMs)
        let ahead = edges.filter { $0 > nowMs && $0 <= nowMs + horizonMs }.sorted()
        return ([nowMs] + ahead).map { moment(read, atMs: $0, calendar: calendar) }
    }

    public static func moment(_ read: CacheRead<PlanEntry>?, atMs t: Double, calendar: Calendar = .current) -> Moment {
        guard let read else {
            return Moment(atMs: t, state: .nothing, readAtMs: nil, events: [], backdrop: [], currency: "", summary: PlanWord.openToSee.text,
                          next: nil, nextWhen: nil, nextWhat: nil, nextUntil: nil, cheapText: nil, laterText: nil, ageText: nil)
        }
        let old = t - read.record.readAtMs >= staleAfterMs
        let state: State = read.value.boxStale || read.srcState == .stale ? .boxStale : (old ? .old : .plan)
        return moment(read.value, state: state, readAtMs: read.record.readAtMs, atMs: t, calendar: calendar)
    }

    /// Now's own reading, straight from the session: never old.
    public static func live(_ entry: PlanEntry, nowMs: Double, calendar: Calendar = .current) -> Moment {
        moment(entry, state: entry.boxStale ? .boxStale : .plan, readAtMs: nil, atMs: nowMs, calendar: calendar)
    }

    private static func moment(_ entry: PlanEntry, state: State, readAtMs: Double?, atMs t: Double, calendar: Calendar) -> Moment {
        let clock = Clock(calendar: calendar)
        let list = events(entry, fromMs: t, toMs: t + horizonMs)
        let actions = list.filter { $0.kind != .cheap }
        let under = entry.prices.filter { $0.startMs + $0.durationMs > t && $0.startMs < t + horizonMs }
        let backdrop = PriceStrip.summary(Prices(zone: "", currency: entry.currency, slots: under, stale: false), nowMs: t).bars

        var age: String?
        if let readAtMs {
            age = state == .old ? PlanWord.planFrom.format(clock.at(readAtMs, asEnd: false, from: t)) : PlanWord.planned.format(clock.at(readAtMs, asEnd: false, from: t))
        }

        let summary: String
        switch state {
        case .nothing:
            summary = PlanWord.openToSee.text
        case .boxStale:
            summary = PlanWord.boxStale.text
        case .plan, .old:
            if entry.battery == nil, entry.charges.isEmpty {
                summary = PlanWord.noPlanYet.text
            } else {
                summary = line(list, from: t, clock: clock, ongoingIsNow: state == .plan)
            }
        }

        // An old plan does not say what happens now: it may not.
        let next = state == .plan ? actions.first : nil
        return Moment(
            atMs: t,
            state: state,
            readAtMs: readAtMs,
            events: list,
            backdrop: backdrop,
            currency: entry.currency,
            summary: summary,
            next: next,
            nextWhen: next.map { $0.startMs <= t + graceMs ? PlanWord.now.text : ahead($0.startMs, asEnd: false, from: t, clock: clock) },
            nextWhat: next.map(what),
            nextUntil: next.map { PlanWord.until.format(ahead($0.endMs, asEnd: true, from: t, clock: clock)) },
            cheapText: state == .nothing ? nil : list.first { $0.kind == .cheap }.map { PlanWord.cheapest.format(range($0, from: t, clock: clock, ongoingIsNow: state == .plan)) },
            laterText: next.flatMap { n in
                let rest = list.filter { $0 != n }
                return rest.isEmpty ? nil : line(rest, from: t, clock: clock, ongoingIsNow: true, actions: 1)
            },
            ageText: age
        )
    }

    /// "02–05 car charges to 80 % · 06–09 battery gives power · cheapest
    /// 02–04": the car's next charge and the battery's next move, in the
    /// order they happen, then the cheap hours. Without a car, the battery's
    /// next two moves.
    static func line(_ events: [Event], from t: Double, clock: Clock, ongoingIsNow: Bool, actions most: Int = 2) -> String {
        let car = events.first { $0.kind == .car }
        let battery = events.filter { $0.kind == .charge || $0.kind == .discharge }.prefix(car == nil ? most : most - 1)
        let actions = ([car].compactMap { $0 } + battery).sorted { $0.startMs < $1.startMs }
        var parts = actions.map { e -> String in
            let when = range(e, from: t, clock: clock, ongoingIsNow: ongoingIsNow)
            switch e.kind {
            case .car:
                return e.targetPct.map { PlanWord.carChargesTo.format(when, percent($0)) } ?? PlanWord.carCharges.format(when)
            case .charge: return PlanWord.batteryCharges.format(when)
            case .discharge: return PlanWord.batteryGives.format(when)
            case .cheap: return ""
            }
        }
        if parts.isEmpty { parts.append(PlanWord.nothingPlanned.text) }
        if let cheap = events.first(where: { $0.kind == .cheap }) {
            parts.append(PlanWord.cheapest.format(range(cheap, from: t, clock: clock, ongoingIsNow: ongoingIsNow)))
        }
        return parts.joined(separator: " · ")
    }

    /// "02–05", "02:15–04:47", "now–05". Tomorrow is named only when the
    /// clock alone would read as later today, as the price widget does: at
    /// 20:00 "02–04" can only be tonight, at 14:00 "15–17" cannot.
    static func range(_ e: Event, from t: Double, clock: Clock, ongoingIsNow: Bool) -> String {
        let a = clock.wall(e.startMs, asEnd: false)
        let b = clock.wall(e.endMs, asEnd: true)
        let whole = a.minute == 0 && b.minute == 0
        func short(_ w: Clock.Wall) -> String { whole ? String(format: "%02d", w.hour) : w.hm }
        let start = e.startMs <= t + graceMs && ongoingIsNow ? PlanWord.nowLower.text : short(a)
        let text = "\(start)–\(short(b))"
        let now = clock.wall(t, asEnd: false)
        guard e.startMs > t, a.day > now.day, (a.hour, a.minute) > (now.hour, now.minute) else { return text }
        return GlanceWord.tomorrow.format(text)
    }

    /// Whether `e` is under way at `t`, give or take the minute a screen
    /// marks.
    public static func started(_ e: Event, at t: Double) -> Bool { e.startMs <= t + graceMs }

    /// "01:00", or "tomorrow 15:00" where the clock alone would read as
    /// later today.
    static func ahead(_ ms: Double, asEnd: Bool, from t: Double, clock: Clock) -> String {
        let a = clock.wall(ms, asEnd: asEnd)
        let now = clock.wall(t, asEnd: false)
        guard a.day > now.day, (a.hour, a.minute) > (now.hour, now.minute) else { return a.hm }
        return GlanceWord.tomorrow.format(a.hm)
    }

    /// "Car charges to 80 %", for the widget's headline.
    public static func what(_ e: Event) -> String {
        switch e.kind {
        case .car: return e.targetPct.map { PlanWord.carTo.format(percent($0)) } ?? PlanWord.car.text
        case .charge: return PlanWord.batteryCharging.text
        case .discharge: return PlanWord.batteryGiving.text
        case .cheap: return PlanWord.cheapPower.text
        }
    }

    static func percent(_ v: Double) -> String { "\(Int(v.rounded()))\u{00A0}%" }

    public static var title: String { PlanWord.title.text }
    public static var summaryText: String { PlanWord.summary.text }
}

/// Every sentence the plan shows, on Now and in its widget. The English is
/// the key; the Swedish lives in `Resources/sv.lproj/Plan.strings`, and a
/// test checks each one has it.
enum PlanWord: String, CaseIterable {
    case title = "Plan ahead"
    case summary = "What FTW plans to do over the next hours, and when power is cheapest."
    case openToSee = "Open FTW to see the plan"
    case noPlanYet = "No plan from your box yet"
    case boxStale = "Your box couldn't plan ahead · it runs on safe defaults"
    case nothingPlanned = "Nothing planned for 12 hours"
    case carChargesTo = "%@ car charges to %@"
    case carCharges = "%@ car charges"
    case batteryCharges = "%@ battery charges"
    case batteryGives = "%@ battery gives power"
    case cheapest = "cheapest %@"
    case now = "Now"
    case nowLower = "now"
    case until = "until %@"
    case carTo = "Car charges to %@"
    case car = "Car charges"
    case batteryCharging = "Battery charges"
    case batteryGiving = "Battery gives power"
    case cheapPower = "Cheapest power"
    case planned = "Planned %@"
    case planFrom = "Plan from %@ · open FTW"

    var text: String { Words.bundle.localizedString(forKey: rawValue, value: rawValue, table: "Plan") }

    func format(_ args: String...) -> String {
        var out = text
        for a in args {
            guard let r = out.range(of: "%@") else { break }
            out.replaceSubrange(r, with: a)
        }
        return out
    }
}
