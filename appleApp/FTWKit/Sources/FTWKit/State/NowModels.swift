import Foundation
import Observation

/// A screen that is on screen. Models only ask the box for what someone can
/// see; a hidden tab keeps its state and stops asking.
@MainActor
public protocol Activatable: AnyObject {
    func activate()
    func deactivate()
}

/// Repeats a read on a fixed period while `shouldRun` holds, and reports a
/// retained answer as out of date once it is older than `maxAgeMs`.
@MainActor
final class Poller {
    private let scheduler: Scheduler
    private let periodMs: Double
    private let shouldRun: @MainActor () -> Bool
    private let work: @MainActor () async -> Void
    private var timer: Cancellable?
    private var running = false
    private var busy = false
    private var again = false

    init(scheduler: Scheduler, periodMs: Double, shouldRun: @escaping @MainActor () -> Bool, work: @escaping @MainActor () async -> Void) {
        self.scheduler = scheduler
        self.periodMs = periodMs
        self.shouldRun = shouldRun
        self.work = work
    }

    func start() {
        guard !running else { return }
        running = true
        tick()
    }

    func stop() {
        running = false
        timer?.cancel()
    }

    /// Read now, rather than at the next period. A confirmed action should
    /// reach the screen before its next timer.
    func refresh() {
        if busy { again = true } else if running { tick() }
    }

    private func tick() {
        timer?.cancel()
        guard running else { return }
        busy = true
        again = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.shouldRun() { await self.work() }
            self.busy = false
            guard self.running else { return }
            self.timer = self.scheduler.after(self.again ? 0 : self.periodMs) { [weak self] in self?.tick() }
        }
    }
}

/// The dashboard's own live document, GET /api/status, every two seconds
/// while the Now screen is up. Per-driver nodes, energy today, the fuse.
@Observable
@MainActor
public final class StatusWatch: Activatable {
    public static let maxAgeMs: Double = 15_000

    public private(set) var status: JSON?
    public private(set) var receivedAtMs: Double?
    public private(set) var fresh = false

    @ObservationIgnored private unowned let site: SiteModel
    @ObservationIgnored private var poller: Poller!
    @ObservationIgnored private var expiry: Cancellable?
    @ObservationIgnored private var active = 0

    public init(site: SiteModel) {
        self.site = site
        poller = Poller(scheduler: site.scheduler, periodMs: 2_000, shouldRun: { [weak self] in
            guard let self else { return false }
            return self.site.documentVisible && self.site.session.phase == .streaming && self.site.hasPassthrough
        }, work: { [weak self] in await self?.read() })
    }

    public func activate() {
        active += 1
        if active == 1 { poller.start() }
    }

    public func deactivate() {
        active = max(0, active - 1)
        if active == 0 {
            poller.stop()
            fresh = false
        }
    }

    private func read() async {
        do {
            let started = site.scheduler.nowMs
            guard let json = try await site.callBox(.get, "/api/status"), json.object != nil else { throw BoxAPIError(code: "E_BAD_BODY", help: "", status: nil) }
            let took = site.scheduler.nowMs - started
            status = json
            receivedAtMs = site.scheduler.nowMs
            fresh = took < Self.maxAgeMs && site.session.phase == .streaming
            expiry?.cancel()
            expiry = site.scheduler.after(max(0, Self.maxAgeMs - took)) { [weak self] in self?.fresh = false }
        } catch {
            expiry?.cancel()
            fresh = false
        }
    }
}

/// The chargers, read every five seconds for the Now diagram and the car
/// notice. Hidden phones stop polling.
@Observable
@MainActor
public final class ChargingWatch: Activatable {
    public private(set) var points: [Loadpoint] = []
    public private(set) var fresh = false

    @ObservationIgnored private unowned let site: SiteModel
    @ObservationIgnored private var poller: Poller!
    @ObservationIgnored private var expiry: Cancellable?
    @ObservationIgnored private var active = 0

    public init(site: SiteModel) {
        self.site = site
        poller = Poller(scheduler: site.scheduler, periodMs: 5_000, shouldRun: { [weak self] in
            guard let self else { return false }
            if !(self.site.documentVisible && self.site.session.phase == .streaming && self.site.hasPassthrough) {
                self.fresh = false
                return false
            }
            return true
        }, work: { [weak self] in await self?.read() })
    }

    public func activate() {
        active += 1
        if active == 1 { poller.start() }
    }

    public func deactivate() {
        active = max(0, active - 1)
        if active == 0 {
            poller.stop()
            fresh = false
        }
    }

    public func refresh() { poller.refresh() }

    /// Charger watts for the diagram, zero unless fresh.
    public var chargeW: Double { fresh ? Flow.loadpointChargeW(points) : 0 }

