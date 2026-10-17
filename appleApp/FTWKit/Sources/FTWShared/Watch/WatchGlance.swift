import Foundation

/// What each watch screen says, worked out from the records alone, so the
/// app, its complications and a test agree.
///
/// Light means live, on the wrist too. A reading glows only when it came
/// from the phone as a live frame (`WatchNews.now`) a moment ago, over a
/// live carrier with its own source live. Everything read from the
/// context or the watch's cache is ink, with the time it was read.
public enum WatchGlance {
    /// The least time a forwarded frame stays lit after it arrived: the
    /// relay's gap rule (3.5 s), with room for the hop from the phone.
    /// `Glow` lengthens it to the stream's own pace.
    public static let liveForMs: Double = 4_000
    /// How long a complication shows the battery's level after the phone
    /// read it. Past this the level may have moved, and the centre is
    /// left empty.
    public static let levelForMs: Double = 15 * 60_000

    // MARK: Now

    /// Whether Now is live at `nowMs`. `arrivedAtMs` is when the frame
    /// reached the watch, by the watch's clock; nil for a record from the
    /// context or the cache, which never glows. `forMs` is how long a frame
    /// stays lit, from `Glow`.
    public static func lit(_ record: CacheRecord<WatchNow>?, arrivedAtMs: Double?, forMs: Double = liveForMs, nowMs: Double) -> Bool {
        guard let record, let arrivedAtMs else { return false }
        guard record.carrier.connected, record.srcState == .live else { return false }
        return nowMs - arrivedAtMs >= -1_000 && nowMs - arrivedAtMs <= forMs
    }

    /// How long a live frame stays lit on the wrist: as long as the phone
    /// itself counts it live (`WatchNow.standsMs`), and at least about 2.5
    /// of the stream's last intervals, each with the hop from the phone,
    /// never less than `liveForMs`. A stream at 1 Hz stays lit through a
    /// late frame; one at 0.2 Hz from a phone in a pocket does not blink
    /// between frames. A real silence still goes dark: the interval counted
    /// is at most `longestMs`, so without the phone's word no frame stays
    /// lit longer than `longestForMs`.
    public struct Glow: Equatable, Sendable {
        /// The phone's own pace, from the times it read the last two frames.
        public private(set) var intervalMs: Double?
        /// The phone's own word for how long the last frame stands.
        public private(set) var standsMs: Double?
        private var lastReadAtMs: Double?

        public static let hopMs: Double = 1_000
        public static let longestMs: Double = 6_000
        public static var longestForMs: Double { 2.5 * longestMs + hopMs }

        public init() {}

        /// A live frame, read by the phone at `readAtMs`.
        public mutating func frame(readAtMs: Double, standsMs: Double? = nil) {
            if let last = lastReadAtMs, readAtMs > last { intervalMs = min(readAtMs - last, Self.longestMs) }
            lastReadAtMs = max(readAtMs, lastReadAtMs ?? readAtMs)
            self.standsMs = standsMs
        }

        /// The stream stopped, or the watch looked away: the next frame
        /// starts a new pace.
        public mutating func reset() {
            self = Glow()
        }

        public var forMs: Double {
            let pace = intervalMs.map { 2.5 * $0 + Self.hopMs } ?? 0
            let phone = standsMs.map { $0 + Self.hopMs } ?? 0
            return max(WatchGlance.liveForMs, pace, phone)
        }
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
        /// Which way the battery or the grid runs, for the mark on its
        /// glyph: up while it stores or the home buys, down while it gives
        /// or sells, as the trace draws them. Nil for the rest, and at rest.
        public let direction: Direction?
        public var id: WatchNow.Node { node }
    }

    public enum Direction: Sendable, Equatable { case up, down }

