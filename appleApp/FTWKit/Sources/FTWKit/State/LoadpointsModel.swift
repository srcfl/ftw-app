import Foundation
import FTWShared
import Observation

/// Where Charge now shows outside the app: the Live Activity and the
/// Control. The app supplies one built on ActivityKit and WidgetKit; a test
/// supplies a fake. `home` keeps one home's Live Activity apart from
/// another's, and from the demo's.
@MainActor
public protocol ChargeNowHost: AnyObject {
    func current(home: String, loadpointID: String) -> ChargeNowActivity.State?
    func apply(_ action: ChargeNowActivity.Action, home: String, loadpointID: String, zone: TimeZone)
    /// The chargers with a Live Activity up in one home.
    func loadpointIDs(home: String) -> [String]
    /// End every Live Activity except `home`'s; nil ends them all.
    func endAll(except home: String?)
    /// The box's account of Charge now changed and the App Group record
    /// holds it: the Control reads it again.
    func holdChanged()
}

/// The car view. Everything on it is a fact the box served; the controls
/// express intent and the box decides. Each command is followed from the
/// tap to the box's answer and stays on screen, and after any outcome the
/// charger is read again, because the box's account is the truth to
/// repaint from.
///
/// No timer asks the box. The chargers are read when a screen that shows
/// them appears, after a command, when the stream says the car started or
/// stopped drawing power, when FTW Cloud or a pushed plan says a cable went
/// in or out, when a pushed plan says the goal changed elsewhere, and when
/// the stream comes back. Each car's plan comes with
/// the plan the box pushes when it replans. A box whose plan comes without
/// chargers pushes none: it is read each quarter while a car is plugged in, and
/// every 15 s while it says its plan is being made or a cable just moved.
@Observable
@MainActor
public final class LoadpointsModel: Activatable {
    public enum GoalSave: Equatable, Sendable {
        case saving
        case saved
        case removed
        case failed(String)
    }

    /// The chargers as the box last described them, and when and how that
    /// reached this phone. The same chargers again change nothing.
    public private(set) var stamp: Stamped<[Loadpoint]>?
    public var points: [Loadpoint] { stamp?.value ?? [] }
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
    public var fromCache: Bool { stamp?.fromCache ?? false }

    /// The chargers and their plan, as the home file keeps them.
    public struct Chargers: Codable, Equatable, Sendable {
        public var points: [Loadpoint]
        public var windows: [String: [Loadpoint.Window]]
    }

    @ObservationIgnored private unowned let site: SiteModel
    @ObservationIgnored private var ask: LiveAsk?
    @ObservationIgnored private var activityAsk: LiveAsk?
    /// FTW Cloud's chargers as last taken, so they are taken once.
    @ObservationIgnored private var cloudTaken: Stamped<[CarEntry.Car]>?
    /// Charge now per charger as the last read found it, so the Control is
    /// told only when it changed.
    @ObservationIgnored private var lastHolding: [String: Bool] = [:]
    @ObservationIgnored private var planAsk: LiveAsk?
    @ObservationIgnored private var active = 0
    @ObservationIgnored private var planWatchers = 0
    @ObservationIgnored private var token = 0
    @ObservationIgnored private var inlinePlan = false
    @ObservationIgnored private var reading: Task<Void, Error>?
    @ObservationIgnored private var levelSending: Set<String> = []
    @ObservationIgnored private var clearing: [String: Cancellable] = [:]
    /// Bumped by `reread`: a person asked to look again.
    @ObservationIgnored private var rereads = 0
    /// Bumped when FTW Cloud or a pushed plan says a cable went in or out,
    /// or names a car this phone has not read: a reason to read the
    /// chargers once. A read itself never bumps it.
    @ObservationIgnored private var plugNews = 0 {
        didSet { plugNewsAtMs = site.scheduler.nowMs }
    }
    @ObservationIgnored private var plugNewsAtMs: Double?
    /// Bumped when a pushed plan says a charger's goal changed, wherever
    /// that was done: the schedule and target are read once.
    @ObservationIgnored private var goalNews = 0
    /// Each charger's goal revision as the last pushed plan gave it.
    @ObservationIgnored private var goalRevs: [String: UInt32] = [:]
    /// The plan whose chargers were last taken, so a pushed plan is taken
    /// once.
    @ObservationIgnored private var planTaken: Plan?
    /// Bumped each time a plan's chargers are taken. A read on the wire while
    /// one arrived does not put its older plan back.
    @ObservationIgnored private var planTakes = 0
    /// How long a read of the chargers stands when someone starts looking
    /// again. The stream says when a car starts or stops drawing; this
    /// covers a cable plugged in while nobody looked.
    nonisolated static let readStandsMs: Double = 60_000

