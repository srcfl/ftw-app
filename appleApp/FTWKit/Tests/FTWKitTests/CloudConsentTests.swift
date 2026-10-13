import Foundation
import Testing
@testable import FTWKit

/// The first-start consent and the owner's grant at the box.
@MainActor
@Suite struct CloudConsentTests {
    func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "ftw-consent-\(UUID().uuidString)"))
    }

    /// A home whose box answers hello and the cloud routes as Core does.
    func home(role: String = Contract.roleOwner, caps: [String] = [Contract.capCloudLink, Contract.capAPIPassthrough], cloud: Bool = false) throws -> CloudSite {
        let w = try CloudSite()
        w.open()
        w.site.connect(w.relay)
        w.relay.api = { method, path, _ in
            switch (method, path) {
            case ("POST", "/api/cloud/grant"): return (200, #"{"state":"on","purposes":["serve"],"connected":false}"#)
            case ("POST", "/api/cloud/stats"): return (200, #"{"state":"on","purposes":["serve","stats"]}"#)
            case ("DELETE", "/api/cloud/grant"): return (200, #"{"state":"revoking","purposes":["serve"]}"#)
            case ("GET", "/api/cloud"): return (200, #"{"state":"off","purposes":[],"purgedAtMs":1791821000000}"#)
            default: return (404, #"{"code":"E_NOT_FOUND"}"#)
            }
        }
        w.relay.open(w.scheduler.nowMs)
        w.relay.helloOk(uptimeMs: w.uptime, cloud: cloud ? w.identity : nil, role: role, caps: caps)
        return w
    }

    @Test func askedOnceOnARealHome() throws {
        let d = try defaults()
        let consent = CloudConsent(defaults: d)
        #expect(!consent.shouldAsk(nil))
        let demo = SiteModel(siteId: nil, build: "t", ua: "t", scheduler: ManualScheduler(), files: nil, isDemo: true)
        #expect(!consent.shouldAsk(demo))
        let w = try CloudSite()
        w.open()
        #expect(consent.shouldAsk(w.site))
        #expect(!consent.contributeStats)
    }

    @Test func anOwnerTurnsItOnAtTheBoxWithEveryCloudScope() async throws {
        let w = try home()
        let d = try defaults()
        let consent = CloudConsent(defaults: d)
        #expect(CloudConsent.audience(w.site) == .owner)
        await consent.accept(w.site)
        #expect(consent.answered)
        #expect(!consent.shouldAsk(w.site))
        #expect(CloudConsent(defaults: d).answered)
        let grant = try #require(w.relay.calls.first)
        #expect(grant.method == "POST" && grant.path == "/api/cloud/grant")
        let body = try JSON(parsing: Bytes(grant.body.utf8))
        #expect(body["scopes"]?.array?.compactMap(\.string) == Contract.cloudScopes)
        #expect(body["policy"]?.string == CloudConsent.policy)
        // No statistics unless ticked.
        #expect(w.relay.calls.count == 1)
        #expect(consent.box?.on == true)
    }

    @Test func statisticsGoOnlyWhenTicked() async throws {
        let w = try home()
        let consent = CloudConsent(defaults: try defaults())
        consent.contributeStats = true
        await consent.accept(w.site)
        #expect(w.relay.calls.map(\.path) == ["/api/cloud/grant", "/api/cloud/stats"])
        #expect(consent.box?.stats == true)
    }

    /// The grant is asked for once per home. After that the box's word
    /// stands: turned off on the box or in About, it stays off.
    @Test func theGrantIsAskedForOncePerHome() async throws {
        let w = try home()
        let d = try defaults()
        let consent = CloudConsent(defaults: d)
        await consent.accept(w.site)
        await consent.ensure(w.site)
        await CloudConsent(defaults: d).ensure(w.site)
        #expect(w.relay.calls.count == 1)
    }

    @Test func aViewerIsToldToAskTheOwner() async throws {
        let w = try home(role: Contract.roleViewer)
        let consent = CloudConsent(defaults: try defaults())
        #expect(CloudConsent.audience(w.site) == .viewer)
        await consent.accept(w.site)
        await consent.refresh(w.site)
        #expect(w.relay.calls.isEmpty)
        #expect(consent.answered)
    }

    /// A box that cannot run the uplink yet gets the grant once it can.
    @Test func aBoxWithoutTheUplinkIsAskedLater() async throws {
        let w = try home(caps: [Contract.capAPIPassthrough])
        let d = try defaults()
        let consent = CloudConsent(defaults: d)
        #expect(CloudConsent.audience(w.site) == .ownerLater)
        await consent.accept(w.site)
        #expect(w.relay.calls.isEmpty)
        w.relay.helloOk(uptimeMs: w.uptime, cloud: nil, caps: [Contract.capCloudLink, Contract.capAPIPassthrough])
        await consent.ensure(w.site)
        #expect(w.relay.calls.map(\.path) == ["/api/cloud/grant"])
    }

    @Test func alreadyOnIsLeftAlone() async throws {
        let w = try home(cloud: true)
        let consent = CloudConsent(defaults: try defaults())
        await consent.accept(w.site)
        #expect(w.relay.calls.isEmpty)
    }

    /// About: off asks the box to erase the copy; the receipt is the time on
    /// the service's confirmation.
    @Test func offAndTheReceipt() async throws {
        let w = try home(cloud: true)
        let consent = CloudConsent(defaults: try defaults())
        #expect(await consent.turnOff(w.site))
        #expect(consent.box?.erasing == true)
        await consent.refresh(w.site)
        #expect(consent.box?.on == false)
        #expect(consent.box?.erasedAtMs == 1_791_821_000_000)
    }

    @Test func theScopesAreTheRegistrys() throws {
        let yaml = try RepoFiles.read("protocol/registry.yaml")
        #expect(yaml.contains("cloud_scopes: [\(Contract.cloudScopes.joined(separator: ", "))]"))
        #expect(yaml.contains("cloud_purposes: [\(Contract.cloudPurposes.joined(separator: ", "))]"))
        #expect(Contract.cloudPurposes.contains(Contract.cloudPurposeStats))
    }

    /// Every sentence of the screen has Swedish.
    @Test func theWordsAreInBothLanguages() {
        let keys = ["The FTW app uses FTW Cloud", "Contribute to statistics", "Ask the owner of this home to turn on FTW Cloud.", "Continue",
                    "Copy erased %@", "FTW Cloud is on for this home."]
        for k in keys { #expect(CloudWords.sv[k] != nil, "\(k)") }
        AppWords.$language.withValue(.sv) {
            #expect(CloudWords.text("Continue") == "Fortsätt")
            #expect(CloudWords.text("Contribute to statistics") == "Bidra till statistik")
        }
    }
}
