import Foundation
import FTWShared
import Observation

/// The owner's cars, as the box keeps them (docs/cars.md in srcfl/ftw).
///
/// A box that lists `der.car` keeps each car apart from the charger: its
/// level, its goal and its sources. The charger names the car on it, and
/// this model puts the two together: which car is on which charger, which
/// charger asks "Which car?", and each car's level when nothing is plugged
/// in. A box without `der.car` has no list; the car view draws the charger
/// as before, and this model reads nothing.
///
/// No timer asks the box. The list is read after each hello, when the home
/// comes back on screen and the last read is over a minute old, after a
/// car command, when a read of the chargers or a pushed plan shows a car
/// that moved (plugged, named, or its level), and FTW Cloud's car class
/// moves each car's level as the box sends it.
@Observable
@MainActor
public final class CarsModel: Activatable {
    /// The cars as the box last listed them, and when and how that reached
    /// this phone.
    public private(set) var stamp: Stamped<[Car]>?
    public var cars: [Car] { stamp?.value ?? [] }
    /// Whether the box has ever answered in this session.
    public private(set) var loaded = false
    public private(set) var error: String?
    /// The last level per car, from the tap to the box's answer.
    public private(set) var levelStep: [String: EVText.Step] = [:]
    /// A level tapped and not yet answered.
    public private(set) var levelWanted: [String: Double] = [:]
    public private(set) var goalSave: [String: LoadpointsModel.GoalSave] = [:]
    /// The last "Which car?" answer per charger.
    public private(set) var choice: [String: Choice] = [:]
    /// The last change to the list per car; `newCarKey` while a car is
    /// being added.
    public private(set) var edit: [String: Edit] = [:]

    public static let newCarKey = "new"

    /// One answer to "Which car?", from the tap to the box's answer.
    public struct Choice: Equatable, Sendable {
        public enum Result: Equatable, Sendable {
            case applied
            case unconfirmed
            case refused(String)
        }

        /// The car tapped; empty for "None of these".
        public var carID: String
        public var acked = false
        public var result: Result?

        public var settled: Bool { result != nil }
    }

    /// One change to the list: add, rename, capacity, sources or remove.
    public enum Edit: Equatable, Sendable {
        case saving
        case saved
        case removed
        case failed(String)
    }

    @ObservationIgnored private unowned let site: SiteModel
    @ObservationIgnored private unowned let loadpoints: LoadpointsModel
    @ObservationIgnored private var ask: LiveAsk?
    @ObservationIgnored private var active = 0
    @ObservationIgnored private var reading: Task<Void, Error>?
    @ObservationIgnored private var token = 0
    @ObservationIgnored private var levelSending: Set<String> = []
    @ObservationIgnored private var clearing: [String: Cancellable] = [:]
    /// Bumped each time the session starts streaming: the list is read
    /// after each hello.
    @ObservationIgnored private var hellos = 0
    @ObservationIgnored private var wasStreaming = false
    /// Bumped when a read of the chargers or a pushed plan shows a car that
    /// moved: a reason to read the list once.
    @ObservationIgnored private var news = 0
    /// What the chargers last said about their cars, so the same again is
    /// no news.
    @ObservationIgnored private var chargerSeen: [String] = []
    @ObservationIgnored private var planSeen: [String] = []
    /// FTW Cloud's cars as last taken, so they are taken once.
    @ObservationIgnored private var cloudTaken: Stamped<[Car]>?
    /// The id of a car being added, kept until the box confirms it.
    @ObservationIgnored private var addingID: String?
    /// The cars the cloud table lacked when hello was last asked for again.
    @ObservationIgnored private var askedTableFor: [String] = []

    /// How long a read of the list stands when the home comes back on
    /// screen. A car that is not plugged in changes only when its own
    /// source reads it.
    nonisolated static let readStandsMs: Double = 60_000

