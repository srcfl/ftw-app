import Foundation
import FTWShared
import Observation

/// This phone's watch on its own (srcfl/ftw ADR 0009, "Through FTW Cloud").
///
/// The watch offers the public half of its own key over WatchConnectivity.
/// An owner adds it to the box once, with a passkey step-up; the box then
/// lists the watch, and FTW Cloud admits it. The phone hands the watch a
/// link with what it needs to reach the box with no phone near: the box's
/// keys, FTW Cloud's home id and its tables, and what Charge now asks of
/// each charger. The box decides everything after that.
@Observable
@MainActor
public final class WatchAccess {
    /// The paired watch's public key, as it last offered it. Nil before a
    /// watch with FTW has spoken.
    public var watchKey: Data?
    public private(set) var adding = false
    /// Why the last add did not go through, in a sentence. Nil after one did.
    public private(set) var failure: String?
    /// The watch key this phone added to each home, by site. Not a secret:
    /// the box holds the list, and this spares asking it again.
    private var added: [String: Data]
    @ObservationIgnored private let defaults: UserDefaults
    static let addedKey = "FTWWatchAdded"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        added = (defaults.dictionary(forKey: Self.addedKey) as? [String: Data]) ?? [:]
    }

    /// Whether to offer adding the watch: a watch that offered its key, an
    /// owner's phone, and a box whose link to FTW Cloud carries a watch's
    /// exchange (`cmd.exchange`).
    public func canAdd(_ home: HomeModels) -> Bool {
        watchKey != nil && home.site.canConfigure && home.site.session.caps.contains(Contract.capCmdExchange)
    }

    /// This phone added the watch it has now to this home.
    public func isAdded(_ home: HomeModels) -> Bool {
        guard let siteId = home.site.siteId, let key = watchKey else { return false }
        return added[siteId] == key
    }

    /// Add the watch to the box by its key. The step-up runs first: a watch
    /// is a new key that can charge the car from anywhere.
    public func add(_ home: HomeModels) async {
        guard let siteId = home.site.siteId, let key = watchKey, !adding else { return }
        adding = true
        failure = nil
        defer { adding = false }
        do {
            _ = try await home.site.callBox(.post, "/api/app-link/pairing", body: .object([
                ("role", .string(Contract.roleWatch)),
                ("key", .string(Base64url.encode(Bytes(key)))),
            ]), freshStepUp: true)
            added[siteId] = key
            defaults.set(added, forKey: Self.addedKey)
        } catch let e as BoxAPIError {
            failure = e.help.isEmpty ? AppWords.text("That didn't work. Nothing on your box has changed.") : e.help
        } catch {
            failure = AppWords.text("That didn't work. Nothing on your box has changed.")
        }
    }

    /// The link for the watch, once this phone added it to the home. Nil
    /// before, and while the box has not named its home at FTW Cloud.
    public func link(_ home: HomeModels, boxKey: Data, cloudHome: String?) -> WatchLink? {
        guard isAdded(home), let key = watchKey else { return nil }
        let site = home.site
        let identity = site.cloudIdentity
        guard let cloudHome = identity?.home ?? cloudHome else { return nil }
        var chargeNow = [String: WatchLink.ChargeNow]()
        for lp in home.loadpoints.points {
            let range = EVText.current(lp)
            chargeNow[lp.id] = WatchLink.ChargeNow(powerW: EVText.watts(lp, amps: range.maxA), phaseMode: range.phases == 1 ? "1p" : "3p")
        }
        return WatchLink(
            site: WatchShare.homeKey(home),
            cloudHome: cloudHome,
            boxKey: boxKey,
            cloudKey: identity?.copyOn == true ? identity.map { Data($0.pk) } : nil,
            sources: identity?.sources ?? [:],
            loadpoints: identity?.loadpoints ?? [:],
            watchKey: key,
            chargeNow: chargeNow,
            timeZone: site.session.box?.tz
        )
    }
}
