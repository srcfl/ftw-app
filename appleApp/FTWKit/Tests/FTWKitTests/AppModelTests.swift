import Foundation
import Testing
@testable import FTWKit
import FTWDemo

@MainActor
@Suite struct DemoHomeTests {
    /// The demo: every screen's model against the simulated box, with no
    /// passkey, no relay and nothing written.
    func demo() async -> (AppModel, HomeModels, ManualScheduler) {
        let scheduler = ManualScheduler()
        let app = AppModel(store: MemoryStore(), files: nil, passkeys: nil, scheduler: scheduler, build: "test", ua: "test", demo: SimulatedBox.loopback)
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

    @Test func pricesSavingsAndStatusFill() async {
        let (_, home, s) = await demo()
        home.prices.activate()
        home.savings.activate()
        home.status.activate()
        await run(s, 3_000)
        #expect(home.prices.prices?.currency == "SEK")
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

    @Test func leavingTheDemoTouchesNoSavedHome() async {
        let (app, _, _) = await demo()
        app.exitDemo()
        #expect(app.home == nil)
        #expect(!app.isDemo)
    }

    /// A build without FTWDemo has no simulated home to open.
    @Test func noDemoWithoutTheDemoModule() {
        let app = AppModel(store: MemoryStore(), files: nil, passkeys: nil, scheduler: ManualScheduler(), build: "test", ua: "test")
        #expect(!app.canDemo)
        app.startDemo()
        #expect(app.home == nil)
        #expect(!app.isDemo)
    }

    /// The demo writes nothing a widget could mistake for a home.
    @Test func theDemoLeavesNothingForWidgets() async throws {
        let scheduler = ManualScheduler()
        let shared = AppGroupFiles(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ftw-shared-\(UUID().uuidString)"))
        let app = AppModel(store: MemoryStore(), files: nil, shared: shared, passkeys: nil, scheduler: scheduler, build: "test", ua: "test", demo: SimulatedBox.loopback)
        app.startDemo()
        let home = try #require(app.home)
        home.prices.activate()
        home.charging.activate()
        await run(scheduler, 7_000)
        #expect(home.prices.prices != nil)
        #expect(shared.siteIDs(PriceEntry.self).isEmpty)
        #expect(shared.siteIDs(CarEntry.self).isEmpty)
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
        let passkeys = FakePasskeys()
        let shared = AppGroupFiles(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ftw-shared-\(UUID().uuidString)"))
        let widgetWakes = Counter()

        init() {
            files = SealedFiles(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ftw-test-\(UUID().uuidString)"), store: store)
            box = SimulatedBox(scheduler: scheduler)
            endpoint = NoiseBoxEndpoint(box: box)
            relay = FakeRelay(scheduler: scheduler, endpoint: endpoint)
        }

        func app() -> AppModel {
            AppModel(store: store, files: files, shared: shared, sharedWritten: { [widgetWakes] in widgetWakes.count += 1 }, passkeys: passkeys, scheduler: scheduler, build: "test", ua: "test", relayURL: URL(string: "wss://relay.test")!, makeSocket: relay.factory)
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

    @Test func aConfigureWriteGoesThrough() async throws {
        let world = World()
        let app = world.app()
        let pair = PairModel(app: app)
        let t = Task { await pair.pair(world.pairingURL) }
        await world.run(500)
        await t.value
        let site = try #require(app.site)
        let task = Task { try await site.callBox(.put, "/api/loadpoints/garage/schedule", body: ["soc": .number(0.7), "time_of_day_min_utc": 300, "recurring": true, "days": 0, "surplus_unlock_bat_soc": 0]) }
        await world.run(300)
        _ = try await task.value
        #expect(world.box.house.schedule?.socFraction == 0.7)
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
        // The widgets lose their records and are told.
        #expect(world.shared.siteIDs(PriceEntry.self).isEmpty)
        #expect(world.widgetWakes.count > 0)
    }

    /// iOS freezes a backgrounded app within seconds. The session closes
    /// first, freeing one of the relay's four streams, and a new one opens
    /// on return without a passkey.
    @Test func theBackgroundClosesTheSessionAndTheForegroundReopensIt() async throws {
        let world = World()
        let app = world.app()
        let pair = PairModel(app: app)
        let t = Task { await pair.pair(world.pairingURL) }
        await world.run(500)
        await t.value
        let site = try #require(app.site)
        #expect(site.session.phase == .streaming)

        app.setVisible(false)
        app.suspend()
        await world.run(100)
        #expect(!site.core.hasCarrier)
        #expect(world.relay.current == nil)
        #expect(site.carrier == .none)
        // What was on screen stays, dated.
        #expect(site.session.fields[Contract.FID.gridW] != nil)
        #expect(!site.isLive)

        app.setVisible(true)
        await world.run(1_000)
        #expect(site.session.phase == .streaming)
        #expect(site.isLive || site.srcState == .live)
        #expect(world.relay.dialled.count == 2)
        #expect(world.passkeys.assertions.isEmpty)
    }

    /// Widgets read what the app leaves in the App Group, never the relay.
    @Test func widgetsGetThePricesAndTheCar() async throws {
        let world = World()
        let app = world.app()
        let pair = PairModel(app: app)
        let t = Task { await pair.pair(world.pairingURL) }
        await world.run(500)
        await t.value
        let home = try #require(app.home)
        let siteId = try #require(home.site.siteId)
        home.prices.activate()
        home.charging.activate()
        await world.run(6_000, step: 100)

        let reader = CacheReader(sources: [world.shared])
        #expect(reader.latestSiteID(PriceEntry.self) == siteId)
        let prices = try #require(reader.read(PriceEntry.self, siteId: siteId))
        #expect(prices.value.prices.currency == "SEK")
        #expect(!prices.value.prices.slots.isEmpty)
        // It arrived over the relay, and reads back as the cache.
        #expect(prices.record.carrier == .relay)
        #expect(prices.carrier == .cache)
        let car = try #require(reader.read(CarEntry.self, siteId: siteId)?.value.cars.first)
        #expect(car.loadpointID == "garage")
        #expect(car.socSource == world.box.house.carSocSource)
        #expect(car.socReadAtMs != nil)
        #expect(world.widgetWakes.count >= 2)

        // The same car five seconds later is not written again.
        let wakes = world.widgetWakes.count
        await world.run(6_000, step: 100)
        #expect(world.widgetWakes.count == wakes)
    }
}

@MainActor
final class Counter {
    var count = 0
}
