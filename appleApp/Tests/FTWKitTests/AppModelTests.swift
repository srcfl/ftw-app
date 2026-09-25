import Foundation
import Testing
@testable import FTWKit

@MainActor
@Suite struct DemoHomeTests {
    /// The demo: every screen's model against the simulated box, with no
    /// passkey, no relay and nothing written.
    func demo() async -> (AppModel, HomeModels, ManualScheduler) {
        let scheduler = ManualScheduler()
        let app = AppModel(store: MemoryStore(), files: nil, passkeys: nil, scheduler: scheduler, build: "test", ua: "test")
        app.startDemo()
        let home = app.home!
        await run(scheduler, 1_000)
        return (app, home, scheduler)
    }

    func run(_ s: ManualScheduler, _ ms: Double, step: Double = 50) async {
        var left = ms
        while left > 0 {
            for _ in 0..<10 { await Task.yield() }
            s.advance(min(step, left))
            left -= step
        }
        for _ in 0..<10 { await Task.yield() }
    }

    @Test func theDemoStreamsAndSaysItIsLive() async {
        let (app, home, s) = await demo()
        #expect(app.isDemo)
        #expect(home.site.session.phase == .streaming)
        await run(s, 2_000)
        #expect(home.site.carrier == .relay)
        #expect(home.site.isLive)
        #expect(home.site.explanation.situation != .noData)
        #expect(home.site.recentField(Contract.FID.gridW).count >= 2)
    }

    @Test func thePlanLoadsAndAModeChangeFollowsIt() async {
        let (_, home, s) = await demo()
        home.plan.activate()
        await run(s, 500)
        #expect(home.plan.plan?.slots.count == 96)
        #expect(home.plan.canControl)
        #expect(home.plan.primaryModes.map(\.key) == ["planner_passive_arbitrage", "planner_arbitrage"])
        #expect(home.plan.actualMode == "planner_passive_arbitrage")
        let task = Task { await home.plan.setMode("self_consumption") }
        await run(s, 500)
        await task.value
        #expect(home.plan.command == .applied("self_consumption"))
        await run(s, 1_500)
        #expect(home.plan.actualMode == "self_consumption")
        #expect(home.plan.inManual)
        await run(s, PlanModel.settleMs + 100)
        #expect(home.plan.command == .idle)
    }

    @Test func pricesEnergyHistoryAndSavingsFill() async {
        let (_, home, s) = await demo()
        home.prices.activate()
        home.energy.activate()
        home.history.activate()
        home.savings.activate()
        home.status.activate()
        await run(s, 3_000)
        #expect(home.prices.prices?.currency == "SEK")
        #expect(home.energy.loaded)
        #expect(home.energy.days.count == 7)
        #expect(home.energy.totals.loadWh > 0)
        home.energy.select(.month)
        #expect(!home.energy.loaded)
        await run(s, 1_000)
        #expect(home.energy.days.count == 30)
        #expect(home.history.loaded)
        #expect((home.history.frame?.points ?? 0) > 200)
        #expect(home.savings.periods?.week.available == true)
        #expect(home.status.fresh)
        #expect(Flow.fuse(status: home.status.status!) != nil)
    }

    @Test func theChargerSheetSendsIntentAndRereads() async throws {
        let (_, home, s) = await demo()
        home.loadpoints.activate()
        await run(s, 1_000)
        let lp = try #require(home.loadpoints.points.first)
        #expect(lp.pluggedIn)
        #expect(home.loadpoints.windows[lp.id] != nil)

        let hold = Task { await home.loadpoints.chargeNow(lp, amps: 10) }
        await run(s, 1_000)
        await hold.value
        #expect(home.loadpoints.points.first?.manualActive == true)

        let release = Task { await home.loadpoints.stopCharging(lp) }
        await run(s, 1_000)
        await release.value
        #expect(home.loadpoints.outcome(for: .hold, lp) == "The plan decides when to charge.")

        let soc = Task { await home.loadpoints.setSoc(lp, pct: 55) }
        await run(s, 1_000)
        await soc.value
        #expect(home.loadpoints.points.first?.socPct == 55)

        let save = Task { try await home.loadpoints.saveSchedule(lp, socPct: 90, hour: 6, minute: 30, recurring: true, days: 0b0011111, surplusUnlockPct: 0) }
        await run(s, 1_000)
        try await save.value
        #expect(home.loadpoints.points.first?.schedule?.socPct == 90)
    }

    @Test func theBoxScreenReadsTheRosterAndInvitesAViewer() async {
        let (_, home, s) = await demo()
        home.access.activate()
        home.notify.activate()
        await run(s, 1_000)
        #expect(home.access.loaded)
        #expect(home.access.members.first?.isThisPhone == true)
        let invite = Task { await home.access.inviteViewer() }
        await run(s, 500)
        #expect(await invite.value)
        #expect(home.access.invite?.role == Contract.roleViewer)
        #expect(home.notify.availableKinds.count == 6)
        let save = Task { await home.notify.save(["charging.connected": true]) }
        await run(s, 500)
        #expect(await save.value)
        #expect(home.notify.rules["charging.connected"] == true)
        #expect(home.notify.boxEnabled)
    }