    /// Below this a node rests: the threshold Now uses for a beam.
    public static let restW: Double = 42

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
                lit: lit && r.live,
                direction: direction(r.node, r.way)
            )
        }
    }

    public static func direction(_ node: WatchNow.Node, _ way: WatchNow.Way) -> Direction? {
        guard node == .battery || node == .grid else { return nil }
        switch way {
        case .charging, .buying: return .up
        case .giving, .selling: return .down
        default: return nil
        }
    }

    /// The reading under a finger on the trace, as the large figure says
    /// it: its value and the word for its direction. Never lit: it is a
    /// moment past, under the finger.
    public static func figure(_ node: WatchNow.Node, at sample: LiveSample) -> Figure {
        let watts = abs(sample.v)
        let way = way(node, signedW: sample.v)
        let parts = PowerFormat.parts(watts)
        return Figure(node: node, title: title(node), value: Words.decimal(parts.text), unit: parts.unit, word: word(way), level: nil, lit: false, direction: direction(node, way))
    }

    /// The word for a signed reading of `node`, as the trace draws it.
    public static func way(_ node: WatchNow.Node, signedW v: Double) -> WatchNow.Way {
        let resting = abs(v) <= restW
        switch node {
        case .solar: return resting ? .resting : .making
        case .battery: return resting ? .resting : (v > 0 ? .charging : .giving)
        case .home: return .using
        case .grid: return resting ? .balanced : (v > 0 ? .buying : .selling)
        case .car: return resting ? .resting : .charging
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

    /// The mono line at the top of Now, in the phone's words and in the
    /// watch's short form: `● LIVE · FTW IN CONTROL`, `○ 07:00 · FTW IN
    /// CONTROL`. It never counts seconds and never says "as of": a hollow
    /// ring and the minute the reading was read are the age. For its time
    /// after a change of mode, the box's receipt takes the line:
    /// `SENT ▸ ACCEPTED ▸`, then `SENT ▸ CONFIRMED`.
    public struct Status: Equatable, Sendable {
        public enum Tone: Equatable, Sendable { case ink, live, alarm }

        public struct Part: Equatable, Sendable {
            public let text: String
            public let tone: Tone
        }

        public let lit: Bool
        public let parts: [Part]

        /// The line as one string, for VoiceOver and as its identity.
        public var text: String { parts.map(\.text).joined(separator: " · ") }
        /// Some part of it is a warning.
        public var alarm: Bool { parts.contains { $0.tone == .alarm } }
    }

    /// How long a settled receipt keeps the line, as on the phone.
    public static let receiptShownMs: Double = 4_000

    public static func status(_ record: CacheRecord<WatchNow>?, lit: Bool, demo: Bool, zone: TimeZone, receipt: WatchReceipt? = nil) -> Status {
        typealias Part = Status.Part
        if let receipt { return Status(lit: lit, parts: receiptParts(receipt)) }
        guard let record else { return Status(lit: false, parts: [Part(text: WatchWord.noReadingYet.text, tone: .ink)]) }
        var parts = [Part]()
        if lit {
            parts.append(Part(text: demo ? WatchWord.demo.text : WatchWord.live.text, tone: .ink))
        } else {
            parts.append(Part(text: ZoneClock.of(zone).label(record.readAtMs), tone: .ink))
        }
        switch record.value.control {
        case .inControl: parts.append(Part(text: WatchWord.inControl.text, tone: .ink))
        case .notInControl: parts.append(Part(text: WatchWord.notInControl.text, tone: .alarm))
        case .unknown: break
        }
        return Status(lit: lit, parts: parts)
    }

    /// A command's receipt in the status line's words: how far the box has
    /// come, never a mark the box has not given.
    static func receiptParts(_ r: WatchReceipt) -> [Status.Part] {
        let sent = ReceiptLog.word(.sent) + " ▸"
        switch r.tone {
        case .done:
            return [Status.Part(text: "\(sent) \(ReceiptLog.word(.confirmed))", tone: .live)]
        case .failed:
            let word = r.sent == .failed ? WatchWord.notSent.text : "▲ " + ReceiptLog.refusedWord
            return [Status.Part(text: word, tone: .alarm)]
        case .warning:
            return [Status.Part(text: WatchWord.notConfirmed.text, tone: .alarm)]
        case .working:
            if r.accepted == .done { return [Status.Part(text: "\(sent) \(ReceiptLog.word(.accepted)) ▸", tone: .ink)] }
            if r.sent == .done { return [Status.Part(text: sent, tone: .ink)] }
            return [Status.Part(text: WatchWord.sending.text, tone: .ink)]
        }
    }

    /// The longest ordinary line in the phone's language, in characters,
    /// so the watch can set one size that holds it on every screen: "07:00
    /// · FTW IN CONTROL" in English, "SKICKAT ▸ MOTTAGET ▸" in Swedish. A
    /// warning may run longer and take a second line.
    public static var statusChars: Int {
        let readings = [WatchWord.live.text, WatchWord.demo.text, "00:00"].map { "\($0) · \(WatchWord.inControl.text)" }
        let sent = ReceiptLog.word(.sent) + " ▸"
        let receipts = [WatchWord.sending.text, sent, "\(sent) \(ReceiptLog.word(.accepted)) ▸", "\(sent) \(ReceiptLog.word(.confirmed))"]
        return (readings + receipts + [WatchWord.noReadingYet.text]).map(\.count).max() ?? 22
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
        /// On a box that keeps cars: the car, its name, and where its level
        /// comes from and how old it is ("from the car · 1 h ago").
        public var carID: String? = nil
        public var name: String? = nil
        public var origin: String? = nil
        public var id: String { carID ?? loadpointID }

        /// The page's shape, drawn redacted while nothing is known. Never
        /// shown as a car.
        public static let shape = Car(loadpointID: "", levelPct: 50, cells: 5, levelText: "50 %", state: WatchWord.pluggedIn.text, holding: false, pluggedIn: true, goal: WatchWord.goal.format("80 %"), next: nil, asOf: WatchWord.asOf.format("00:00"))
    }

    public static func cars(_ record: CacheRecord<CarEntry>?, plan: PlanEntry?, nowMs: Double, zone: TimeZone) -> [Car] {
        guard let record else { return [] }
        let clock = ZoneClock.of(zone)
        func state(_ c: CarEntry.Car?) -> String {
            guard let c else { return WatchWord.notPluggedIn.text }
            if c.holding == true { return WatchWord.chargeNowOn.text }
            if c.pluggedIn, c.powerW > PlanGlance.idleW { return WatchWord.chargingAt.format(Words.decimal(PowerFormat.text(c.powerW))) }
            return c.pluggedIn ? WatchWord.pluggedIn.text : WatchWord.notPluggedIn.text
        }
        func next(_ loadpointID: String) -> String? {
            let window = plan?.charges
                .filter { $0.loadpointID == loadpointID && $0.toMs > nowMs }
                .min { $0.fromMs < $1.fromMs }
            return window.map { w in
                WatchWord.chargesAt.format("\(w.fromMs <= nowMs ? PlanWord.nowLower.text : clock.label(w.fromMs))–\(clock.label(w.toMs))")
            }
        }
        func cells(_ pct: Double?) -> Int? { pct.map { min(10, max(0, Int(($0 / 10).rounded(.down)))) } }
        let asOf = WatchWord.asOf.format(clock.label(record.readAtMs))
        func charger(_ c: CarEntry.Car) -> Car {
            let assumed = c.socSource == "assumed"
            let level = c.socPct.map { PlanGlance.percent($0) }
            var car = Car(
                loadpointID: c.loadpointID,
                levelPct: c.socPct,
                cells: cells(c.socPct),
                levelText: level.map { assumed ? WatchWord.levelAssumed.format($0) : $0 },
                state: state(c),
                holding: c.holding == true,
                pluggedIn: c.pluggedIn,
                goal: c.targetSocPct.map { WatchWord.goal.format(PlanGlance.percent($0)) },
                next: next(c.loadpointID),
                asOf: asOf
            )
            car.name = c.carName
            return car
        }
        // A box that keeps cars: each of the owner's cars, plugged in or not,
        // with its own level and how old it is, then each plugged-in charger
        // whose car the box cannot name, so Charge now still reaches a
        // visitor. Until the list is read, the chargers as before.
        guard let owned = record.value.owned, !owned.isEmpty else { return record.value.cars.map(charger) }
        let cars = owned.map { o in
            let on = o.loadpointID.flatMap { id in record.value.cars.first { $0.loadpointID == id } }
            let level = o.socPct.map { PlanGlance.percent($0) }
            let shown = level.map { o.socEstimate ? WatchWord.estimated.format($0) : $0 }
            let origin: String?
            switch o.source {
            case _ where o.socPct == nil: origin = nil
            case CarSource.assumed: origin = WatchWord.assumedAtPlugIn.text
            case CarSource.vehicle, CarSource.manual:
                let age = o.socReadAtMs.map { PowerFormat.age(max(0, nowMs - $0) < 60_000 ? 0 : (max(0, nowMs - $0) / 60_000).rounded(.down) * 60_000) }
                origin = age.map { (o.source == CarSource.vehicle ? WatchWord.fromCar : WatchWord.setByHand).format($0) }
            default: origin = nil
            }
            var car = Car(
                loadpointID: o.loadpointID ?? "",
                levelPct: o.socPct,
                cells: cells(o.socPct),
                levelText: shown,
                state: state(on),
                holding: on?.holding == true,
                pluggedIn: on?.pluggedIn == true,
                goal: o.targetSocPct.map { WatchWord.goal.format(PlanGlance.percent($0)) },
                next: o.loadpointID.flatMap(next),
                asOf: asOf
            )
            car.carID = o.id
            car.name = o.name
            car.origin = origin
            return car
        }
        let named = Set(owned.compactMap(\.loadpointID))
        return cars + record.value.cars.filter { $0.pluggedIn && $0.carID == nil && !named.contains($0.loadpointID) }.map(charger)
    }

    /// A car's level sources as `CarEntry.Owned` carries them: the registry's
    /// `car_soc_sources`, held to it by a test in FTWKit.
    public enum CarSource {
        public static let vehicle = "vehicle"
        public static let manual = "manual"
        public static let assumed = "assumed"
        public static let all = [vehicle, manual, assumed]
    }

    /// A charger that asks which car is on it, with the cars one tap may
    /// pick.
    public struct Asking: Equatable, Sendable, Identifiable {
        public let loadpointID: String
        public let session: String
        public let choices: [CarEntry.Asking.Choice]
        /// The phone read it live, or else when: "AS OF 14:05".
        public let live: Bool
        public let asOf: String
        public var id: String { loadpointID }
    }

    public static func asking(_ record: CacheRecord<CarEntry>?, zone: TimeZone = .current) -> [Asking] {
        guard let record else { return [] }
        let live = record.carrier.connected && record.srcState == .live
        let asOf = WatchWord.asOf.format(ZoneClock.of(zone).label(record.readAtMs))
        return (record.value.asking ?? []).filter { !$0.session.isEmpty && !$0.choices.isEmpty }.map {
            Asking(loadpointID: $0.loadpointID, session: $0.session, choices: $0.choices, live: live, asOf: asOf)
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
        /// "29": the price in whole units, for a slot with room for one
        /// figure.
        public let short: String
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
                price: "\(Words.decimal(PriceStrip.text(block.meanMinor, currency))) \(PriceUnits.unit(currency).label)",
                short: "\(Int(PriceUnits.display(block.meanMinor, currency).rounded()))"
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
