import Foundation
import Testing
@testable import FTWKit
import FTWDemo

/// Access against the simulated box, which checks every approval signature
/// over the bytes the box would build: the first grant registers the key
/// under the same Face ID, a change is signed, a removal is one tap, and an
/// assistant's request is approved over exactly what was shown.
@MainActor
@Suite struct AccessFlowTests {
    @MainActor final class World {
        let scheduler = ManualScheduler(nowMs: 1_792_000_000_000)
        let box: SimulatedBox
        let site: SiteModel
        let keyring = SimulatedKeyring()
        let access: AccessModel

        init(seed: Bool = true, phoneClockOffMs: Double = 0) {
            box = SimulatedBox(scheduler: scheduler)
            if seed { box.access.seed() }
            site = SiteModel(siteId: "home1", build: "t", ua: "t", scheduler: scheduler, files: nil)
            let s = scheduler
            access = AccessModel(site: site, signedFor: AccessModel.demoFor, keyring: keyring, wallMs: { s.nowMs + phoneClockOffMs })
            site.start()
            site.connect(LoopbackCarrier(box: box, scheduler: scheduler, latencyMs: 20))
        }

        func run(_ ms: Double = 1_000) async {
            var left = ms
            while left > 0 {
                for _ in 0..<20 { await Task.yield() }
                scheduler.advance(min(10, left))
                left -= 10
            }
            for _ in 0..<20 { await Task.yield() }
        }

        /// Run `work` while the clock moves, as the box answers.
        func during<T: Sendable>(_ work: @escaping @MainActor () async -> T) async -> T {
            let task = Task { await work() }
            await run(2_000)
            return await task.value
        }

        func offer(support: Bool = false) throws -> GrantOffer {
            try SimulatedAccess.offer(support: support, nowMs: scheduler.nowMs).open(keys: SimulatedAccess.offerKeys, nowMs: Int64(scheduler.nowMs))
        }
    }

    func world(seed: Bool = true, phoneClockOffMs: Double = 0) async -> World {
        let w = World(seed: seed, phoneClockOffMs: phoneClockOffMs)
        await w.run(500)
        return w
    }

    /// A box that takes a year says so, and the owner may grant it.
    @Test func aBoxThatTakesAYearIsOfferedAYear() async throws {
        let w = await world()
        let year: Int64 = 365 * 86_400_000
        await w.during { await w.access.refresh() }
        #expect(w.access.boxLongestMs(Contract.roleAgent) == year)
        let offer = try w.offer()
        let boxMs = w.access.boxLongestMs(offer.role)
        #expect(Grant.lengths(role: offer.role, offeredS: offer.ttlS, boxMs: boxMs).last == year)
        let row = await w.during { await w.access.approve(offer, grant: Grant.from(offer, control: false, lengthMs: year, boxMs: boxMs)) }
        let added = try #require(row)
        #expect(added.expiresAtMs > Int64(w.scheduler.nowMs) + year - 86_400_000)
    }

    /// A consent page's link opens the offer with nothing else having read
    /// the box. The page reads it, so a box that takes a year is offered a
    /// year, and the grant goes through for a year.
    @Test func aLinkToABoxThatTakesAYearOffersAYear() async throws {
        let w = await world(seed: false)
        let day: Int64 = 86_400_000
        let link = OfferLink(request: "r1", offer: SimulatedAccess.offer(nowMs: w.scheduler.nowMs).base64url)
        let flow = OfferFlow(link: link, lookup: OfferLookup(base: URL(string: "https://cloud.test")!) { _ in (Data(), 500) },
                             keys: SimulatedAccess.offerKeys, wallMs: { [s = w.scheduler] in s.nowMs })
        await flow.start(home: nil)
        guard case .review(let offer) = flow.step else { Issue.record("no review: \(flow.step)"); return }
        #expect(flow.lengths(boxMs: w.access.boxLongestMs(offer.role)).last == 30 * day)
        // What the offer page does when it appears.
        await w.during { await w.access.refresh() }
        #expect(flow.lengths(boxMs: w.access.boxLongestMs(offer.role)).last == 365 * day)
        flow.lengthMs = 365 * day
        await w.during { await flow.approve(w.access, home: nil) }
        guard case .done(let row) = flow.step else { Issue.record("not granted: \(flow.step) \(w.access.help ?? "")"); return }
        #expect(row.expiresAtMs > Int64(w.scheduler.nowMs) + 364 * day)
    }