    public init(site: SiteModel, loadpoints: LoadpointsModel) {
        self.site = site
        self.loadpoints = loadpoints
        // A cold start paints the cars as last read, from the sealed home
        // file, before the box has answered.
        if let kept = site.kept?.cars { stamp = kept.cached }
        site.keep { [weak self] home in
            guard let self, let stamp = self.stamp else { return }
            home.cars = stamp
        }
        site.observe { [weak self] in
            self?.noticeHello()
            self?.takeCloud()
        }
        loadpoints.cars = self
    }

    // MARK: What the box offers

    /// The box keeps cars apart from chargers. Before hello this is what
    /// the box said last time, from the home file.
    public var keepsCars: Bool { site.session.caps.contains(Contract.capDerCar) }

    /// This phone may keep the owner's list: add, rename, remove.
    public var canEdit: Bool {
        site.canConfigure && site.session.scopes.contains(Contract.scopeCarsWrite) && site.heardFromBox
    }

    /// This phone may set a car's goal and level and say which car is on a
    /// charger.
    public var canControl: Bool { site.canConfigure && site.heardFromBox }

    // MARK: Reading

    public func activate() {
        active += 1
        if ask == nil {
            ask = LiveAsk(site: site, order: .loadpoints, ttlMs: Self.readStandsMs, want: { [weak self] in
                guard let self, self.active > 0, self.keepsCars, self.site.documentVisible, self.site.hasPassthrough else { return nil }
                return "cars \(self.hellos) \(self.news)"
            }, ask: { [weak self] in try await self?.load() })
        }
        ask?.evaluate()
    }

    public func deactivate() {
        active = max(0, active - 1)
        ask?.evaluate()
    }

    private func noticeHello() {
        let streaming = site.session.phase == .streaming
        defer { wasStreaming = streaming }
        guard streaming, !wasStreaming else { return }
        hellos += 1
        ask?.evaluate()
    }

    /// Read the list now. Two reads at once are one.
    public func load() async throws {
        if let reading {
            try await reading.value
            return
        }
        let task = Task { @MainActor in try await self.read() }
        reading = task
        defer { reading = nil }
        try await task.value
    }

    private func read() async throws {
        token += 1
        let mine = token
        do {
            let wire = try await site.callBox(.get, "/api/cars")
            guard mine == token else { return }
            let list = (wire?["cars"]?.array ?? []).compactMap(Car.init)
            take(Stamped(list, asOfMs: site.scheduler.nowMs, origin: .relay))
            if !loaded { loaded = true }
            if error != nil { error = nil }
        } catch {
            guard mine == token else { return }
            if let e = error as? BoxAPIError, cars.isEmpty {
                self.error = e.help
            } else {
                self.error = AppWords.text("Not up to date — your box is out of reach")
            }
            throw error
        }
    }

    private func take(_ next: Stamped<[Car]>) {
        guard let taken = Stamped.taking(next, over: stamp) else { return }
        stamp = taken
        loadpoints.shareOutside()
        site.shareCarNames(taken.value)
        refreshCloudTable()
    }

    /// FTW Cloud names a car by an opaque id the box gives in hello. A car
    /// the table lacks, one added here or on the box page, gets no cloud
    /// level and no "Which car?" button until the table is asked for again:
    /// once per set of missing cars.
    private func refreshCloudTable() {
        guard keepsCars, let table = site.session.cloud?.cars else { return }
        let known = Set(table.values)
        let missing = cars.map(\.id).filter { !known.contains($0) }
        guard !missing.isEmpty, missing != askedTableFor else { return }
        askedTableFor = missing
        site.refreshHello()
    }

    // MARK: From outside the app

    /// "Which car?" from a notification's button: the session is opened by
    /// the caller; this waits for the stream, reads the chargers, and taps
    /// as the car view would, for the plug-in the notification named.
    public func perform(choice carID: String?, loadpointID: String, session: String, waitMs: Double = LoadpointsModel.remoteStreamWaitMs) async -> RemoteOutcome {
        guard await WatchShare.streaming(site, within: waitMs) else {
            return RemoteOutcome(.failed, AppWords.text("Not connected to FTW right now. Try again when the connection is back."))
        }
        guard keepsCars else { return RemoteOutcome(.failed, AppWords.text("Your box cannot do this yet. It may need an update.")) }
        try? await loadpoints.loadChargers()
        guard let lp = loadpoints.points.first(where: { $0.id == loadpointID }), lp.chargerCar?.session == session else {
            return RemoteOutcome(.failed, CarWords.text("That plug-in has ended."))
        }
        await choose(lp, carID: carID)
        guard let c = choice[loadpointID] else { return RemoteOutcome(.failed, AppWords.text("That did not go through. Try again.")) }
        let said = choiceText(c)
        switch c.result {
        case .applied?: return RemoteOutcome(.done, said.text)
        case .unconfirmed?, nil: return RemoteOutcome(.pending, said.text)
        case .refused?: return RemoteOutcome(.failed, said.text)
        }
    }

