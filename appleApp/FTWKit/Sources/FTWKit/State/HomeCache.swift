import Foundation
import FTWShared

/// What the app keeps of a home between launches beside its readings
/// (`snapshot-<site>`): what the box said at hello, the planner's
/// preferences, the plan, the forecast, the prices, the chargers and which
/// nodes Now draws. Sealed like the readings, in `home-<site>`.
///
/// Every screen opens on it in its final shape, dated, and the box corrects
/// it. A household's habits live here, in the sealed app cache, and never in
/// the App Group; removing the phone erases them with the rest.
public struct HomeCache: Codable, Equatable, Sendable {
    static let version = 1

    /// What the box said at hello. Applied at start without `heardFromBox`:
    /// until the box has spoken, none of it unlocks a control, and hello
    /// replaces all of it.
    public struct Hello: Codable, Equatable, Sendable {
        public var caps: [String]
        public var modes: [ModeInfo]
        public var box: BoxInfo?
        public var role: String
        public var scopes: [String]

        init(_ s: SessionState) {
            caps = s.caps.sorted()
            modes = s.modes
            box = s.box
            role = s.role
            scopes = s.scopes.sorted()
        }

        func apply(to s: inout SessionState) {
            s.caps = Set(caps)
            s.modes = modes
            s.box = box
            s.role = role
            s.scopes = Set(scopes)
        }
    }

    public var version = HomeCache.version
    public var siteId: String
    public var hello: Hello?
    public var prefs: Stamped<ModeModel.Prefs>?
    public var plan: Stamped<Plan>?
    public var forecast: Stamped<[PlanModel.Forecast]>?
    public var prices: Stamped<PriceEntry>?
    public var chargers: Stamped<LoadpointsModel.Chargers>?
    /// The nodes Now drew, in its order.
    public var nodes: [EnergyNode]?

    public init(siteId: String) {
        self.siteId = siteId
    }

    /// As a later launch reads it: every stamp from the cache. Two files
    /// that read back the same say the same thing.
    var asRead: HomeCache {
        var c = self
        c.prefs = prefs?.cached
        c.plan = plan?.cached
        c.forecast = forecast?.cached
        c.prices = prices?.cached
        c.chargers = chargers?.cached
        return c
    }
}
