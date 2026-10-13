import Foundation
import Observation

/// FTW Cloud as the person agrees to it, and as the box holds it.
///
/// The app uses FTW Cloud as part of the service, so the answer is given
/// once, when the person starts using the app, on one screen. Statistics are
/// a separate box on that screen, off until ticked. The grant itself lives on
/// the box: an owner's phone turns it on there over its Noise session, the
/// first time, and an owner can turn it off again from About. A viewer cannot
/// change it and is told to ask the owner.
@Observable
@MainActor
public final class CloudConsent {
    /// The consent texts the person read. The box records the names.
    public static let policy = "ftw-cloud-2026-10"
    public static let statsPolicy = "ftw-stats-2026-10"

    /// What the box says about FTW Cloud, for an owner.
    public struct BoxState: Equatable, Sendable {
        /// off, on or revoking.
        public var state: String
        public var stats: Bool
        public var connected: Bool
        /// When the service confirmed it erased the home's copy.
        public var erasedAtMs: Double?

        public var on: Bool { state == "on" }
        public var erasing: Bool { state == "revoking" }

        init(_ json: JSON) {
            state = json["state"]?.string ?? "off"
            stats = (json["purposes"]?.array ?? []).contains { $0.string == Contract.cloudPurposeStats }
            connected = json["connected"]?.bool ?? false
            erasedAtMs = json["purgedAtMs"]?.number.flatMap { $0 > 0 ? $0 : nil }
        }
    }

    /// Whom the screen speaks to.
    public enum Audience: Equatable, Sendable {
        /// An owner whose box can run FTW Cloud.
        case owner
        /// An owner whose box cannot yet: it turns FTW Cloud on after an
        /// update.
        case ownerLater
        case viewer
        /// The box has not answered yet.
        case unknown
    }

    public private(set) var answered: Bool
    /// The statistics box. Off until the person ticks it.
    public var contributeStats = false
    public private(set) var box: BoxState?
    public private(set) var working = false
    public private(set) var help: String?

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        answered = defaults.string(forKey: Keys.answered) == Self.policy
        contributeStats = defaults.bool(forKey: Keys.stats)
    }

    /// The one screen, once, on a real home.
    public func shouldAsk(_ site: SiteModel?) -> Bool {
        guard let site, !site.isDemo, site.siteId != nil else { return false }
        return !answered
    }

    public static func audience(_ site: SiteModel) -> Audience {
        guard site.heardFromBox else { return .unknown }
        guard site.canConfigure else { return .viewer }
        return site.session.caps.contains(Contract.capCloudLink) ? .owner : .ownerLater
    }

    /// The person read the screen and went on. An owner's phone turns FTW
    /// Cloud on at the box now, or once the box can.
    public func accept(_ site: SiteModel?) async {
        defaults.set(Self.policy, forKey: Keys.answered)
        defaults.set(contributeStats, forKey: Keys.stats)
        answered = true
        guard let site else { return }
        await ensure(site)
    }

    /// Turn FTW Cloud on at the box for an owner who agreed, once per home.
    /// After that the box's word stands: if someone turned it off, on the box
    /// or in About, it stays off until an owner turns it on again.
    public func ensure(_ site: SiteModel) async {
        guard answered, let siteId = site.siteId, !site.isDemo, Self.audience(site) == .owner,
              !defaults.bool(forKey: Keys.asked(siteId)) else { return }
        // Already on: nothing to ask for, now or later.
        if site.cloudOn {
            defaults.set(true, forKey: Keys.asked(siteId))
            return
        }
        if await turnOn(site) {
            defaults.set(true, forKey: Keys.asked(siteId))
        }
    }

    /// What the box holds now. Owners only; a viewer's phone may not ask.
    public func refresh(_ site: SiteModel) async {
        guard site.canConfigure else { return }
        do {
            box = try await site.callBox(.get, "/api/cloud").map(BoxState.init)
            help = nil
        } catch let e as BoxAPIError {
            help = e.help
        } catch {
            help = nil
        }
    }

    /// FTW Cloud on, with statistics if the person agreed to them.
    @discardableResult
    public func turnOn(_ site: SiteModel) async -> Bool {
        await act {
            let scopes = JSON.array(Contract.cloudScopes.map { .string($0) })
            let granted = try await site.callBox(.post, "/api/cloud/grant", body: .object([("scopes", scopes), ("policy", .string(Self.policy))]))
            box = granted.map(BoxState.init)
            if contributeStats {
                box = try await site.callBox(.post, "/api/cloud/stats", body: .object([("policy", .string(Self.statsPolicy))])).map(BoxState.init)
            }
            if let siteId = site.siteId { defaults.set(true, forKey: Keys.asked(siteId)) }
        }
    }

    /// FTW Cloud off. The box asks the service to erase its copy and shows
    /// the receipt once it has one.
    @discardableResult
    public func turnOff(_ site: SiteModel) async -> Bool {
        // Off by hand is the person's word: the app never turns it on again
        // by itself.
        if let siteId = site.siteId { defaults.set(true, forKey: Keys.asked(siteId)) }
        return await act {
            box = try await site.callBox(.delete, "/api/cloud/grant").map(BoxState.init)
        }
    }

    @discardableResult
    public func setStats(_ on: Bool, _ site: SiteModel) async -> Bool {
        contributeStats = on
        defaults.set(on, forKey: Keys.stats)
        return await act {
            box = on
                ? try await site.callBox(.post, "/api/cloud/stats", body: .object([("policy", .string(Self.statsPolicy))])).map(BoxState.init)
                : try await site.callBox(.delete, "/api/cloud/stats").map(BoxState.init)
        }
    }

    private func act(_ work: () async throws -> Void) async -> Bool {
        working = true
        defer { working = false }
        do {
            try await work()
            help = nil
            return true
        } catch let e as BoxAPIError {
            help = e.help
        } catch {
            help = CloudWords.text("That didn't work. Nothing on your box has changed.")
        }
        return false
    }

    enum Keys {
        static let answered = "FTWCloudConsent"
        static let stats = "FTWCloudStats"
        static func asked(_ siteId: String) -> String { "FTWCloudAsked-\(siteId)" }
    }
}