    /// A read of the chargers landed. A car that moved (plugged in, named,
    /// asked about, or its level) is a reason to read the list once, so the
    /// car view and the widgets show the car's own level.
    func chargersRead(_ points: [Loadpoint]) {
        guard keepsCars else { return }
        let seen = points.map { lp in
            "\(lp.id) \(lp.pluggedIn) \(lp.chargerCar?.carID ?? "-") \(lp.chargerCar?.identifiedBy ?? "-") \(lp.socPct ?? -1) \(lp.socSource)"
        }
        defer { chargerSeen = seen }
        // The first read after a hello is news only for a car the list does
        // not have; the hello reads the list anyway.
        let unknown = loaded && points.contains { lp in car(on: lp) == nil && !(lp.chargerCar?.carID ?? "").isEmpty }
        guard unknown || (!chargerSeen.isEmpty && seen != chargerSeen) else { return }
        news += 1
        ask?.evaluate()
    }

    /// A pushed plan names each charger's car. A car this phone has not
    /// read, or a charger whose car changed, is read once.
    func planTaken(_ chargers: [PlanCharger]) {
        guard keepsCars else { return }
        let seen = chargers.map { "\($0.id) \($0.carId ?? "-")" }
        defer { planSeen = seen }
        let unknown = chargers.contains { c in c.carId.map { id in !cars.contains { $0.id == id } } ?? false }
        guard unknown || (seen != planSeen && !planSeen.isEmpty) else { return }
        news += 1
        ask?.evaluate()
    }

    /// FTW Cloud's car class: each car's level and goal as the box sent
    /// them, under ids the phone maps from the table the box gave over
    /// Noise. Taken when newer than the box's last answer here.
    private func takeCloud() {
        guard let cloud = site.cloudCarList else { return }
        take(cloud: cloud)
    }

