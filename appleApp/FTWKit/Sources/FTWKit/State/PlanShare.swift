import Foundation
import FTWShared

extension PlanEntry {
    /// The plan as the app holds it right now: the box's battery plan, each
    /// car's charging windows with the level it charges toward, and the
    /// prices under them. Prices come from the price model, or else from the
    /// plan's own slots.
    public static func live(plan: Plan?, points: [Loadpoint], windows: [String: [Loadpoint.Window]], prices: Prices?, timeZone: String? = nil) -> PlanEntry {
        let battery = plan.map { p in p.slots.map { Slot(startMs: $0.startMs, durationMs: $0.durationMs, batteryW: $0.batteryW, reason: $0.reason) } }
        var charges = [Charge]()
        for lp in points {
            for w in windows[lp.id] ?? lp.planWindows {
                charges.append(Charge(loadpointID: lp.id, fromMs: w.fromMs, toMs: w.toMs, energyWh: w.energyWh, targetPct: lp.targetSocPct ?? lp.schedule?.socPct))
            }
        }
        var slots = prices?.slots ?? []
        if slots.isEmpty, let plan {
            slots = plan.slots.compactMap { s in s.priceMinor.map { PriceSlot(startMs: s.startMs, durationMs: s.durationMs, spotMinor: $0, totalMinor: $0) } }
        }
        return PlanEntry(battery: battery, charges: charges, prices: slots, currency: prices?.currency ?? "SEK", boxStale: plan?.stale ?? false, timeZone: timeZone)
    }

    /// Only what lies ahead, for the widget's record: from an hour back to a
    /// day ahead.
    func trimmed(nowMs: Double) -> PlanEntry {
        let from = nowMs - 3_600_000, to = nowMs + 24 * 3_600_000
        var e = self
        e.battery = battery?.filter { $0.startMs + $0.durationMs > from && $0.startMs < to }
        e.charges = charges.filter { $0.toMs > from && $0.fromMs < to }
        e.prices = prices.filter { $0.startMs + $0.durationMs > from && $0.startMs < to }
        return e
    }
}

/// Leaves the plan for the plan widget whenever it changes: a new plan from
/// the box, the same plan confirmed by a fresh `plan.get`, a car's windows
/// or goal, or the prices under them. A plan kept from an earlier launch is
/// never written back: the widget already holds it, dated.
///
/// The record carries when the box last sent its plan, not when the app
/// wrote the file, so the widget's age is the plan's age.
@MainActor
public final class PlanShare {
    private unowned let site: SiteModel
    private unowned let plan: PlanModel
    private unowned let loadpoints: LoadpointsModel
    private unowned let prices: PriceModel
    /// The plan the app left for its widgets at an earlier launch, for Now
    /// to open on when the sealed home file holds none.
    private let kept: CacheRead<PlanEntry>?
    private var token: Int?
    private var lastKey: String?
    private var lastSentAtMs: Double?

    public init(site: SiteModel, plan: PlanModel, loadpoints: LoadpointsModel, prices: PriceModel, cache: CacheReader? = nil) {
        self.site = site
        self.plan = plan
        self.loadpoints = loadpoints
        self.prices = prices
        kept = site.siteId.flatMap { cache?.read(PlanEntry.self, siteId: $0) }
        token = site.observe { [weak self] in self?.check() }
        plan.received = { [weak self] in self?.check() }
    }

    /// The plan as Now draws it.
    public var entry: PlanEntry {
        PlanEntry.live(plan: plan.plan, points: loadpoints.points, windows: loadpoints.windows, prices: prices.prices, timeZone: loadpoints.zone.identifier)
    }

    /// The plan at `nowMs` as Now and the plan view show it: the box's own
    /// once it has answered; else the plan kept from an earlier launch,
    /// dated; else the card's shape until the box answers. "No plan" is
    /// said only after the box has answered without one.
    public func moment(nowMs: Double) -> PlanGlance.Moment {
        if let s = plan.stamped {
            return s.fromCache ? PlanGlance.kept(entry, readAtMs: s.asOfMs, nowMs: nowMs) : PlanGlance.live(entry, nowMs: nowMs)
        }
        if let kept { return PlanGlance.kept(kept.value, readAtMs: kept.record.readAtMs, nowMs: nowMs) }
        return PlanGlance.waiting(entry, nowMs: nowMs, note: plan.problem)
    }

    /// What would make the record different. Cheap enough for every tick.
    var key: String {
        let w = loadpoints.points.map { lp in "\(lp.id):\((loadpoints.windows[lp.id] ?? lp.planWindows).map { "\($0.fromMs)-\($0.toMs)" }.joined(separator: ",")):\(lp.targetSocPct ?? lp.schedule?.socPct ?? -1)" }
        let p = prices.prices.map { "\($0.slots.count)@\($0.slots.first?.startMs ?? 0)" } ?? "-"
        let plan = self.plan.plan
        return "\(plan?.rev ?? 0)|\(plan?.slots.first?.startMs ?? 0)|\(plan?.slots.count ?? 0)|\(plan?.stale ?? false)|\(w.joined(separator: ";"))|\(p)"
    }

    func check() {
        plan.sync()
        // Nothing to say until the box has sent a plan in this session.
        guard let s = plan.stamped, !s.fromCache, let sent = plan.receivedAtMs else { return }
        let key = self.key
        guard key != lastKey || sent != lastSentAtMs else { return }
        lastKey = key
        lastSentAtMs = sent
        site.sharePlan(entry.trimmed(nowMs: site.nowMs), sentAtMs: sent)
    }
}
