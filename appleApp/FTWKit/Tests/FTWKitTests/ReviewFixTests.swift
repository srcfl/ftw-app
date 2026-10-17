import Foundation
import Testing
@testable import FTWKit
import FTWShared

/// A store that cannot answer, as the keychain before the first unlock: every
/// read throws errSecInteractionNotAllowed, and every write is counted.
@MainActor
final class LockedStore: SecureStore {
    private(set) var writes: [String] = []

    func get(_ key: String) -> Bytes? { nil }
    func read(_ key: String) throws -> Bytes? { throw SecureStoreUnavailable(status: -25308) }
    func put(_ key: String, _ value: Bytes) { writes.append(key) }
    func remove(_ key: String) {}
}

@MainActor
@Suite struct ReviewFixTests {
    /// Every open used to say "Reconnecting to your box", because a carrier
    /// made a moment earlier was woken at once. A cold start says it is
    /// connecting, and says reconnecting only once the carrier really drops.
    @Test func aColdStartSaysConnectingNeverReconnecting() async throws {
        let world = ShellTests.World()
        let first = world.app()
        let pair = PairModel(app: first)
        let task = Task { await pair.pair(world.pairingURL) }
        await world.run(500)
        await task.value
        first.suspend()

        let app = world.app()
        app.launch()
        let site = try #require(app.site)
        var said: [String] = []
        for _ in 0..<40 {
            await world.run(20, step: 10)
            let message = site.freshness(noCarrier: false).message
            if said.last != message { said.append(message) }
        }
        #expect(site.session.phase == .streaming)
        #expect(said.contains("Connecting to your box"))
        #expect(!said.contains("Reconnecting to your box"), "\(said)")

        world.cloud.close(code: 1006)
        await world.run(40, step: 10)
        #expect(site.freshness(noCarrier: false).message == "Reconnecting to your box")
    }

    /// A command on a carrier that is not open fails at once, not after the
    /// five seconds an ack would get.
    @Test func aCommandOnAClosedCarrierFailsAtOnce() async throws {
        let scheduler = ManualScheduler()
        let site = SiteModel(siteId: "s1", build: "t", ua: "t", scheduler: scheduler, files: nil)
        site.start()
        let relay = ScriptedBox()
        site.connect(relay)
        let started = scheduler.nowMs
        do {
            _ = try await site.command(Contract.opSetMode, args: [("mode", .text("self_consumption"))])
            Issue.record("a command went out on a carrier that was not open")
        } catch let e as CommandError {
            #expect(e.code == "E_NO_ACK")
        }
        #expect(scheduler.nowMs - started < 100)
        #expect(relay.sent.isEmpty)
    }

