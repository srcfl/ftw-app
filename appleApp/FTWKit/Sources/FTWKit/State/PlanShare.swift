import Foundation
import FTWShared

extension PlanEntry {
    /// The plan as the app holds it right now: the box's battery plan, each
    /// car's charging windows with the level it charges toward, and the
    /// prices under them. Prices come from the price model, or else from the
    /// plan's own slots.
    public static func live(plan: Plan?, points: [Loadpoint], windows: [String: [Loadpoint.Window]], prices: Prices?) -> PlanEntry {
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
        return PlanEntry(battery: battery, charges: charges, prices: slots, currency: prices?.currency ?? "SEK", boxStale: plan?.stale ?? false)
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
/// or goal, or the prices under them.
///
/// The record carries when the box last sent its plan, not when the app
/// wrote the file, so the widget's age is the plan's age.
@MainActor
public final class PlanShare {
    private unowned let site: SiteModel
    private unowned let plan: PlanModel
    private unowned let loadpoints: LoadpointsModel
    private unowned let prices: PriceModel
    private var token: Int?
    private var lastKey: String?
    private var lastPlanKey: String?
    private var lastSentAtMs: Double?
    /// When the plan on the session last changed, for one the box pushed.
    private var changedAtMs: Double?

    public init(site: SiteModel, plan: PlanModel, loadpoints: LoadpointsModel, prices: PriceModel) {
        self.site = site
        self.plan = plan
        self.loadpoints = loadpoints
        self.prices = prices
        token = site.observe { [weak self] in self?.check() }
    }

    /// The plan as Now draws it.
    public var entry: PlanEntry {
        PlanEntry.live(plan: site.session.plan, points: loadpoints.points, windows: loadpoints.windows, prices: prices.prices)
    }

    /// What would make the record different. Cheap enough for every tick.
    var key: String {
        let w = loadpoints.points.map { lp in "\(lp.id):\((loadpoints.windows[lp.id] ?? lp.planWindows).map { "\($0.fromMs)-\($0.toMs)" }.joined(separator: ",")):\(lp.targetSocPct ?? lp.schedule?.socPct ?? -1)" }
        let p = prices.prices.map { "\($0.slots.count)@\($0.slots.first?.startMs ?? 0)" } ?? "-"
        return "\(planKey)|\(w.joined(separator: ";"))|\(p)"
    }

    private var planKey: String {
        let p = site.session.plan
        return "\(p?.rev ?? 0)|\(p?.slots.first?.startMs ?? 0)|\(p?.slots.count ?? 0)|\(p?.stale ?? false)"
    }

    /// When the box last sent the plan: the latest answer to `plan.get`, or
    /// the moment a plan it pushed landed.
    var sentAtMs: Double? {
        [plan.receivedAtMs, changedAtMs].compactMap { $0 }.max()
    }

    func check() {
        let planKey = self.planKey
        if planKey != lastPlanKey {
            lastPlanKey = planKey
            if site.session.plan != nil { changedAtMs = site.nowMs }
        }
        // Nothing to say until the box has sent a plan.
        guard site.session.plan != nil, let sent = sentAtMs else { return }
        let key = self.key
        guard key != lastKey || sent != lastSentAtMs else { return }
        lastKey = key
        lastSentAtMs = sent
        site.sharePlan(entry.trimmed(nowMs: site.nowMs), sentAtMs: sent)
    }
}