    /// Approving reads the box first when the page has not: a year chosen
    /// before the list arrived is kept, not cut to 30 days.
    @Test func approvingReadsTheBoxFirst() async throws {
        let w = await world(seed: false)
        let day: Int64 = 86_400_000
        let link = OfferLink(request: "r1", offer: SimulatedAccess.offer(nowMs: w.scheduler.nowMs).base64url)
        let flow = OfferFlow(link: link, lookup: OfferLookup(base: URL(string: "https://cloud.test")!) { _ in (Data(), 500) },
                             keys: SimulatedAccess.offerKeys, wallMs: { [s = w.scheduler] in s.nowMs })
        await flow.start(home: nil)
        #expect(!w.access.keysKnown)
        flow.lengthMs = 365 * day
        await w.during { await flow.approve(w.access, home: nil) }
        guard case .done(let row) = flow.step else { Issue.record("not granted: \(flow.step) \(w.access.help ?? "")"); return }
        #expect(row.expiresAtMs > Int64(w.scheduler.nowMs) + 364 * day)
    }

    /// A box from before longestMs says nothing and takes 30 days. The app
    /// offers it no more, though the offer asks for a year, so the grant goes
    /// through; a year would have been refused.
    @Test func anOlderBoxIsOfferedNoMoreThan30Days() async throws {
        let w = await world()
        w.box.access.longestMs = nil
        let day: Int64 = 86_400_000
        await w.during { await w.access.refresh() }
        #expect(w.access.boxLongestMs(Contract.roleAgent) == nil)
        let offer = try w.offer()
        #expect(offer.ttlS == 365 * 86_400)
        let boxMs = w.access.boxLongestMs(offer.role)
        #expect(Grant.lengths(role: offer.role, offeredS: offer.ttlS, boxMs: boxMs).last == 30 * day)
        let grant = Grant.from(offer, control: false, lengthMs: 365 * day, boxMs: boxMs)
        #expect(grant.lengthMs == 30 * day)
        #expect(await w.during { await w.access.approve(offer, grant: grant) } != nil)

        var tooLong = grant
        tooLong.lengthMs = 365 * day
        let second = try w.offer()
        #expect(await w.during { await w.access.approve(second, grant: tooLong) } == nil)
        #expect(w.access.help != nil)
    }

    @Test func theBoxSaysWhoHasAccess() async {
        let w = await world()
        #expect(w.access.available)
        await w.during { await w.access.refresh() }
        #expect(w.access.assistants.map(\.principal.client) == ["Claude"])
        #expect(w.access.support.map(\.principal.ticket) == ["FTW-1042"])
        #expect(w.access.pending.map(\.op) == ["site.mode.set"])
        #expect(!w.access.boxHasKey)
    }

