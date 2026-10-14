import Foundation
import FTWShared
import Observation

/// What the box means to do over the next hours. The battery and the grid
/// come from the session's own plan (`plan.get`); the sun and the home's use
/// come from the forecast the planner worked from (`GET /api/mpc/plan`),
/// read only while one of those two views is open.
///
/// A plan is asked for when a view opens, again every quarter of an hour
/// while it stays open, and after a change of mode until the box has
/// replanned. Nothing runs while no plan is on screen.
@Observable
@MainActor
public final class PlanModel {
    /// One slot of the planner's forecast: what it expects the sun to make
    /// and the home to use.
    public struct Forecast: Equatable, Sendable, Identifiable, Codable {
        public let startMs: Double
        public let durationMs: Double
        /// Watts the sun is expected to make, never negative.
        public let pvW: Double
        public let loadW: Double
        public let priceMinor: Double?
        /// The battery's planned level at the end of the slot, in percent.
        public var levelPct: Double? = nil
        public var id: Double { startMs }
    }

    public nonisolated static let aheadMs: Double = 12 * 3_600_000
    nonisolated static let reaskMs: Double = 15 * 60_000
    nonisolated static let followMs: Double = 3_000
    nonisolated static let followTries = 6

    /// The plan on screen: the box's latest word, or the plan an earlier
    /// launch kept, dated, until the box answers. The same plan again
    /// changes nothing.
    public private(set) var stamped: Stamped<Plan>?
    public private(set) var forecastStamp: Stamped<[Forecast]>?
    /// Whether the box has answered for the forecast in this session. Until
    /// then an empty forecast is unknown, not empty.
    public private(set) var forecastLoaded = false
    /// Whether the box has answered `plan.get` in this session. Until then
    /// no plan is unknown, never "no plan".
    public private(set) var loaded = false
    /// When the box last sent its plan: an answer to `plan.get`, which
    /// confirms the plan on screen even when it is the same, or a plan it
    /// pushed.
    public private(set) var receivedAtMs: Double?
    public private(set) var problem: String?

    @ObservationIgnored private unowned let site: SiteModel
    @ObservationIgnored private var ask: LiveAsk?
    @ObservationIgnored private var forecastAsk: LiveAsk?
    @ObservationIgnored private var active = 0
    @ObservationIgnored private var forecastActive = 0
    @ObservationIgnored private var want = 0
    @ObservationIgnored private var following: Cancellable?
    /// The plan on the session as last taken, so a pushed one is taken once.
    @ObservationIgnored private var sessionPlan: Plan?
    /// Runs each time the box has sent its plan, the same or a new one, so
    /// the widget's record is dated by it.
    @ObservationIgnored var received: (@MainActor () -> Void)?

    public init(site: SiteModel) {
        self.site = site
        stamped = site.kept?.plan?.cached
        forecastStamp = site.kept?.forecast?.cached
        site.keep { [weak self] home in
            home.plan = self?.stamped
            home.forecast = self?.forecastStamp
        }
        // A plan also arrives unasked, right after a command.
        site.observe { [weak self] in self?.sync() }
    }

    public var plan: Plan? { stamped?.value }
    public var forecast: [Forecast] { forecastStamp?.value ?? [] }

    /// Take the session's plan when the box sent a new one.
    func sync() {
        guard let p = site.session.plan, p != sessionPlan else { return }
        sessionPlan = p
        receivedAtMs = site.nowMs
        take(p)
        received?()
    }

    private func take(_ p: Plan) {
        if let next = Stamped.taking(Stamped(p, asOfMs: site.nowMs, origin: .relay), over: stamped) { stamped = next }
    }

    public func activate(forecast: Bool = false) {
        active += 1
        if ask == nil {
            ask = LiveAsk(site: site, order: .plan, want: { [weak self] in
                guard let self, self.active > 0, self.site.documentVisible else { return nil }
                return "plan \(self.want) \(Int(self.site.nowMs / Self.reaskMs))"
            }, ask: { [weak self] in try await self?.load() })
        }
        ask?.evaluate()
        guard forecast else { return }
        forecastActive += 1
        if forecastAsk == nil {
            forecastAsk = LiveAsk(site: site, order: .plan, want: { [weak self] in
                guard let self, self.forecastActive > 0, self.site.documentVisible, self.site.hasPassthrough else { return nil }
                return "forecast \(self.want) \(Int(self.site.nowMs / Self.reaskMs))"
            }, ask: { [weak self] in try await self?.loadForecast() })
        }
        forecastAsk?.evaluate()
    }

