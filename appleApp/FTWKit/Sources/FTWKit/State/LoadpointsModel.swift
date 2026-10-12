import Foundation
import FTWShared
import Observation

/// The car view. Everything on it is a fact the box served; the controls
/// express intent and the box decides. Each command is followed from the
/// tap to the box's answer and stays on screen, and after any outcome the
/// charger is read again, because the box's account is the truth to
/// repaint from.
///
/// No timer asks the box. The chargers are read when a screen that shows
/// them appears, after a command, when the stream says the car started or
/// stopped drawing power, and when the stream comes back. Until the box
/// streams charger state (M5), that is all.
@Observable
@MainActor
public final class LoadpointsModel: Activatable {
    public enum GoalSave: Equatable, Sendable {
        case saving
        case saved
        case removed
        case failed(String)
    }

    public private(set) var points: [Loadpoint] = []
    public private(set) var windows: [String: [Loadpoint.Window]] = [:]
    public private(set) var planMissing = false
    public private(set) var loading = false
    /// Whether the box has ever answered. No answer is not an empty bay.
    public private(set) var loaded = false
    public private(set) var readAtMs: Double?
    public private(set) var error: String?
    /// The plan's shortfall per car, in battery watt-hours, read while the
    /// car view is open. Missing means the plan has no goal for that car.
    public private(set) var shortfallWh: [String: Double] = [:]
    public private(set) var shortfallReadAtMs: Double?
    /// The last level and the last charge command per charger, from the
    /// tap to the box's answer.
    public private(set) var levelStep: [String: EVText.Step] = [:]
    public private(set) var holdStep: [String: EVText.Step] = [:]
    public private(set) var goalSave: [String: GoalSave] = [:]
    /// A level tapped and not yet answered: what the view shows meanwhile.
    public private(set) var levelWanted: [String: Double] = [:]
    /// Levels set from this phone, kept while the car stays plugged in, so
    /// the view can say "you set it".
    public private(set) var levelSet: [String: EVText.LevelSet] = [:]
    /// What is on screen came from the phone's own cache, not the box. True
    /// from a cold start until the first read.
    public private(set) var fromCache = false

    @ObservationIgnored private unowned let site: SiteModel
    @ObservationIgnored private let charging: ChargingWatch?
    @ObservationIgnored private var ask: LiveAsk?
    @ObservationIgnored private var planAsk: LiveAsk?
    @ObservationIgnored private var active = 0
    @ObservationIgnored private var planWatchers = 0
    @ObservationIgnored private var token = 0
    @ObservationIgnored private var inlinePlan = false
    @ObservationIgnored private var reading: Task<Void, Error>?
    @ObservationIgnored private var levelSending: Set<String> = []
    @ObservationIgnored private var clearing: [String: Cancellable] = [:]
    /// Bumped by each appearance and by `reread`: a new reason to ask.
    @ObservationIgnored private var visits = 0

    /// `cache` is what the app left for its widgets; a cold start paints the
    /// car from it before the box has answered. Nil in the demo and tests.
    public init(site: SiteModel, charging: ChargingWatch?, cache: CacheReader? = CacheReader.shared()) {
        self.site = site
        self.charging = charging
        if let siteId = site.siteId, let read = cache?.read(CarEntry.self, siteId: siteId) {
            points = read.value.cars.map { Self.loadpoint($0, readAtMs: read.record.readAtMs) }
            readAtMs = read.record.readAtMs
            fromCache = true
        }
    }

    /// A charger as the cache kept it: enough for the level, its source and
    /// age, the cable and the power. The goal and the plan wait for the box.
    static func loadpoint(_ car: CarEntry.Car, readAtMs: Double) -> Loadpoint {
        var w: [(String, JSON)] = [
            ("id", .string(car.loadpointID)),
            ("plugged_in", .bool(car.pluggedIn)),
            ("soc_source", .string(car.socSource)),
            ("current_power_w", .number(car.powerW)),
        ]
        if let pct = car.socPct { w.append(("current_soc", .number(pct / 100))) }
        if let pct = car.targetSocPct { w.append(("target_soc", .number(pct / 100))) }
        if car.socSource == "vehicle", let at = car.socReadAtMs { w.append(("vehicle_soc_age_s", .number(max(0, readAtMs - at) / 1000))) }
        return Loadpoint(.object(w))
    }