    /// The Live Activity for Charge now. A test sets its own; otherwise the
    /// app's, which it installs at launch.
    @ObservationIgnored public var chargeNowHost: (any ChargeNowHost)?
    public static var sharedChargeNowHost: (any ChargeNowHost)?
    private var activityHost: (any ChargeNowHost)? { chargeNowHost ?? Self.sharedChargeNowHost }

    /// `cache` is what the app left for its widgets; a cold start paints the
    /// car from it before the box has answered. Nil in the demo and tests.
    public init(site: SiteModel, charging _: ChargingWatch?, cache: CacheReader? = CacheReader.shared(), chargeNowHost: (any ChargeNowHost)? = nil) {
        self.site = site
        self.chargeNowHost = chargeNowHost
        // A cold start paints the chargers as last read: from the sealed
        // home file, with their goals and windows, or else from the record
        // left for the widgets, whichever is newer.
        let shared = site.siteId.flatMap { cache?.read(CarEntry.self, siteId: $0) }
        if let kept = site.kept?.chargers, kept.asOfMs >= shared?.record.readAtMs ?? 0 {
            stamp = Stamped(kept.value.points, asOfMs: kept.asOfMs, origin: .cache)
            windows = kept.value.windows
            readAtMs = kept.asOfMs
        } else if let read = shared {
            stamp = Stamped(read.value.cars.map { Self.loadpoint($0, readAtMs: read.record.readAtMs) }, asOfMs: read.record.readAtMs, origin: .cache)
            readAtMs = read.record.readAtMs
        }
        site.keep { [weak self] home in
            guard let self, let stamp = self.stamp else { return }
            home.chargers = Stamped<Chargers>(Chargers(points: stamp.value, windows: self.windows), asOfMs: stamp.asOfMs, origin: stamp.origin)
        }
        site.observe { [weak self] in
            self?.takeCloud()
            self?.takePlan()
            self?.noticeDrawing()
        }
        // A Live Activity from another home, or from the demo, has no
        // business on this phone once this home is open.
        activityHost?.endAll(except: activityHome)
        // A Live Activity is only as good as the last read: when the stream
        // comes back while someone looks and the last read is over a
        // minute old, read the chargers once, so the Live Activity is
        // confirmed again or ended.
        activityAsk = LiveAsk(site: site, order: .loadpoints, ttlMs: Self.readStandsMs, want: { [weak self] in
            guard let self, self.site.documentVisible, self.site.hasPassthrough,
                  let host = self.activityHost, !host.loadpointIDs(home: self.activityHome).isEmpty else { return nil }
            return "live activity"
        }, ask: { [weak self] in try await self?.loadChargers() })
    }

    /// FTW Cloud's chargers, when they are newer than the box's last answer
    /// here. They carry the cable, the level and the power; the goal and
    /// the plan stay as the box last gave them.
    private func takeCloud() {
        guard let cloud = site.cloudCars, cloud != cloudTaken else { return }
        cloudTaken = cloud
        if let stamp, !stamp.fromCache, stamp.asOfMs >= cloud.asOfMs { return }
        let known = Dictionary(points.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if cloud.value.contains(where: { known[$0.loadpointID]?.pluggedIn != $0.pluggedIn }) { plugNews += 1 }
        let next = cloud.value.map { car -> Loadpoint in
            let fresh = Self.loadpoint(car, readAtMs: cloud.asOfMs)
            guard var lp = known[car.loadpointID] else { return fresh }
            lp.pluggedIn = fresh.pluggedIn
            lp.powerW = fresh.powerW
            lp.socPct = fresh.socPct
            lp.socSource = fresh.socSource
            lp.vehicleSocAgeS = fresh.vehicleSocAgeS
            if let target = fresh.targetSocPct { lp.targetSocPct = target }
            return lp
        }
        guard let taken = Stamped.taking(Stamped(next, asOfMs: cloud.asOfMs, origin: .cloud), over: stamp) else { return }
        stamp = taken
        readAtMs = taken.asOfMs
        ask?.evaluate()
    }

    /// A plan the box sent carries each car's share: its windows, its
    /// cable, whether a newer plan is being made, and its shortfall. Taken
    /// at once, without a read. A cable that moved, or a car this phone
    /// has not read, is read once for the rest of the car.
    func takePlan() {
        guard let plan = site.session.plan, plan != planTaken, let chargers = plan.chargers else { return }
        planTaken = plan
        planTakes += 1
        var nextWindows = windows
        var nextShortfall = shortfallWh
        var lps = points
        for car in chargers {
            // While the next plan is made, the box goes on with this one.
            nextWindows[car.id] = car.outdated && !car.pending ? [] : car.windows
            nextShortfall[car.id] = car.pending || car.outdated ? nil : car.shortfallWh
            if let rev = car.goalRev {
                if let seen = goalRevs[car.id], seen != rev { goalNews += 1 }
                goalRevs[car.id] = rev
            }
            guard let i = lps.firstIndex(where: { $0.id == car.id }) else {
                plugNews += 1
                continue
            }
            if lps[i].pluggedIn != car.pluggedIn { plugNews += 1 }
            lps[i].pluggedIn = car.pluggedIn
            Self.plan(&lps[i], from: car)
        }
        if nextWindows != windows { windows = nextWindows }
        if nextShortfall != shortfallWh { shortfallWh = nextShortfall }
        shortfallReadAtMs = site.scheduler.nowMs
        if let stamp, lps != stamp.value { self.stamp = Stamped(lps, asOfMs: stamp.asOfMs, origin: stamp.origin) }
        ask?.evaluate()
    }

    /// A charger's plan as the box pushed it.
    static func plan(_ lp: inout Loadpoint, from car: PlanCharger) {
        let gone = car.outdated && !car.pending
        lp.planPending = car.pending
        lp.planOutdated = car.outdated
        lp.planWindows = gone ? [] : car.windows
        lp.planTotalWh = gone ? nil : car.totalWh
        lp.planStartMs = lp.planWindows.first?.fromMs
        lp.planEndMs = lp.planWindows.first?.toMs
        lp.gridDeferred = car.gridDeferred
    }

    /// Whether this box pushes its plan, chargers and all, each time it
    /// replans: a plan with chargers has come.
    var boxPushesPlan: Bool { site.session.plan?.chargers != nil }

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
        if car.holding == true { w.append(("manual_active", .bool(true))) }
        if car.socSource == "vehicle", let at = car.socReadAtMs { w.append(("vehicle_soc_age_s", .number(max(0, readAtMs - at) / 1000))) }
        return Loadpoint(.object(w))
    }