    private func read() async {
        do {
            guard let list = try await site.callBox(.get, "/api/loadpoints")?["loadpoints"]?.array else {
                throw BoxAPIError(code: "E_BAD_BODY", help: "", status: nil)
            }
            let next = list.map(Loadpoint.init).map { lp -> Loadpoint in
                // A charger that went out of touch keeps its last known cable.
                var lp = lp
                if lp.charger?.available == false, points.first(where: { $0.id == lp.id })?.pluggedIn == true { lp.pluggedIn = true }
                return lp
            }
            points = next
            fresh = site.documentVisible && site.session.phase == .streaming
            expiry?.cancel()
            expiry = site.scheduler.after(15_000) { [weak self] in self?.fresh = false }
        } catch {
            fresh = false
        }
    }
}

/// Prices across today and tomorrow, from local midnight, asked for again
/// when the day turns and when tomorrow's rates publish.
@Observable
@MainActor
public final class PriceModel: Activatable {
    static let horizonMs: Double = 48 * 3_600_000
    static let publishHour = 14

    public private(set) var prices: Prices?
    public private(set) var fromMs: Double = 0

    @ObservationIgnored private unowned let site: SiteModel
    @ObservationIgnored private var ask: LiveAsk?
    @ObservationIgnored private var active = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let calendar: Calendar

    public init(site: SiteModel, calendar: Calendar = .current) {
        self.site = site
        self.calendar = calendar
    }

    public var currency: String { prices?.currency ?? "SEK" }
    public var hasHole: Bool { prices.map { PriceUnits.hasHole($0.slots, fromMs: fromMs) } ?? false }

    func midnight(_ ms: Double) -> Double {
        calendar.startOfDay(for: Date(timeIntervalSince1970: ms / 1000)).timeIntervalSince1970 * 1000
    }

    /// The window, named by what would make it out of date.
    var wanted: String? {
        guard active > 0, site.session.caps.contains(Contract.capPriceSpot) else { return nil }
        let now = Date(timeIntervalSince1970: site.nowMs / 1000)
        let hour = calendar.component(.hour, from: now)
        return "\(midnight(site.nowMs))/\(hour >= Self.publishHour ? "published" : "pending")"
    }

    public func activate() {
        active += 1
        if ask == nil {
            ask = LiveAsk(site: site, want: { [weak self] in
                guard let self else { return nil }
                // A box that stopped offering prices shows none; a window
                // from yesterday is not today's.
                if !self.site.session.caps.contains(Contract.capPriceSpot) { self.prices = nil }
                if self.prices != nil, self.midnight(self.site.nowMs) != self.fromMs { self.prices = nil }
                return self.wanted
            }, ask: { [weak self] in try await self?.load() })
        }
        ask?.evaluate()
    }

    public func deactivate() {
        active = max(0, active - 1)
        ask?.evaluate()
    }

    func load() async throws {
        generation += 1
        let mine = generation
        let from = midnight(site.nowMs)
        do {
            let wire = try await site.prices(fromMs: from, toMs: from + Self.horizonMs)
            guard mine == generation else { return }
            prices = wire
            fromMs = from
        } catch {
            // A window already drawn stays drawn; today's prices are still
            // today's. Rethrown so the ask heals.
            guard mine == generation else { return }
            throw error
        }
    }
}

/// Money saved today and this week, GET /api/savings/daily.
@Observable
@MainActor
public final class SavingsModel: Activatable {
    public private(set) var periods: Savings.Periods?

    @ObservationIgnored private unowned let site: SiteModel
    @ObservationIgnored private var ask: LiveAsk?
    @ObservationIgnored private var active = 0
    @ObservationIgnored private let calendar: Calendar

    public init(site: SiteModel, calendar: Calendar = .current) {
        self.site = site
        self.calendar = calendar
    }

    public func activate() {
        active += 1
        if ask == nil {
            ask = LiveAsk(site: site, want: { [weak self] in
                guard let self, self.active > 0, self.site.hasPassthrough else { return nil }
                return "savings \(self.calendar.startOfDay(for: Date(timeIntervalSince1970: self.site.nowMs / 1000)).timeIntervalSince1970)"
            }, ask: { [weak self] in try await self?.load() })
        }
        ask?.evaluate()
    }

    public func deactivate() {
        active = max(0, active - 1)
        ask?.evaluate()
    }

    func load() async throws {
        let wire = try await site.callBox(.get, "/api/savings/daily", query: ["days": "7"])
        let days = (wire?["days"]?.array ?? []).compactMap(Savings.day)
        let next = Savings.periods(days)
        periods = next.today.available || next.week.available ? next : nil
    }
}
