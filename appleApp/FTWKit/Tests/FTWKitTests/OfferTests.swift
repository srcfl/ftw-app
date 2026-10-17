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
    }

    @Test func theReleasePinsTheCloudOfferKeyUnderItsKid() throws {
        let keys = OfferKeys(pins: OfferKeys.releasePins)
        let pub = try #require(keys.pub("s0xLrCPjFa-AoMMl"))
        #expect(OfferKeys.kid(pub) == "s0xLrCPjFa-AoMMl")
        #expect(OfferKeys.releasePins.count == 1)
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
        #expect(throws: OfferError.notFromSourceful) { try sign(o, key).open(keys: keys, nowMs: 1_000) }
        o.clientId = AccessWire.supportClientID
        #expect(try sign(o, key).open(keys: keys, nowMs: 1_000).ticket == "FTW-1")
    }

    /// A host in look-alike letters is no host; punycode stays as it is.
    @Test func aLookAlikeHostIsRefused() throws {
        let key = SoftwareSigner()
        let keys = OfferKeys(pins: ["\(OfferKeys.kid(key.publicKey)):\(Base64url.encode(key.publicKey))"])
        var o = offer()
        o.clientHost = "claude.\u{0430}i"
        #expect(throws: OfferError.strangeHost) { try sign(o, key).open(keys: keys, nowMs: 1_000) }
        o.clientHost = "claude.ai\u{202E}"
        #expect(throws: OfferError.strangeHost) { try sign(o, key).open(keys: keys, nowMs: 1_000) }
        o.clientHost = ""
        #expect(throws: OfferError.strangeHost) { try sign(o, key).open(keys: keys, nowMs: 1_000) }
        o.clientHost = "xn--clude-0ve.ai"
        #expect(try sign(o, key).open(keys: keys, nowMs: 1_000).clientHost == "xn--clude-0ve.ai")
        o.clientHost = "127.0.0.1:18943"
        #expect(throws: Never.self) { try sign(o, key).open(keys: keys, nowMs: 1_000) }
    }

    /// No release client is pinned, so no release offer opens.
    @Test func aReleaseOfferIsRefused() throws {
        let key = SoftwareSigner()
        let keys = OfferKeys(pins: ["\(OfferKeys.kid(key.publicKey)):\(Base64url.encode(key.publicKey))"])
        var o = offer()
        o.role = Contract.roleRelease
        o.scopes = ["ftw.health.read"]
        #expect(throws: OfferError.notFromSourceful) { try sign(o, key).open(keys: keys, nowMs: 1_000) }
    }

    /// An offer FTW Cloud no longer holds open is answered already.
    @Test func anAnsweredOfferIsRefused() async throws {
        let key = SoftwareSigner()
        let keys = OfferKeys(pins: ["\(OfferKeys.kid(key.publicKey)):\(Base64url.encode(key.publicKey))"])
        let wire = try sign(offer(), key).base64url
        let flow = OfferFlow(link: nil, lookup: lookup { _ in
            (try JSONSerialization.data(withJSONObject: ["offer": wire, "status": "approved"]), 200)
        }, keys: keys, wallMs: { 1_000 })
        flow.typed = "K7QF2MXD"
        await flow.submit(home: nil)
        #expect(flow.step == .refused(.used))
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
        // Only the fragment carries a request: a path would reach a log.
        #expect(OfferLink("https://app.ftw.energy/a/rid_1#b2ZmZXI") == nil)
        #expect(OfferLink("https://app.ftw.energy/a/rid_1") == nil)
        #expect(OfferLink("https://app.ftw.energy/a?x=1#rid_1.b2ZmZXI") == nil)
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

    /// A link, tapped or opened by the iPhone Camera from the page's QR
    /// code, is checked at once and goes straight to review: no code to
    /// type. The page's code is there to compare.
    @Test func aLinkGoesStraightToReview() async throws {
        let key = SoftwareSigner()
        let keys = OfferKeys(pins: ["\(OfferKeys.kid(key.publicKey)):\(Base64url.encode(key.publicKey))"])
        let link = OfferLink(request: "r1", offer: try sign(offer(), key).base64url)
        let flow = OfferFlow(link: link, lookup: lookup { _ in
            Issue.record("a link asked FTW Cloud")
            return (Data(), 500)
        }, keys: keys, wallMs: { 1_000 })
        #expect(flow.step == .checking)
        await flow.start(home: nil)
        guard case .review(let o) = flow.step else { Issue.record("no review: \(flow.step)"); return }
        #expect(o.client == "Claude")
        #expect(flow.typed.isEmpty)
        #expect(flow.pageCode == "K7QF-2MXD")
        // Control is off until ticked, and the length starts at 30 days.
        #expect(!flow.control)
        #expect(flow.lengthMs == 30 * 86_400_000)
        // A code typed into a link's flow changes nothing.
        flow.typed = "AAAA-BBBB"
        await flow.submit(home: nil)
        #expect(flow.step == .review(o))
    }

    /// The checks a link always had: unsigned, expired, broken, support from
    /// anyone but Sourceful, or a build that pins no key. None reaches review.
    @Test func aBadLinkIsStillRefused() async throws {
        let pinned = SoftwareSigner()
        let keys = OfferKeys(pins: ["\(OfferKeys.kid(pinned.publicKey)):\(Base64url.encode(pinned.publicKey))"])
        func flow(_ text: String, keys: OfferKeys = keys) async -> OfferFlow {
            let f = OfferFlow(link: OfferLink(request: "r1", offer: text), lookup: lookup { _ in (Data(), 500) }, keys: keys, wallMs: { 1_000 })
            await f.start(home: nil)
            return f
        }
        #expect(await flow(try sign(offer(), SoftwareSigner()).base64url).step == .refused(.unsigned))
        var old = offer()
        old.expMs = 1_000
        #expect(await flow(try sign(old, pinned).base64url).step == .refused(.expired))
        #expect(await flow("bm90LWFuLW9mZmVy").step == .refused(.malformed))
        var support = offer()
        support.role = Contract.roleSupport
        #expect(await flow(try sign(support, pinned).base64url).step == .refused(.notFromSourceful))
        #expect(await flow(try sign(offer(), pinned).base64url, keys: OfferKeys(pins: [])).step == .refused(.noPinnedKey))
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
        // No link: the code first, and start does nothing.
        #expect(flow.step == .code)
        await flow.start(home: nil)
        #expect(flow.step == .code)
        flow.typed = "k7qf2mxd"
        await flow.submit(home: nil)
        guard case .review = flow.step else { Issue.record("no review: \(flow.step)"); return }
        // The owner just typed it: nothing to compare.
        #expect(flow.pageCode == nil)

        let gone = OfferFlow(link: nil, lookup: lookup { _ in (Data(), 404) }, keys: keys, wallMs: { 1_000 })
        gone.typed = "K7QF2MXD"
        await gone.submit(home: nil)
        #expect(gone.step == .code)
        #expect(gone.codeHelp == AccessWords.offer(.notFound))
    }

    /// A typed code must be the offer's own. FTW Cloud is asked once, even
    /// when Return and Continue both fire: the code works once.
    @Test func aTypedCodeIsAskedOnceAndMustMatch() async throws {
        let key = SoftwareSigner()
        let keys = OfferKeys(pins: ["\(OfferKeys.kid(key.publicKey)):\(Base64url.encode(key.publicKey))"])
        let wire = try sign(offer(), key).base64url
        let asked = Asked()
        let flow = OfferFlow(link: nil, lookup: lookup { _ in
            asked.add()
            return (try JSONSerialization.data(withJSONObject: ["offer": wire, "status": "pending"]), 200)
        }, keys: keys, wallMs: { 1_000 })
        flow.typed = "AAAA-BBBB"
        await flow.submit(home: nil)
        #expect(flow.step == .refused(.wrongCode))
        #expect(asked.count == 1)

        let twice = OfferFlow(link: nil, lookup: lookup { _ in
            asked.add()
            return (try JSONSerialization.data(withJSONObject: ["offer": wire, "status": "pending"]), 200)
        }, keys: keys, wallMs: { 1_000 })
        twice.typed = "K7QF2MXD"
        async let first: Void = twice.submit(home: nil)
        async let second: Void = twice.submit(home: nil)
        _ = await (first, second)
        guard case .review = twice.step else { Issue.record("no review: \(twice.step)"); return }
        #expect(asked.count == 2)
    }

    /// Coming back to the page runs `start` again; it changes nothing the
    /// owner chose, and no other offer can be swapped in under the review.
    @Test func startingAgainChangesNothing() async throws {
        let key = SoftwareSigner()
        let keys = OfferKeys(pins: ["\(OfferKeys.kid(key.publicKey)):\(Base64url.encode(key.publicKey))"])
        var o = offer()
        o.verified = false
        o.scopes = ["ftw.dispatch.hold", "ftw.live.read"]
        let flow = OfferFlow(link: OfferLink(request: "r1", offer: try sign(o, key).base64url), lookup: lookup { _ in (Data(), 500) }, keys: keys, wallMs: { 1_000 })
        await flow.start(home: nil)
        guard case .review(let shown) = flow.step else { Issue.record("no review: \(flow.step)"); return }
        flow.control = true
        flow.trustsUnknown = true
        flow.lengthMs = 86_400_000
        await flow.start(home: nil)
        var other = offer()
        other.client = "Someone else"
        flow.present(try sign(other, key), home: nil)
        #expect(flow.step == .review(shown))
        #expect(flow.control && flow.trustsUnknown)
        #expect(flow.lengthMs == 86_400_000)
    }

    /// Approving checks the signed offer again, against the home open then
    /// and the clock then: a home picked after the review, or an offer
    /// that ran out while the owner read, is refused.
    @Test func approvingChecksAgain() async throws {
        let key = SoftwareSigner()
        let keys = OfferKeys(pins: ["\(OfferKeys.kid(key.publicKey)):\(Base64url.encode(key.publicKey))"])
        var o = offer()
        o.home = "homeA"
        var now = 1_000.0
        let flow = OfferFlow(link: OfferLink(request: "r1", offer: try sign(o, key).base64url), lookup: lookup { _ in (Data(), 500) }, keys: keys, wallMs: { now })
        await flow.start(home: "homeA")
        guard case .review = flow.step else { Issue.record("no review: \(flow.step)"); return }
        let site = SiteModel(siteId: "homeB", build: "t", ua: "t", scheduler: ManualScheduler(), files: nil)
        let access = AccessModel(site: site, signedFor: SignedFor(boxKey: [], deviceID: "x"), keyring: nil)
        await flow.approve(access, home: "homeB")
        #expect(flow.step == .refused(.unknownHome))

        let late = OfferFlow(link: OfferLink(request: "r1", offer: try sign(o, key).base64url), lookup: lookup { _ in (Data(), 500) }, keys: keys, wallMs: { now })
        await late.start(home: "homeA")
        now += 10 * 60_000
        await late.approve(access, home: "homeA")
        #expect(late.step == .refused(.expired))
    }

    /// An unknown client waits for the owner to say they started it.
    @Test func anUnknownClientWaitsForTheOwnersWord() async throws {
        let key = SoftwareSigner()
        let keys = OfferKeys(pins: ["\(OfferKeys.kid(key.publicKey)):\(Base64url.encode(key.publicKey))"])
        var o = offer()
        o.verified = false
        let flow = OfferFlow(link: OfferLink(request: "r1", offer: try sign(o, key).base64url), lookup: lookup { _ in (Data(), 500) }, keys: keys, wallMs: { 1_000 })
        await flow.start(home: nil)
        let site = SiteModel(siteId: "h", build: "t", ua: "t", scheduler: ManualScheduler(), files: nil)
        await flow.approve(AccessModel(site: site, signedFor: SignedFor(boxKey: [], deviceID: "x"), keyring: nil), home: nil)
        guard case .review = flow.step else { Issue.record("moved without the owner's word: \(flow.step)"); return }
        #expect(!flow.trustsUnknown)
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
        guard case .review = same.step else { Issue.record("no review: \(same.step)"); return }
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

    /// An assistant may have up to a year, where the offer and the box allow
    /// it. A box that says nothing takes 30 days, so it is offered no more,
    /// whatever the offer asks.
    @Test func aYearOnlyWhereTheBoxSaysItTakesOne() {
        let day: Int64 = 86_400_000
        let year = 365 * day
        var o = offer()
        o.ttlS = 365 * 86_400
        #expect(Grant.lengths(role: Contract.roleAgent, offeredS: o.ttlS, boxMs: year) == [day, 7 * day, 30 * day, 90 * day, year])
        #expect(Grant.lengths(role: Contract.roleAgent, offeredS: o.ttlS, boxMs: nil) == [day, 7 * day, 30 * day])
        #expect(Grant.lengths(role: Contract.roleAgent, offeredS: 30 * 86_400, boxMs: year).last == 30 * day)
        #expect(Grant.from(o, control: false, lengthMs: year, boxMs: year).lengthMs == year)
        #expect(Grant.from(o, control: false, lengthMs: year, boxMs: nil).lengthMs == 30 * day)
        // Never past the app's own year, whatever a box says.
        #expect(Grant.lengths(role: Contract.roleAgent, offeredS: 0, boxMs: 2 * year).last == year)
        // Support stays at 14 days; the box saying nothing changes nothing.
        #expect(Grant.lengths(role: Contract.roleSupport, boxMs: nil).last == 14 * day)
        #expect(AccessWords.length(year) == AccessWords.text("1 year"))
    }

    /// The offer asks for a year; the owner starts at 30 days, Sourceful at a
    /// week.
    @Test func anOfferStartsAt30Days() {
        let day: Int64 = 86_400_000
        #expect(Grant.startLength(role: Contract.roleAgent, in: [day, 7 * day, 30 * day, 90 * day, 365 * day]) == 30 * day)
        #expect(Grant.startLength(role: Contract.roleAgent, in: [day, 7 * day]) == 7 * day)
        #expect(Grant.startLength(role: Contract.roleSupport, in: [day, 3 * day, 7 * day, 14 * day]) == 7 * day)
    }

    /// agent.list's longestMs, read as the box sent it; a box from before it
    /// sends none.
    @Test func theBoxSaysHowLongItTakes() {
        let year: Int64 = 365 * 86_400_000
        let newer = AgentList(CBOR.map([("agents", .array([])), ("longestMs", .map([
            CBOR.Entry(.text(Contract.roleAgent), .int(year)), CBOR.Entry(.text(Contract.roleSupport), .int(14 * 86_400_000)),
        ]))]))
        #expect(newer.longestMs == [Contract.roleAgent: year, Contract.roleSupport: 14 * 86_400_000])
        let older = AgentList(CBOR.map([("agents", .array([])), ("requests", .array([])), ("keys", .array([]))]))
        #expect(older.longestMs.isEmpty)
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

/// How many times FTW Cloud's code lookup was asked.
final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var count: Int { lock.withLock { n } }
    func add() { lock.withLock { n += 1 } }
}