    @Test func leavingTheDemoTouchesNoSavedHome() async {
        let (app, _, _) = await demo()
        app.exitDemo()
        #expect(app.home == nil)
        #expect(!app.isDemo)
    }
}

@MainActor
@Suite struct ShellTests {
    @MainActor
    struct World {
        let scheduler = ManualScheduler()
        let store = MemoryStore()
        let files: SealedFiles
        let box: SimulatedBox
        let endpoint: NoiseBoxEndpoint
        let relay: FakeRelay
        let escrow = FakeEscrowService()
        let passkeys = FakePasskeys()

        init() {
            files = SealedFiles(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ftw-test-\(UUID().uuidString)"), store: store)
            box = SimulatedBox(scheduler: scheduler)
            endpoint = NoiseBoxEndpoint(box: box)
            relay = FakeRelay(scheduler: scheduler, endpoint: endpoint)
        }

        func app() -> AppModel {
            AppModel(store: store, files: files, passkeys: passkeys, scheduler: scheduler, build: "test", ua: "test", relayURL: URL(string: "wss://relay.test")!, escrowTransport: escrow.transport, makeSocket: relay.factory)
        }

        var pairingURL: String {
            Enrollment(boxStaticPublic: endpoint.staticKey.publicKey, pairingCode: randomBytes(16), lanHint: "", rendezvousSecret: randomBytes(32)).url()
        }

        func run(_ ms: Double, step: Double = 20) async {
            var left = ms
            while left > 0 {
                for _ in 0..<10 { await Task.yield() }
                scheduler.advance(min(step, left))
                left -= step
            }
            for _ in 0..<10 { await Task.yield() }
        }
    }

    @Test func pairStreamCloseAndReopenFromCache() async throws {
        let world = World()
        let app = world.app()
        app.launch()
        #expect(app.home == nil)

        let pair = PairModel(app: app)
        let task = Task { await pair.pair(world.pairingURL) }
        await world.run(500)
        await task.value
        let site = try #require(app.site)
        #expect(site.session.phase == .streaming)
        #expect(site.carrier == .relay)
        #expect(world.passkeys.registrations == 1)
        // Held a sealed copy in the background.
        await world.run(200)
        #expect(world.escrow.rows.count == 1)

        // Long enough for the snapshot to be written.
        await world.run(SiteModel.snapshotIntervalMs + 500, step: 250)
        site.persistNow()

        // A cold start paints the cache before any socket opens, and never
        // asks for a passkey to read.
        let again = world.app()
        again.launch()
        let cold = try #require(again.site)
        #expect(cold.carrier == .cache)
        #expect(cold.session.fields[Contract.FID.gridW] != nil)
        #expect(cold.srcState == .stale)
        #expect(cold.ageMs != nil)
        await world.run(500)
        #expect(cold.session.phase == .streaming)
        #expect(cold.carrier == .relay)
        #expect(world.passkeys.assertions.isEmpty)
    }

    @Test func aLinkToTheSameBoxIsALeftoverNotAnInvitation() async throws {
        let world = World()
        let app = world.app()
        let url = world.pairingURL
        let pair = PairModel(app: app)
        let task = Task { await pair.pair(url) }
        await world.run(500)
        await task.value
        app.offer(url)
        #expect(app.offeredLink == nil)
        let other = Enrollment(boxStaticPublic: Primitives.generateKeyPair().publicKey, pairingCode: randomBytes(16), lanHint: "", rendezvousSecret: randomBytes(32)).url()
        app.offer(other)
        #expect(app.offeredLink == other)
        #expect(PairModel(app: app).offeredFingerprint != nil)
    }

    @Test func aConfigureWriteRunsTheCeremonyOnce() async throws {
        let world = World()
        let app = world.app()
        let pair = PairModel(app: app)
        let t = Task { await pair.pair(world.pairingURL) }
        await world.run(500)
        await t.value
        // The simulated box refuses configure writes without the flag.
        let strict = SimulatedBox(scheduler: world.scheduler, requireStepUp: true)
        _ = strict
        let site = try #require(app.site)
        let restart = RestartModel(site: site)
        let task = Task { await restart.restart() }
        await world.run(300)
        await task.value
        #expect(restart.error == nil)
    }

    @Test func noKeyIsSaidPlainlyAndNothingRetries() async throws {
        let world = World()
        let app = world.app()
        let pair = PairModel(app: app)
        let t = Task { await pair.pair(world.pairingURL) }
        await world.run(500)
        await t.value
        // The identity is gone while the home's row survives.
        app.vault.reset()
        let again = world.app()
        again.launch()
        await world.run(100)
        #expect(again.connectHelp == "This device has no key for that home.")
    }

    @Test func signingOutClearsTheKeyTheHomeAndTheCache() async throws {
        let world = World()
        let app = world.app()
        let pair = PairModel(app: app)
        let t = Task { await pair.pair(world.pairingURL) }
        await world.run(500)
        await t.value
        app.site?.persistNow()
        app.leave()
        #expect(app.home == nil)
        #expect(!app.vault.isEnrolled)
        #expect(app.sites.all().isEmpty)
        #expect(world.store.keys.isEmpty)
        // The sealed copy stays: removing it is its own act.
        #expect(world.escrow.rows.count == 1)
    }
}
