import Foundation

/// What each watch screen says, worked out from the records alone, so the
/// app, its complications and a test agree.
///
/// Light means live, on the wrist too. A reading glows only when it came
/// from the phone as a live frame (`WatchNews.now`) a moment ago, over a
/// live carrier with its own source live. Everything read from the
/// context or the watch's cache is ink, with the time it was read.
public enum WatchGlance {
    /// How long a forwarded frame stays lit after it arrived: the relay's
    /// gap rule (3.5 s), with room for the hop from the phone.
    public static let liveForMs: Double = 4_000
    /// How long a complication shows the battery's level after the phone
    /// read it. Past this the level may have moved, and the centre is
    /// left empty.
    public static let levelForMs: Double = 15 * 60_000

    // MARK: Now

    /// Whether Now is live at `nowMs`. `arrivedAtMs` is when the frame
    /// reached the watch, by the watch's clock; nil for a record from the
    /// context or the cache, which never glows.
    public static func lit(_ record: CacheRecord<WatchNow>?, arrivedAtMs: Double?, nowMs: Double) -> Bool {
        guard let record, let arrivedAtMs else { return false }
        guard [.relay, .webrtc, .cloud].contains(record.carrier), record.srcState == .live else { return false }
        return nowMs - arrivedAtMs >= -1_000 && nowMs - arrivedAtMs <= liveForMs
    }

    /// One figure on Now.
    public struct Figure: Equatable, Sendable, Identifiable {
        public let node: WatchNow.Node
        public let title: String
        /// "2,3", or "—" without a reading.
        public let value: String
        public let unit: String
        public let word: String
        /// "64 %" for the battery and the car.
        public let level: String?
        /// Lit: the frame is live and so is this reading.
        public let lit: Bool
        public var id: WatchNow.Node { node }
    }

    public static func figures(_ now: WatchNow?, lit: Bool) -> [Figure] {
        guard let now else { return [] }
        return now.readings.map { r in
            let parts = r.watts.map(PowerFormat.parts)
            var level: String?
            if let pct = r.levelPct {
                let text = PlanGlance.percent(pct)
                level = r.levelAssumed ? WatchWord.levelAssumed.format(text) : text
            }
            return Figure(
                node: r.node,
                title: title(r.node),
                value: parts.map { Words.decimal($0.text) } ?? "—",
                unit: parts?.unit ?? "",
                word: word(r.way),
                level: level,
                lit: lit && r.live
            )
        }
    }

    public static func title(_ node: WatchNow.Node) -> String {
        switch node {
        case .solar: return WatchWord.solar.text
        case .battery: return WatchWord.battery.text
        case .home: return WatchWord.home.text
        case .grid: return WatchWord.grid.text
        case .car: return WatchWord.car.text
        }
    }

    public static func word(_ way: WatchNow.Way) -> String {
        switch way {
        case .making: return WatchWord.making.text
        case .resting: return WatchWord.resting.text
        case .charging: return WatchWord.charging.text
        case .giving: return WatchWord.giving.text
        case .using: return WatchWord.using.text
        case .buying: return WatchWord.buying.text
        case .selling: return WatchWord.selling.text
        case .balanced: return WatchWord.balanced.text
        case .noReading: return WatchWord.noReading.text
        }
    }

    /// The mono line under the title, in the phone's words: `● LIVE · FTW
    /// IN CONTROL`, or `○ AS OF 14:05 · FTW IN CONTROL`. It never counts
    /// seconds; a cached reading names the minute it was read.
    public struct Status: Equatable, Sendable {
        public let lit: Bool
        public let text: String
        /// The second half is a warning.
        public let alarm: Bool
    }

    public static func status(_ record: CacheRecord<WatchNow>?, lit: Bool, demo: Bool, zone: TimeZone) -> Status {
        guard let record else { return Status(lit: false, text: WatchWord.noReadingYet.text, alarm: false) }
        var parts = [String]()
        if lit {
            parts.append(demo ? WatchWord.demo.text : WatchWord.live.text)
        } else {
            parts.append(WatchWord.asOf.format(ZoneClock.of(zone).label(record.readAtMs)))
        }
        var alarm = false
        switch record.value.control {
        case .inControl: parts.append(WatchWord.inControl.text)
        case .notInControl:
            parts.append(WatchWord.notInControl.text)
            alarm = true
        case .unknown: break
        }
        return Status(lit: lit, text: parts.joined(separator: " · "), alarm: alarm)
    }

    /// The household's zone, from whichever record names it.
    public static func zone(_ ctx: WatchContext?) -> TimeZone {
        let id = ctx?.plan?.value.timeZone ?? ctx?.prices?.value.timeZone
        return id.flatMap(TimeZone.init(identifier:)) ?? .current
    }

    // MARK: The car

    public struct Car: Equatable, Sendable, Identifiable {
        public let loadpointID: String
        /// Whole percent, when the box has a level.
        public let levelPct: Double?
        /// The 10-cell meter: how many cells are full.
        public let cells: Int?
        /// "64 %", or "64 % assumed".
        public let levelText: String?
        /// "Charge now on", "Charging · 7,4 kW", "Plugged in", "Not plugged in".
        public let state: String
        public let holding: Bool
        public let pluggedIn: Bool
        /// "Goal 80 %"
        public let goal: String?
        /// "Charges 02–05": the next window the plan gives it.
        public let next: String?
        /// "AS OF 14:05"
        public let asOf: String
        public var id: String { loadpointID }