    /// The first approval registers this phone's key and grants, under one
    /// Face ID; the box checked both signatures.
    @Test func theFirstGrantRegistersTheKeyUnderTheSameFaceID() async throws {
        let w = await world()
        let offer = try w.offer()
        let row = await w.during { await w.access.approve(offer, grant: Grant.from(offer, control: false, lengthMs: 30 * 86_400_000)) }
        #expect(w.access.help == nil)
        let added = try #require(row)
        #expect(w.keyring.unlocks == 1)
        #expect(w.box.access.keys[AccessModel.demoFor.deviceID] != nil)
        #expect(w.access.boxHasKey)
        #expect(added.scopes == ["ftw.events.read", "ftw.health.read", "ftw.history.read", "ftw.live.read", "ftw.plan.read"])
        #expect(added.ops.isEmpty)
        #expect(added.principal.clientId == "https://claude.ai/oauth/mcp-oauth-client-metadata")
        // Within the role's longest, as the box holds it.
        #expect(added.expiresAtMs <= Int64(w.scheduler.nowMs) + 30 * 86_400_000)
        #expect(w.access.assistants.contains { $0.id == added.id })
        #expect(w.box.access.audit.prefix(2).map(\.what) == ["agent.add", "approval.key.set"])
        // The row names its client by id; the phone keeps where it lives.
        #expect(w.access.host(added) == "claude.ai")
        #expect(w.access.verified(added) == true)
        var registered = added
        registered.principal.clientId = "ftwc_zXEOM7hsgr"
        registered.id = "someoneE"
        #expect(w.access.host(registered).isEmpty)
        #expect(w.access.place(registered) == AccessWords.format("Assistant %@", "someoneE"))

        // The next grant needs no new key: one more Face ID, nothing else.
        let second = try w.offer()
        _ = await w.during { await w.access.approve(second, grant: Grant.from(second, control: true, lengthMs: 86_400_000)) }
        #expect(w.keyring.unlocks == 2)
        #expect(w.box.access.audit.first?.what == "agent.add")
        let controlled = try #require(w.access.list?.agents.first { $0.key == second.key })
        #expect(controlled.ops == ["car.goal.set", "loadpoint.hold", "planner.prefs.set", "site.mode.set"])
        #expect(controlled.caps.holdS == 1_800 && controlled.caps.maxW == 11_000)
    }

    /// A support grant carries its ticket, and what the owner wrote stays on
    /// the phone.
    @Test func supportIsTiedToItsTicket() async throws {
        let w = await world(seed: false)
        let offer = try w.offer(support: true)
        let grant = Grant.from(offer, control: false, lengthMs: 7 * 86_400_000)
        #expect(!grant.scopes.contains(AccessWire.scopeHold))
        let row = try #require(await w.during { await w.access.approve(offer, grant: grant) })
        #expect(row.role == Contract.roleSupport)
        #expect(row.principal.ticket == "FTW-1043")
        w.access.note(row.principal.ticket, problem: "The battery stops at 80 %.")
        #expect(w.access.problem(row) == "The battery stops at 80 %.")
    }

    /// Any change but a removal is signed, the row's key and epoch with it.
    @Test func aChangeIsSigned() async throws {
        let w = await world()
        await w.during { await w.access.refresh() }
        let claude = try #require(w.access.assistants.first)
        let narrower = Grant(scopes: ["ftw.live.read"], ops: [], caps: Caps(perMin: 6), lengthMs: 86_400_000)
        // The key is registered under this change's Face ID too.
        let ok = await w.during { await w.access.widen(claude, to: narrower) }
        #expect(ok)
        let now = try #require(w.access.row(claude.id))
        #expect(now.scopes == ["ftw.live.read"])
        #expect(now.ops.isEmpty)
        #expect(now.epoch == claude.epoch + 1)
        #expect(w.keyring.unlocks == 1)
        // A stale epoch is the box's conflict, in words.
        let stale = await w.during { await w.access.widen(claude, to: narrower) }
        #expect(!stale)
        #expect(w.access.help == AccessWords.text("Someone changed this meanwhile. Look again and try once more."))
    }

    /// Removing access takes one tap and no Face ID.
    @Test func removingIsOneTap() async throws {
        let w = await world()
        await w.during { await w.access.refresh() }
        let claude = try #require(w.access.assistants.first)
        let ok = await w.during { await w.access.revoke(claude) }
        #expect(ok)
        #expect(w.keyring.unlocks == 0)
        #expect(w.access.assistants.isEmpty)
        #expect(w.box.access.rows.allSatisfy { $0.id != claude.id })
        // Its request went with it.
        #expect(w.access.pending.isEmpty)
    }