    /// Before the first unlock the keychain cannot answer. Nothing is then
    /// written: no new wrap key over the old one, no cache key, no list of
    /// homes with the others dropped, and no pairing.
    @Test func aLockedKeychainLeadsToNoWrite() async throws {
        let store = LockedStore()
        let vault = Vault(store: store)
        #expect(throws: SecureStoreUnavailable.self) { try vault.localWrappingKey() }
        let files = SealedFiles(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ftw-locked-\(UUID().uuidString)"), store: store)
        files.write("snapshot-s1", [1, 2, 3])
        #expect(files.read("snapshot-s1") == nil)
        SiteList(store: store).put(StoredSite(siteId: "s1", label: "Home", boxStaticKey: Data(repeating: 1, count: 32), rendezvousSecret: nil, pairingCode: nil, lanHint: nil, addedAtMs: 0, lastSeenAtMs: 0))

        let app = AppModel(store: store, files: files, passkeys: nil, scheduler: ManualScheduler(), build: "t", ua: "t")
        app.launch()
        await app.connect()
        #expect(store.writes.isEmpty, "\(store.writes)")
    }

    /// After 20 s without a connection the band stops counting and says when
    /// the last reading was.
    @Test func aLongWaitSaysCantReachWithTheLastReading() async throws {
        let scheduler = ManualScheduler()
        let site = SiteModel(siteId: "s1", build: "t", ua: "t", scheduler: scheduler, files: nil)
        site.start()
        site.connect(ScriptedBox())
        var band = site.freshness(noCarrier: false)
        #expect(band.wait == "0s")
        for _ in 0..<19 { scheduler.advance(1_000) }
        band = site.freshness(noCarrier: false)
        #expect(band.wait == "19s")
        for _ in 0..<2 { scheduler.advance(1_000) }
        band = site.freshness(noCarrier: false)
        #expect(band.message == "Can't reach your box")
        #expect(band.wait == nil)
        #expect(band.tone == .lost)

        let withReading = Freshness.band(carrier: .cache, transport: .none, srcState: .stale, ageMs: 120_000, phase: .failed,
                                         waitMs: 25_000, bootPct: nil, noCarrier: false, lastReading: "14:02")
        #expect(withReading.message == "Can't reach your box · last reading 14:02")
        #expect(withReading.wait == nil)
        let starting = Freshness.band(carrier: .cache, transport: .none, srcState: .stale, ageMs: 120_000, phase: .booting,
                                      waitMs: 25_000, bootPct: 40, noCarrier: false, lastReading: "14:02")
        #expect(starting.message == "Your box is starting")
    }

    /// While live, the clock moves with the frames: one change a second, not
    /// a frame and a tick.
    @Test func theClockMovesWithTheFrames() async throws {
        let scheduler = ManualScheduler()
        let site = SiteModel(siteId: "s1", build: "t", ua: "t", scheduler: scheduler, files: nil)
        site.start()
        let relay = ScriptedBox()
        site.connect(relay)
        relay.open(scheduler.nowMs)
        relay.helloOk(uptimeMs: 60_000, cloud: nil)
        relay.snap(uptimeMs: 60_000, gridW: 500)
        scheduler.advance(20)
        var changes = 0
        site.observe { changes += 1 }
        for i in 1...10 {
            scheduler.advance(1_000)
            relay.say("delta", .map([("seq", .int(i)), ("uptimeMs", .int(60_000 + i * 1_000)), ("fields", .map(["2": .int(500 + i)]))]))
        }
        scheduler.advance(20)
        #expect(site.isLive)
        #expect(changes <= 12, "\(changes) changes in 10 s of 1 Hz frames")
        #expect(site.nowMs == scheduler.nowMs - 20)

        // Silence: the clock wakes once to say the stream went quiet.
        scheduler.advance(SiteModel.streamQuietAfterMs + 10)
        #expect(site.srcState == .lagging)
    }

    /// Found in the simulator: while a burst waited for its frame, the band
    /// read the newest relay state and said "Live via encrypted relay" as
    /// the card still said "Not live right now". Both read one snapshot now.
    @Test func theBandAndTheCardsNeverDisagree() async throws {
        let scheduler = ManualScheduler()
        let site = SiteModel(siteId: "s1", build: "t", ua: "t", scheduler: scheduler, files: nil)
        site.start()
        let relay = ScriptedBox()
        site.connect(relay)
        relay.open(scheduler.nowMs)
        relay.helloOk(uptimeMs: 60_000, cloud: nil)
        relay.snap(uptimeMs: 60_000, gridW: 500)
        // Within the frame: whatever is shown agrees with itself.
        #expect((site.carrier == .relay) == (site.session.phase == .streaming))
        #expect(!site.isLive || site.carrier == .relay)
        scheduler.advance(20)
        #expect(site.carrier == .relay && site.session.phase == .streaming && site.isLive)
    }

    /// The same home is not written twice, and the background writes once.
    @Test func theSameSnapshotIsNotWrittenTwice() async throws {
        let w = try CloudSite()
        w.open()
        w.site.connect(w.relay)
        w.relay.open(w.scheduler.nowMs)
        w.relay.helloOk(uptimeMs: w.uptime, cloud: nil)
        w.relay.snap(uptimeMs: w.uptime, gridW: 700)
        await w.run(40)
        w.site.persistNow(wait: true)
        // Each write draws a new nonce, so equal bytes prove no second write.
        let first = w.files.read("snapshot-s1")
        w.site.persistNow(wait: true)
        w.site.suspend()
        #expect(first != nil)
        #expect(w.files.read("snapshot-s1") == first)
    }

    /// Numbers never step back: a cloud copy older than the cache on screen
    /// waits until the cloud has something newer.
    @Test func anOlderCopyNeverReplacesANewerOne() async throws {
        let w = try CloudSite()
        w.keepFromEarlierLaunch(gridW: 111)
        // The cache was written a minute ago; the cloud's copy is from five
        // minutes ago and has gone stale.
        let old = try w.live(gridW: 900)
        w.scheduler.advance(300_000)
        w.files.writeJSON("snapshot-s1", CachedSnapshot(siteId: "s1", savedAtMs: w.scheduler.nowMs - 60_000, state: {
            var s = SessionState()
            s.fields = [Contract.FID.gridW: 111]
            return s
        }()))
        w.service.held = [old]
        w.open()
        w.connectCloud()
        await w.run(60)
        #expect(w.site.session.fields[Contract.FID.gridW] == 111)
        #expect(w.site.carrier == .cache)

        // A fresh live from the box is newer than the cache, and takes over.
        w.service.push(try w.live(gridW: 1200))
        await w.run(60)
        #expect(w.site.session.fields[Contract.FID.gridW] == 1200)
        #expect(w.site.carrier == .cloud)
        let at = try #require(w.site.fieldAtMs[Contract.FID.gridW])
        #expect(abs(at - w.scheduler.nowMs) < 200)
    }

    /// Envelopes that land in one burst reach the screens as one change.
    @Test func aBurstIsOneChange() async throws {
        let w = try CloudSite()
        w.keepFromEarlierLaunch(gridW: nil)
        w.service.held = [try w.live(gridW: 1000)]
        w.open()
        w.connectCloud()
        await w.run(60)
        var changes = 0
        w.site.observe { changes += 1 }
        w.service.push(try w.live(gridW: 1100))
        w.service.push(try w.live(gridW: 1150))
        w.service.push(try w.live(gridW: 1200))
        await w.run(60)
        #expect(w.site.session.fields[Contract.FID.gridW] == 1200)
        #expect(changes <= 2, "\(changes) changes for one burst")
    }

    /// The cloud's next grade change is when a reading's age passes S.
    @Test func theCloudSaysWhenItsGradeNextChanges() throws {
        var box = try FakeCloudBox(boot: 1)
        let at: Int64 = 2_000_000
        var view = box.view()
        try view.accept(box.fullLive(at, age: 1_000), arrivalMs: at + 100)
        // Rule N: sent at `at`. S = 10 s, age 1 s: live until at + 9 s.
        #expect(view.nextGradeChange(nowMs: at + 100) == at + 9_001)
        #expect(view.grade(nowMs: at + 9_001).sources["m"] == .lagging)
        #expect(view.grade(nowMs: at + 9_000).sources["m"] == .live)
    }
}
