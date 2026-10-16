import Foundation
import Testing
@testable import FTWKit

/// The signed offer from FTW Cloud's consent page: checked against the
/// pinned offer keys before anything is shown, and refused when it is
/// unsigned, expired, malformed, support from anyone but Sourceful, or for
/// a home this phone does not have.
@MainActor
@Suite struct OfferTests {
    let v: ApprovalVectors.Offer

    init() throws {
        v = try ApprovalVectors.load().offer
    }

    var pinned: OfferKeys { OfferKeys(pins: ["\(v.kid):\(Base64url.encode(Bytes(hex: v.pubHex)))"]) }
    var signed: SignedOffer { get throws { try SignedOffer(base64url: Base64url.encode(Bytes(hex: v.signedOfferHex))) } }

    /// The box's vector opens here, field for field, and the bytes match.
    @Test func theVectorOpens() throws {
        #expect(OfferKeys.kid(Bytes(hex: v.pubHex)) == v.kid)
        let s = try signed
        #expect(s.o.hex == v.oHex)
        #expect(SignedOffer.signedBytes(s.o).hex == v.signedBytesHex)
        let o = try s.open(keys: pinned, nowMs: v.nowMs)
        #expect(o.v == 1 && o.home.isEmpty && o.key.count == 32)
        #expect(o.role == Contract.roleAgent)
        #expect(!o.code.isEmpty)
        // Re-encoded, it is the bytes FTW Cloud signed.
        #expect(encodeDeterministic(o.cbor).hex == v.oHex)
        #expect(s.base64url == Base64url.encode(Bytes(hex: v.signedOfferHex)))
    }

    @Test func aBuildThatPinsNoKeyOpensNoOffer() throws {
        #expect(throws: OfferError.noPinnedKey) { try signed.open(keys: OfferKeys(pins: []), nowMs: v.nowMs) }
        #expect(OfferKeys(pins: OfferKeys.releasePins).isEmpty)
    }

    @Test func anOfferNoPinnedKeySignedIsRefused() throws {
        let other = SoftwareSigner()
        let keys = OfferKeys(pins: ["\(OfferKeys.kid(other.publicKey)):\(Base64url.encode(other.publicKey))"])
        #expect(throws: OfferError.unsigned) { try signed.open(keys: keys, nowMs: v.nowMs) }
        // Signed by the pinned kid, but with bytes changed after.
        var s = try signed
        s.o[s.o.count - 1] ^= 1
        #expect(throws: OfferError.unsigned) { try s.open(keys: pinned, nowMs: v.nowMs) }
        // A kid that is not its key's is no pin.
        #expect(OfferKeys(pins: ["AAAAAAAAAAAAAAAA:\(Base64url.encode(Bytes(hex: v.pubHex)))"]).isEmpty)
    }

    @Test func anExpiredOfferIsRefused() throws {
        let o = try signed.open(keys: pinned, nowMs: v.nowMs)
        #expect(throws: OfferError.expired) { try signed.open(keys: pinned, nowMs: o.expMs) }
        // One that claims to live longer than ten minutes was not made by FTW Cloud.
        #expect(throws: OfferError.expired) { try signed.open(keys: pinned, nowMs: o.expMs - GrantOffer.ttlMs - 1) }
    }

    /// Support counts only from Sourceful's own client.
    @Test func supportFromAStrangerIsRefused() throws {
        let key = SoftwareSigner()
        let keys = OfferKeys(pins: ["\(OfferKeys.kid(key.publicKey)):\(Base64url.encode(key.publicKey))"])
        var o = offer()
        o.role = Contract.roleSupport
        o.ticket = "FTW-1"
        o.clientId = "https://evil.example/clients/sourceful-support"
        #expect(throws: OfferError.supportFromStranger) { try sign(o, key).open(keys: keys, nowMs: 1_000) }
        o.clientId = AccessWire.supportClientID
        #expect(try sign(o, key).open(keys: keys, nowMs: 1_000).ticket == "FTW-1")
    }

    /// Strict, as the box reads it.
    @Test func aFieldTheBoxDoesNotKnowIsNoOffer() throws {
        let key = SoftwareSigner()
        let keys = OfferKeys(pins: ["\(OfferKeys.kid(key.publicKey)):\(Base64url.encode(key.publicKey))"])
        var entries = offer().cbor.entries!
        entries.append(CBOR.Entry(.text("admin"), .bool(true)))
        let raw = encodeDeterministic(.map(entries))
        let s = SignedOffer(o: raw, kid: OfferKeys.kid(key.publicKey), sig: try key.sign(SignedOffer.signedBytes(raw)))
        #expect(throws: OfferError.malformed) { try s.open(keys: keys, nowMs: 1_000) }
        #expect(throws: OfferError.malformed) { try SignedOffer(base64url: "not-cbor") }
    }