    public func activate() {
        active += 1
        visits += 1
        if ask == nil {
            ask = LiveAsk(site: site, want: { [weak self] in
                guard let self, self.active > 0, self.site.documentVisible, self.site.hasPassthrough else { return nil }
                return "loadpoints \(self.visits) \(self.drawing)"
            }, ask: { [weak self] in try await self?.load() })
        }
        ask?.evaluate()
    }

    /// Whether the stream says a car is drawing power. A change is a reason
    /// to read the chargers; nothing else on lane 0 is.
    var drawing: String {
        guard let w = site.session.fields[Contract.FID.evW] else { return "-" }
        return w >= 100 ? "on" : "off"
    }

    public func deactivate() {
        active = max(0, active - 1)
        ask?.evaluate()
    }

    /// The car view is open: read the plan's shortfall too, once a minute
    /// and whenever the car's plan changes.
    public func watchPlan() {
        planWatchers += 1
        if planAsk == nil {
            planAsk = LiveAsk(site: site, want: { [weak self] in
                guard let self, self.planWatchers > 0, self.site.documentVisible, self.site.hasPassthrough, self.inlinePlan else { return nil }
                let goals = self.points.filter { $0.pluggedIn && $0.schedule != nil && !$0.planPending && !$0.planOutdated }
                guard !goals.isEmpty else { return nil }
                return "plan \(goals.map(Self.planKey).joined(separator: ","))"
            }, ask: { [weak self] in try await self?.readShortfall() })
        }
        planAsk?.evaluate()
    }

    public func unwatchPlan() {
        planWatchers = max(0, planWatchers - 1)
        planAsk?.evaluate()
    }

    /// What would make a shortfall read out of date for one car.
    static func planKey(_ lp: Loadpoint) -> String {
        let s = lp.schedule
        return "\(lp.id):\(lp.socPct ?? -1):\(s?.socPct ?? -1):\(s?.timeOfDayMinUTC ?? -1):\(lp.planWindows.count):\(Int(lp.planWindows.first?.fromMs ?? 0)):\(Int(lp.planTotalWh ?? 0))"
    }

    /// Out of date: from the cache, the read failed, or the stream stopped.
    /// An answer is not out of date for being minutes old: the stream would
    /// have said if the car started or stopped drawing.
    public var stale: Bool {
        fromCache || error != nil || site.session.phase != .streaming
    }

    /// Ask again now: pull to refresh, or the demo's cable.
    public func reread() {
        visits += 1
        ask?.evaluate()
    }

    // MARK: Reads

    public func loadChargers() async throws {
        if let reading {
            try await reading.value
            return
        }
        let task = Task { @MainActor in try await self.readChargers() }
        reading = task
        defer { reading = nil }
        try await task.value
    }