    /// Approving signs the request, the agent, the op and the hash of the
    /// args exactly as received; declining is one tap.
    @Test func aRequestIsApprovedOverWhatWasShown() async throws {
        let w = await world()
        await w.during { await w.access.refresh() }
        let req = try #require(w.access.pending.first)
        let lines = AppWords.$language.withValue(.en) { AccessWords.arguments(req, modes: SimulatedBox.modes) }
        #expect(lines.map(\.label) == ["Operating mode"])
        #expect(lines.first?.value == ModeWords.name(SimulatedBox.modes.first { $0.key == "self_consumption" }))
        let ok = await w.during { await w.access.answer(req, approve: true) }
        #expect(ok)
        #expect(w.box.access.requests.first?.state == "approved")
        #expect(w.access.pending.isEmpty)
        #expect(w.keyring.unlocks == 1)
    }

    @Test func declineIsOneTap() async throws {
        let w = await world()
        await w.during { await w.access.refresh() }
        let req = try #require(w.access.pending.first)
        let ok = await w.during { await w.access.answer(req, approve: false) }
        #expect(ok)
        #expect(w.keyring.unlocks == 0)
        #expect(w.box.access.requests.first?.state == "declined")
    }

    /// A phone whose clock is off signs again with the box's time, under
    /// the same Face ID.
    @Test func aClockOffByAnHourSignsAgainWithTheBoxs() async throws {
        let w = await world(phoneClockOffMs: 3_600_000)
        let offer = try w.offer()
        let row = await w.during { await w.access.approve(offer, grant: Grant.from(offer, control: false, lengthMs: 30 * 86_400_000)) }
        #expect(row != nil)
        #expect(w.keyring.unlocks == 1)
        #expect(row!.expiresAtMs <= Int64(w.scheduler.nowMs) + 30 * 86_400_000)
    }

    /// A new key needs the old key's signature; the box takes no other.
    @Test func replacingTheKeyNeedsTheOldOne() async throws {
        let w = await world()
        let offer = try w.offer()
        _ = await w.during { await w.access.approve(offer, grant: Grant.from(offer, control: false, lengthMs: 86_400_000)) }
        let before = try #require(w.box.access.keys[AccessModel.demoFor.deviceID])
        let ok = await w.during { await w.access.replaceKey() }
        #expect(ok)
        let after = try #require(w.box.access.keys[AccessModel.demoFor.deviceID])
        #expect(after != before)
        #expect(after == (try w.keyring.existing())?.publicKey)
    }

    /// A box that holds a key this phone lost: say where to replace it.
    @Test func aLostKeySaysWhereToReplaceIt() async throws {
        let w = await world()
        let offer = try w.offer()
        _ = await w.during { await w.access.approve(offer, grant: Grant.from(offer, control: false, lengthMs: 86_400_000)) }
        let fresh = AccessModel(site: w.site, signedFor: AccessModel.demoFor, keyring: SimulatedKeyring(), wallMs: { [s = w.scheduler] in s.nowMs })
        await w.during { await fresh.refresh() }
        let again = try w.offer()
        let row = await w.during { await fresh.approve(again, grant: Grant.from(again, control: false, lengthMs: 86_400_000)) }
        #expect(row == nil)
        #expect(fresh.help == AccessWords.help(ApprovalKeyLost()))
    }

    /// The audit log names who did what, and a support call's person as
    /// FTW Cloud named them.
    @Test func theAuditSaysWhoDidWhat() async throws {
        let w = await world()
        await w.during { await w.access.refresh() }
        await w.during { await w.access.loadAudit() }
        #expect(!w.access.audit.isEmpty)
        let support = try #require(w.access.audit.first { !$0.by.isEmpty })
        AppWords.$language.withValue(.en) {
            #expect(AccessWords.actor(support, me: AccessModel.demoFor.deviceID, agents: w.access.list?.agents ?? []) == "Sourceful support")
            #expect(AccessWords.by(support) == "anna.lindqvist, named by FTW Cloud")
            #expect(AccessWords.what(support) == "Read the log ×3")
        }
        AppWords.$language.withValue(.sv) {
            #expect(AccessWords.by(support) == "anna.lindqvist, enligt FTW Cloud")
        }
        // Newest first, in seq.
        #expect(w.access.audit.map(\.seq) == w.access.audit.map(\.seq).sorted(by: >))
    }