    @Test func theLinksFTWCloudMakesAreRead() {
        let a = OfferLink("https://app.ftw.energy/a#rid_1.b2ZmZXI")
        #expect(a == OfferLink(request: "rid_1", offer: "b2ZmZXI"))
        #expect(OfferLink("https://app.ftw.energy/a/rid_1#b2ZmZXI") == OfferLink(request: "rid_1", offer: "b2ZmZXI"))
        #expect(OfferLink("https://app.ftw.energy/a/rid_1") == OfferLink(request: "rid_1", offer: nil))
        #expect(OfferLink("https://app.ftw.energy/p#AAAA") == nil)
        #expect(OfferLink("https://evil.example/a#rid.offer") == nil)
        #expect(OfferLink("http://app.ftw.energy/a#rid.offer") == nil)
        #expect(OfferLink("https://app.ftw.energy/a#rid") == nil)
    }

    @Test func aCodeIsReadAsAnOwnerTypesIt() {
        #expect(OfferCode.normalize("k7qf-2mxd") == "K7QF2MXD")
        #expect(OfferCode.normalize(" K7QF 2MXD ") == "K7QF2MXD")
        #expect(OfferCode.normalize("K7QF2MX0") == nil)
        #expect(OfferCode.normalize("K7QF2MX") == nil)
        #expect(OfferCode.show("K7QF2MXD") == "K7QF-2MXD")
        var o = GrantOffer()
        o.code = "K7QF2MXD"
        #expect(OfferCode.matches("k7qf-2mxd", o))
        #expect(!OfferCode.matches("K7QF2MXE", o))
    }

    // MARK: The flow

    /// A link's offer is checked at once, then waits for the code on the
    /// page: a link someone else sent never reaches Face ID on its own.
    @Test func aLinkWaitsForTheCodeOnThePage() async throws {
        let key = SoftwareSigner()
        let keys = OfferKeys(pins: ["\(OfferKeys.kid(key.publicKey)):\(Base64url.encode(key.publicKey))"])
        let link = OfferLink(request: "r1", offer: try sign(offer(), key).base64url)
        let flow = OfferFlow(link: link, lookup: lookup { _ in (Data(), 500) }, keys: keys, wallMs: { 1_000 })
        await flow.start(home: nil)
        #expect(flow.step == .code)
        flow.typed = "AAAA-BBBB"
        await flow.submit(home: nil)
        #expect(flow.step == .code)
        #expect(flow.codeHelp == AccessWords.offer(.wrongCode))
        flow.typed = "k7qf-2mxd"
        await flow.submit(home: nil)
        guard case .review(let o) = flow.step else { Issue.record("no review: \(flow.step)"); return }
        #expect(o.client == "Claude")
        // Control is off until ticked, and the length is the longest asked.
        #expect(!flow.control)
        #expect(flow.lengthMs == 30 * 86_400_000)
    }

    @Test func aLinkWithABadOfferStopsBeforeTheCode() async throws {
        let stranger = SoftwareSigner()
        let pinned = SoftwareSigner()
        let keys = OfferKeys(pins: ["\(OfferKeys.kid(pinned.publicKey)):\(Base64url.encode(pinned.publicKey))"])
        let flow = OfferFlow(link: OfferLink(request: "r1", offer: try sign(offer(), stranger).base64url), lookup: lookup { _ in (Data(), 500) }, keys: keys, wallMs: { 1_000 })
        await flow.start(home: nil)
        #expect(flow.step == .refused(.unsigned))
    }

    /// Typed with no link, the code fetches the offer from FTW Cloud.
    @Test func aCodeFetchesItsOffer() async throws {
        let key = SoftwareSigner()
        let keys = OfferKeys(pins: ["\(OfferKeys.kid(key.publicKey)):\(Base64url.encode(key.publicKey))"])
        let wire = try sign(offer(), key).base64url
        let flow = OfferFlow(link: nil, lookup: lookup { req in
            #expect(req.url?.absoluteString == "https://cloud.test/oauth/requests?code=K7QF2MXD")
            return (try JSONSerialization.data(withJSONObject: ["offer": wire, "status": "pending"]), 200)
        }, keys: keys, wallMs: { 1_000 })
        flow.typed = "k7qf2mxd"
        await flow.submit(home: nil)
        guard case .review = flow.step else { Issue.record("no review: \(flow.step)"); return }

        let gone = OfferFlow(link: nil, lookup: lookup { _ in (Data(), 404) }, keys: keys, wallMs: { 1_000 })
        gone.typed = "K7QF2MXD"
        await gone.submit(home: nil)
        #expect(gone.step == .code)
        #expect(gone.codeHelp == AccessWords.offer(.notFound))
    }

