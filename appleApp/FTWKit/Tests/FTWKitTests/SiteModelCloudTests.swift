import Foundation
import Testing
@testable import FTWKit
import FTWShared

/// A box session the test speaks for frame by frame: hello_ok with or
/// without FTW Cloud, then a snapshot of readings.
@MainActor
final class ScriptedBox: Carrier {
    let kind: CarrierKind = .relay
    private(set) var status: CarrierStatus = .connecting
    private var onFrame: @MainActor (Bytes) -> Void = { _ in }
    private var onStatus: @MainActor (CarrierStatus) -> Void = { _ in }
    private(set) var sent: [String] = []
    /// The box's HTTP API through the passthrough: method, path and body in,
    /// status and JSON out.
    var api: ((String, String, String) -> (Int, String))?
    private(set) var calls: [(method: String, path: String, body: String)] = []

    @discardableResult
    func send(_ frame: Bytes) -> Bool {
        guard status.isOpen else { return false }
        guard let f = try? Frame.decode(frame) else { return true }
        sent.append(f.envelope.t)
        guard f.envelope.t == "api.req", let id = f.envelope.id, let b = f.envelope.b else { return true }
        let method = b["method"]?.string ?? "", path = b["path"]?.string ?? ""
        let body = b["body"]?.byteString.map { String(decoding: $0, as: UTF8.self) } ?? ""
        calls.append((method, path, body))
        let (status, json) = api?(method, path, body) ?? (404, "{}")
        reply("api.head", id, .map([("status", .int(status)), ("headers", .map([("content-type", .text("application/json"))]))]))
        reply("api.chunk", id, .map([("seq", .int(0)), ("data", .bytes(Bytes(json.utf8)))]))
        reply("api.end", id, CBOR.emptyMap)
        return true
    }

    private func reply(_ t: String, _ id: UInt32, _ body: CBOR) {
        guard let frame = try? Frame.encodeBulk(envelope: Envelope(t: t, id: id, b: body)) else { return }
        onFrame(frame)
    }

    func setHandlers(onFrame: @escaping @MainActor (Bytes) -> Void, onStatus: @escaping @MainActor (CarrierStatus) -> Void) {
        self.onFrame = onFrame
        self.onStatus = onStatus
    }

    func wake() {}

    func close(reason: String) {
        status = .closed(reason: reason, retryable: false)
    }

    func open(_ at: Double) {
        status = .open(sinceMs: at)
        onStatus(status)
    }

    func say(_ t: String, _ body: CBOR) {
        guard let frame = try? Frame.encodeBulk(envelope: Envelope(t: t, b: body)) else { return }
        onFrame(frame)
    }

    func helloOk(uptimeMs: Int64, cloud: CloudIdentity?, role: String = Contract.roleOwner, caps: [String] = [Contract.capCloudLink, Contract.capAPIPassthrough]) {
        var body: [(String, CBOR)] = [
            ("proto", .int(Proto.max)), ("mode", .text("full")),
            ("box", .map([("id", .text("box")), ("build", .text("t")), ("tz", .text("Europe/Stockholm"))])),
            ("clock", .map([("source", .text("ntp")), ("syncedAtMs", .int(0)), ("uptimeMs", .int(uptimeMs))])),
            ("caps", .array(caps.map { .text($0) })), ("role", .text(role)), ("modes", .array([])),
            ("subscribed", .bool(true)),
        ]
        if let cloud {
            body.append(("cloud", .map([
                ("pk", .bytes(cloud.pk)), ("home", .text(cloud.home)), ("boot", .bytes(cloud.boot)),
                ("sources", .map(cloud.sources.sorted { $0.key < $1.key }.map { (k, v) -> (String, CBOR) in (k, .text(v)) })),
                ("loadpoints", .map([(String, CBOR)]())),
            ])))
        }
        say("hello_ok", .map(body))
    }

    func snap(uptimeMs: Int64, gridW: Int) {
        say("snap", .map([
            ("uptimeMs", .int(uptimeMs)), ("controlRev", .int(1)),
            ("dict", .map(["2": .map([("name", .text("grid")), ("unit", .text("W")), ("srcId", .text("p1meter"))])])),
            ("fields", .map(["2": .int(gridW)])),
            ("sources", .map(["p1meter": .map([("kind", .text("driver")), ("name", .text("P1 meter")), ("lastOkMs", .int(uptimeMs - 200)),
                                               ("staleAfterMs", .int(10_000)), ("state", .text("live"))])])),
            ("dispatchBlockedBy", .array([])),
        ]))
    }
}