    /// The simulated home has no id; its key is kept under one anyway.
    @Test func theDemoApproves() async throws {
        let scheduler = ManualScheduler(nowMs: 1_792_000_000_000)
        let app = AppModel(store: MemoryStore(), files: nil, passkeys: nil, scheduler: scheduler, build: "t", ua: "t", demo: SimulatedBox.loopback)
        let keyring = SimulatedKeyring()
        app.demoAccess = (keyring, SimulatedAccess.offerKeys, SimulatedDesk(), SimulatedAccess.lookup)
        app.startDemo()
        let access = try #require(app.home?.access)
        func run(_ ms: Double) async {
            var left = ms
            while left > 0 {
                for _ in 0..<20 { await Task.yield() }
                scheduler.advance(10)
                left -= 10
            }
        }
        await run(1_000)
        #expect(access.available)
        let offer = try SimulatedAccess.offer(nowMs: scheduler.nowMs).open(keys: app.offerKeys, nowMs: Int64(scheduler.nowMs))
        let task = Task { await access.approve(offer, grant: Grant.from(offer, control: false, lengthMs: 86_400_000)) }
        await run(3_000)
        let row = await task.value
        #expect(row != nil, "\(access.help ?? "")")
        #expect(keyring.unlocks == 1)
    }

    /// A consent page's link, tapped or opened from its QR code, reaches the
    /// box with one Face ID and no code typed. Approving checks the offer
    /// again before it signs.
    @Test func aLinkIsApprovedWithNoCode() async throws {
        let w = await world(seed: false)
        let link = OfferLink(request: "r1", offer: SimulatedAccess.offer(nowMs: w.scheduler.nowMs).base64url)
        let flow = OfferFlow(link: link, lookup: OfferLookup(base: URL(string: "https://cloud.test")!) { _ in
            Issue.record("a link asked FTW Cloud")
            return (Data(), 500)
        }, keys: SimulatedAccess.offerKeys, wallMs: { [s = w.scheduler] in s.nowMs })
        await flow.start(home: nil)
        guard case .review = flow.step else { Issue.record("no review: \(flow.step)"); return }
        await w.during { await flow.approve(w.access, home: nil) }
        guard case .done(let row) = flow.step else { Issue.record("not granted: \(flow.step) \(w.access.help ?? "")"); return }
        #expect(row.principal.client == "Claude")
        #expect(w.keyring.unlocks == 1)
        #expect(w.box.access.rows.contains { $0.id == row.id })
    }

    /// A cached list knows no keys: the box's own list decides, and with
    /// no answer nothing is signed.
    @Test func aCachedListNeverRegistersAKey() async throws {
        let w = await world()
        let offer = try w.offer()
        _ = await w.during { await w.access.approve(offer, grant: Grant.from(offer, control: false, lengthMs: 86_400_000)) }
        let key = try #require(w.box.access.keys[AccessModel.demoFor.deviceID])
        let sets = w.box.access.audit.filter { $0.what == "approval.key.set" }.count

        // The next visit opens on the kept rows, which carry no keys.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let files = SealedFiles(directory: dir, store: MemoryStore())
        files.writeJSON("access-home1", w.access.list?.agents ?? [])
        let site = SiteModel(siteId: "home1", build: "t", ua: "t", scheduler: w.scheduler, files: files)
        let again = AccessModel(site: site, signedFor: AccessModel.demoFor, keyring: w.keyring, wallMs: { [s = w.scheduler] in s.nowMs })
        #expect(!(again.list?.agents.isEmpty ?? true))
        #expect(!again.keysKnown && !again.boxHasKey)
        site.start()
        site.connect(LoopbackCarrier(box: w.box, scheduler: w.scheduler, latencyMs: 20))
        await w.run(500)
        let second = try w.offer()
        let row = await w.during { await again.approve(second, grant: Grant.from(second, control: false, lengthMs: 86_400_000)) }
        #expect(row != nil, "\(again.help ?? "")")
        #expect(w.box.access.audit.filter { $0.what == "approval.key.set" }.count == sets)
        #expect(w.box.access.keys[AccessModel.demoFor.deviceID] == key)

        // No answer to agent.list: no Face ID and nothing sent.
        let mute = AccessModel(site: site, signedFor: AccessModel.demoFor, keyring: w.keyring, wallMs: { [s = w.scheduler] in s.nowMs })
        w.box.mute = true
        let unlocks = w.keyring.unlocks
        let third = try w.offer()
        let waiting = Task { await mute.approve(third, grant: Grant.from(third, control: false, lengthMs: 86_400_000)) }
        // Past the box's answer deadline.
        await w.run(Session.planTimeoutMs + 1_000)
        let none = await waiting.value
        #expect(none == nil)
        #expect(w.keyring.unlocks == unlocks)
        w.box.mute = false
    }

