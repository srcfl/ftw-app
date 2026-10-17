import Foundation
import Observation

/// The current FTW Cloud terms. Statistics are part of Cloud; the box owns
/// the accepted version. A local-only statistics choice lives on the box UI.
@Observable
@MainActor
public final class CloudConsent {
    nonisolated public static let policy = "ftw-cloud-2026-10-v3"
    nonisolated public static let statsPolicy = "ftw-project-stats-2026-10-v3"
    nonisolated public static let statisticsDetails = "Recorded hourly energy, configured battery capacity, battery and charger power limits, and solar capacity help Sourceful improve FTW and publish group totals. Values are rounded to 10 Wh or W. No names, addresses or device ids."
    nonisolated public static let statisticsPrivacy = "Sourceful links reports to your Cloud home for deletion. They are not anonymous and stay for 48 hours. Public values need at least 20 homes, with no home above 30% of a sum. Turning FTW Cloud off deletes unpublished reports when the box reaches Cloud; published totals remain."
    nonisolated public static let statisticsWaiting = "Hourly collection waits for privacy review and policy activation. Your choice can be saved now; no hourly report leaves before approval."
    nonisolated public static let included = "Everyone using FTW Cloud contributes to project statistics. There is no separate statistics switch. If you do not want to contribute, use FTW locally without Cloud. Local users can choose to share statistics without enabling remote access."

