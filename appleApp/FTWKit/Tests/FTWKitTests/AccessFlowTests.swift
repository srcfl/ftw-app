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
        let errors: [OfferError] = [.noPinnedKey, .unsigned, .expired, .malformed, .supportFromStranger, .unknownHome, .wrongCode, .notFound, .unreachable]
        AppWords.$language.withValue(.sv) {
            for e in errors { #expect(AccessWords.offer(e) != AppWords.$language.withValue(.en) { AccessWords.offer(e) }, "\(e)") }
        }
    }
}