    /// A first key is kept before the box hears of it; one that cannot be
    /// kept is never sent.
    @Test func aKeyThatCannotBeKeptIsNeverSent() async throws {
        let w = await world()
        w.keyring.keepFails = true
        let offer = try w.offer()
        let row = await w.during { await w.access.approve(offer, grant: Grant.from(offer, control: false, lengthMs: 86_400_000)) }
        #expect(row == nil)
        #expect(w.box.access.keys.isEmpty)
        #expect(w.access.help == AccessWords.help(ApprovalKeyNotKept()))
    }

    /// A replacement the box took though its answer was lost stays with the
    /// phone, and the next approval finds the key the box holds.
    @Test func aReplacementIsNeverStranded() async throws {
        let w = await world()
        let offer = try w.offer()
        _ = await w.during { await w.access.approve(offer, grant: Grant.from(offer, control: false, lengthMs: 86_400_000)) }
        let old = try #require(w.box.access.keys[AccessModel.demoFor.deviceID])
        w.box.access.loseNextAnswer = true
        let task = Task { await w.access.replaceKey() }
        await w.run(10_000)
        #expect(await task.value == false)
        let taken = try #require(w.box.access.keys[AccessModel.demoFor.deviceID])
        #expect(taken != old)
        #expect(try w.keyring.pending()?.publicKey == taken)

        let next = try w.offer()
        let row = await w.during { await w.access.approve(next, grant: Grant.from(next, control: false, lengthMs: 86_400_000)) }
        #expect(row != nil, "\(w.access.help ?? "")")
        #expect(try w.keyring.existing()?.publicKey == taken)
        #expect(try w.keyring.pending() == nil)
        // Every Face ID given was ended.
        #expect(w.keyring.ends == w.keyring.unlocks)
    }

    /// A widen that does not renew keeps the end exactly.
    @Test func aChangeWithoutRenewingKeepsTheEnd() async throws {
        let w = await world()
        await w.during { await w.access.refresh() }
        let claude = try #require(w.access.assistants.first)
        let same = Grant(scopes: ["ftw.live.read"], ops: [], caps: Caps(perMin: 6), lengthMs: 0, expiresAtMs: claude.expiresAtMs)
        #expect(await w.during { await w.access.widen(claude, to: same) })
        #expect(w.access.row(claude.id)?.expiresAtMs == claude.expiresAtMs)
    }