    private func readChargers() async throws {
        token += 1
        let mine = token
        loading = true
        defer { if mine == token { loading = false } }
        do {
            let wire = try await site.callBox(.get, "/api/loadpoints")
            guard mine == token else { return }
            let list = wire?["loadpoints"]?.array ?? []
            let before = Dictionary(points.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            points = list.map(Loadpoint.init)
            for lp in points {
                // A level set here belongs to one plug-in.
                let was = before[lp.id]
                if !lp.pluggedIn || (was.map { lp.sessionWh + 100 < $0.sessionWh } ?? false) { levelSet[lp.id] = nil }
            }
            inlinePlan = !points.isEmpty && points.allSatisfy(\.inlinePlan)
            if inlinePlan {
                windows = Dictionary(uniqueKeysWithValues: points.map { ($0.id, $0.planWindows) })
                planMissing = false
            }
            loaded = true
            fromCache = false
            readAtMs = site.scheduler.nowMs
            error = nil
            site.shareCars(points, fresh: true)
            planAsk?.evaluate()
        } catch {
            guard mine == token else { return }
            if let e = error as? BoxAPIError, points.isEmpty {
                self.error = e.help
            } else {
                self.error = AppWords.text("Not up to date — your box is out of reach")
            }
            throw error
        }
    }

    /// The chargers, then the plan's windows for a box that reports them
    /// separately. A failed plan read is a note, not a failure.
    public func load() async throws {
        try await loadChargers()
        if inlinePlan { return }
        let mine = token
        do {
            let wire = try await site.callBox(.get, "/api/mpc/plan")
            guard mine == token else { return }
            let pending = wire?["meta"]?["replanning"]?.bool == true || wire?["meta"]?["outdated"]?.bool == true
            let actions = wire?["plan"]?["actions"]?.array ?? []
            var out = [String: [Loadpoint.Window]]()
            for lp in points {
                out[lp.id] = pending || lp.planPending || lp.planOutdated ? [] : Self.chargeWindows(actions, loadpointID: lp.id)
            }
            windows = out
            takeShortfall(wire, pending: pending)
            planMissing = false
        } catch {
            guard mine == token else { return }
            planMissing = true
        }
    }

    private func readShortfall() async throws {
        let wire = try await site.callBox(.get, "/api/mpc/plan")
        takeShortfall(wire, pending: wire?["meta"]?["replanning"]?.bool == true || wire?["meta"]?["outdated"]?.bool == true)
    }

    /// A plan being remade says nothing about whether the car makes it.
    private func takeShortfall(_ wire: JSON?, pending: Bool) {
        var out = [String: Double]()
        if !pending {
            for (id, wh) in wire?["plan"]?["loadpoint_shortfall_wh"]?.object ?? [] {
                if let v = wh.number, v.isFinite { out[id] = max(0, v) }
            }
        }
        shortfallWh = out
        shortfallReadAtMs = site.scheduler.nowMs
    }

    /// Adjacent charging slots fold into one window; a person asks when it
    /// will charge, not when the reason changes.
    static func chargeWindows(_ actions: [JSON], loadpointID: String) -> [Loadpoint.Window] {
        var out = [Loadpoint.Window]()
        for a in actions {
            guard let start = a["slot_start_ms"]?.number, let len = a["slot_len_min"]?.number,
                  let w = a["loadpoint_power_w"]?[loadpointID]?.number, w > 0 else { continue }
            let end = start + len * 60_000
            let wh = w * len / 60
            if var last = out.last, start <= last.toMs {
                last.toMs = end
                last.peakW = max(last.peakW ?? 0, w)
                last.energyWh = (last.energyWh ?? 0) + wh
                out[out.count - 1] = last
            } else {
                out.append(Loadpoint.Window(fromMs: start, toMs: end, peakW: w, energyWh: wh))
            }
        }
        return out
    }

    // MARK: The level

    /// The level a person tapped. It goes to the box at once; taps made
    /// while one is on its way are folded into the next send, so ±5 pressed
    /// three times sends the last value, not three.
    public func setLevel(_ lp: Loadpoint, pct: Double) async {
        let id = lp.id
        levelWanted[id] = min(100, max(0, pct.rounded()))
        guard !levelSending.contains(id) else { return }
        levelSending.insert(id)
        defer { levelSending.remove(id) }
        var sent: Double?
        while let want = levelWanted[id], want != sent {
            sent = want
            await follow(id, .level(want), op: Contract.opLoadpointSocSet, args: [("id", .text(id)), ("soc", .number(want / 100))], into: \.levelStep, tag: "level")
            if case .applied(let seen)? = levelStep[id]?.result {
                levelSet[id] = EVText.LevelSet(pct: seen.map { ($0 * 100).rounded() } ?? want, atMs: site.scheduler.nowMs)
            }
            if levelWanted[id] == want {
                // Settled and nothing newer: the box's own reading takes over.
                try? await loadChargers()
                if levelWanted[id] == want { levelWanted[id] = nil }
            }
        }
    }

    /// The level to show: the box's account. A tap on its way shows as the
    /// chosen chip and the receipt, never as the level: only the box's
    /// answer moves the number. Between its answer and the next read, the
    /// level it confirmed is the newest fact.
    public func level(_ lp: Loadpoint) -> EVText.Level? {
        let set = levelSet[lp.id]
        guard var level = EVText.level(lp, answeredAtMs: readAtMs ?? site.nowMs, nowMs: site.nowMs, set: set) else { return nil }
        if let set, (readAtMs ?? 0) < set.atMs {
            level = EVText.Level(pct: set.pct, origin: .you, atMs: set.atMs, setPct: nil)
        }
        return level
    }

    /// The chip to show as chosen: the tap on its way, else the level.
    public func chosenLevel(_ lp: Loadpoint) -> Double? {
        levelWanted[lp.id] ?? level(lp)?.pct
    }

    // MARK: Charge now, Pause, Back to the plan

    /// Charge now: the charger's full current, held until Back to the plan
    /// or an unplug. No time limit and no level gate: the level is often a
    /// guess, and a guess must not lock the owner out (Fredrik, 4 Sep 2026).
    public func chargeNow(_ lp: Loadpoint) async {
        let range = EVText.current(lp)
        await hold(lp, .chargeNow, [("id", .text(lp.id)), ("power_w", .number(EVText.watts(lp, amps: range.maxA))), ("hold_s", .int(0)), ("phase_mode", .text(range.phases == 1 ? "1p" : "3p"))])
    }

    /// A zero hold: the charger stays off until the owner chooses.
    public func pause(_ lp: Loadpoint) async {
        await hold(lp, .pause, [("id", .text(lp.id)), ("power_w", .int(0)), ("hold_s", .int(0))])
    }

    /// Release the hold; the plan takes back over.
    public func backToPlan(_ lp: Loadpoint) async {
        await hold(lp, .resume, [("id", .text(lp.id)), ("clear", .bool(true))])
    }

    private func hold(_ lp: Loadpoint, _ ask: EVText.Step.Ask, _ args: [(String, CBOR)]) async {
        if let step = holdStep[lp.id], !step.settled { return }
        await follow(lp.id, ask, op: Contract.opLoadpointHold, args: args, into: \.holdStep, tag: "hold")
        try? await loadChargers()
        charging?.refresh()
    }

    /// One command, written into `into` at every stage: sent, received,
    /// and what the box did or why not.
    private func follow(_ id: String, _ ask: EVText.Step.Ask, op: String, args: [(String, CBOR)], into path: ReferenceWritableKeyPath<LoadpointsModel, [String: EVText.Step]>, tag: String) async {
        let key = "\(tag) \(id)"
        clearing[key]?.cancel()
        self[keyPath: path][id] = EVText.Step(ask: ask)
        let result: EVText.Step.Result
        do {
            let r = try await site.core.command(op, args: args, onAck: { [weak self] in
                guard let self, self[keyPath: path][id]?.ask == ask else { return }
                self[keyPath: path][id]?.acked = true
            })
            switch r.state {
            case .applied: result = .applied(observed: r.observedValue)
            case .superseded: result = .superseded(observed: r.observedValue)
            case .unconfirmed: result = .unconfirmed(note: r.errorCode == nil ? nil : EVText.refusal(r))
            case .rejected, .expired: result = .refused(EVText.refusal(r))
            }
            self[keyPath: path][id]?.acked = true
        } catch {
            result = .refused(EVText.failure(error))
        }
        guard self[keyPath: path][id]?.ask == ask else { return }
        self[keyPath: path][id]?.result = result
        // A success fades once the screen shows its effect; a refusal stays
        // until the next tap.
        if case .applied = result {
            clearing[key] = site.scheduler.after(Self.doneShownMs) { [weak self] in
                guard let self, self[keyPath: path][id]?.result == result else { return }
                self[keyPath: path][id] = nil
            }
        }
    }

    static let doneShownMs: Double = 20_000

    // MARK: The goal

    /// Save a goal in one PUT. The ready time goes as the household clock
    /// and as today's UTC minute: a box that reads the clock takes it, an
    /// older one reads the minute on today's date, as Core does.
    public func saveGoal(_ lp: Loadpoint, socPct: Double, clock: Int, recurring: Bool, days: Int, zone: TimeZone) async {
        guard (0..<1440).contains(clock) else { goalSave[lp.id] = .failed(AppWords.text("Choose a valid ready time.")); return }
        guard (10...100).contains(socPct) else { goalSave[lp.id] = .failed(AppWords.text("Choose a charge target from 10 to 100 %.")); return }
        guard !recurring || days & 0x7f != 0 else { goalSave[lp.id] = .failed(AppWords.text("Choose at least one day.")); return }
        let minuteUTC = EVText.minuteUTC(clock: clock, at: Date(timeIntervalSince1970: site.nowMs / 1000), zone: zone)
        let mask = !recurring || days & 0x7f == 0x7f ? 0 : days & 0x7f
        goalSave[lp.id] = .saving
        do {
            _ = try await site.callBox(.put, "/api/loadpoints/\(Self.escape(lp.id))/schedule", body: [
                "soc": .number(socPct / 100),
                "time_of_day_min": .number(Double(clock)),
                "time_of_day_min_utc": .number(Double(minuteUTC)),
                "recurring": .bool(recurring),
                "days": .number(Double(mask)),
                "surplus_unlock_bat_soc": .number((lp.schedule?.surplusUnlockPct ?? 0) / 100),
            ])
            goalSave[lp.id] = .saved
        } catch let e as BoxAPIError {
            goalSave[lp.id] = .failed(e.help)
        } catch {
            goalSave[lp.id] = .failed(AppWords.text("That did not go through. Try again."))
        }
        try? await loadChargers()
        charging?.refresh()
    }

    public func removeGoal(_ lp: Loadpoint) async {
        goalSave[lp.id] = .saving
        do {
            _ = try await site.callBox(.delete, "/api/loadpoints/\(Self.escape(lp.id))/schedule")
            // The DELETE confirms the removal even if the reread fails.
            if let i = points.firstIndex(where: { $0.id == lp.id }) {
                points[i].schedule = nil
                points[i].targetSocPct = nil
            }
            goalSave[lp.id] = .removed
        } catch let e as BoxAPIError {
            goalSave[lp.id] = .failed(e.help)
        } catch {
            goalSave[lp.id] = .failed(AppWords.text("That did not go through. Try again."))
        }
        try? await loadChargers()
        charging?.refresh()
    }

    public static func goalText(_ save: GoalSave) -> String {
        switch save {
        case .saving: return AppWords.text("Saving the goal…")
        case .saved: return AppWords.text("Goal saved. FTW is updating the plan.")
        case .removed: return AppWords.text("Goal removed.")
        case .failed(let help): return help
        }
    }

    static func escape(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id
    }

    // MARK: What the view shows

    /// The household zone, from the box's hello.
    public var zone: TimeZone { EVText.householdZone(boxTZ: site.session.box?.tz) }

    public func readiness(_ lp: Loadpoint) -> EVText.Readiness? {
        EVText.readiness(lp, level: level(lp), shortfallWh: shortfallWh[lp.id], nowMs: site.nowMs, zone: zone)
    }

    public func outcome(level lp: Loadpoint) -> EVText.Outcome? {
        levelStep[lp.id].map { EVText.outcome($0, lp) }
    }

    public func outcome(hold lp: Loadpoint) -> EVText.Outcome? {
        holdStep[lp.id].map { EVText.outcome($0, lp) }
    }

    public func holdSending(_ lp: Loadpoint) -> Bool {
        holdStep[lp.id].map { !$0.settled } ?? false
    }
}