        /// The page's shape, drawn redacted while nothing is known. Never
        /// shown as a car.
        public static let shape = Car(loadpointID: "", levelPct: 50, cells: 5, levelText: "50 %", state: WatchWord.pluggedIn.text, holding: false, pluggedIn: true, goal: WatchWord.goal.format("80 %"), next: nil, asOf: WatchWord.asOf.format("00:00"))
    }

    public static func cars(_ record: CacheRecord<CarEntry>?, plan: PlanEntry?, nowMs: Double, zone: TimeZone) -> [Car] {
        guard let record else { return [] }
        let clock = ZoneClock.of(zone)
        return record.value.cars.map { c in
            let assumed = c.socSource == "assumed"
            let level = c.socPct.map { PlanGlance.percent($0) }
            let state: String
            if c.holding == true {
                state = WatchWord.chargeNowOn.text
            } else if c.pluggedIn, c.powerW > PlanGlance.idleW {
                state = WatchWord.chargingAt.format(Words.decimal(PowerFormat.text(c.powerW)))
            } else {
                state = c.pluggedIn ? WatchWord.pluggedIn.text : WatchWord.notPluggedIn.text
            }
            let window = plan?.charges
                .filter { $0.loadpointID == c.loadpointID && $0.toMs > nowMs }
                .min { $0.fromMs < $1.fromMs }
            let next = window.map { w in
                WatchWord.chargesAt.format("\(w.fromMs <= nowMs ? PlanWord.nowLower.text : clock.label(w.fromMs))–\(clock.label(w.toMs))")
            }
            return Car(
                loadpointID: c.loadpointID,
                levelPct: c.socPct,
                cells: c.socPct.map { min(10, max(0, Int(($0 / 10).rounded(.down)))) },
                levelText: level.map { assumed ? WatchWord.levelAssumed.format($0) : $0 },
                state: state,
                holding: c.holding == true,
                pluggedIn: c.pluggedIn,
                goal: c.targetSocPct.map { WatchWord.goal.format(PlanGlance.percent($0)) },
                next: next,
                asOf: WatchWord.asOf.format(clock.label(record.readAtMs))
            )
        }
    }

    // MARK: Cheap power

    /// A stretch of cheap power, for the Smart Stack.
    public struct CheapWindow: Equatable, Sendable, Identifiable {
        public let startMs: Double
        public let endMs: Double
        public let meanMinor: Double
        /// "02–04"
        public let range: String
        /// "28,5 öre"
        public let price: String
        public var id: Double { startMs }
    }

    /// The cheapest two hours left in each day the prices cover, when they
    /// stand out from the rest of that day: today from now on, as the price
    /// page says it, and tomorrow whole.
    public static func cheapWindows(_ entry: PriceEntry?, nowMs: Double) -> [CheapWindow] {
        guard let entry else { return [] }
        let zone = entry.timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
        let clock = ZoneClock.of(zone)
        let slots = entry.prices.slots.filter { $0.totalMinor.isFinite }.sorted { $0.startMs < $1.startMs }
        let ahead = slots.filter { $0.startMs + $0.durationMs > nowMs }
        let days = Dictionary(grouping: ahead) { clock.calendar.startOfDay(for: Date(timeIntervalSince1970: $0.startMs / 1000)) }
        var out = [CheapWindow]()
        for day in days.keys.sorted() {
            let daySlots = days[day] ?? []
            guard daySlots.count >= 2, let block = PriceStrip.bestBlock(daySlots, hours: 2, cheapest: true) else { continue }
            let mean = daySlots.map(\.totalMinor).reduce(0, +) / Double(daySlots.count)
            guard block.meanMinor < mean * PlanGlance.cheapShare || block.meanMinor < 0 else { continue }
            let currency = entry.prices.currency
            out.append(CheapWindow(
                startMs: block.startMs,
                endMs: block.endMs,
                meanMinor: block.meanMinor,
                range: "\(clock.label(block.startMs))–\(clock.label(block.endMs))",
                price: "\(Words.decimal(PriceStrip.text(block.meanMinor, currency))) \(PriceUnits.unit(currency).label)"
            ))
        }
        return out
    }

    // MARK: Complications

    /// One complication entry: the dial, the battery's level while it is
    /// recent enough to show, and the plan and the price in words.
    public struct Face: Equatable, Sendable {
        public let atMs: Double
        public let dial: PlanDial?
        public let batteryPct: Double?
        public let plan: PlanGlance.Moment
        public let price: PriceGlance.Moment
    }

    /// Entries for the plan complication: one now and one each quarter hour
    /// ahead while the plan or the prices reach, at most a day.
    public static func faces(plan: CacheRead<PlanEntry>?, prices: CacheRead<PriceEntry>?, now: CacheRead<WatchNow>?, nowMs: Double) -> [Face] {
        let ends = [plan?.value.battery?.map { $0.startMs + $0.durationMs }.max(), prices?.value.prices.slots.map { $0.startMs + $0.durationMs }.max()].compactMap { $0 }
        let until = min(nowMs + 24 * 3_600_000, ends.max() ?? nowMs)
        var times = [nowMs]
        var t = (nowMs / PlanDial.quarterMs).rounded(.down) * PlanDial.quarterMs + PlanDial.quarterMs
        while t < until {
            times.append(t)
            t += PlanDial.quarterMs
        }
        let level = now?.value.reading(.battery)?.levelPct
        return times.map { at in
            Face(
                atMs: at,
                dial: plan == nil && prices == nil ? nil : PlanDial(plan: plan?.value, prices: prices?.value, nowMs: at),
                batteryPct: now.flatMap { at - $0.record.readAtMs <= levelForMs ? level : nil },
                plan: PlanGlance.moment(plan, atMs: at),
                price: PriceGlance.moment(prices, atMs: at)
            )
        }
    }
}