    public func activate() {
        active += 1
        if ask == nil {
            ask = LiveAsk(site: site, order: .loadpoints, ttlMs: Self.readStandsMs, want: { [weak self] in
                guard let self, self.active > 0, self.site.documentVisible, self.site.hasPassthrough else { return nil }
                return "loadpoints \(self.rereads) \(self.drawing) \(self.plugNews) \(self.goalNews)\(self.unpushedPlan)"
            }, ask: { [weak self] in try await self?.load() })
        }
        ask?.evaluate()
    }

    /// For a box known to push no plan, because its plan came without
    /// chargers: the quarter while a car is plugged in, since the box replans
    /// each quarter, and every 15 s while it says the plan is being made or
    /// for a minute after a cable moved: such a box notices a cable within
    /// 10 s, or 40 s after a replan of its own, and then solves. Nothing until a plan has come,
    /// so a box that pushes never pays for the fallback.
    var unpushedPlan: String {
        guard let plan = site.session.plan, plan.chargers == nil else { return "" }
        let nowMs = site.nowMs
        let settling = plugNewsAtMs.map { nowMs - $0 < Self.plugSettleMs } ?? false
        if settling || points.contains(where: \.planPending) { return " pending \(Int(nowMs / Self.pendingAskMs))" }
        if points.contains(where: \.pluggedIn) { return " quarter \(Int(nowMs / 900_000))" }
        return ""
    }

    nonisolated static let pendingAskMs: Double = 15_000
    nonisolated static let plugSettleMs: Double = 60_000

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

