import Foundation
import Testing
@testable import FTWKit

/// A real offer from a local ftwcloudd, read the way the app reads it. Off
/// unless FTW_LIVE_OFFER_LINK names the consent page's link. The link goes
/// straight to review; FTW_LIVE_OFFER_CODE, if set, must be the code the
/// review shows:
///
///     FTW_LIVE_OFFER_LINK='https://app.ftw.energy/a#…' FTW_LIVE_OFFER_CODE=ABCD-EFGH \
///     FTW_LIVE_OFFER_KEYS='<kid>:<pub>' swift test --filter LiveOfferTests
///
/// The keys are what ftwcloudd serves at /.well-known/ftw-offer-key.
@MainActor
@Suite struct LiveOfferTests {
    @Test func aRealOfferOpens() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let text = env["FTW_LIVE_OFFER_LINK"], let pins = env["FTW_LIVE_OFFER_KEYS"] else { return }
        let link = try #require(OfferLink(text))
        let keys = OfferKeys(pins: [pins])
        #expect(!keys.isEmpty)
        let flow = OfferFlow(link: link, lookup: OfferLookup(base: URL(string: "https://127.0.0.1:18943")!) { _ in (Data(), 500) }, keys: keys)
        await flow.start(home: nil)
        guard case .review(let offer) = flow.step else {
            Issue.record("no review: \(flow.step)")
            return
        }
        if let code = env["FTW_LIVE_OFFER_CODE"] {
            #expect(flow.pageCode == OfferCode.normalize(code).map(OfferCode.show))
        }
        #expect(offer.role == Contract.roleAgent)
        #expect(offer.key.count == 32)
        #expect(offer.home.isEmpty)
        print("live offer:", offer.client, offer.clientHost, offer.verified, offer.scopes, offer.ops, offer.caps, offer.ttlS)
    }
}
