import Foundation
import FTWShared

/// The five places energy goes on Now, each a door to its own view: the
/// sun, the house battery, the home's own use, the grid and the car.
public enum EnergyNode: String, CaseIterable, Hashable, Sendable, Identifiable, Codable {
    case solar, battery, home, grid, car

    public var id: String { rawValue }

    /// The lane 0 field that carries it, by the site convention: positive
    /// into the site. Solar is never positive; the battery is positive while
    /// it charges; the grid while the home imports.
    public var fid: Int {
        switch self {
        case .solar: return Contract.FID.pvW
        case .battery: return Contract.FID.batteryW
        case .home: return Contract.FID.loadW
        case .grid: return Contract.FID.gridW
        case .car: return Contract.FID.evW
        }
    }

    /// How a reading reads on screen: solar as what it makes, everything
    /// else as the box signs it. The sign becomes a word, never a minus.
    public func shown(_ watts: Double) -> Double {
        self == .solar ? -watts : watts
    }

    /// The registry's name for the series, which history uses too.
    public var series: String {
        switch self {
        case .solar: return "pv_w"
        case .battery: return "battery_w"
        case .home: return "load_w"
        case .grid: return "grid_w"
        case .car: return "ev_w"
        }
    }

    /// Its name, in the phone's language.
    public var title: String {
        switch self {
        case .solar: return NodeWords.text("Solar")
        case .battery: return NodeWords.text("Battery")
        case .home: return NodeWords.text("Usage")
        case .grid: return NodeWords.text("Grid")
        case .car: return NodeWords.text("Car")
        }
    }

    /// Its name as the small capitals over a figure.
    public var caps: String {
        switch self {
        case .solar: return NodeWords.text("SOLAR")
        case .battery: return NodeWords.text("BATTERY")
        case .home: return NodeWords.text("USAGE")
        case .grid: return NodeWords.text("GRID")
        case .car: return NodeWords.text("CAR")
        }
    }

    /// The least its chart's scale reaches, in watts, so a quiet node's
    /// noise stays small: a grid held at 0 ± 60 W by the battery spreads
    /// 40 pt on a scale fitted to the noise and 3 pt on 3 kW. A known
    /// rating (the inverter, the panels' peak, the charger's maximum, the
    /// main fuse) takes the place of the default.
    public func scaleFloorW(rating: Double? = nil) -> Double {
        if let rating, rating.isFinite, rating > 0 { return rating }
        switch self {
        case .home: return 2_000
        case .grid: return 3_000
        case .battery: return 3_000
        case .solar: return 3_000
        case .car: return 3_700
        }
    }

    /// Which way is up on its curve, for the two whose curve crosses zero.
    public var directions: (up: String, down: String)? {
        switch self {
        case .battery: return (NodeWords.text("charging"), NodeWords.text("giving power"))
        case .grid: return (NodeWords.text("buying"), NodeWords.text("selling"))
        default: return nil
        }
    }
}

/// Whether one node's reading is live, said the way the band says it for
/// the whole home: how frames reach the phone (`carrier`) and whether the
/// device behind this one reading answers (`srcState`). Two facts, never
/// one. A node looks live only while both are.
public struct NodeFreshness: Equatable, Sendable {
    public let carrier: CarrierKind
    public let srcState: SourceState
    /// How old the reading is, in ms. Nil when the box cannot place it,
    /// which happens after a restart.
    public let ageMs: Double?
    /// The device behind the reading, as the box names it.
    public let sourceName: String?

    public init(carrier: CarrierKind, srcState: SourceState, ageMs: Double?, sourceName: String?) {
        self.carrier = carrier
        self.srcState = srcState
        self.ageMs = ageMs
        self.sourceName = sourceName
    }

    public var live: Bool {
        carrier.connected && srcState == .live
    }

    /// From the session as it stands: the field's source in the box's
    /// dictionary, that source's state, and how long the stream has been
    /// quiet. A field the box computes itself has no source of its own and
    /// takes the worst of the sources on screen.
    public static func of(
        fid: Int,
        session: SessionState,
        carrier: CarrierKind,
        streamQuietMs: Double,
        shelfMs: Double?,
        fallback: SourceState
    ) -> NodeFreshness {
        guard session.fields[fid] != nil else {
            return NodeFreshness(carrier: carrier, srcState: .never, ageMs: nil, sourceName: nil)
        }
        let srcId = session.dict[fid]?.srcId
        let source = srcId.flatMap { session.sources[$0] }
        var state = srcId == nil ? fallback : (source?.state ?? .never)
        var age: Double? = source.flatMap { s in
            let a = session.uptimeMs - s.lastOkMs
            return a < 0 ? nil : a
        }
        // Off the disk, every state is as it was written; the shelf is part
        // of the age.
        if let shelfMs {
            if state == .live { state = .stale }
            age = age.map { $0 + shelfMs } ?? shelfMs
        } else if streamQuietMs > 0 {
            // A stream gone quiet is not live however healthy it looked.
            if state == .live { state = .lagging }
            age = age.map { $0 + streamQuietMs }
        }
        return NodeFreshness(carrier: carrier, srcState: state, ageMs: age, sourceName: source?.name)
    }
}

extension SiteModel {
    /// One node's freshness, from the stream as it stands.
    public func freshness(_ node: EnergyNode) -> NodeFreshness {
        freshness(fid: node.fid)
    }

    public func freshness(fid: Int) -> NodeFreshness {
        let f = NodeFreshness.of(
            fid: fid,
            session: asCached(session),
            carrier: carrier,
            streamQuietMs: sinceLastFrameMs,
            shelfMs: carrier == .cache ? cachedAtMs.map { max(0, nowMs - $0) } : nil,
            fallback: lastFrameAtMs == nil ? .stale : srcState
        )
        // Through FTW Cloud a reading is no fresher than the cloud's own
        // grade for its field: anchored, and inside the age rules.
        guard carrier == .cloud, let cap = cloudGrade(fid: fid), cap > f.srcState else { return f }
        return NodeFreshness(carrier: f.carrier, srcState: cap, ageMs: f.ageMs, sourceName: f.sourceName)
    }
}

/// Everything the nodes' views read, built once per home beside the other
/// models, so a second visit is instant and the live curve has been
/// recording since the home opened.
@MainActor
public final class NodeModels {
    public let live: LiveTrace
    public let history: HistoryModel
    public let carEnergy: CarEnergyModel
    public let plan: PlanModel
    public let mode: ModeModel
    public let sources: SourcesModel
    /// The plan as Now draws it, and as the plan widget reads it.
    public let planShare: PlanShare

    public init(site: SiteModel, loadpoints: LoadpointsModel, prices: PriceModel, cache: CacheReader? = nil) {
        live = LiveTrace(site: site)
        history = HistoryModel(site: site)
        carEnergy = CarEnergyModel(site: site)
        plan = PlanModel(site: site)
        mode = ModeModel(site: site)
        sources = SourcesModel(site: site)
        planShare = PlanShare(site: site, plan: plan, loadpoints: loadpoints, prices: prices, cache: cache)
        // A change the box applied is followed by its new plan.
        mode.applied = { [plan] in plan.follow() }
        mode.willSend = { [plan] in plan.expectChange() }
    }
}
