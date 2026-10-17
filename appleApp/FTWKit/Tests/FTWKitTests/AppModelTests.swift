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
        #expect(home.nodes.live.points(Contract.FID.gridW, sinceMs: 0).count >= 2)
    }

    @Test func pricesSavingsAndStatusFill() async {
        let (_, home, s) = await demo()
        home.prices.activate()
        home.savings.activate()
        home.status.activate()
        await run(s, 3_000)
        #expect(home.prices.prices?.currency == "SEK")
        #expect(home.savings.week?.value.totals?.priced == true)
        #expect(home.status.fresh)
        #expect(Flow.fuse(status: home.status.status!) != nil)
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
        let endpoint: FakeTunnelBox
        let cloud: FakeCloudService
        let code = randomBytes(16)
        static let home = "abcdefghijklmnopqrstuvwx23"
        let passkeys = FakePasskeys()
        let shared = AppGroupFiles(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ftw-shared-\(UUID().uuidString)"))
        let widgetWakes = Counter()

        init() {
            files = SealedFiles(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ftw-test-\(UUID().uuidString)"), store: store)
            box = SimulatedBox(scheduler: scheduler)
            box.moreCaps = [Contract.capCloudTun]
            endpoint = FakeTunnelBox(simulated: box)
            endpoint.code = code
            cloud = FakeCloudService(scheduler: scheduler)
            cloud.tunBox = endpoint
            cloud.pending = [CloudWire.pairingHash(home: Self.home, code: code)]
        }

        func app() -> AppModel {
            AppModel(store: store, files: files, shared: shared, sharedWritten: { [widgetWakes] in widgetWakes.count += 1 }, passkeys: passkeys, scheduler: scheduler, build: "test", ua: "test", cloudEndpoint: cloud.endpoint, makeSocket: sockets)
        }

        var sockets: WebSocketFactory {
            { [self] url, events in
                cloud.roster.formUnion(endpoint.paired)
                return cloud.factory(url, events)
            }
        }

        var pairingURL: String {
            Enrollment(boxStaticPublic: endpoint.staticKey.publicKey, pairingCode: code, lanHint: "", rendezvousSecret: randomBytes(32), home: Self.home).url()
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
        #expect(site.carrier == .tunnel)
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
        #expect(cold.carrier == .tunnel)
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

    /// The pairing scanner reads an assistant's consent QR as its link: the
    /// saved home opens with the offer, and nothing pairs. With no home it
    /// says to connect the box first.
    @Test func aConsentQRInThePairingScannerOpensTheOffer() async throws {
        let world = World()
        let link = "https://app.ftw.energy/a#r1.b2ZmZXI"
        let app = world.app()
        app.launch()
        let first = PairModel(app: app)
        await first.pair(link)
        #expect(first.stage == .intro)
        #expect(first.message == NodeWords.text("That is an assistant's QR code. Connect your box first, then scan it again."))
        #expect(app.accessLink == nil)
        #expect(world.passkeys.registrations == 0)

        let pairing = PairModel(app: app)
        let t = Task { await pairing.pair(world.pairingURL) }
        await world.run(500)
        await t.value
        let siteId = try #require(app.site?.siteId)
        // Back on the scanner from the home, as "Scan a new pairing QR" is.
        app.recovering = true
        let again = PairModel(app: app)
        #expect(again.canOpen)
        await again.pair(link)
        #expect(app.accessLink == OfferLink(link))
        #expect(!app.needsPairing)
        #expect(app.site?.siteId == siteId)
        #expect(world.passkeys.registrations == 1)
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

    /// Closing the passkey sheet at start is not a lost key: the screen says
    /// so and offers to try again, instead of sending the person to pair.
    @Test func aCancelledUnlockIsNotALostKey() async throws {
        let world = World()
        let app = world.app()
        let pair = PairModel(app: app)
        let t = Task { await pair.pair(world.pairingURL) }
        await world.run(500)
        await t.value
        // A device enrolled before the local copy existed asks once more.
        try? app.vault.removeCredential(Vault.localCredentialID)
        #expect(try app.vault.silentWrappingKey() == nil)
        world.passkeys.cancel = true
        let again = world.app()
        again.launch()
        await world.run(100)
        #expect(again.connectHelp == "Unlocking was cancelled. Try again to open your home.")
    }

    /// Every help text a connect can show has Swedish. Read from the
    /// source, so a new one cannot slip through.
    @Test func everyConnectHelpHasSwedish() throws {
        let pattern = #/AppWords\.text\("((?:[^"\\]|\\.)*)"\)/#
        var seen = 0
        for file in ["appleApp/FTWKit/Sources/FTWKit/State/AppModel.swift", "appleApp/FTWKit/Sources/FTWKit/Identity/Vault.swift"] {
            for match in try RepoFiles.read(file).matches(of: pattern) {
                let english = String(match.1).replacingOccurrences(of: "\\\"", with: "\"")
                seen += 1
                #expect(AppWords.sv[english] != nil, "no Swedish for \"\(english)\" in \(file)")
            }
        }
        #expect(seen >= 7)
        #expect(AppWords.sv[Vault.lockedHelp] != nil)
        AppWords.$language.withValue(.sv) {
            #expect(AppWords.text(Vault.lockedHelp).hasPrefix("Enheten kan inte längre"))
        }
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
        #expect(world.cloud.current == nil)
        #expect(site.carrier == .none)
        // What was on screen stays, dated.
        #expect(site.session.fields[Contract.FID.gridW] != nil)
        #expect(!site.isLive)

        app.setVisible(true)
        await world.run(1_000)
        #expect(site.session.phase == .streaming)
        #expect(site.isLive || site.srcState == .live)
        #expect(world.cloud.dialled.count == 2)
        #expect(world.passkeys.assertions.isEmpty)
    }

    /// Coming back, iOS passes through inactive before active. The dial
    /// starts there, so the handshake runs beside the app switch, and a
    /// glance at Control Center keeps the session and its rate.
    @Test func theReturnDialsAtInactive() async throws {
        let world = World()
        let app = world.app()
        let pair = PairModel(app: app)
        let t = Task { await pair.pair(world.pairingURL) }
        await world.run(500)
        await t.value
        let site = try #require(app.site)

        // A glance from the front: nothing closes, nothing slows.
        app.glance()
        await world.run(100)
        #expect(site.documentVisible)
        #expect(site.core.hasCarrier)
        #expect(world.cloud.dialled.count == 1)

        app.setVisible(false)
        app.suspend()
        await world.run(100)
        #expect(!site.core.hasCarrier)

        // Inactive on the way back: the new carrier dials now.
        app.glance()
        await world.run(1_000)
        #expect(world.cloud.dialled.count == 2)
        #expect(site.session.phase == .streaming)
        #expect(site.documentVisible)
        app.setVisible(true)
        await world.run(100)
        #expect(world.cloud.dialled.count == 2)
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
        #expect(prices.record.carrier == .tunnel)
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