    public struct BoxState: Equatable, Sendable {
        public var state: String
        public var stats: Bool
        public var termsAccepted: Bool
        public var connected: Bool
        public var erasedAtMs: Double?
        public var on: Bool { state == "on" }
        public var erasing: Bool { state == "revoking" }
        init(_ json: JSON) {
            state = json["state"]?.string ?? "off"
            stats = json["statisticsPolicy"]?.string == CloudConsent.statsPolicy && json["statisticsActive"]?.bool == true
            termsAccepted = json["cloudPolicy"]?.string == CloudConsent.policy && json["cloudTermsAccepted"]?.bool == true
            connected = json["connected"]?.bool ?? false
            erasedAtMs = json["purgedAtMs"]?.number.flatMap { $0 > 0 ? $0 : nil }
        }
    }
    public enum Audience: Hashable, Sendable { case owner, ownerLater, viewer, unknown }
    public private(set) var answered: Bool
    public private(set) var acceptedHome: String?
    public private(set) var box: BoxState?
    public private(set) var working = false
    public private(set) var help: String?
    public private(set) var statisticsReady = false
    public private(set) var policyAvailable = false
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        answered = defaults.string(forKey: Keys.answered) == Self.policy
    }
    public func shouldAsk(_ site: SiteModel?) -> Bool {
        guard let site, !site.isDemo, site.siteId != nil else { return false }
        let accepted = acceptedHome == site.siteId || defaults.string(forKey: Keys.asked(site.siteId!)) == Self.policy
        return !answered || !accepted || defaults.string(forKey: Keys.pending(site.siteId!)) == Self.policy
    }
    public static func audience(_ site: SiteModel) -> Audience {
        guard site.heardFromBox else { return .unknown }
        guard site.canConfigure else { return .viewer }
        return site.session.caps.contains(Contract.capCloudLink) ? .owner : .ownerLater
    }
    @discardableResult
    public func accept(_ site: SiteModel?) async -> Bool {
        guard let site else { return false }
        switch Self.audience(site) {
        case .owner:
            guard await turnOn(site) else { return false }
        case .viewer:
            // This phone accepts the terms; only an owner can grant the
            // home's scope. Cloud enforces that scope for the whole home.
            break
        case .ownerLater, .unknown:
            help = CloudWords.text("Update your box before accepting the new Cloud terms.")
            return false
        }
        if let id = site.siteId {
            defaults.set(Self.policy, forKey: Keys.asked(id))
            defaults.removeObject(forKey: Keys.pending(id))
        }
        defaults.set(Self.policy, forKey: Keys.answered)
        acceptedHome = site.siteId
        answered = true
        return true
    }
    public func review() {
        defaults.removeObject(forKey: Keys.answered)
        answered = false
    }
    /// Reading terms never reconnects. Only the explicit accept action saves
    /// this per-home intent; fresh box policy is checked after reconnecting.
    public func prepareReconnect(_ id: String) { defaults.set(Self.policy,forKey:Keys.pending(id)) }
    public func cancelReconnect(_ id: String) { defaults.removeObject(forKey:Keys.pending(id)) }
    public func finishPendingAcceptance(_ site: SiteModel) async {
        guard let id=site.siteId, site.heardFromBox, !working,
              defaults.string(forKey:Keys.pending(id))==Self.policy else { return }
        working=true
        defer { working=false }
        _ = await accept(site)
    }
    public func refresh(_ site: SiteModel) async {
        guard site.canConfigure else { return }
        do {
            box = try await site.callBox(.get, "/api/cloud").map(BoxState.init)
            await refreshStatisticsPolicy(site)
            help = nil
        } catch let e as BoxAPIError { help = e.help }
        catch { help = CloudWords.text("The choice could not be saved. Check the box status before trying again.") }
    }
    @discardableResult
    public func turnOn(_ site: SiteModel) async -> Bool {
        guard site.canConfigure else { return false }
        await refreshStatisticsPolicy(site)
        guard policyAvailable else {
            help = CloudWords.text("Update your box before accepting the new Cloud terms.")
            return false
        }
        return await act {
            let scopes = JSON.array(Contract.cloudScopes.map { .string($0) })
            box = try await site.callBox(.post, "/api/cloud/grant", body: .object([("scopes", scopes), ("policy", .string(Self.policy))])).map(BoxState.init)
            if let id = site.siteId { defaults.set(Self.policy, forKey: Keys.asked(id)) }
        }
    }
    /// This ends all Cloud functions, rather than opting out of statistics.
    /// A remote connection can close before its deletion receipt arrives;
    /// the local box remains the place to verify that receipt.
    @discardableResult
    public func turnOff(_ site: SiteModel) async -> Bool {
        if let id = site.siteId { defaults.set(Self.policy, forKey: Keys.asked(id)) }
        return await act { box = try await site.callBox(.delete, "/api/cloud").map(BoxState.init) }
    }
    public func refreshStatisticsPolicy(_ site: SiteModel) async {
        guard site.canConfigure else { policyAvailable = false; statisticsReady = false; return }
        do {
            let p = try await site.callBox(.get, "/api/cloud/stats-policy")
            policyAvailable = p?["policy"]?.string == Self.statsPolicy && p?["cloud_policy"]?.string == Self.policy && p?["cloud_includes_statistics"]?.bool == true
            statisticsReady = policyAvailable && p?["available"]?.bool == true
        } catch { policyAvailable = false; statisticsReady = false }
    }
    private func act(_ work: () async throws -> Void) async -> Bool {
        working = true
        defer { working = false }
        do { try await work(); help = nil; return true }
        catch let e as BoxAPIError { help = e.help }
        catch { help = CloudWords.text("The choice could not be saved. Check the box status before trying again.") }
        return false
    }
    enum Keys {
        static let answered = "FTWCloudConsent"
        static func asked(_ id: String) -> String { "FTWCloudAsked-\(id)" }
        static func pending(_ id: String) -> String { "FTWCloudPending-\(id)" }
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
        "Demo: no reports leave this phone.":        "Demo: inga rapporter lämnar telefonen.",
        CloudConsent.statisticsDetails: "Dela registrerad timenergi, inställd batterikapacitet, effektgränser för batterier och laddare samt solkapacitet med Sourceful för att förbättra FTW och publicera gruppsummor. Värden avrundas till 10 Wh eller W. Inga namn, adresser eller enhets-id:n.",
        CloudConsent.statisticsPrivacy: "Sourceful kopplar rapporterna till ditt Cloud-hem för att kunna radera dem. De är inte anonyma och sparas i 48 timmar. Publika värden kräver minst 20 hem och att inget hem står för mer än 30 procent av summan. Stänger du av FTW Cloud raderas opublicerade rapporter när boxen når Cloud; publicerade gruppsummor finns kvar.",
        CloudConsent.statisticsWaiting: "Timinsamlingen väntar på integritetsgranskning och aktivering. Ditt val kan sparas nu; ingen timrapport lämnar boxen före godkännandet.",
        CloudConsent.included: "Alla som använder FTW Cloud bidrar till projektstatistik. Det finns inget separat statistikval. Vill du inte bidra använder du FTW lokalt utan Cloud. Lokala användare kan välja att dela statistik utan att slå på fjärråtkomst.",
        "Accept Cloud terms": "Godkänn Cloud-villkoren",
        "Homes": "Hem",
        "Pair a home": "Parkoppla ett hem",
        "Use the box locally": "Använd boxen lokalt",
        "Statistics are included with FTW Cloud": "Statistik ingår i FTW Cloud",
        "Update your box before accepting the new Cloud terms.": "Uppdatera boxen innan du godkänner de nya Cloud-villkoren.",
        "This phone has stopped using FTW Cloud. Your box keeps working locally.": "Den här telefonen har slutat använda FTW Cloud. Boxen fungerar vidare lokalt.",
        "Review Cloud terms": "Läs Cloud-villkoren",
        "Turning FTW Cloud off stops remote access for phones and assistants. The box keeps working locally. You may need to pair phones again later. Check the local box for the deletion receipt.": "Stänger du av FTW Cloud förlorar telefoner och assistenter sin fjärråtkomst. Boxen fungerar vidare lokalt. Du kan behöva parkoppla telefonerna igen senare. Boxens lokala sida visar kvittot på radering.",
        "Turn FTW Cloud off?": "Stänga av FTW Cloud?",
        "Turn off": "Stäng av",
        "Cancel": "Avbryt",
        "Review the new statistics policy": "Läs den nya statistikpolicyn",

        "The FTW app uses FTW Cloud": "FTW-appen använder FTW Cloud",
        "FTW Cloud is part of the service. It keeps a copy of your home, signed by your box, so the app opens at once and stays up to date.":
            "FTW Cloud ingår i tjänsten. Den håller en kopia av ditt hem, signerad av din box, så att appen öppnar direkt och håller sig uppdaterad.",
        "Your box still decides. Commands stay encrypted between this phone and your box.":
            "Boxen bestämmer fortfarande. Kommandon är krypterade mellan telefonen och boxen.",
        "Contribute to statistics": "Bidra till statistik",
        "Hourly energy totals, without your name or address, help make FTW better. Off unless you turn it on.":
            "Energisummor per timme, utan namn eller adress, hjälper oss att göra FTW bättre. Av tills du slår på det.",
        "Ask the owner of this home to turn on FTW Cloud.": "Be ägaren av hemmet att slå på FTW Cloud.",
        "Your box turns on FTW Cloud after its next update.": "Din box slår på FTW Cloud efter nästa uppdatering.",
        "Continue": "Fortsätt",
        "Privacy policy": "Integritetspolicy",
        "You can turn FTW Cloud off in About.": "Du kan stänga av FTW Cloud under Om.",
        "The choice could not be saved. Check the box status before trying again.": "Valet kunde inte sparas. Kontrollera boxens status innan du försöker igen.",
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
        "Turning it off ends remote access and requests deletion. Check the local box for the receipt.":
            "Stänger du av upphör fjärråtkomst och boxen begär radering. Boxens lokala sida visar kvittot.",
        "With FTW Cloud on, Sourceful keeps a copy of your home's readings, signed by your box, to serve this app. Commands travel encrypted between this phone and your box, and Sourceful cannot read them.":
            "Med FTW Cloud på håller Sourceful en kopia av hemmets mätvärden, signerad av din box, för den här appen. Kommandon går krypterade mellan telefonen och boxen, och Sourceful kan inte läsa dem.",
    ]
}