    public func deactivate(forecast: Bool = false) {
        active = max(0, active - 1)
        if forecast { forecastActive = max(0, forecastActive - 1) }
        ask?.evaluate()
        forecastAsk?.evaluate()
    }

    func load() async throws {
        do {
            let p = try await site.core.plan()
            sessionPlan = p
            receivedAtMs = site.nowMs
            take(p)
            received?()
            if !loaded { loaded = true }
            if problem != nil { problem = nil }
        } catch {
            // The plan on screen stays; what happens now is that the app
            // asks again on its own, so that is what it says.
            problem = NodeWords.text("Couldn't get the plan from your box. Still trying.")
            throw error
        }
    }

    func loadForecast() async throws {
        let wire = try await site.callBox(.get, "/api/mpc/plan")
        let next = Stamped(Self.forecast(wire?["plan"]?["actions"]?.array ?? []), asOfMs: site.nowMs, origin: .relay)
        if let taken = Stamped.taking(next, over: forecastStamp) { forecastStamp = taken }
        if !forecastLoaded { forecastLoaded = true }
    }

    static func forecast(_ actions: [JSON]) -> [Forecast] {
        actions.compactMap { a in
            guard let start = a["execution_start_ms"]?.number ?? a["slot_start_ms"]?.number,
                  let slotStart = a["slot_start_ms"]?.number, let len = a["slot_len_min"]?.number else { return nil }
            let end = slotStart + len * 60_000
            let pv = a["forecast_pv_w"]?.number ?? a["pv_w"]?.number ?? 0
            let load = a["forecast_load_w"]?.number ?? a["load_w"]?.number ?? 0
            let soc = a["soc"]?.number.flatMap { $0.isFinite && $0 >= 0 && $0 <= 1 ? $0 * 100 : nil }
            return Forecast(startMs: start, durationMs: max(0, end - start), pvW: abs(pv), loadW: max(0, load), priceMinor: a["price_ore"]?.number, levelPct: soc)
        }
    }

    /// The box acknowledges a change before its planner has replanned, so
    /// the plan is asked for again a few times, three seconds apart, until
    /// its revision moves.
    public func follow() {
        following?.cancel()
        let before = plan?.rev
        var tries = 0
        func step() {
            guard tries < Self.followTries, plan?.rev == before else { return }
            tries += 1
            want += 1
            ask?.evaluate()
            forecastAsk?.evaluate()
            following = site.scheduler.after(Self.followMs) { step() }
        }
        step()
    }

    /// Slots from now to `aheadMs` on, the one running now first.
    public func ahead(nowMs: Double) -> [PlanSlot] {
        (plan?.slots ?? []).filter { $0.endMs > nowMs && $0.startMs < nowMs + Self.aheadMs }
    }

    public func forecastAhead(nowMs: Double) -> [Forecast] {
        forecast.filter { $0.startMs + $0.durationMs > nowMs && $0.startMs < nowMs + Self.aheadMs }
    }
}

/// A plan in sentences. The box sends reason codes; every word is decided
/// here. A plan is intent, not prophecy, so the words say what the box means
/// to do and never promise it.
public enum PlanText {
    public enum Action: Equatable, Sendable { case charge, discharge, rest }

    /// The box page's idle line for a battery that is neither charging nor
    /// giving power.
    static let idleW: Double = 100

    static let reasons: [String: String] = [
        "cheap_import": "power is cheap",
        "expensive_import": "power is dear",
        "solar_surplus": "spare solar",
        "peak_shaving": "holding the grid limit",
        "reserve_held": "keeping a reserve",
        "export_paid": "selling pays",
        "idle": "nothing to gain",
    ]

    /// A reason this app has not heard of is still the box's reason.
    public static func reason(_ code: String) -> String {
        reasons[code].map(NodeWords.text) ?? code.replacingOccurrences(of: "_", with: " ")
    }

    public static func action(_ slot: PlanSlot) -> Action {
        if slot.batteryW > idleW { return .charge }
        if slot.batteryW < -idleW { return .discharge }
        return .rest
    }