    /// Only what the app can show may be approved; the rest is declined.
    @Test func aStrangeRequestCanOnlyBeDeclined() async throws {
        func request(_ op: String, _ args: CBOR) -> AgentRequest {
            AgentRequest(reqId: "r", agent: "a", op: op, args: args, why: "", atMs: 0, expiresAtMs: 0, state: "pending")
        }
        #expect(AccessWords.approvable(request("site.mode.set", .map([("mode", .text("self_consumption"))]))))
        #expect(!AccessWords.approvable(request("site.mode.set", .map([("mode", .text("x")), ("admin", .bool(true))]))))
        #expect(!AccessWords.approvable(request("site.mode.set", .map([("mode", .int(3))]))))
        #expect(!AccessWords.approvable(request("car.add", .emptyMap)))
        #expect(!AccessWords.approvable(request("planner.prefs.set", .map([("battery_export", .text("sometimes"))]))))
        #expect(!AccessWords.approvable(request("car.goal.set", .map([("ready_by_min", .double(.infinity))]))))
        #expect(!AccessWords.approvable(request("car.goal.set", .map([("ready_by_min", .double(1e300))]))))
        // Never a crash on a number too large to mean anything.
        let huge = request("car.goal.set", .map([("ready_by_min", .double(1e300)), ("days", .double(-.infinity)), ("target", .double(.nan))]))
        #expect(AccessWords.arguments(huge).count == 3)

        let w = await world()
        await w.during { await w.access.refresh() }
        let strange = request("site.mode.set", .map([("mode", .text("idle")), ("extra", .text("x"))]))
        #expect(await w.during { await w.access.answer(strange, approve: true) } == false)
        #expect(w.keyring.unlocks == 0)
    }

    /// An assistant may not call itself Sourceful or FTW; every name is its
    /// own word, quoted, with no hidden characters.
    @Test func noAssistantPassesForSourceful() {
        AppWords.$language.withValue(.en) {
            var row = AgentRow(id: "q7Xn2vKd", key: [], role: Contract.roleAgent, scopes: [], ops: [], caps: Caps(), expiresAtMs: 0,
                               principal: Principal(client: "Sourceful support", clientId: "https://evil.example/c"))
            #expect(AccessWords.name(row) == "Assistant q7Xn2vKd")
            row.principal.client = "FTW Helper"
            #expect(AccessWords.name(row) == "Assistant q7Xn2vKd")
            row.principal.client = "Ｓourceful"
            #expect(AccessWords.name(row) == "Assistant q7Xn2vKd")
            row.principal.client = "Claude\u{202E}evil"
            #expect(AccessWords.name(row) == "“Claude evil”")
            row.role = Contract.roleSupport
            #expect(AccessWords.name(row) == "Sourceful support")
            var o = GrantOffer()
            o.role = Contract.roleAgent
            o.client = "Sourceful"
            o.clientHost = "evil.example"
            #expect(AccessWords.clientName(o) == "Assistant at evil.example")
            #expect(AccessWords.nameHidden(o.client))
            #expect(AccessModel.cut(String(repeating: "å", count: 200)).utf8.count == 256)
            #expect(AccessModel.cut(String(repeating: "å", count: 200)).count == 128)
        }
    }

    /// Every word an owner reads has its Swedish.
    @Test func everyWordHasItsSwedish() {
        for scope in Contract.agentRoleScopes[Contract.roleAgent]! {
            #expect(AccessWords.sv[AccessWords.scopeWords[scope] ?? ""] != nil, "\(scope)")
        }
        for op in Contract.agentOps.keys {
            #expect(AccessWords.sv[AccessWords.opWords[op] ?? ""] != nil, "\(op)")
        }
        for args in Contract.agentArgs.values {
            for a in args { #expect(AccessWords.sv[a.label] != nil, "\(a.label)") }
        }
        for (_, en) in AccessWords.auditWords { #expect(AccessWords.sv[en] != nil, "\(en)") }
        for (_, en) in AccessWords.enumWords { #expect(AccessWords.sv[en] != nil, "\(en)") }
        let errors: [OfferError] = [.noPinnedKey, .unsigned, .expired, .malformed, .notFromSourceful, .strangeHost, .used, .unknownHome, .wrongCode, .notFound, .unreachable]
        AppWords.$language.withValue(.sv) {
            for e in errors { #expect(AccessWords.offer(e) != AppWords.$language.withValue(.en) { AccessWords.offer(e) }, "\(e)") }
        }
    }
}