/// The words of the consent screen and the FTW Cloud row in About, in
/// English or Swedish, with the language `AppWords` uses.
public enum CloudWords {
    public static func text(_ en: String) -> String {
        AppWords.language == .sv ? (sv[en] ?? en) : en
    }

    public static func format(_ en: String, _ args: String...) -> String {
        var out = text(en)
        for a in args {
            guard let r = out.range(of: "%@") else { break }
            out.replaceSubrange(r, with: a)
        }
        return out
    }

    static let sv: [String: String] = [
        "The FTW app uses FTW Cloud": "FTW-appen använder FTW Cloud",
        "FTW Cloud is part of the service. It keeps a copy of your home, signed by your box, so the app opens at once and stays up to date.":
            "FTW Cloud ingår i tjänsten. Den håller en kopia av ditt hem, signerad av din box, så att appen öppnar direkt och håller sig uppdaterad.",
        "Your box still decides. Commands go straight to it, never through FTW Cloud.":
            "Boxen bestämmer fortfarande. Kommandon går direkt till den, aldrig via FTW Cloud.",
        "Contribute to statistics": "Bidra till statistik",
        "Hourly energy totals, without your name or address, help make FTW better. Off unless you turn it on.":
            "Energisummor per timme, utan namn eller adress, hjälper oss att göra FTW bättre. Av tills du slår på det.",
        "Ask the owner of this home to turn on FTW Cloud.": "Be ägaren av hemmet att slå på FTW Cloud.",
        "Your box turns on FTW Cloud after its next update.": "Din box slår på FTW Cloud efter nästa uppdatering.",
        "Continue": "Fortsätt",
        "Privacy policy": "Integritetspolicy",
        "You can turn FTW Cloud off in About.": "Du kan stänga av FTW Cloud under Om.",
        "That didn't work. Nothing on your box has changed.": "Det gick inte. Inget på din box har ändrats.",
        "FTW Cloud": "FTW Cloud",
        "On": "På",
        "Off": "Av",
        "Erasing the copy": "Raderar kopian",
        "Copy erased %@": "Kopian raderad %@",
        "Connected": "Ansluten",
        "Not connected": "Inte ansluten",
        "Only the owner of this home can change this.": "Bara ägaren av hemmet kan ändra det här.",
        "FTW Cloud is on for this home.": "FTW Cloud är på för det här hemmet.",
        "FTW Cloud is off for this home.": "FTW Cloud är av för det här hemmet.",
        "Your box can't use FTW Cloud yet.": "Din box kan inte använda FTW Cloud än.",
        "Turning it off erases the copy in FTW Cloud. Your box shows when it is gone.":
            "Stänger du av raderas kopian i FTW Cloud. Boxen visar när den är borta.",
        "With FTW Cloud on, Sourceful keeps a copy of your home's readings, signed by your box, to serve this app. Commands travel encrypted between this phone and your box, and Sourceful cannot read them.":
            "Med FTW Cloud på håller Sourceful en kopia av hemmets mätvärden, signerad av din box, för den här appen. Kommandon går krypterade mellan telefonen och boxen, och Sourceful kan inte läsa dem.",
    ]
}