    /// The car view is open: read the plan's shortfall too, whenever the
    /// car's plan changes. A box that pushes its plan sends the shortfall
    /// with it.
    public func watchPlan() {
        planWatchers += 1
        if planAsk == nil {
            planAsk = LiveAsk(site: site, order: .plan, want: { [weak self] in
                guard let self, self.planWatchers > 0, self.site.documentVisible, self.site.hasPassthrough, self.inlinePlan, !self.boxPushesPlan else { return nil }
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

    /// How fresh the chargers' figures are, as a node says it: live while
    /// this session's read stands, else stale and as old as the read.
    public var freshness: NodeFreshness {
        let age = readAtMs.map { max(0, site.nowMs - $0) }
        guard stale else { return NodeFreshness(carrier: site.carrier, srcState: .live, ageMs: age, sourceName: nil) }
        return NodeFreshness(carrier: fromCache ? .cache : site.carrier, srcState: .stale, ageMs: age, sourceName: nil)
    }

    /// Ask again now: pull to refresh, or the demo's cable.
    public func reread() {
        rereads += 1
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
        let takes = planTakes
        loading = true
        defer { if mine == token { loading = false } }
        do {
            let wire = try await site.callBox(.get, "/api/loadpoints")
            guard mine == token else { return }
            let list = wire?["loadpoints"]?.array ?? []
            let before = Dictionary(points.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let now = site.scheduler.nowMs
            // A plan pushed while this read was on the wire is at least as
            // new as the read's: its cable and its share of each charger stay.
            let pushed = planTakes != takes
            let read = list.map { json -> Loadpoint in
                var lp = Loadpoint(json)
                if pushed, let car = planTaken?.chargers?.first(where: { $0.id == lp.id }) {
                    lp.pluggedIn = car.pluggedIn
                    Self.plan(&lp, from: car)
                }
                return lp
            }
            if let taken = Stamped.taking(Stamped(read, asOfMs: now, origin: .relay), over: stamp) { stamp = taken }
            for lp in points {
                // A level set here belongs to one plug-in.
                let was = before[lp.id]
                if !lp.pluggedIn || (was.map { lp.sessionWh + 100 < $0.sessionWh } ?? false) { levelSet[lp.id] = nil }
            }
            inlinePlan = !points.isEmpty && points.allSatisfy(\.inlinePlan)
            if inlinePlan, !pushed {
                let next = Dictionary(uniqueKeysWithValues: points.map { ($0.id, $0.planWindows) })
                if next != windows { windows = next }
                if planMissing { planMissing = false }
            }
            if !loaded { loaded = true }
            readAtMs = now
            if error != nil { error = nil }
            site.shareCars(points, fresh: true)
            readOutside()
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
            if out != windows { windows = out }
            takeShortfall(wire, pending: pending)
            if planMissing { planMissing = false }
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
    public func chargeNow(_ lp: Loadpoint, cmdId: String? = nil) async {
        let range = EVText.current(lp)
        await hold(lp, .chargeNow, [("id", .text(lp.id)), ("power_w", .number(EVText.watts(lp, amps: range.maxA))), ("hold_s", .int(0)), ("phase_mode", .text(range.phases == 1 ? "1p" : "3p"))], cmdId: cmdId)
    }

    /// A zero hold: the charger stays off until the owner chooses.
    public func pause(_ lp: Loadpoint, cmdId: String? = nil) async {
        await hold(lp, .pause, [("id", .text(lp.id)), ("power_w", .int(0)), ("hold_s", .int(0))], cmdId: cmdId)
    }

    /// Release the hold; the plan takes back over.
    public func backToPlan(_ lp: Loadpoint, cmdId: String? = nil) async {
        await hold(lp, .resume, [("id", .text(lp.id)), ("clear", .bool(true))], cmdId: cmdId)
    }

    private func hold(_ lp: Loadpoint, _ ask: EVText.Step.Ask, _ args: [(String, CBOR)], cmdId: String? = nil) async {
        if let step = holdStep[lp.id], !step.settled { return }
        // Charge now shows outside the app as the receipt does inside it:
        // sent at once, received on the box's `cmd.ack`, on only once the
        // box confirms it.
        var acked: (@MainActor () -> Void)?
        if ask == .chargeNow {
            showChargeNow(lp.id, .sent(atMs: site.scheduler.nowMs))
            let id = lp.id
            acked = { [weak self] in
                guard let self else { return }
                self.showChargeNow(id, .received(atMs: self.site.scheduler.nowMs))
            }
        }
        await follow(lp.id, ask, op: Contract.opLoadpointHold, args: args, into: \.holdStep, tag: "hold", acked: acked, cmdId: cmdId)
        // The box's answer moves the Live Activity at once: the read below
        // can take a while.
        let result = holdStep[lp.id]?.ask == ask ? holdStep[lp.id]?.result : nil
        switch (ask, result) {
        case (.chargeNow, .applied?): showChargeNow(lp.id, .started(atMs: site.scheduler.nowMs))
        case (.chargeNow, .refused?), (.chargeNow, .superseded?): showChargeNow(lp.id, .refused)
        case (.resume, .applied?), (.pause, .applied?): showChargeNow(lp.id, .stopped)
        default: break
        }
        try? await loadChargers()
        // Taken and never confirmed: the charger's own account decides.
        if ask == .chargeNow, case .unconfirmed? = result {
            let now = points.first(where: { $0.id == lp.id })
            showChargeNow(lp.id, now.map(Self.holding) == true ? .started(atMs: readAtMs ?? site.scheduler.nowMs) : .refused)
        }
    }

    /// Whether Charge now is on for this charger, in the box's account. The
    /// box ends the hold when the car is unplugged; its flag says so.
    static func holding(_ lp: Loadpoint) -> Bool {
        lp.manualActive && !EVText.isPaused(lp)
    }

    /// MEASURED on the receipt: lane 0 shows the car doing what was asked,
    /// live, once the box has the command. Lane 0 has one car figure for
    /// every charger, so it lights the Live Activity only when the home has
    /// one up, and the car view's receipt only for a home with one charger.
    private func noticeDrawing() {
        let evW = site.session.fields[Contract.FID.evW]
        let live = site.isLive
        if ReceiptLog.measures(evW: evW, live: live), let host = activityHost {
            let ids = host.loadpointIDs(home: activityHome)
            if ids.count == 1 { showChargeNow(ids[0], .measured(atMs: site.scheduler.nowMs)) }
        }
        guard live, let evW, points.count == 1, let lp = points.first,
              let step = holdStep[lp.id], step.acked, !step.measured else { return }
        switch step.result {
        case .refused?, .superseded?: return
        case .applied?, .unconfirmed?, nil: break
        }
        let planned = (windows[lp.id] ?? lp.planWindows).contains { $0.fromMs <= site.nowMs && site.nowMs < $0.toMs }
        guard Self.measures(step.ask, evW: evW, planCharges: planned) else { return }
        holdStep[lp.id]?.measured = true
        // Its last slot has lit: a success fades a while after this.
        if case .applied? = step.result { fadeLater("hold \(lp.id)", \.holdStep, lp.id, afterMs: Self.doneShownMs) }
    }

    /// Whether lane 0's car power is what the command asked for: drawing
    /// for Charge now, still for Pause, and for Back to the plan whatever
    /// the plan says for this moment.
    nonisolated static func measures(_ ask: EVText.Step.Ask, evW: Double, planCharges: Bool) -> Bool {
        let drawing = evW > ReceiptLog.drawingW
        switch ask {
        case .chargeNow: return drawing
        case .pause: return !drawing
        case .resume: return drawing == planCharges
        case .level: return false
        }
    }

    /// The Live Activity's home key: the site, or the demo's own.
    public var activityHome: String { site.siteId ?? "demo" }

    /// A read of the chargers, as the Live Activity and the Control see it:
    /// a charger still holding confirms its Live Activity again, one that
    /// stopped or is gone ends it, and a change reaches the Control once
    /// the App Group record holds it.
    private func readOutside() {
        let at = readAtMs ?? site.scheduler.nowMs
        for lp in points { showChargeNow(lp.id, .seen(holding: Self.holding(lp), atMs: at)) }
        guard let host = activityHost else { return }
        for id in host.loadpointIDs(home: activityHome) where !points.contains(where: { $0.id == id }) {
            host.apply(.end, home: activityHome, loadpointID: id, zone: zone)
        }
        let holding = Dictionary(points.map { ($0.id, Self.holding($0)) }, uniquingKeysWith: { a, _ in a })
        guard holding != lastHolding else { return }
        lastHolding = holding
        Task { [site, weak host] in
            await site.flushShared()
            host?.holdChanged()
        }
    }

    /// Leaving this home: Exit demo or Remove this phone. No Live Activity
    /// of it may stay, because its button would reach whatever home opens
    /// next.
    public func endLiveActivities() {
        activityHost?.endAll(except: nil)
    }

    private func showChargeNow(_ id: String, _ event: ChargeNowActivity.Event) {
        guard let host = activityHost else { return }
        let action = ChargeNowActivity.next(host.current(home: activityHome, loadpointID: id), event)
        guard action != .none else { return }
        host.apply(action, home: activityHome, loadpointID: id, zone: zone)
    }

    /// One command, written into `into` at every stage: sent, received,
    /// and what the box did or why not.
    private func follow(_ id: String, _ ask: EVText.Step.Ask, op: String, args: [(String, CBOR)], into path: ReferenceWritableKeyPath<LoadpointsModel, [String: EVText.Step]>, tag: String, acked: (@MainActor () -> Void)? = nil, cmdId: String? = nil) async {
        let key = "\(tag) \(id)"
        clearing[key]?.cancel()
        self[keyPath: path][id] = EVText.Step(ask: ask)
        let result: EVText.Step.Result
        do {
            let r = try await site.core.command(op, args: args, onAck: { [weak self] in
                guard let self, self[keyPath: path][id]?.ask == ask else { return }
                self[keyPath: path][id]?.acked = true
                acked?()
            }, cmdId: cmdId)
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
        // until the next tap. A charge command waits up to a minute for
        // MEASURED, which comes when the car has started or stopped.
        if case .applied = result {
            let waits = tag == "hold" && self[keyPath: path][id]?.measured == false
            fadeLater(key, path, id, afterMs: waits ? Self.measureWaitMs : Self.doneShownMs)
        }
    }

    /// A settled success leaves the screen after `afterMs`, unless another
    /// command took its place.
    private func fadeLater(_ key: String, _ path: ReferenceWritableKeyPath<LoadpointsModel, [String: EVText.Step]>, _ id: String, afterMs: Double) {
        guard let step = self[keyPath: path][id], case .applied? = step.result else { return }
        clearing[key]?.cancel()
        clearing[key] = site.scheduler.after(afterMs) { [weak self] in
            guard let self, let now = self[keyPath: path][id], now.ask == step.ask, case .applied? = now.result else { return }
            self[keyPath: path][id] = nil
        }
    }

    static let doneShownMs: Double = 20_000
    /// How long a confirmed charge command waits for lane 0 to show it.
    static let measureWaitMs: Double = 60_000

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
    }

    public func removeGoal(_ lp: Loadpoint) async {
        goalSave[lp.id] = .saving
        do {
            _ = try await site.callBox(.delete, "/api/loadpoints/\(Self.escape(lp.id))/schedule")
            // The DELETE confirms the removal even if the reread fails.
            if var s = stamp, let i = s.value.firstIndex(where: { $0.id == lp.id }) {
                s.value[i].schedule = nil
                s.value[i].targetSocPct = nil
                stamp = s
            }
            goalSave[lp.id] = .removed
        } catch let e as BoxAPIError {
            goalSave[lp.id] = .failed(e.help)
        } catch {
            goalSave[lp.id] = .failed(AppWords.text("That did not go through. Try again."))
        }
        try? await loadChargers()
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

    /// The receipt log for the last level and the last charge command:
    /// `SENT ▸ ACCEPTED ▸ MEASURED ▸ CONFIRMED`, each lit on its evidence.
    public func receipt(level lp: Loadpoint) -> ReceiptLog? {
        levelStep[lp.id].map { EVText.receipt($0, lp) }
    }

    public func receipt(hold lp: Loadpoint) -> ReceiptLog? {
        holdStep[lp.id].map { EVText.receipt($0, lp) }
    }

    public func holdSending(_ lp: Loadpoint) -> Bool {
        holdStep[lp.id].map { !$0.settled } ?? false
    }

    // MARK: From outside the app

    /// How long a command from outside the app waits for the stream. An
    /// intent gets about 30 s in all, and the box's receipt and result can
    /// take 20 of them.
    public static let remoteStreamWaitMs: Double = 10_000

    /// A command from a Control, Siri, the Live Activity or a notification.
    /// The caller has opened the session; this waits for the stream, reads
    /// the chargers, sends the command exactly as the car view would, and
    /// says how it ended. The Live Activity moves as it does for a tap in
    /// the car view. A notification names its charger in `loadpointID`;
    /// the others let the box's account pick one.
    public func perform(_ command: RemoteCommand, loadpointID: String? = nil, waitMs: Double = LoadpointsModel.remoteStreamWaitMs, cmdId: String? = nil) async -> RemoteOutcome {
        // A Live Activity's button names its home. One from another home,
        // or from the demo, never reaches this one: its card closes instead.
        if case .backToPlan(let id, let home?) = command, home != activityHome {
            if let id {
                activityHost?.apply(.end, home: home, loadpointID: id, zone: zone)
            } else {
                activityHost?.endAll(except: activityHome)
            }
            return RemoteOutcome(.failed, Self.say("That card was for another home. It is closed now."))
        }
        guard await streaming(within: waitMs) else {
            if site.busy { return RemoteOutcome(.failed, Self.say("FTW is busy: as many apps and browsers are watching this home as it serves. Try again when one closes.")) }
            return RemoteOutcome(.failed, AppWords.text("Not connected to FTW right now. Try again when the connection is back."))
        }
        guard site.hasPassthrough else {
            return RemoteOutcome(.failed, AppWords.text("Your box cannot do this yet. It may need an update."))
        }
        do {
            try await loadChargers()
        } catch {
            return RemoteOutcome(.failed, self.error ?? EVText.failure(error))
        }
        // A charger named and not found is not swapped for another.
        let named = loadpointID.flatMap { id in points.first { $0.id == id } }
        guard let lp = loadpointID == nil ? Self.target(command, in: points) : named else {
            return RemoteOutcome(.failed, Self.say("FTW has no charger to control."))
        }
        // Charge now with no car would hold a charger that has nothing to
        // charge; say so instead.
        if command == .chargeNow, !lp.pluggedIn {
            return RemoteOutcome(.failed, Self.say("The car is not plugged in."))
        }
        let busy = Self.say("FTW is still busy with your last command. Try again in a moment.")
        switch command {
        case .chargeNow, .backToPlan:
            guard !holdSending(lp) else { return RemoteOutcome(.failed, busy) }
            let ask: EVText.Step.Ask = command == .chargeNow ? .chargeNow : .resume
            if ask == .chargeNow { await chargeNow(lp, cmdId: cmdId) } else { await backToPlan(lp, cmdId: cmdId) }
            return remoteOutcome(holdStep[lp.id], lp.id, ask: ask, busy: busy)
        case .setLevel(let pct):
            guard !levelSending.contains(lp.id) else { return RemoteOutcome(.failed, busy) }
            await setLevel(lp, pct: pct)
            return remoteOutcome(levelStep[lp.id], lp.id, ask: .level(min(100, max(0, pct.rounded()))), busy: busy)
        }
    }

    /// The charger the app means when a person names none: the one with a
    /// car, then the one that holds, then the first.
    public var primary: Loadpoint? { Self.primary(in: points) }

    static func primary(in points: [Loadpoint]) -> Loadpoint? {
        points.first(where: \.pluggedIn) ?? points.first(where: \.manualActive) ?? points.first
    }

    /// The charger a command means. Back to the plan means the one that
    /// holds; the rest mean the primary one.
    static func target(_ command: RemoteCommand, in points: [Loadpoint]) -> Loadpoint? {
        switch command {
        case .backToPlan(let id?, _):
            return points.first { $0.id == id }
        case .backToPlan(nil, _):
            return points.first(where: \.manualActive) ?? primary(in: points)
        case .chargeNow, .setLevel:
            return primary(in: points)
        }
    }

    /// The receipt's sentence, and whether the box did it, has it, or not.
    /// A receipt for another command, one tapped meanwhile, is not this
    /// command's outcome.
    private func remoteOutcome(_ step: EVText.Step?, _ id: String, ask: EVText.Step.Ask, busy: String) -> RemoteOutcome {
        guard let step else { return RemoteOutcome(.failed, AppWords.text("That did not go through. Try again.")) }
        guard step.ask == ask else { return RemoteOutcome(.failed, busy) }
        let text = EVText.outcome(step, points.first { $0.id == id }).text
        switch step.result {
        case .applied?: return RemoteOutcome(.done, text)
        case .unconfirmed?, nil: return RemoteOutcome(.pending, text)
        case .superseded?, .refused?: return RemoteOutcome(.failed, text)
        }
    }

    /// The app opened because a command from the Control did not happen:
    /// the reason stays on the car's receipt until the next tap.
    public func show(refusal: String) {
        guard let lp = primary else { return }
        clearing["hold \(lp.id)"]?.cancel()
        holdStep[lp.id] = EVText.Step(ask: .chargeNow, acked: false, result: .refused(refusal))
    }

    /// Read what "Is the car ready?" needs: the chargers, and the plan's
    /// shortfall when a car has a goal. False when the stream did not come
    /// in time; the answer is then the last one this phone had.
    public func refreshForAnswer(waitMs: Double = LoadpointsModel.remoteStreamWaitMs) async -> Bool {
        guard await streaming(within: waitMs), site.hasPassthrough else { return false }
        do {
            try await loadChargers()
            if points.contains(where: { $0.pluggedIn && $0.schedule != nil && !$0.manualActive }) {
                try await readShortfall()
            }
            return true
        } catch {
            return false
        }
    }

    /// "Is the car ready?" from what the box last said. Locked, the answer
    /// is the gist alone: no level, no time and no power.
    public func answer(locked: Bool) -> CarAnswer {
        guard let lp = primary else {
            return CarAnswer(gist: .noCharger, headline: Self.say("FTW has no charger to control."), details: [], readAtMs: readAtMs, loadpointID: nil, holding: false, canChargeNow: false, home: activityHome)
        }
        let r = readiness(lp)
        let holds = Self.holding(lp)
        let gist: CarAnswer.Gist
        if !lp.pluggedIn {
            gist = .unplugged
        } else if holds {
            gist = .chargingNow
        } else if EVText.isPaused(lp) {
            gist = .paused
        } else if let r {
            switch r {
            case .reached: gist = .ready
            case .onTrack: gist = .onTrack
            case .short: gist = .short
            }
        } else {
            gist = .pluggedIn
        }
        var answer = CarAnswer(gist: gist, headline: Self.say(CarAnswer.gistWords[gist] ?? ""), details: [], readAtMs: readAtMs, loadpointID: lp.id, holding: holds, canChargeNow: lp.pluggedIn && !holds, home: activityHome)
        guard !locked else { return answer }
        let level = level(lp)
        switch gist {
        case .ready, .onTrack, .short:
            answer.headline = EVText.readiness(r!, level: level, nowMs: site.nowMs, zone: zone)
        case .chargingNow, .paused:
            answer.headline = EVText.manualStatus(lp)
        default:
            answer.headline = EVText.status(lp, zone: zone)
        }
        answer.receipt = outcome(hold: lp)?.text
        if let level { answer.details.append("\(AppWords.percent(level.pct)) · \(EVText.originShort(level, zone: zone))") }
        if !holds, let plan = EVText.plan(lp, windows: windows[lp.id] ?? lp.planWindows, nowMs: site.nowMs, zone: zone) {
            answer.details.append(plan)
        } else if let goal = EVText.nextGoal(lp, nowMs: site.nowMs, zone: zone), gist == .pluggedIn {
            answer.details.append(goal)
        }
        return answer
    }

    /// True once the session streams, false if it has not within `ms`.
    private func streaming(within ms: Double) async -> Bool {
        if site.session.phase == .streaming { return true }
        let wait = RemoteWait()
        let ok = await withCheckedContinuation { cont in
            wait.continuation = cont
            wait.token = site.observe { [weak self, wait] in
                if self?.site.session.phase == .streaming { wait.settle(true) }
            }
            wait.timer = site.scheduler.after(ms) { [wait] in wait.settle(false) }
        }
        if let token = wait.token { site.unobserve(token) }
        return ok
    }

    /// FTWKit's Swedish lives in `AppWords`; these few sentences are said
    /// only outside the app.
    nonisolated static func say(_ en: String) -> String {
        AppWords.language == .sv ? (remoteSv[en] ?? en) : en
    }

    nonisolated static let remoteSv: [String: String] = [
        "FTW has no charger to control.": "FTW har ingen laddare att styra.",
        "The car is not plugged in.": "Bilen är inte inkopplad.",
        "Charge now is on.": "Ladda nu är på.",
        "Charging is paused.": "Laddningen är pausad.",
        "The car is ready.": "Bilen är klar.",
        "The car will be ready in time.": "Bilen blir klar i tid.",
        "The car will not be ready in time.": "Bilen blir inte klar i tid.",
        "The car is plugged in.": "Bilen är inkopplad.",
        "Read %@.": "Läst %@.",
        "Read %@": "Läst %@",
        "FTW is still busy with your last command. Try again in a moment.": "FTW arbetar fortfarande med ditt förra kommando. Försök igen om en stund.",
        "That card was for another home. It is closed now.": "Kortet gällde ett annat hem. Det är stängt nu.",
        "FTW is busy: as many apps and browsers are watching this home as it serves. Try again when one closes.": "FTW är upptaget: lika många appar och webbläsare tittar på hemmet som det klarar. Försök igen när någon stänger.",
    ]
}

/// "Is the car ready?", answered for Siri and its card.
public struct CarAnswer: Equatable, Sendable {
    public enum Gist: Equatable, Sendable {
        case noCharger, unplugged, chargingNow, paused, ready, onTrack, short, pluggedIn
    }

    public var gist: Gist
    /// The answer in one sentence.
    public var headline: String
    /// The level and the plan, as the car view says them. Empty when locked.
    public var details: [String]
    /// When the box said it, so the card can date it.
    public var readAtMs: Double?
    public var loadpointID: String?
    /// Charge now is on: the card offers Back to the plan.
    public var holding: Bool
    /// A car is plugged in and not held: the card offers Charge now.
    public var canChargeNow: Bool
    /// The home the answer is about, for the card's Back to the plan.
    public var home: String
    /// The last command's receipt, as the car view shows it: what was sent
    /// and what the box did. Nil when locked or when there is none.
    public var receipt: String? = nil

    /// Spoken: the answer, and its age once it is minutes old.
    public func spoken(nowMs: Double) -> String {
        guard let at = readAtMs, nowMs - at >= 5 * 60_000 else { return headline }
        return headline + " " + LoadpointsModel.say("Read %@.").replacingOccurrences(of: "%@", with: PowerFormat.age(nowMs - at))
    }

    /// On the card: "Read just now", "Read 12 min ago".
    public func readText(nowMs: Double) -> String? {
        guard let at = readAtMs else { return nil }
        return LoadpointsModel.say("Read %@").replacingOccurrences(of: "%@", with: PowerFormat.age(max(0, nowMs - at)))
    }

    /// What a locked phone says.
    static let gistWords: [Gist: String] = [
        .noCharger: "FTW has no charger to control.",
        .unplugged: "The car is not plugged in.",
        .chargingNow: "Charge now is on.",
        .paused: "Charging is paused.",
        .ready: "The car is ready.",
        .onTrack: "The car will be ready in time.",
        .short: "The car will not be ready in time.",
        .pluggedIn: "The car is plugged in.",
    ]
}

/// One wait for the stream, settled once. The timer settles it even if the
/// model is gone, so an intent always ends.
@MainActor
private final class RemoteWait {
    var continuation: CheckedContinuation<Bool, Never>?
    var token: Int?
    var timer: Cancellable?

    func settle(_ ok: Bool) {
        guard let cont = continuation else { return }
        continuation = nil
        timer?.cancel()
        cont.resume(returning: ok)
    }
}