    func take(cloud: Stamped<[Car]>) {
        guard keepsCars, cloud != cloudTaken else { return }
        cloudTaken = cloud
        guard let stamp, stamp.fromCache || stamp.asOfMs < cloud.asOfMs else { return }
        let byID = Dictionary(cloud.value.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let shift = (cloud.asOfMs - stamp.asOfMs) / 1000
        let next = stamp.value.map { car -> Car in
            guard let c = byID[car.id] else {
                var aged = car
                aged.socAgeS = car.socAgeS.map { $0 + shift }
                return aged
            }
            var out = car
            out.socPermille = c.socPermille
            out.socSource = c.socSource
            out.socAgeS = c.socAgeS
            out.energySinceWh = c.energySinceWh
            out.socEstimate = c.socEstimate
            out.chargeLimitPermille = c.chargeLimitPermille
            out.goal = c.goal
            out.surplusOnly = c.surplusOnly
            return out
        }
        take(Stamped(next, asOfMs: cloud.asOfMs, origin: .cloud))
    }

    // MARK: What the screens read

    public var readAtMs: Double? { stamp?.asOfMs }
    /// The clock the screens date levels by, ticking by the minute.
    public var minuteMs: Double { site.minuteMs }
    /// The household zone, from the box's hello.
    public var zone: TimeZone { loadpoints.zone }

    /// When the list is out of date, what to say: the box's last word and
    /// when, or why there is none now. Nil while it stands.
    public var staleNote: String? {
        guard stale else { return nil }
        if let error, !fromCache { return error }
        guard let at = readAtMs else { return AppWords.text("Waiting for your box.") }
        return AppWords.format("Last known %@.", AppWords.clock(at, zone: zone))
    }
    public var fromCache: Bool { stamp?.fromCache ?? false }

    public func car(_ id: String?) -> Car? {
        guard let id, !id.isEmpty else { return nil }
        return cars.first { $0.id == id }
    }

    /// The charger a car is plugged into, as the chargers last said.
    public func charger(of car: Car) -> Loadpoint? {
        loadpoints.points.first { $0.pluggedIn && $0.chargerCar?.carID == car.id }
    }

    /// The car on a charger, when the box knows which.
    public func car(on lp: Loadpoint) -> Car? {
        guard lp.pluggedIn else { return nil }
        return car(lp.chargerCar?.carID)
    }

    /// The cars in the order the screens show them: each on a charger
    /// first, then the rest as the box lists them.
    public var ordered: [Car] {
        let on = cars.filter { charger(of: $0) != nil }
        return on + cars.filter { charger(of: $0) == nil }
    }

    /// The chargers that ask "Which car?": a car is plugged in, the box
    /// waits for a tap, and it named the cars a tap may pick.
    public var asking: [Loadpoint] {
        loadpoints.points.filter { $0.pluggedIn && $0.chargerCar?.asking == true && !($0.chargerCar?.session.isEmpty ?? true) }
    }

    /// The cars a tap may pick on a charger that asks, by name, in the
    /// box's order. A car this phone has not read yet is left out until
    /// the list is read.
    public func choices(_ lp: Loadpoint) -> [Car] {
        let ids = lp.chargerCar?.choose ?? []
        return ids.compactMap { car($0) }
    }

    /// The plugged-in chargers with a car the box cannot name and no longer
    /// asks about: a visitor's.
    public var visitors: [Loadpoint] {
        loadpoints.points.filter { unnamed($0) && $0.chargerCar?.asking != true }
    }

    /// The car whose level stands beside the car's power: the one on a
    /// charger, else the first. Nil while a plugged-in car is one the box
    /// cannot name, so a visitor never shows another car's level.
    public var shownCar: Car? {
        if let plugged = loadpoints.points.first(where: \.pluggedIn) { return car(on: plugged) }
        return ordered.first
    }

    /// A plugged-in charger whose car the box cannot name: a visitor's, or
    /// one it still asks about.
    public func unnamed(_ lp: Loadpoint) -> Bool {
        lp.pluggedIn && (lp.chargerCar?.carID ?? "").isEmpty
    }

    /// The car's level, dated from when the box said it. A level tapped and
    /// confirmed shows at once from the box's answer.
    public func level(_ car: Car) -> CarLevel? {
        car.level(answeredAtMs: readAtMs ?? site.nowMs)
    }

    /// The chip to show as chosen: the tap on its way, else the level.
    public func chosenLevel(_ car: Car) -> Double? {
        levelWanted[car.id] ?? level(car)?.pct
    }

    /// Out of date: from the cache, the read failed, or the stream stopped.
    public var stale: Bool {
        fromCache || error != nil || site.session.phase != .streaming
    }

    // MARK: Which car?

    /// One tap names the car on a charger, or none of them for a visitor.
    /// The tap names the plug-in, so the box refuses it once the car has
    /// left.
    public func choose(_ lp: Loadpoint, carID: String?, cmdId: String? = nil) async {
        guard let session = lp.chargerCar?.session, !session.isEmpty else { return }
        if let step = choice[lp.id], !step.settled { return }
        let id = lp.id
        let want = carID ?? ""
        clearing["choice \(id)"]?.cancel()
        choice[id] = Choice(carID: want)
        let result: Choice.Result
        do {
            let r = try await site.core.command(Contract.opSessionCarSet, args: [("id", .text(id)), ("session", .text(session)), ("car_id", .text(want))], onAck: { [weak self] in
                guard let self, self.choice[id]?.carID == want else { return }
                self.choice[id]?.acked = true
            }, cmdId: cmdId)
            switch r.state {
            case .applied: result = .applied
            case .unconfirmed: result = .unconfirmed
            case .superseded, .rejected, .expired: result = .refused(CarText.refusal(r))
            }
            if r.state == .applied, let held = r.charger { loadpoints.takeChargerCar(id, held) }
        } catch {
            result = .refused(EVText.failure(error))
        }
        guard choice[id]?.carID == want else { return }
        choice[id]?.acked = true
        choice[id]?.result = result
        if result == .applied { fadeLater("choice \(id)") { $0.choice[id] = nil } }
        // The box planned again for the car it now has; read what it says.
        try? await loadpoints.loadChargers()
        try? await load()
    }

    /// What the receipt under "Which car?" says.
    public func choiceText(_ c: Choice) -> (text: String, tone: EVText.Outcome.Tone) {
        switch c.result {
        case nil: return (CarWords.text(c.acked ? "FTW received your choice." : "Sending your choice…"), .working)
        case .applied?:
            if c.carID.isEmpty { return (CarWords.text("FTW now charges it as a visitor's car."), .done) }
            return (CarWords.format("FTW now plans for %@.", car(c.carID)?.shownName ?? CarWords.text("Car")), .done)
        case .unconfirmed?: return (AppWords.text("FTW received it but has not confirmed the result yet."), .warning)
        case .refused(let why)?: return (why, .failed)
        }
    }

    /// The same answer in the three marks the watch shows.
    public func choiceOutcome(_ c: Choice) -> EVText.Outcome {
        let said = choiceText(c)
        switch c.result {
        case nil: return EVText.Outcome(sent: .done, received: c.acked ? .done : .active, done: c.acked ? .active : .waiting, text: said.text, tone: said.tone)
        case .applied?: return EVText.Outcome(sent: .done, received: .done, done: .done, text: said.text, tone: said.tone)
        case .unconfirmed?: return EVText.Outcome(sent: .done, received: .done, done: .waiting, text: said.text, tone: said.tone)
        case .refused?: return EVText.Outcome(sent: .done, received: c.acked ? .done : .failed, done: .failed, text: said.text, tone: said.tone)
        }
    }

    public func choiceReceipt(_ c: Choice) -> ReceiptLog {
        var r = ReceiptLog(accepted: c.acked, slots: [.sent, .accepted, .confirmed])
        switch c.result {
        case .applied?: r.confirmed = true
        case .refused(let why)?: r.refused = why
        case .unconfirmed?, nil: break
        }
        return r
    }

    // MARK: The level

    /// The level a person tapped, as the car's own (`car.soc.set`). Taps made
    /// while one is on its way fold into the next send.
    public func setLevel(_ car: Car, pct: Double) async {
        let id = car.id
        levelWanted[id] = min(100, max(0, pct.rounded()))
        guard !levelSending.contains(id) else { return }
        levelSending.insert(id)
        defer { levelSending.remove(id) }
        var sent: Double?
        while let want = levelWanted[id], want != sent {
            sent = want
            await follow(id, ask: .level(want), op: Contract.opCarSocSet, args: [("id", .text(id)), ("soc", .number(want / 100))])
            if levelWanted[id] == want {
                try? await load()
                if levelWanted[id] == want { levelWanted[id] = nil }
            }
        }
    }

    public func receipt(level car: Car) -> ReceiptLog? {
        levelStep[car.id].map { EVText.receipt($0, nil) }
    }

    public func outcome(level car: Car) -> EVText.Outcome? {
        levelStep[car.id].map { EVText.outcome($0, nil) }
    }

    private func follow(_ id: String, ask: EVText.Step.Ask, op: String, args: [(String, CBOR)]) async {
        let key = "level \(id)"
        clearing[key]?.cancel()
        levelStep[id] = EVText.Step(ask: ask)
        let result: EVText.Step.Result
        do {
            let r = try await site.core.command(op, args: args, onAck: { [weak self] in
                guard let self, self.levelStep[id]?.ask == ask else { return }
                self.levelStep[id]?.acked = true
            })
            switch r.state {
            case .applied: result = .applied(observed: r.observedValue)
            case .superseded: result = .superseded(observed: r.observedValue)
            case .unconfirmed: result = .unconfirmed(note: r.errorCode == nil ? nil : CarText.refusal(r))
            case .rejected, .expired: result = .refused(CarText.refusal(r))
            }
            if let car = r.car { patch(car) }
        } catch {
            result = .refused(EVText.failure(error))
        }
        guard levelStep[id]?.ask == ask else { return }
        levelStep[id]?.acked = true
        levelStep[id]?.result = result
        if case .applied = result { fadeLater(key) { $0.levelStep[id] = nil } }
    }

    /// A car as a `cmd.result` gave it, in brief: its level, goal and
    /// surplus choice now. The rest stays as last read.
    private func patch(_ brief: Car) {
        guard var s = stamp, let i = s.value.firstIndex(where: { $0.id == brief.id }) else { return }
        let now = site.scheduler.nowMs
        let shift = (now - s.asOfMs) / 1000
        s.value = s.value.enumerated().map { j, car in
            guard j == i else {
                var aged = car
                aged.socAgeS = car.socAgeS.map { $0 + shift }
                return aged
            }
            var out = car
            out.socPermille = brief.socPermille
            out.socSource = brief.socSource
            out.socAgeS = brief.socAgeS
            out.energySinceWh = brief.energySinceWh
            out.socEstimate = brief.socEstimate
            out.chargeLimitPermille = brief.chargeLimitPermille ?? car.chargeLimitPermille
            out.goal = brief.goal
            out.surplusOnly = brief.surplusOnly
            return out
        }
        s.asOfMs = now
        s.origin = .relay
        stamp = s
        loadpoints.shareOutside()
    }

    // MARK: The goal

    /// One goal per car (`car.goal.set`), used wherever it is plugged in.
    /// `recurring` false is once; every day is all seven days. The goal is
    /// replaced whole, so "to the car's own limit" goes with it each time.
    public func saveGoal(_ car: Car, socPct: Double, clock: Int, recurring: Bool, days: Int, finishAtLimit: Bool = false) async {
        guard (0..<1440).contains(clock) else { goalSave[car.id] = .failed(AppWords.text("Choose a valid ready time.")); return }
        guard (10...100).contains(socPct) else { goalSave[car.id] = .failed(AppWords.text("Choose a charge target from 10 to 100 %.")); return }
        guard !recurring || days & 0x7F != 0 else { goalSave[car.id] = .failed(AppWords.text("Choose at least one day.")); return }
        await goalOp(car, [("target", .number(socPct / 100)), ("ready_by_min", .int(clock)), ("days", .int(Self.goalDays(recurring: recurring, days: days))),
                           ("finish_at_limit", .bool(finishAtLimit))], removing: false)
    }

    public func removeGoal(_ car: Car) async {
        await goalOp(car, [("clear", .bool(true))], removing: true)
    }

    /// A goal's days on the wire: 0 once, 127 every day, else the mask.
    nonisolated static func goalDays(recurring: Bool, days: Int) -> Int {
        guard recurring else { return 0 }
        let m = days & 0x7F
        return m == 0 ? Car.Goal.everyDay : m
    }

    private func goalOp(_ car: Car, _ args: [(String, CBOR)], removing: Bool) async {
        goalSave[car.id] = .saving
        do {
            let r = try await site.core.command(Contract.opCarGoalSet, args: [("id", .text(car.id))] + args)
            switch r.state {
            case .applied:
                if let brief = r.car { patch(brief) }
                goalSave[car.id] = removing ? .removed : .saved
            case .unconfirmed:
                goalSave[car.id] = .failed(AppWords.text("FTW received it but has not confirmed the result yet."))
            case .superseded, .rejected, .expired:
                goalSave[car.id] = .failed(CarText.refusal(r))
            }
        } catch {
            goalSave[car.id] = .failed(EVText.failure(error))
        }
        try? await load()
    }

    /// The goal as the car view's sentences read it: the car's goal in a
    /// charger's schedule, on the household clock.
    public static func schedule(_ goal: Car.Goal, nowMs: Double, zone: TimeZone) -> Loadpoint.Schedule {
        let at = Date(timeIntervalSince1970: nowMs / 1000)
        let everyDay = goal.days & 0x7F == 0x7F
        return Loadpoint.Schedule(
            socPct: (Double(goal.targetPermille) / 10).rounded(),
            timeOfDayMinUTC: EVText.minuteUTC(clock: goal.readyByMin, at: at, zone: zone),
            clockMin: goal.readyByMin,
            surplusUnlockPct: 0,
            recurring: goal.days != 0,
            days: everyDay ? 0 : goal.days & 0x7F,
            finishAtVehicleLimit: goal.finishAtLimit
        )
    }

    // MARK: The list

    /// Add a car with the id this phone mints. A try after one the box did
    /// not confirm keeps the id, so it updates that car rather than adding
    /// a second.
    public func add(name: String, capacityWh: Double) async {
        let id = addingID ?? Car.mintID()
        addingID = id
        var args: [(String, CBOR)] = [("id", .text(id)), ("name", .text(name.trimmingCharacters(in: .whitespacesAndNewlines)))]
        if capacityWh > 0 { args.append(("capacity_wh", .int(Int(capacityWh.rounded())))) }
        await listOp(Self.newCarKey, Contract.opCarAdd, args, removing: false)
    }

    /// Change what the box knows about a car: what is nil stays.
    public func update(_ car: Car, name: String? = nil, capacityWh: Double? = nil, sources: [String]? = nil) async {
        var args: [(String, CBOR)] = [("id", .text(car.id))]
        if let name { args.append(("name", .text(name.trimmingCharacters(in: .whitespacesAndNewlines)))) }
        if let capacityWh { args.append(("capacity_wh", .int(Int(max(0, capacityWh).rounded())))) }
        if let sources { args.append(("sources", .array(sources.map { .text($0) }))) }
        guard args.count > 1 else { return }
        await listOp(car.id, Contract.opCarUpdate, args, removing: false)
    }

    /// Remove a car. The box keeps its id as removed, and a session on it
    /// becomes a visitor's.
    public func remove(_ car: Car) async {
        await listOp(car.id, Contract.opCarRemove, [("id", .text(car.id))], removing: true)
    }

    private func listOp(_ key: String, _ op: String, _ args: [(String, CBOR)], removing: Bool) async {
        clearing["edit \(key)"]?.cancel()
        edit[key] = .saving
        do {
            let r = try await site.core.command(op, args: args)
            switch r.state {
            case .applied:
                edit[key] = removing ? .removed : .saved
                if key == Self.newCarKey { addingID = nil }
                if removing, var s = stamp {
                    s.value.removeAll { $0.id == key }
                    stamp = s
                }
                fadeLater("edit \(key)") { $0.edit[key] = nil }
            case .unconfirmed:
                edit[key] = .failed(AppWords.text("FTW received it but has not confirmed the result yet."))
            case .superseded, .rejected, .expired:
                edit[key] = .failed(CarText.refusal(r))
            }
        } catch {
            edit[key] = .failed(EVText.failure(error))
        }
        try? await load()
        if removing { try? await loadpoints.loadChargers() }
    }

    public static func editText(_ e: Edit) -> String {
        switch e {
        case .saving: return CarWords.text("Saving…")
        case .saved: return CarWords.text("Saved.")
        case .removed: return CarWords.text("Removed.")
        case .failed(let why): return why
        }
    }

    /// The level sources this box could bind to a car: each source the
    /// car has, then each driver the box reports that no other car has and
    /// that is not a charger.
    public func sourceChoices(for car: Car) -> [String] {
        let taken = Set(cars.filter { $0.id != car.id }.flatMap(\.sources)).union(loadpoints.points.compactMap(\.driverName))
        let others = site.session.sources.keys.filter { !taken.contains($0) && !car.sources.contains($0) }.sorted()
        return car.sources + others
    }

    // MARK: Shared

    private func fadeLater(_ key: String, _ clear: @escaping @MainActor (CarsModel) -> Void) {
        clearing[key]?.cancel()
        clearing[key] = site.scheduler.after(LoadpointsModel.doneShownMs) { [weak self] in
            guard let self else { return }
            clear(self)
        }
    }
}