    /// One sentence about the battery's next change, which is what a plan
    /// is for: "Charges at 2.5 kW until 06:00, power is cheap."
    public static func battery(_ slots: [PlanSlot], stale: Bool, nowMs: Double, zone: TimeZone) -> String {
        if stale { return NodeWords.text("Your box couldn't plan ahead just now, so it runs on safe defaults.") }
        guard let first = slots.first else { return NodeWords.text("No plan for the hours ahead yet.") }
        let now = action(first)
        var end = 0
        while end + 1 < slots.count, action(slots[end + 1]) == now { end += 1 }
        let until = AppWords.clock(slots[end].endMs, zone: zone)
        let why = reason(first.reason)
        let peak = slots[0...end].map { abs($0.batteryW) }.max() ?? 0
        let lead: String
        switch now {
        case .charge: lead = NodeWords.format("Charges at up to %@ until %@, %@.", AppWords.power(peak), until, why)
        case .discharge: lead = NodeWords.format("Gives the home up to %@ until %@, %@.", AppWords.power(peak), until, why)
        case .rest: lead = NodeWords.format("Rests until %@, %@.", until, why)
        }
        guard end + 1 < slots.count else { return lead }
        let next = slots[end + 1]
        switch action(next) {
        case .charge: return lead + " " + NodeWords.format("Then charges, %@.", reason(next.reason))
        case .discharge: return lead + " " + NodeWords.format("Then gives power, %@.", reason(next.reason))
        case .rest: return lead + " " + NodeWords.text("Then rests.")
        }
    }

    /// What the grid is expected to do: how much the home buys and sells
    /// over the hours ahead.
    public static func grid(_ slots: [PlanSlot], stale: Bool) -> String {
        if stale { return NodeWords.text("Your box couldn't plan ahead just now, so it runs on safe defaults.") }
        guard !slots.isEmpty else { return NodeWords.text("No plan for the hours ahead yet.") }
        var buy = 0.0, sell = 0.0
        for s in slots {
            let wh = abs(s.gridW) * s.durationMs / 3_600_000
            if s.gridW >= 0 { buy += wh } else { sell += wh }
        }
        if sell >= 100 {
            return NodeWords.format("Expects to buy %@ and sell %@ over the next 12 hours.", AppWords.energy(buy), AppWords.energy(sell))
        }
        return NodeWords.format("Expects to buy %@ over the next 12 hours.", AppWords.energy(buy))
    }

    /// When the car charges in the hours ahead, and how much in all.
    public static func car(_ windows: [Loadpoint.Window], nowMs: Double, zone: TimeZone) -> String {
        let ahead = windows.filter { $0.toMs > nowMs && $0.fromMs < nowMs + PlanModel.aheadMs }.sorted { $0.fromMs < $1.fromMs }
        guard let first = ahead.first, let last = ahead.last else { return NodeWords.text("No charging planned in the next 12 hours.") }
        let wh = ahead.reduce(0) { $0 + ($1.energyWh ?? ($1.peakW ?? 0) * ($1.toMs - $1.fromMs) / 3_600_000) }
        return NodeWords.format("Charges %@–%@, %@ in all.", AppWords.clock(max(nowMs, first.fromMs), zone: zone), AppWords.clock(last.toMs, zone: zone), AppWords.energy(wh))
    }

    public static func solar(_ slots: [PlanModel.Forecast]) -> String {
        guard !slots.isEmpty else { return NodeWords.text("No forecast for the hours ahead yet.") }
        let wh = slots.reduce(0) { $0 + $1.pvW * $1.durationMs / 3_600_000 }
        if wh < 50 { return NodeWords.text("No sun expected in the next 12 hours.") }
        return NodeWords.format("Expects the sun to make %@ in the next 12 hours.", AppWords.energy(wh))
    }

    public static func home(_ slots: [PlanModel.Forecast]) -> String {
        guard !slots.isEmpty else { return NodeWords.text("No forecast for the hours ahead yet.") }
        let wh = slots.reduce(0) { $0 + $1.loadW * $1.durationMs / 3_600_000 }
        return NodeWords.format("Expects the home to use %@ in the next 12 hours.", AppWords.energy(wh))
    }
}