/// A home with FTW Cloud on: a box that signs, the service, and a site model
/// that reads them.
@MainActor
final class CloudSite {
    let scheduler = ManualScheduler()
    let store = MemoryStore()
    let files: SealedFiles
    let shared = AppGroupFiles(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ftw-shared-\(UUID().uuidString)"))
    let service: FakeCloudService
    let device = Primitives.generateKeyPair()
    var box: FakeCloudBox
    let identity: CloudIdentity
    var site: SiteModel!
    let relay = ScriptedBox()

    init(noClock: Bool = false) throws {
        files = SealedFiles(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ftw-test-\(UUID().uuidString)"), store: store)
        service = FakeCloudService(scheduler: scheduler)
        box = try FakeCloudBox(boot: 1)
        box.start = Int64(scheduler.nowMs) - 60_000
        box.noClock = noClock
        identity = CloudIdentity(pk: box.pk, boot: box.boot, sources: ["m": "p1meter"])
        service.roster = [device.publicKey]
    }

    var at: Int64 { Int64(scheduler.nowMs) }
    var uptime: Int64 { at - box.start }

    /// What an earlier launch left: the box's word on FTW Cloud, and a home
    /// on screen a minute ago.
    func keepFromEarlierLaunch(gridW: Int? = 111) {
        files.writeJSON("cloud-s1", CloudCache(identity: identity, offset: nil))
        guard let gridW else { return }
        var s = SessionState()
        s.fields = [Contract.FID.gridW: Double(gridW)]
        s.uptimeMs = 50_000
        s.sources = ["p1meter": Source(kind: "driver", name: "P1 meter", lastOkMs: 49_800, staleAfterMs: 10_000, state: .live)]
        s.dict = [Contract.FID.gridW: FieldDef(name: "grid", unit: "W", srcId: "p1meter")]
        files.writeJSON("snapshot-s1", CachedSnapshot(siteId: "s1", savedAtMs: scheduler.nowMs - 60_000, state: s))
    }

    func open() {
        site = SiteModel(siteId: "s1", build: "test", ua: "test", scheduler: scheduler, files: files, shared: shared)
        site.start()
    }

    func connectCloud() {
        site.connectCloud(deviceKey: device, makeSocket: service.factory, endpoint: service.endpoint)
    }

    func live(gridW: Int, age: Int64 = 400) throws -> CloudWire.Envelope {
        let h = box.header(at)
        let m = CBOR.map([("kind", .text("driver")), ("state", .text("live")), ("lastOkMs", .int(uptime - age)), ("staleAfterMs", .int(10_000))])
        return try box.seal(CloudWire.msgLive, h + [
            ("fields", .map(["2": .int(Int64(gridW))])), ("fieldSources", .map(["2": .array([.text("m")])])),
            ("sources", .map(["m": m])), ("srcRev", .unsigned(1)), ("ages", .map(["m": .int(age)])), ("dispatchBlockedBy", .array([])),
        ])
    }

    func run(_ ms: Double) async {
        var left = ms
        while left > 0 {
            for _ in 0..<5 { await Task.yield() }
            scheduler.advance(min(10, left))
            left -= 10
        }
        for _ in 0..<20 { await Task.yield() }
    }
}

@MainActor
@Suite struct SiteModelCloudTests {
    /// The three layers: the phone's cache at once, the cloud's copy one
    /// round trip later, then each change on the same socket.
    @Test func cacheThenTheCloudsCopyThenEachChange() async throws {
        let w = try CloudSite()
        w.keepFromEarlierLaunch(gridW: 111)
        w.service.held = [try w.live(gridW: 1000)]
        w.open()
        #expect(w.site.carrier == .cache)
        #expect(w.site.session.fields[Contract.FID.gridW] == 111)

        w.connectCloud()
        await w.run(60)
        #expect(w.site.carrier == .cloud)
        #expect(w.site.session.fields[Contract.FID.gridW] == 1000)
        #expect(w.site.isLive)
        #expect(w.site.srcState == .live)
        #expect(w.site.freshness(noCarrier: false).message == "Live via FTW Cloud")
        // Names come from the box's table, never from the service.
        #expect(w.site.session.dict[Contract.FID.gridW]?.srcId == "p1meter")
        #expect(w.site.session.sources["p1meter"]?.state == .live)

        let firstFrame = w.site.lastFrameAtMs
        w.service.push(try w.live(gridW: 1200))
        await w.run(50)
        #expect(w.site.session.fields[Contract.FID.gridW] == 1200)
        #expect(w.site.lastFrameAtMs != firstFrame)
    }

    /// The doc's replay case on the phone: a snapshot the service held back
    /// an hour arrives, signed and intact, and shows its age, never live.
    @Test func aReplayedSnapshotIsNotLive() async throws {
        let w = try CloudSite()
        w.keepFromEarlierLaunch(gridW: nil)
        // The box signed it an hour before the phone opens.
        let old = try w.live(gridW: 900)
        w.scheduler.advance(3_600_000)
        w.service.held = [old]
        w.open()
        w.connectCloud()
        await w.run(60)
        #expect(w.site.carrier == .cloud)
        #expect(w.site.session.fields[Contract.FID.gridW] == 900)
        #expect(w.site.srcState == .down)
        #expect(!w.site.isLive)
        #expect((w.site.ageMs ?? 0) > 3_500_000)
    }

    /// No wall clock on the box and no rule U yet: shown, unverified, never
    /// live.
    @Test func noAnchorIsNeverLive() async throws {
        let w = try CloudSite(noClock: true)
        w.keepFromEarlierLaunch(gridW: nil)
        w.service.held = [try w.live(gridW: 1000)]
        w.open()
        w.connectCloud()
        await w.run(60)
        #expect(w.site.carrier == .cloud)
        #expect(w.site.srcState == .stale)
        #expect(w.site.ageMs == nil)
        #expect(w.site.freshness(noCarrier: false).message == "FTW Cloud · age unverified")
    }

    /// Rule U from the box session gives the same box a trusted clock.
    @Test func theBoxSessionAnchorsABoxWithoutAClock() async throws {
        let w = try CloudSite(noClock: true)
        w.open()
        w.connectCloud()
        w.site.connect(w.relay)
        w.relay.open(w.scheduler.nowMs)
        w.relay.helloOk(uptimeMs: w.uptime, cloud: w.identity)
        w.service.held = [try w.live(gridW: 1000)]
        await w.run(60)
        #expect(w.site.carrier == .cloud)
        #expect(w.site.srcState == .live)
        #expect(w.site.ageMs != nil)
    }

    /// The cloud fails or is out of reach: the box session's readings take
    /// over under its own name, and the cloud takes back over when it heals.
    @Test func theRelayTakesOverWhileTheCloudIsDown() async throws {
        let w = try CloudSite()
        w.open()
        w.connectCloud()
        w.site.connect(w.relay)
        w.relay.open(w.scheduler.nowMs)
        w.relay.helloOk(uptimeMs: w.uptime, cloud: w.identity)
        w.relay.snap(uptimeMs: w.uptime, gridW: 700)
        w.service.held = [try w.live(gridW: 1000)]
        await w.run(60)
        #expect(w.site.carrier == .cloud)
        #expect(w.site.session.fields[Contract.FID.gridW] == 1000)

        w.service.close(code: 1006)
        await w.run(20)
        #expect(w.site.carrier == .relay)
        #expect(w.site.session.fields[Contract.FID.gridW] == 700)
        #expect(w.site.freshness(noCarrier: false).message == "Live via encrypted relay")

        await w.run(600)
        #expect(w.site.carrier == .cloud)
    }

    /// A box session that streams live wins over a cloud copy that is not
    /// live: never show older data than the phone has.
    @Test func aLiveBoxSessionBeatsAStaleCloud() async throws {
        let w = try CloudSite()
        w.open()
        w.connectCloud()
        w.site.connect(w.relay)
        w.relay.open(w.scheduler.nowMs)
        w.relay.helloOk(uptimeMs: w.uptime, cloud: w.identity)
        let old = try w.live(gridW: 900, age: 120_000)
        w.service.held = [old]
        w.relay.snap(uptimeMs: w.uptime, gridW: 700)
        await w.run(60)
        #expect(w.site.carrier == .relay)
        #expect(w.site.session.fields[Contract.FID.gridW] == 700)
    }

    /// The box said FTW Cloud is off: the session closes and nothing of it
    /// is kept.
    @Test func aGrantTurnedOffForgetsTheCloud() async throws {
        let w = try CloudSite()
        w.keepFromEarlierLaunch(gridW: nil)
        w.service.held = [try w.live(gridW: 1000)]
        w.open()
        w.connectCloud()
        await w.run(60)
        #expect(w.site.cloudOn)
        w.site.connect(w.relay)
        w.relay.open(w.scheduler.nowMs)
        w.relay.helloOk(uptimeMs: w.uptime, cloud: nil)
        await w.run(30)
        #expect(!w.site.cloudOn)
        #expect(w.site.carrier != .cloud)
        #expect(w.service.current == nil)
        #expect(w.files.readJSON(CloudCache.self, "cloud-s1") == nil)
    }

    /// A first launch learns FTW Cloud from hello and keeps it for the next.
    @Test func helloStartsTheCloudAndIsKept() async throws {
        let w = try CloudSite()
        w.service.held = [try w.live(gridW: 1000)]
        w.open()
        w.connectCloud()
        await w.run(60)
        #expect(w.service.dialled.isEmpty)
        w.site.connect(w.relay)
        w.relay.open(w.scheduler.nowMs)
        w.relay.helloOk(uptimeMs: w.uptime, cloud: w.identity)
        await w.run(60)
        #expect(w.service.dialled.count == 1)
        #expect(w.site.carrier == .cloud)
        #expect(w.files.readJSON(CloudCache.self, "cloud-s1")?.identity == w.identity)
    }

    /// An envelope that does not verify never reaches a screen.
    @Test func anEnvelopeTheBoxDidNotSignIsDropped() async throws {
        let w = try CloudSite()
        w.keepFromEarlierLaunch(gridW: nil)
        w.service.held = [try w.live(gridW: 1000)]
        w.open()
        w.connectCloud()
        await w.run(60)
        var forged = try w.live(gridW: 5)
        forged.b[forged.b.count - 3] ^= 1
        w.service.push(forged)
        await w.run(50)
        #expect(w.site.session.fields[Contract.FID.gridW] == 1000)
    }

    /// Prices and cars from the cloud go to the widgets, labelled as read
    /// through FTW Cloud.
    @Test func theWidgetsGetTheCloudsPricesAndCars() async throws {
        let w = try CloudSite()
        w.keepFromEarlierLaunch(gridW: nil)
        let t0 = w.at - w.at % 86_400_000
        let prices = try w.box.seal(CloudWire.msgPrices, w.box.header(w.at) + [
            ("zone", .text("SE3")), ("currency", .text("SEK")), ("t0Ms", .int(t0)), ("slotMs", .int(900_000)),
            ("spotMinor", .array([.int(42), .null, .int(40)])), ("totalMinor", .array([.int(118), .null, .int(115)])),
        ])
        let lp = try w.box.seal(CloudWire.msgLP, w.box.header(w.at) + [
            ("controlRev", .int(3)),
            ("loadpoints", .array([.map([("id", .text("j3HZ")), ("src", .text("m")), ("plugged", .bool(true)),
                                        ("socPermille", .int(430)), ("socSource", .text("vehicle")), ("socAgeS", .int(60)),
                                        ("targetPermille", .int(800)), ("powerW", .int(2100))])])),
            ("feedback", .array([])),
        ])
        w.service.held = [try w.live(gridW: 1000), prices, lp]
        w.open()
        w.connectCloud()
        await w.run(60)
        for _ in 0..<200 where w.shared.read(CarEntry.self, siteId: "s1") == nil {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let p = try #require(w.shared.read(PriceEntry.self, siteId: "s1"))
        #expect(p.carrier == .cloud)
        #expect(p.value.prices.slots.count == 2)
        #expect(p.value.prices.slots.first?.totalMinor == 118)
        let car = try #require(w.shared.read(CarEntry.self, siteId: "s1"))
        #expect(car.carrier == .cloud)
        #expect(car.value.cars.first?.socPct == 43)
        #expect(car.value.cars.first?.pluggedIn == true)
    }

    /// The background closes the session, as it closes the relay's.
    @Test func theBackgroundClosesTheCloud() async throws {
        let w = try CloudSite()
        w.keepFromEarlierLaunch(gridW: nil)
        w.service.held = [try w.live(gridW: 1000)]
        w.open()
        w.connectCloud()
        await w.run(60)
        w.site.suspend()
        #expect(w.service.current == nil)
        #expect(w.site.carrier != .cloud)
        #expect(w.site.cloudStatus == nil)
        // The readings stay, with their age.
        #expect(w.site.session.fields[Contract.FID.gridW] == 1000)
    }
}
