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
        /// The level the plan leads the battery to by the end of the slot,
        /// in percent. Nil when the box did not say.
        public var levelPct: Double?

        public init(startMs: Double, durationMs: Double, batteryW: Double, reason: String, levelPct: Double? = nil) {
            self.startMs = startMs
            self.durationMs = durationMs
            self.batteryW = batteryW
            self.reason = reason
            self.levelPct = levelPct
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
    /// The household's time zone, as the box names it, so a widget reads the
    /// clock the way the home does. Nil in a record from before it was kept.
    public var timeZone: String?
    /// Where the box's own solar forecast expects the panels to make power,
    /// for the plan dial's sky. Nil when the app has not read the forecast.
    public var daylight: Daylight?

    /// A stretch of time.
    public struct Span: Codable, Sendable, Equatable {
        public var fromMs: Double
        public var toMs: Double

        public init(fromMs: Double, toMs: Double) {
            self.fromMs = fromMs
            self.toMs = toMs
        }
    }

    /// The stretch the solar forecast covers, and the runs in it where it
    /// expects the panels to make power.
    public struct Daylight: Codable, Sendable, Equatable {
        public var covered: Span
        public var sun: [Span]

        public init(covered: Span, sun: [Span]) {
            self.covered = covered
            self.sun = sun
        }

        /// From the forecast's slots: start, length and expected watts.
        public init?(_ slots: [(startMs: Double, durationMs: Double, pvW: Double)]) {
            let sorted = slots.filter { $0.durationMs > 0 }.sorted { $0.startMs < $1.startMs }
            guard let first = sorted.first, let last = sorted.last else { return nil }
            var runs = [Span]()
            for s in sorted where s.pvW >= PlanDial.sunW {
                let end = s.startMs + s.durationMs
                if let open = runs.last, s.startMs <= open.toMs + 1 {
                    runs[runs.count - 1].toMs = max(open.toMs, end)
                } else {
                    runs.append(Span(fromMs: s.startMs, toMs: end))
                }
            }
            self.init(covered: Span(fromMs: first.startMs, toMs: last.startMs + last.durationMs), sun: runs)
        }
    }

    public init(battery: [Slot]?, charges: [Charge], prices: [PriceSlot], currency: String, boxStale: Bool, timeZone: String? = nil, daylight: Daylight? = nil) {
        self.battery = battery
        self.charges = charges
        self.prices = prices
        self.currency = currency
        self.boxStale = boxStale
        self.timeZone = timeZone
        self.daylight = daylight
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
        /// Where the battery's run leaves it, in percent, when the box said.
        public let endLevelPct: Double?
        public var id: String { "\(kind.rawValue)-\(Int64(startMs))" }

        public init(kind: Kind, startMs: Double, endMs: Double, peakW: Double? = nil, targetPct: Double? = nil, energyWh: Double? = nil, reason: String? = nil, endLevelPct: Double? = nil) {
            self.kind = kind
            self.startMs = startMs
            self.endMs = endMs
            self.peakW = peakW
            self.targetPct = targetPct
            self.energyWh = energyWh
            self.reason = reason
            self.endLevelPct = endLevelPct
        }
    }

    /// What happens between `fromMs` and `toMs`, in order: the battery's
    /// runs of charging and giving power, each car's windows, and the
    /// cheapest two hours when they stand out. A run under way starts at
    /// `fromMs`; one that goes on past `toMs` keeps its own end, so a time
    /// on screen is always one the box planned.
    public static func events(_ entry: PlanEntry, fromMs t: Double, toMs end: Double) -> [Event] {
        var out = [Event]()
        // Every slot still to come, so a run that starts inside the window
        // keeps the end the box gave it.
        let slots = (entry.battery ?? []).filter { $0.startMs + $0.durationMs > t }.sorted { $0.startMs < $1.startMs }
        var i = 0
        while i < slots.count {
            let kind = action(slots[i].batteryW)
            var j = i
            var peak = abs(slots[i].batteryW)
            while j + 1 < slots.count, action(slots[j + 1].batteryW) == kind, slots[j + 1].startMs <= slots[j].startMs + slots[j].durationMs + 1 {
                j += 1
                peak = max(peak, abs(slots[j].batteryW))
            }
            if let kind, slots[i].startMs < end {
                out.append(Event(kind: kind, startMs: max(t, slots[i].startMs), endMs: slots[j].startMs + slots[j].durationMs, peakW: peak, reason: slots[i].reason, endLevelPct: slots[j].levelPct))
            }
            i = j + 1
        }
        for c in entry.charges where c.toMs > t && c.fromMs < end {
            let watts = c.energyWh.map { $0 * 3_600_000 / max(1, c.toMs - c.fromMs) }
            out.append(Event(kind: .car, startMs: max(t, c.fromMs), endMs: c.toMs, peakW: watts, targetPct: c.targetPct, energyWh: c.energyWh))
        }
        if let cheap = cheapest(entry, fromMs: t, toMs: end) { out.append(cheap) }
        return out.sorted { ($0.startMs, $0.kind.rawValue) < ($1.startMs, $1.kind.rawValue) }
    }

    /// Where the plan the box sent ends, for the plan view's lanes: its
    /// last battery slot or car window, at least `horizonMs` on, and never
    /// past the end of tomorrow, so a clock on it reads as today or
    /// tomorrow. The box plans over every published price, so in the
    /// evening this is tomorrow's last priced quarter.
    public static func reach(_ entry: PlanEntry, fromMs t: Double, calendar: Calendar) -> Double {
        let ends = (entry.battery ?? []).map { $0.startMs + $0.durationMs } + entry.charges.map(\.toMs)
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: t / 1000))
        let tomorrowEnds = calendar.date(byAdding: .day, value: 2, to: today).map { $0.timeIntervalSince1970 * 1000 } ?? t + 48 * 3_600_000
        return max(t + horizonMs, min(ends.max() ?? t, tomorrowEnds))
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
        /// The plan is older than `staleAfterMs`, or from a box this phone
        /// cannot reach: grey, dated, no "now".
        case old
        /// The box itself could not plan.
        case boxStale
        /// The box has not answered yet and this phone kept no plan: the
        /// shape of the card, and no sentence about a plan that may exist.
        case waiting
    }

    public struct Moment: Equatable, Sendable {
        public let atMs: Double
        public let state: State
        public let readAtMs: Double?
        /// Where the moment looks to: `horizonMs` on, or for the plan
        /// view's lanes the whole plan (`reach`).
        public let toMs: Double
        /// Everything up to `toMs`, in order.
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
        /// Now's strip in one sentence: the next thing the box will do and
        /// what follows. "Battery gives power until 21:15, then stores
        /// 22:00."
        public let nextText: String
        /// `nextText` cut short, each form one clause less, for a screen
        /// with no room for the whole: the first sentence alone, then
        /// without where it leaves the battery, then without its reason.
        /// Empty when the sentence has nothing to drop.
        public let nextShorter: [String]
        /// The plan under the dial in up to three sentences: the battery's
        /// next two moves and the car's charge, each with its reason. The
        /// verbs are marked so they can take their colour.
        public let story: [Phrase]
        /// The battery's planned level at the end of each slot ahead, for a
        /// ghost line over the lanes. Empty when the box did not say.
        public let levels: [LevelPoint]
        /// The zone the clock in this moment is read in.
        public let timeZone: TimeZone

        public var isGrey: Bool { state != .plan }
        /// Waiting with nothing to say yet: the line is drawn as its shape.
        public var placeholder: Bool { state == .waiting && summary == PlanWord.reading.text }

        /// "now–20:45", "23:15–24:00", or "tomorrow 21:00–22:30" where the
        /// clock alone would read as later today: the day once, before the
        /// start.
        public func times(_ e: Event) -> String {
            var calendar = Calendar.current
            calendar.timeZone = timeZone
            let clock = Clock(calendar: calendar)
            let start = PlanGlance.started(e, at: atMs) ? PlanWord.nowLower.text : PlanGlance.ahead(e.startMs, asEnd: false, from: atMs, clock: clock)
            return "\(start)–\(clock.wall(e.endMs, asEnd: true).hm)"
        }
    }

    /// The widget's timeline: one moment now, one at every start and end
    /// ahead, and one where the plan turns old.
    public static func moments(_ read: CacheRead<PlanEntry>?, nowMs: Double, calendar given: Calendar? = nil) -> [Moment] {
        let calendar = given ?? .household(read?.value.timeZone)
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

    public static func moment(_ read: CacheRead<PlanEntry>?, atMs t: Double, calendar given: Calendar? = nil) -> Moment {
        let calendar = given ?? .household(read?.value.timeZone)
        guard let read else {
            return Moment(atMs: t, state: .nothing, readAtMs: nil, toMs: t + horizonMs, events: [], backdrop: [], currency: "", summary: PlanWord.openToSee.text,
                          next: nil, nextWhen: nil, nextWhat: nil, nextUntil: nil, cheapText: nil, laterText: nil, ageText: nil, nextText: PlanWord.openToSee.text, nextShorter: [], story: [], levels: [], timeZone: calendar.timeZone)
        }
        let old = t - read.record.readAtMs >= staleAfterMs
        let state: State = read.value.boxStale || read.srcState == .stale ? .boxStale : (old ? .old : .plan)
        return moment(read.value, state: state, readAtMs: read.record.readAtMs, atMs: t, calendar: calendar)
    }

    /// Now's own reading, straight from the session: never old. `whole`
    /// looks over the whole plan rather than `horizonMs`, for the lanes.
    public static func live(_ entry: PlanEntry, nowMs: Double, calendar: Calendar? = nil, whole: Bool = false) -> Moment {
        moment(entry, state: entry.boxStale ? .boxStale : .plan, readAtMs: nil, atMs: nowMs, calendar: calendar ?? .household(entry.timeZone), whole: whole)
    }

    /// A plan this phone kept from an earlier launch, inside the app until
    /// the box answers: dated "Planned 14:05", and grey once old. From a box
    /// this phone cannot reach, it is old at once: the box may have planned
    /// again since.
    public static func kept(_ entry: PlanEntry, readAtMs: Double, nowMs: Double, unreachable: Bool = false, calendar: Calendar? = nil, whole: Bool = false) -> Moment {
        let state: State = entry.boxStale ? .boxStale : (unreachable || nowMs - readAtMs >= staleAfterMs ? .old : .plan)
        return moment(entry, state: state, readAtMs: readAtMs, atMs: nowMs, calendar: calendar ?? .household(entry.timeZone), inApp: true, whole: whole)
    }

    /// Before the box's first answer, with no plan kept. `note` says what
    /// happens instead, when something does.
    public static func waiting(_ entry: PlanEntry, nowMs: Double, note: String? = nil, calendar: Calendar? = nil, whole: Bool = false) -> Moment {
        let m = moment(entry, state: .waiting, readAtMs: nil, atMs: nowMs, calendar: calendar ?? .household(entry.timeZone), whole: whole)
        guard let note else { return m }
        return Moment(atMs: m.atMs, state: m.state, readAtMs: nil, toMs: m.toMs, events: m.events, backdrop: m.backdrop, currency: m.currency, summary: note,
                      next: nil, nextWhen: nil, nextWhat: nil, nextUntil: nil, cheapText: nil, laterText: nil, ageText: nil, nextText: note, nextShorter: [], story: [], levels: m.levels, timeZone: m.timeZone)
    }

    private static func moment(_ entry: PlanEntry, state: State, readAtMs: Double?, atMs t: Double, calendar: Calendar, inApp: Bool = false, whole: Bool = false) -> Moment {
        let clock = Clock(calendar: calendar)
        let end = whole ? reach(entry, fromMs: t, calendar: calendar) : t + horizonMs
        let list = events(entry, fromMs: t, toMs: end)
        let actions = list.filter { $0.kind != .cheap }
        let under = entry.prices.filter { $0.startMs + $0.durationMs > t && $0.startMs < end }
        let backdrop = PriceStrip.summary(Prices(zone: "", currency: entry.currency, slots: under, stale: false), nowMs: t).bars

        var age: String?
        if let readAtMs {
            // Only a widget sends the reader to the app for a newer plan.
            age = state == .old && !inApp ? PlanWord.planFrom.format(clock.at(readAtMs, asEnd: false, from: t)) : PlanWord.planned.format(clock.at(readAtMs, asEnd: false, from: t))
        }

        let summary: String
        let nextText: String
        var nextShorter = [String]()
        switch state {
        case .nothing:
            summary = PlanWord.openToSee.text
            nextText = summary
        case .boxStale:
            summary = PlanWord.boxStale.text
            nextText = summary
        case .waiting:
            summary = PlanWord.reading.text
            nextText = summary
        case .plan, .old:
            if entry.battery == nil, entry.charges.isEmpty {
                summary = PlanWord.noPlanYet.text
                nextText = summary
            } else {
                summary = line(list, from: t, clock: clock, ongoingIsNow: state == .plan)
                nextText = sentence(list, entry: entry, from: t, clock: clock, ongoingIsNow: state == .plan)
                nextShorter = shorter(list, entry: entry, from: t, clock: clock, ongoingIsNow: state == .plan, than: nextText)
            }
        }

        // An old plan does not say what happens now: it may not.
        let next = state == .plan ? actions.first : nil
        return Moment(
            atMs: t,
            state: state,
            readAtMs: readAtMs,
            toMs: end,
            events: list,
            backdrop: backdrop,
            currency: entry.currency,
            summary: summary,
            next: next,
            nextWhen: next.map { $0.startMs <= t + graceMs ? PlanWord.now.text : ahead($0.startMs, asEnd: false, from: t, clock: clock) },
            nextWhat: next.map(what),
            nextUntil: next.map { PlanWord.until.format(ahead($0.endMs, asEnd: true, from: t, clock: clock)) },
            cheapText: state == .nothing || state == .waiting ? nil : list.first { $0.kind == .cheap }.map { PlanWord.cheapest.format(range($0, from: t, clock: clock, ongoingIsNow: state == .plan)) },
            laterText: next.flatMap { n in
                let rest = list.filter { $0 != n }
                return rest.isEmpty ? nil : line(rest, from: t, clock: clock, ongoingIsNow: true, actions: 1)
            },
            ageText: age,
            nextText: nextText,
            nextShorter: nextShorter,
            story: state == .plan || state == .old ? story(list, entry: entry, from: t, clock: clock, ongoingIsNow: state == .plan) : [],
            levels: (entry.battery ?? []).filter { $0.startMs + $0.durationMs > t && $0.startMs < end }
                .compactMap { s in s.levelPct.map { LevelPoint(ms: s.startMs + s.durationMs, pct: $0) } },
            timeZone: calendar.timeZone
        )
    }

    /// "02–05 car charges to 80 % · 06–09 battery gives power · cheapest
    /// 02–04": the car's next charge and the battery's next move, in the
    /// order they happen, then the cheap hours. Without a car, the battery's
    /// next two moves, said once when they are the same: "now–20:45 and
    /// 21:00–21:30 battery gives power".
    static func line(_ events: [Event], from t: Double, clock: Clock, ongoingIsNow: Bool, actions most: Int = 2) -> String {
        let car = events.first { $0.kind == .car }
        let battery = events.filter { $0.kind == .charge || $0.kind == .discharge }.prefix(car == nil ? most : most - 1)
        let actions = ([car].compactMap { $0 } + battery).sorted { $0.startMs < $1.startMs }
        var runs = [(event: Event, when: String)]()
        for e in actions {
            let when = range(e, from: t, clock: clock, ongoingIsNow: ongoingIsNow)
            if let last = runs.last, last.event.kind == e.kind, e.kind == .charge || e.kind == .discharge {
                runs[runs.count - 1].when = PlanWord.both.format(last.when, when)
            } else {
                runs.append((e, when))
            }
        }
        var parts = runs.map { e, when -> String in
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

    /// The battery's planned level at a moment, in percent.
    public struct LevelPoint: Equatable, Sendable {
        public let ms: Double
        public let pct: Double
    }

    /// One sentence about the plan, with its verb marked: the words in
    /// turns plain and marked, so a screen can colour what the battery or
    /// the car does. "Battery *gives power* until 23:30, when power costs
    /// up to 465 öre."
    public struct Phrase: Equatable, Sendable {
        public let kind: Kind
        /// Even entries are plain, odd entries are the verb.
        public let parts: [String]
        public var plain: String { parts.joined() }

        init(kind: Kind, marked: String) {
            self.kind = kind
            parts = marked.components(separatedBy: "*")
        }
    }

    /// Now's strip: the next thing the box will do and why, then the one
    /// after it and why. "Battery gives power until 23:30, when power
    /// costs up to 465 öre. Then stores 03:45 for 297 öre." A thing under
    /// way says until when; one to come says when it runs. The second names
    /// its subject when that changes. A plan that may no longer hold
    /// (`ongoingIsNow` false) never says "until".
    static func sentence(_ events: [Event], entry: PlanEntry, from t: Double, clock: Clock, ongoingIsNow: Bool) -> String {
        let actions = events.filter { $0.kind != .cheap }
        guard let first = actions.first else { return PlanWord.nothingPlanned.text }
        var text = clause(first, entry: entry, from: t, clock: clock, ongoingIsNow: ongoingIsNow, level: isNews(first, entry: entry, from: t)).plain
        if let then = actions.dropFirst().first {
            let when = ahead(then.startMs, asEnd: false, from: t, clock: clock)
            let battery = first.kind == .charge || first.kind == .discharge
            let lead: PlanWord
            switch then.kind {
            case .charge: lead = battery ? .thenStores : .thenBatteryStores
            case .discharge: lead = battery ? .thenGives : .thenBatteryGives
            case .car, .cheap: lead = .thenCar
            }
            text += " " + Phrase(kind: then.kind, marked: PlanWord.sentence.format(why(then, lead.format(when), entry: entry))).plain
        }
        return text
    }

    /// The first sentence of `sentence` alone, then without where it leaves
    /// the battery, then without its reason: each shorter than the last,
    /// none the same as the whole.
    static func shorter(_ events: [Event], entry: PlanEntry, from t: Double, clock: Clock, ongoingIsNow: Bool, than whole: String) -> [String] {
        guard let first = events.first(where: { $0.kind != .cheap }) else { return [] }
        let forms = [
            clause(first, entry: entry, from: t, clock: clock, ongoingIsNow: ongoingIsNow, level: isNews(first, entry: entry, from: t)),
            clause(first, entry: entry, from: t, clock: clock, ongoingIsNow: ongoingIsNow, level: false),
            clause(first, entry: entry, from: t, clock: clock, ongoingIsNow: ongoingIsNow, level: false, reason: false),
        ].map(\.plain)
        var out = [String]()
        for f in forms where f.count < (out.last ?? whole).count { out.append(f) }
        return out
    }

    /// The plan under the dial: the battery's next two moves and the car's
    /// next charge, in the order they happen, a sentence each, each with
    /// its reason.
    static func story(_ events: [Event], entry: PlanEntry, from t: Double, clock: Clock, ongoingIsNow: Bool) -> [Phrase] {
        let battery = events.filter { $0.kind == .charge || $0.kind == .discharge }.prefix(2)
        let car = events.first { $0.kind == .car }
        return (Array(battery) + [car].compactMap { $0 })
            .sorted { $0.startMs < $1.startMs }
            .map { clause($0, entry: entry, from: t, clock: clock, ongoingIsNow: ongoingIsNow) }
    }

    /// Whether where a battery run leaves the battery is news on a line
    /// with no room for more: a run that empties it to the lowest point of
    /// the hours ahead, or one that fills it.
    static func isNews(_ e: Event, entry: PlanEntry, from t: Double) -> Bool {
        guard let end = e.endLevelPct else { return false }
        switch e.kind {
        case .charge:
            return end >= 98
        case .discharge:
            let ahead = (entry.battery ?? []).filter { $0.startMs + $0.durationMs > t && $0.startMs < t + horizonMs }.compactMap(\.levelPct)
            return ahead.min().map { end <= $0 + 2 } ?? false
        case .car, .cheap:
            return false
        }
    }

    /// One event as a sentence with its verb marked and its reason, and
    /// for a battery run where it leaves the battery. `level` and `reason`
    /// false leave those out.
    static func clause(_ e: Event, entry: PlanEntry, from t: Double, clock: Clock, ongoingIsNow: Bool, level: Bool = true, reason: Bool = true) -> Phrase {
        let start = ahead(e.startMs, asEnd: false, from: t, clock: clock)
        let end = ahead(e.endMs, asEnd: true, from: t, clock: clock)
        // "17:15–23:30", or "tomorrow 02:00–05:00": the day once.
        let span = "\(start)–\(clock.wall(e.endMs, asEnd: true).hm)"
        let under = started(e, at: t) && ongoingIsNow
        let lead: String
        switch e.kind {
        case .charge: lead = under ? PlanWord.storesUntil.format(end) : PlanWord.storesAt.format(span)
        case .discharge: lead = under ? PlanWord.givesUntil.format(end) : PlanWord.givesAt.format(span)
        case .car, .cheap: lead = under ? PlanWord.carUntil.format(end) : PlanWord.carAt.format(span)
        }
        var text = reason ? why(e, lead, entry: entry) : lead
        if level, let pct = e.endLevelPct, e.kind == .charge || e.kind == .discharge {
            text = (e.kind == .charge ? PlanWord.levelUp : PlanWord.levelDown).format(text, percent(pct))
        }
        return Phrase(kind: e.kind, marked: PlanWord.sentence.format(text))
    }

    /// The box's reason, said as what drives it: the price when power is
    /// dear or cheap, the sun, selling, the grid limit, or the car's goal.
    /// A reason with no price to show leaves the clause as it is.
    static func why(_ e: Event, _ lead: String, entry: PlanEntry) -> String {
        if e.kind == .car {
            return e.targetPct.map { PlanWord.toPercent.format(lead, percent($0)) } ?? lead
        }
        let under = entry.prices.filter { $0.totalMinor.isFinite && $0.startMs < e.endMs && $0.startMs + $0.durationMs > e.startMs }
        func price(_ minor: Double) -> String {
            Words.decimal(PriceStrip.text(abs(minor), entry.currency)) + " " + PriceUnits.unit(entry.currency).label
        }
        switch (e.kind, e.reason) {
        case (.discharge, "export_paid"?):
            return PlanWord.whySell.format(lead)
        case (.discharge, "peak_shaving"?):
            return PlanWord.whyLimit.format(lead)
        case (.discharge, _):
            guard let top = under.map(\.totalMinor).max() else { return lead }
            return PlanWord.whyDear.format(lead, price(top))
        case (.charge, "solar_surplus"?):
            return PlanWord.whySun.format(lead)
        case (.charge, _):
            guard !under.isEmpty else { return lead }
            let mean = under.map(\.totalMinor).reduce(0, +) / Double(under.count)
            return mean < 0 ? PlanWord.whyPaid.format(lead) : PlanWord.whyCheap.format(lead, price(mean))
        default:
            return lead
        }
    }

    /// What a new plan moved, in one line: "New plan 16:53: stores 22:45
    /// instead of 03:45." The first move that changed, by when it starts:
    /// the battery's charging, its giving power or the car's charge, moved,
    /// new or gone. Nil when nothing a person would see moved.
    public static func moved(from old: PlanEntry, to new: PlanEntry, atMs t: Double, calendar given: Calendar? = nil) -> String? {
        let calendar = given ?? .household(new.timeZone)
        let clock = Clock(calendar: calendar)
        let before = events(old, fromMs: t, toMs: t + horizonMs).filter { $0.kind != .cheap }
        let after = events(new, fromMs: t, toMs: t + horizonMs).filter { $0.kind != .cheap }
        let made = ahead(t, asEnd: false, from: t, clock: clock)
        func word(_ k: Kind) -> String {
            switch k {
            case .charge: return PlanWord.stores.text
            case .discharge: return PlanWord.gives.text
            case .car, .cheap: return PlanWord.carChargesWord.text
            }
        }
        func at(_ e: Event) -> String { ahead(e.startMs, asEnd: false, from: t, clock: clock) }
        var lines: [(ms: Double, text: String)] = []
        for kind in [Kind.charge, .discharge, .car] {
            let a = before.first { $0.kind == kind }, b = after.first { $0.kind == kind }
            switch (a, b) {
            case let (a?, b?) where abs(a.startMs - b.startMs) >= 60_000:
                lines.append((min(a.startMs, b.startMs), PlanWord.movedInstead.format(made, word(kind), at(b), at(a))))
            case let (nil, b?):
                lines.append((b.startMs, PlanWord.movedNew.format(made, word(kind), at(b))))
            case let (a?, nil):
                lines.append((a.startMs, PlanWord.movedGone.format(made, word(kind), at(a))))
            default:
                break
            }
        }
        return lines.min { $0.ms < $1.ms }?.text
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
    /// "NOW", after the price on the strip's header.
    public static var nowWord: String { PlanWord.nowMark.text }
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
    case reading = "Reading the plan from your box…"
    case boxStale = "Your box couldn't plan ahead · it runs on safe defaults"
    case nothingPlanned = "Nothing planned for 12 hours"
    case carChargesTo = "%@ car charges to %@"
    case carCharges = "%@ car charges"
    case batteryCharges = "%@ battery charges"
    case batteryGives = "%@ battery gives power"
    case cheapest = "cheapest %@"
    case both = "%@ and %@"
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
    // Now's strip and the story under the dial: the verb between marks
    // (*) takes the colour of what it says.
    case storesUntil = "Battery *stores* until %@"
    case givesUntil = "Battery *gives power* until %@"
    case carUntil = "Car *charges* until %@"
    case storesAt = "Battery *stores* %@"
    case givesAt = "Battery *gives power* %@"
    case carAt = "Car *charges* %@"
    case toPercent = "%@, to %@"
    case sentence = "%@."
    case thenStores = "Then *stores* %@"
    case thenGives = "Then *gives power* %@"
    case thenBatteryStores = "Then the battery *stores* %@"
    case thenBatteryGives = "Then the battery *gives power* %@"
    case thenCar = "Then the car *charges* %@"
    // Why: what drives the move.
    case whyDear = "%@, when power costs up to %@"
    case whyCheap = "%@ for %@"
    case whyPaid = "%@, when you are paid to use power"
    case whySun = "%@ from spare sun"
    case whySell = "%@, as selling pays"
    case whyLimit = "%@ to hold the grid limit"
    // What a new plan moved.
    case movedInstead = "New plan %@: %@ %@ instead of %@."
    case movedNew = "New plan %@: %@ %@."
    case movedGone = "New plan %@: no longer %@ %@."
    // Where a battery run leaves the battery.
    case levelDown = "%@, and leaves %@"
    case levelUp = "%@, and reaches %@"
    // The strip's header and what a finger reads on it.
    case next12h = "NEXT 12 H"
    case plannedAt = "PLANNED %@"
    case oldPlan = "OLD PLAN · %@"
    case nowMark = "NOW"
    case stores = "stores"
    case gives = "gives power"
    case waits = "waits"
    case carChargesWord = "car charges"
    case carGoal = "car at %@"
    case belowZero = "below zero"
    case noPrice = "no price yet"

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
