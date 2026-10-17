import Foundation
import Testing
@testable import FTWKit

@MainActor
@Suite struct CloudConsentTests {
    func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "ftw-consent-\(UUID().uuidString)"))
    }
    static let currentPolicy = #"{"policy":"ftw-project-stats-2026-10-v2","cloud_policy":"ftw-cloud-2026-10-v2","cloud_includes_statistics":true,"available":false}"#
    static let granted = #"{"state":"on","policy":"ftw-cloud-2026-10-v2","cloudPolicy":"ftw-cloud-2026-10-v2","cloudTermsAccepted":true,"statisticsPolicy":"ftw-project-stats-2026-10-v2","statisticsActive":true,"connected":true}"#
    func home(role: String = Contract.roleOwner, caps: [String] = [Contract.capCloudLink, Contract.capAPIPassthrough], cloud: Bool = false) async throws -> CloudSite {
        let w = try CloudSite()
        w.open()
        w.site.connect(w.relay)
        w.relay.api = { method, path, _ in
            switch (method, path) {
            case ("GET", "/api/cloud/stats-policy"): return (200, Self.currentPolicy)
            case ("POST", "/api/cloud/grant"): return (200, Self.granted)
            case ("DELETE", "/api/cloud"): return (200, #"{"state":"revoking","link":"ending"}"#)
            case ("GET", "/api/cloud"): return (200, #"{"state":"off","purgedAtMs":1791821000000}"#)
            default: return (404, #"{"code":"E_NOT_FOUND"}"#)
            }
        }
        w.relay.open(w.scheduler.nowMs)
        w.relay.helloOk(uptimeMs: w.uptime, cloud: cloud ? w.identity : nil, role: role, caps: caps)
        await w.run(20)
        return w
    }
    @Test func oldAnswersAndCheckboxesDoNotAcceptTheNewCloudTerms() async throws {
        let d = try defaults()
        d.set("ftw-cloud-2026-10", forKey: CloudConsent.Keys.answered)
        d.set(true, forKey: "FTWCloudStats")
        let c = CloudConsent(defaults: d)
        let w = try await home()
        #expect(!c.answered)
        #expect(c.shouldAsk(w.site))
        _ = c.shouldAsk(w.site)
        #expect(w.relay.calls.isEmpty)
    }
    @Test func acceptingCloudUsesOneBundledGrantAndNoSeparateStatisticsRequest() async throws {
        let w = try await home()
        let d = try defaults()
        let c = CloudConsent(defaults: d)
        #expect(await c.accept(w.site))
        #expect(c.answered && c.box?.stats == true && c.box?.termsAccepted == true)
        let posts = w.relay.calls.filter { $0.method == "POST" }
        #expect(posts.map(\.path) == ["/api/cloud/grant"])
        let body = try JSON(parsing: Bytes(posts[0].body.utf8))
        #expect(body["policy"]?.string == CloudConsent.policy)
        #expect(body["scopes"]?.array?.compactMap(\.string) == Contract.cloudScopes)
        #expect(d.string(forKey: CloudConsent.Keys.asked(w.site.siteId!)) == CloudConsent.policy)
        #expect(!c.statisticsReady) // approval gate off; only the choice is saved
    }
    @Test func aLegacyCloudHomeMustAcceptEvenWhenItWasAlreadyOn() async throws {
        let w = try await home(cloud: true)
        let d = try defaults()
        d.set(true, forKey: CloudConsent.Keys.asked(w.site.siteId!))
        let c = CloudConsent(defaults: d)
        #expect(await c.accept(w.site))
        #expect(w.relay.calls.contains { $0.path == "/api/cloud/grant" })
    }
    @Test func unknownOrOlderPolicyIsNotAccepted() async throws {
        for p in [#"{"policy":"ftw-project-stats-2026-10-v1","available":true}"#, #"{"policy":"future-policy","cloud_policy":"future","cloud_includes_statistics":true}"#] {
            let w = try await home()
            w.relay.api = { _, _, _ in (200, p) }
            let c = CloudConsent(defaults: try defaults())
            #expect(await c.accept(w.site) == false)
            #expect(!c.answered)
            #expect(w.relay.calls.allSatisfy { $0.method == "GET" })
        }
    }
    @Test func aFailedGrantDoesNotSaveAnAcceptedAnswer() async throws {
        let w = try await home()
        w.relay.api = { _, path, _ in path == "/api/cloud/stats-policy" ? (200, Self.currentPolicy) : (503, #"{"code":"E_UNAVAILABLE"}"#) }
        let d = try defaults()
        let c = CloudConsent(defaults: d)
        #expect(await c.accept(w.site) == false)
        #expect(!c.answered && c.box?.stats != true)
        #expect(d.string(forKey: CloudConsent.Keys.asked(w.site.siteId!)) == nil)
    }
    @Test func anAcceptedHomeIsNotGrantedAgainOnEveryFrame() async throws {
        let w = try await home()
        let c = CloudConsent(defaults: try defaults())
        await c.accept(w.site)
        _ = c.shouldAsk(w.site)
        #expect(w.relay.calls.filter { $0.method == "POST" }.count == 1)
    }
    @Test func turningCloudOffDoesNotTurnItBackOnAtRestart() async throws {
        let d = try defaults()
        let w = try await home()
        let c = CloudConsent(defaults: d)
        await c.accept(w.site)
        #expect(await c.turnOff(w.site))
        #expect(w.relay.calls.last?.path == "/api/cloud")
        let later = try await home()
        _ = CloudConsent(defaults: d).shouldAsk(later.site)
        #expect(later.relay.calls.isEmpty)
    }
    @Test func acceptingAnotherHomeDoesNotSilentlyEnableThisOne() async throws {
        let d = try defaults()
        d.set(CloudConsent.policy,forKey:CloudConsent.Keys.answered)
        d.set(CloudConsent.policy,forKey:CloudConsent.Keys.asked("another-home"))
        let w = try await home()
        let c = CloudConsent(defaults:d)
        #expect(c.shouldAsk(w.site))
        #expect(w.relay.calls.isEmpty)
    }
    @Test func aViewerCannotGrantTheHomeScope() async throws {
        let w = try await home(role: Contract.roleViewer)
        let c = CloudConsent(defaults: try defaults())
        #expect(await c.accept(w.site))
        #expect(c.answered)
        #expect(w.relay.calls.isEmpty)
    }
    @Test func anOldBoxWaitsForAnUpdate() async throws {
        let w = try await home(caps: [Contract.capAPIPassthrough])
        let c = CloudConsent(defaults: try defaults())
        #expect(await c.accept(w.site) == false)
        #expect(!c.answered && w.relay.calls.isEmpty)
    }
    @Test func oldStatisticsStateIsNeverShownAsTheNewScope() throws {
        let old = CloudConsent.BoxState(try JSON(parsing: Bytes(#"{"state":"on","purposes":["serve","stats"]}"#.utf8)))
        #expect(!old.stats && !old.termsAccepted)
    }
    @Test func theNewTermsCanBeReviewedAgain() throws {
        let d = try defaults()
        d.set(CloudConsent.policy, forKey: CloudConsent.Keys.answered)
        let c = CloudConsent(defaults: d)
        #expect(c.answered)
        c.review()
        #expect(!c.answered)
    }
    @Test func readingTermsCreatesNoReconnectIntentAndNoGrant() async throws {
        let w=try await home();let c=CloudConsent(defaults:try defaults())
        c.review()
        await c.finishPendingAcceptance(w.site)
        #expect(w.relay.calls.isEmpty)
    }
    @Test func onlyExplicitPerHomeReconnectAcceptanceCanFinishAGrant() async throws {
        let w=try await home();let c=CloudConsent(defaults:try defaults())
        c.prepareReconnect("another-home")
        await c.finishPendingAcceptance(w.site)
        #expect(w.relay.calls.isEmpty)
        c.prepareReconnect(w.site.siteId!)
        #expect(w.relay.calls.isEmpty)
        await c.finishPendingAcceptance(w.site)
        await c.finishPendingAcceptance(w.site)
        #expect(w.relay.calls.filter{$0.method=="POST"}.count==1)
        #expect(c.answered)
    }
    @Test func decliningAgainCancelsThePendingReconnectGrant() async throws {
        let w=try await home();let c=CloudConsent(defaults:try defaults())
        c.prepareReconnect(w.site.siteId!)
        c.cancelReconnect(w.site.siteId!)
        await c.finishPendingAcceptance(w.site)
        #expect(w.relay.calls.isEmpty)
    }
    @Test func theWordsAreInBothLanguages() {
        for key in [CloudConsent.included, CloudConsent.statisticsDetails, CloudConsent.statisticsPrivacy, CloudConsent.statisticsWaiting, "Accept Cloud terms", "Use the box locally", "Review Cloud terms"] {
            #expect(CloudWords.sv[key] != nil, "Missing translation: \(key)")
        }
    }
}