    /// FTW Cloud leaves the home empty. One that names a home must name
    /// this one.
    @Test func anOfferForAnotherHomeIsRefused() async throws {
        let key = SoftwareSigner()
        let keys = OfferKeys(pins: ["\(OfferKeys.kid(key.publicKey)):\(Base64url.encode(key.publicKey))"])
        var o = offer()
        o.home = "otherhome"
        let flow = OfferFlow(link: OfferLink(request: "r1", offer: try sign(o, key).base64url), lookup: lookup { _ in (Data(), 500) }, keys: keys, wallMs: { 1_000 })
        await flow.start(home: "myhome")
        #expect(flow.step == .refused(.unknownHome))
        let same = OfferFlow(link: OfferLink(request: "r1", offer: try sign(o, key).base64url), lookup: lookup { _ in (Data(), 500) }, keys: keys, wallMs: { 1_000 })
        await same.start(home: "otherhome")
        #expect(same.step == .code)
    }

    // MARK: What the owner grants

    @Test func controlIsASeparateSwitch() {
        var o = offer()
        o.scopes = ["ftw.dispatch.hold", "ftw.goals.request", "ftw.live.read", "ftw.plan.read"]
        o.ops = ["loadpoint.hold", "site.mode.set"]
        o.caps = Caps(holdS: 1_800, maxW: 11_000, perMin: 6)
        let read = Grant.from(o, control: false, lengthMs: 30 * 86_400_000)
        #expect(read.scopes == ["ftw.live.read", "ftw.plan.read"])
        #expect(read.ops.isEmpty)
        #expect(read.caps.holdS == 0 && read.caps.maxW == 0)
        let control = Grant.from(o, control: true, lengthMs: 30 * 86_400_000)
        #expect(control.scopes == ["ftw.dispatch.hold", "ftw.goals.request", "ftw.live.read", "ftw.plan.read"])
        #expect(control.ops == ["loadpoint.hold", "site.mode.set"])
        #expect(control.caps == Caps(holdS: 1_800, maxW: 11_000, perMin: 6))
    }

    /// Never more than the offer asks, the role allows, or the box takes.
    @Test func neverMoreThanAsked() {
        var o = offer()
        o.role = Contract.roleRelease
        o.scopes = ["ftw.health.read", "ftw.logs.read"]
        o.ttlS = 3 * 86_400
        let g = Grant.from(o, control: true, lengthMs: 90 * 86_400_000)
        #expect(g.scopes == ["ftw.health.read"])
        #expect(g.lengthMs == 86_400_000)
        #expect(Grant.lengths(role: Contract.roleAgent) == [86_400_000, 7 * 86_400_000, 30 * 86_400_000])
        let day: Int64 = 86_400_000
        let support = Grant.lengths(role: Contract.roleSupport)
        #expect(support == [day, 3 * day, 7 * day, 14 * day])
        var big = offer()
        big.scopes = ["ftw.dispatch.hold", "ftw.live.read"]
        big.caps = Caps(holdS: 99_999, maxW: 999_999, perMin: 600)
        let capped = Grant.from(big, control: true, lengthMs: 86_400_000)
        #expect(capped.caps == Caps(holdS: 1_800, maxW: 100_000, perMin: 60))
    }

    // MARK: Helpers

    func offer() -> GrantOffer {
        var o = GrantOffer()
        o.v = 1
        o.key = Bytes(repeating: 0xa0, count: 32)
        o.role = Contract.roleAgent
        o.client = "Claude"
        o.clientId = "https://claude.ai/oauth/mcp-oauth-client-metadata"
        o.clientHost = "claude.ai"
        o.verified = true
        o.scopes = ["ftw.live.read", "ftw.plan.read"]
        o.ttlS = 30 * 86_400
        o.code = "K7QF2MXD"
        o.expMs = 1_000 + 9 * 60_000
        return o
    }

    func sign(_ o: GrantOffer, _ key: SoftwareSigner) throws -> SignedOffer {
        let raw = encodeDeterministic(o.cbor)
        return SignedOffer(o: raw, kid: OfferKeys.kid(key.publicKey), sig: try key.sign(SignedOffer.signedBytes(raw)))
    }

    func lookup(_ answer: @escaping @Sendable (URLRequest) throws -> (Data, Int)) -> OfferLookup {
        OfferLookup(base: URL(string: "https://cloud.test")!) { try answer($0) }
    }
}
