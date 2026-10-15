import Foundation
import Testing
@testable import FTWKit
import FTWDemo
import FTWShared

/// A box behind the fake FTW Cloud: the responder half of each phone's own
/// session, one per `sid`, admitting a paired key or a live pairing code and
/// answering a key it does not know with silence, as Core does. It echoes
/// each frame, or hands it to a simulated box when it has one.
@MainActor
final class FakeTunnelBox {
    let staticKey = Primitives.generateKeyPair()
    var paired: Set<Bytes> = []
    /// The QR code on the box's screen. Spent once.
    var code: Bytes?
    let simulated: SimulatedBox?
    private(set) var opened: [UInt32] = []
    private(set) var ended: [UInt32] = []
    private(set) var frames: [Bytes] = []
    private var sessions: [UInt32: (key: Bytes, transport: NoiseTransport, reply: (CloudWire.Tun) -> Void)] = [:]
    private var newest: UInt32?

    init(simulated: SimulatedBox? = nil) {
        self.simulated = simulated
        simulated?.send = { [weak self] frame in
            guard let self, let sid = self.newest, let s = self.sessions[sid], let wire = try? s.transport.encrypt(frame) else { return }
            s.reply(CloudWire.Tun(sid: sid, d: wire))
        }
    }

    var prologue: Bytes { NoiseCarrier.prologue(boxStaticKey: staticKey.publicKey) }

    func receive(_ tun: CloudWire.Tun, from device: Bytes, reply: @escaping (CloudWire.Tun) -> Void) {
        if tun.ended {
            sessions[tun.sid] = nil
            ended.append(tun.sid)
            return
        }
        if let s = sessions[tun.sid] {
            guard let frame = try? s.transport.decrypt(tun.d) else { return }
            frames.append(frame)
            if let simulated {
                simulated.receive(frame)
            } else if let echo = try? s.transport.encrypt(frame) {
                reply(CloudWire.Tun(sid: tun.sid, d: echo))
            }
            return
        }
        let hs = HandshakeState.responder(staticKey: staticKey, prologue: prologue)
        guard let payload = try? hs.readMessage(tun.d), let message2 = try? hs.writeMessage(), let keys = try? hs.split() else {
            // Not message 1 of a session this box holds: start again.
            reply(CloudWire.Tun(sid: tun.sid, d: []))
            return
        }
        // The service names the device; the handshake proves it.
        guard keys.remoteStatic == device else { return }
        if !paired.contains(keys.remoteStatic) {
            guard let code, payload == code else { return }
            self.code = nil
            paired.insert(keys.remoteStatic)
        }
        // One session per device: a new one ends the older.
        for (sid, s) in sessions where s.key == keys.remoteStatic { sessions[sid] = nil }
        sessions[tun.sid] = (keys.remoteStatic, NoiseTransport(keys), reply)
        newest = tun.sid
        opened.append(tun.sid)
        reply(CloudWire.Tun(sid: tun.sid, d: message2))
    }

    /// The box drops a session and says so.
    func end(_ sid: UInt32) {
        guard let s = sessions.removeValue(forKey: sid) else { return }
        s.reply(CloudWire.Tun(sid: sid, d: []))
    }

    /// A frame on a session, as the box sends one.
    func say(_ frame: Bytes, on sid: UInt32) {
        guard let s = sessions[sid], let wire = try? s.transport.encrypt(frame) else { return }
        s.reply(CloudWire.Tun(sid: sid, d: wire))
    }
}

/// The relay the fallback builds, standing still: it opens when told to.
@MainActor
final class StandInRelay: Carrier {
    let kind: CarrierKind = .relay
    private(set) var status: CarrierStatus = .connecting
    private(set) var sent: [Bytes] = []
    private(set) var closedWith: String?
    private var onStatus: @MainActor (CarrierStatus) -> Void = { _ in }

    func send(_ frame: Bytes) -> Bool {
        guard status.isOpen else { return false }
        sent.append(frame)
        return true
    }

    func setHandlers(onFrame: @escaping @MainActor (Bytes) -> Void, onStatus: @escaping @MainActor (CarrierStatus) -> Void) {
        self.onStatus = onStatus
    }

    func wake() {}

    func close(reason: String) {
        closedWith = reason
        status = .closed(reason: reason, retryable: false)
    }

    func open() {
        status = .open(sinceMs: 0)
        onStatus(status)
    }
}

/// A phone's FTW Cloud session with its box session riding it.
@MainActor
final class TunnelRig {
    let scheduler = ManualScheduler()
    let service: FakeCloudService
    let box = FakeTunnelBox()
    let device = Primitives.generateKeyPair()
    static let home = "abcdefghijklmnopqrstuvwx23"
    var home: String { Self.home }
    let cloud: CloudCarrier
    var relays: [StandInRelay] = []
    var frames: [Bytes] = []
    var statuses: [CarrierStatus] = []

    init(paired: Bool = true, pair: Bytes? = nil) {
        service = FakeCloudService(scheduler: scheduler)
        service.tunBox = box
        if paired {
            service.roster = [device.publicKey]
            box.paired = [device.publicKey]
        }
        cloud = CloudCarrier(endpoint: service.endpoint, home: Self.home, deviceKey: device, looking: true, pair: pair, scheduler: scheduler, makeSocket: service.factory)
        cloud.setHandlers(onSnapshot: { _, _ in }, onEnvelope: { _, _ in }, onStatus: { _ in })
    }

    /// The box session as the app builds it: Noise to the box, over the
    /// tunnel, with or without the relay behind it.
    func session(fallback: Bool = false, code: Bytes = []) -> NoiseCarrier {
        let tunnel = TunnelCarrier(cloud: cloud, scheduler: scheduler)
        let inner: Carrier = fallback
            ? FallbackCarrier(tunnel: tunnel, relay: { [unowned self] in
                let r = StandInRelay()
                self.relays.append(r)
                return r
            }, scheduler: scheduler)
            : tunnel
        let noise = NoiseCarrier(inner: inner, staticKey: device, remoteStatic: box.staticKey.publicKey,
                                 prologue: box.prologue, handshakePayload: code, scheduler: scheduler)
        noise.setHandlers(
            onFrame: { [unowned self] f in self.frames.append(f) },
            onStatus: { [unowned self] s in self.statuses.append(s) }
        )
        return noise
    }

    /// Box sessions that opened, by their message 1 through the service.
    var message1Sids: [UInt32] { box.opened }

    func run(_ ms: Double, step: Double = 5) async {
        var left = ms
        while left > 0 {
            for _ in 0..<5 { await Task.yield() }
            scheduler.advance(min(step, left))
            left -= step
        }
        for _ in 0..<5 { await Task.yield() }
    }
}

@MainActor
@Suite struct TunnelCarrierTests {
    /// The box session's message 1 rides the app session's, so the box's
    /// answer follows message 2 by one leg: up one round trip after TLS.
    @Test func theBoxSessionRidesMessage1AndIsUpOneRoundTripAfterTLS() async throws {
        let rig = TunnelRig()
        rig.cloud.start()
        let noise = rig.session()
        // Socket open at 10 ms, message 1 at the service at 20, message 2
        // and the box's answer back at 30.
        await rig.run(30)
        #expect(noise.status.isOpen)
        #expect(noise.kind == .tunnel)
        #expect(rig.service.nowBodies.count == 1)
        #expect(rig.service.nowBodies.first?["tun"] != nil)
        #expect(rig.service.nowBodies.first?["pair"] == nil)
        #expect(rig.message1Sids.count == 1)

        // Frames go both ways, sealed for the box alone.
        let frame = Bytes(repeating: 0x42, count: Frame.controlBuckets[0])
        #expect(noise.send(frame))
        await rig.run(30)
        #expect(rig.box.frames == [frame])
        #expect(rig.frames == [frame])
        #expect(!rig.service.tunsFromPhone.contains { holds($0.d, Bytes(frame.prefix(32))) })
    }

    /// A session already dialling has sent its message 1: the box session's
    /// waits for message 2 and goes then.
    @Test func message1WaitsForMessage2WhenTheAppSessionIsAlreadyDialling() async throws {
        let rig = TunnelRig()
        rig.cloud.start()
        await rig.run(15)
        let noise = rig.session()
        await rig.run(15)
        #expect(!noise.status.isOpen)
        await rig.run(25)
        #expect(noise.status.isOpen)
        #expect(rig.service.nowBodies.first?["tun"] == nil)
        #expect(rig.service.tunsFromPhone.count == 1)
    }

    /// Every handshake draws a new sid, so the late end of an older session
    /// can never end the new one, and the box never mistakes a second
    /// message 1 for a frame of the first.
    @Test func eachHandshakeDrawsANewSid() async throws {
        let rig = TunnelRig()
        rig.box.paired = []
        rig.cloud.start()
        let noise = rig.session()
        await rig.run(100)
        // The box answers a key it does not know with silence.
        #expect(!noise.status.isOpen)
        #expect(rig.service.tunsFromPhone.count == 1)
        rig.box.paired = [rig.device.publicKey]
        // The handshake's own deadline, then a retry with backoff.
        await rig.run(NoiseCarrier.handshakeDeadlineMs + NoiseCarrier.handshakeBackoffBaseMs, step: 50)
        #expect(noise.status.isOpen)
        let sids = rig.service.tunsFromPhone.map(\.sid)
        #expect(sids.count == 2)
        #expect(Set(sids).count == 2)
        #expect(rig.message1Sids == [sids[1]])
    }

    /// The box dropped the session: a new one starts after a short backoff,
    /// under a new sid, on the same app session.
    @Test func anEndFromTheBoxStartsANewSession() async throws {
        let rig = TunnelRig()
        rig.cloud.start()
        let noise = rig.session()
        await rig.run(40)
        let first = try #require(rig.message1Sids.first)
        rig.box.end(first)
        await rig.run(12)
        #expect(!noise.status.isOpen)
        await rig.run(TunnelCarrier.backoffBaseMs + 50)
        #expect(noise.status.isOpen)
        #expect(rig.message1Sids.count == 2)
        #expect(rig.message1Sids[1] != first)
        #expect(rig.service.dialled.count == 1)
    }

    /// A frame or an end that arrives for a session this phone has left is
    /// dropped: the sid names the session it belongs to.
    @Test func aLateFrameOfAnOlderSessionIsDropped() async throws {
        let rig = TunnelRig()
        rig.service.silentTun = true
        rig.cloud.start()
        let tunnel = TunnelCarrier(cloud: rig.cloud, scheduler: rig.scheduler)
        var frames: [Bytes] = []
        tunnel.setHandlers(onFrame: { frames.append($0) }, onStatus: { _ in })
        tunnel.beginSession()
        let old = tunnel.sid
        #expect(tunnel.send([0xaa]))
        await rig.run(40)
        tunnel.beginSession()
        let socket = try #require(rig.service.current)
        socket.tun(CloudWire.Tun(sid: old, d: [1]))
        socket.tun(CloudWire.Tun(sid: old, d: []))
        socket.tun(CloudWire.Tun(sid: tunnel.sid, d: [2]))
        await rig.run(30)
        #expect(frames == [[2]])
        #expect(tunnel.status.isOpen)
    }

    /// A wake after sleep dials the app session afresh, as the relay
    /// does: a socket that looks open may be dead.
    @Test func aWakeDialsAfresh() async throws {
        let rig = TunnelRig()
        rig.cloud.start()
        let noise = rig.session()
        await rig.run(40)
        noise.wake()
        await rig.run(40)
        #expect(rig.service.dialled.count == 2)
        #expect(noise.status.isOpen)
        // Its message 1 rode the new app session's.
        #expect(rig.service.nowBodies.count == 2)
        #expect(rig.service.nowBodies.last?["tun"] != nil)
    }

    /// Closing the box session ends it at the box and leaves the app
    /// session up for the readable copy.
    @Test func closingEndsTheBoxSessionAndLeavesTheAppSession() async throws {
        let rig = TunnelRig()
        rig.cloud.start()
        let noise = rig.session()
        await rig.run(40)
        let sid = try #require(rig.message1Sids.first)
        noise.close(reason: "test")
        await rig.run(30)
        #expect(rig.box.ended == [sid])
        #expect(rig.cloud.status.isOpen)
    }

    /// The app session closing for good closes the tunnel for good.
    @Test func aClosedAppSessionClosesTheTunnel() async throws {
        let rig = TunnelRig()
        rig.cloud.start()
        let tunnel = TunnelCarrier(cloud: rig.cloud, scheduler: rig.scheduler)
        await rig.run(40)
        #expect(tunnel.status.isOpen)
        rig.cloud.close()
        #expect(tunnel.status == .closed(reason: "FTW Cloud session closed", retryable: false))
        #expect(!tunnel.send([1]))
    }

    /// A new phone is in no roster. It proves the code it scanned by its
    /// hash, the service admits it once, and the box pairs it inside the
    /// session as over the relay: the code itself never leaves the Noise
    /// session to the box.
    @Test func aNewPhonePairsThroughTheService() async throws {
        let code = randomBytes(16)
        let hash = CloudWire.pairingHash(home: TunnelRig.home, code: code)
        let rig = TunnelRig(paired: false, pair: hash)
        rig.service.pending = [hash]
        rig.box.code = code
        rig.cloud.start()
        let noise = rig.session(code: code)
        await rig.run(40)
        #expect(noise.status.isOpen)
        #expect(rig.service.nowBodies.first?["pair"]?.byteString == hash)
        #expect(rig.service.pending.isEmpty)
        #expect(rig.box.paired == [rig.device.publicKey])
        #expect(!rig.service.tunsFromPhone.contains { holds($0.d, code) })
    }
}

/// Whether `needle` appears in `hay`, byte for byte.
private func holds(_ hay: Bytes, _ needle: Bytes) -> Bool {
    guard !needle.isEmpty, hay.count >= needle.count else { return false }
    return (0...(hay.count - needle.count)).contains { Array(hay[$0..<($0 + needle.count)]) == needle }
}

@MainActor
@Suite struct FallbackCarrierTests {
    /// While the tunnel carries, the relay is never dialled: a socket held
    /// in reserve would take one of the relay's streams for the home.
    @Test func theRelayStaysUndialledWhileTheTunnelCarries() async throws {
        let rig = TunnelRig()
        rig.cloud.start()
        let noise = rig.session(fallback: true)
        await rig.run(40)
        #expect(noise.status.isOpen)
        #expect(noise.kind == .tunnel)
        for _ in 0..<5 {
            #expect(noise.send([7]))
            await rig.run(2_000, step: 50)
        }
        #expect(rig.relays.isEmpty)
        #expect(rig.frames.count == 5)
    }

    /// No session for this phone at FTW Cloud: the relay at once.
    @Test func aRefusedAppSessionMovesToTheRelay() async throws {
        let rig = TunnelRig()
        rig.service.roster = []
        rig.cloud.start()
        let noise = rig.session(fallback: true)
        await rig.run(40)
        #expect(rig.relays.count == 1)
        #expect(noise.kind == .relay)
        rig.relays[0].open()
        await rig.run(5)
        // The handshake goes again, over the relay.
        #expect(rig.relays[0].sent.count == 1)
    }

    /// FTW Cloud unreachable: the relay at once.
    @Test func anUnreachableServiceMovesToTheRelay() async throws {
        let rig = TunnelRig()
        rig.cloud.start()
        let noise = rig.session(fallback: true)
        rig.service.close(code: 1006)
        await rig.run(5)
        #expect(rig.relays.count == 1)
        #expect(noise.kind == .relay)
    }

    /// The service has no box to give the session to, as with a box that is
    /// offline or does not take `tun`: the relay at once.
    @Test func aSessionEndedBeforeAnyAnswerMovesToTheRelay() async throws {
        let rig = TunnelRig()
        rig.service.tunBox = nil
        rig.cloud.start()
        let noise = rig.session(fallback: true)
        await rig.run(40)
        #expect(rig.relays.count == 1)
        #expect(noise.kind == .relay)
    }

    /// An older box lists the phone without `tun`, and the service passes
    /// nothing on and says nothing. The tunnel's wait ends it.
    @Test func silenceMovesToTheRelayAfterTheWait() async throws {
        let rig = TunnelRig()
        rig.service.silentTun = true
        rig.cloud.start()
        let noise = rig.session(fallback: true)
        await rig.run(FallbackCarrier.tunnelWaitMs - 100, step: 50)
        #expect(rig.relays.isEmpty)
        await rig.run(200, step: 50)
        #expect(rig.relays.count == 1)
        #expect(noise.kind == .relay)
    }

    /// A tunnel that carried and drops for a moment, as when FTW Cloud
    /// restarts, comes back on its own.
    @Test func aCarryingTunnelThatDropsBrieflyStays() async throws {
        let rig = TunnelRig()
        rig.cloud.start()
        let noise = rig.session(fallback: true)
        await rig.run(40)
        #expect(noise.send([1]))
        await rig.run(30)
        rig.service.close(code: 1006)
        await rig.run(1_000, step: 10)
        #expect(noise.status.isOpen)
        #expect(noise.kind == .tunnel)
        #expect(rig.relays.isEmpty)
        #expect(rig.service.dialled.count == 2)
    }

    /// A tunnel that carried and does not come back within the wait moves
    /// to the relay.
    @Test func aCarryingTunnelThatStaysDownMovesToTheRelay() async throws {
        let rig = TunnelRig()
        rig.cloud.start()
        let noise = rig.session(fallback: true)
        await rig.run(40)
        #expect(noise.send([1]))
        await rig.run(30)
        rig.service.silentTun = true
        rig.service.close(code: 1006)
        await rig.run(FallbackCarrier.tunnelWaitMs + 200, step: 50)
        #expect(rig.relays.count == 1)
        #expect(noise.kind == .relay)
    }

    /// Without a relay to fall back on, the tunnel manages alone.
    @Test func withoutARelayTheTunnelKeepsTrying() async throws {
        let rig = TunnelRig()
        rig.service.tunBox = nil
        rig.cloud.start()
        let tunnel = TunnelCarrier(cloud: rig.cloud, scheduler: rig.scheduler)
        let fallback = FallbackCarrier(tunnel: tunnel, relay: nil, scheduler: rig.scheduler)
        let noise = NoiseCarrier(inner: fallback, staticKey: rig.device, remoteStatic: rig.box.staticKey.publicKey,
                                 prologue: rig.box.prologue, scheduler: rig.scheduler)
        await rig.run(FallbackCarrier.tunnelWaitMs + 2_000, step: 50)
        #expect(!fallback.onRelay)
        #expect(fallback.kind == .tunnel)
        #expect(rig.service.tunsFromPhone.count >= 2)
        rig.service.tunBox = rig.box
        await rig.run(NoiseCarrier.handshakeDeadlineMs + 4_000, step: 50)
        #expect(noise.status.isOpen)
    }
}

/// The whole app against a simulated box behind FTW Cloud: pairing from a
/// v3 code, the stream and the carrier the band names, with the relay
/// unreachable or with FTW Cloud unreachable.
@MainActor
@Suite struct OneDoorShellTests {
    @MainActor
    final class World {
        let scheduler = ManualScheduler()
        let store = MemoryStore()
        let files: SealedFiles
        let passkeys = FakePasskeys()
        let simulated: SimulatedBox
        let service: FakeCloudService
        /// The box behind FTW Cloud, when the tunnel world has one.
        let tunnelBox: FakeTunnelBox?
        /// The box behind the relay, when the relay world has one.
        let relay: FakeRelay?
        let boxKey: Bytes
        private(set) var relayDials: [URL] = []
        let code = randomBytes(16)
        static let home = "fjzyr67buzpyncqmjliwgezvde"

        /// `throughCloud`: the box sits behind FTW Cloud and the relay is
        /// unreachable. Otherwise the box sits behind the relay and FTW
        /// Cloud refuses every session.
        init(throughCloud: Bool) {
            files = SealedFiles(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ftw-test-\(UUID().uuidString)"), store: store)
            simulated = SimulatedBox(scheduler: scheduler)
            service = FakeCloudService(scheduler: scheduler)
            if throughCloud {
                let box = FakeTunnelBox(simulated: simulated)
                box.code = code
                tunnelBox = box
                relay = nil
                boxKey = box.staticKey.publicKey
                service.tunBox = box
                service.pending = [CloudWire.pairingHash(home: Self.home, code: code)]
            } else {
                let endpoint = NoiseBoxEndpoint(box: simulated)
                relay = FakeRelay(scheduler: scheduler, endpoint: endpoint)
                tunnelBox = nil
                boxKey = endpoint.staticKey.publicKey
            }
        }

        var cloudEndpoint: CloudEndpoint {
            CloudEndpoint(url: URL(string: "wss://cloud.test/v1/app")!, serviceKeys: [service.staticKey.publicKey])
        }

        var sockets: WebSocketFactory {
            { [unowned self] url, events in
                if url.host == "cloud.test" { return self.service.factory(url, events) }
                self.relayDials.append(url)
                if let relay = self.relay { return relay.factory(url, events) }
                // Nothing answers at the relay's address.
                let socket = DeadSocket()
                _ = self.scheduler.after(10) { events.onClose(1006, "") }
                return socket
            }
        }

        func app() -> AppModel {
            AppModel(store: store, files: files, passkeys: passkeys, scheduler: scheduler, build: "test", ua: "test",
                     relayURL: URL(string: "wss://relay.test")!, cloudEndpoint: cloudEndpoint, makeSocket: sockets)
        }

        func qr(home: String?) -> String {
            Enrollment(boxStaticPublic: boxKey, pairingCode: code, lanHint: "", rendezvousSecret: randomBytes(32), home: home).url()
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

    @MainActor
    final class DeadSocket: WebSocketConnection {
        func send(_ data: Bytes) {}
        func close() {}
    }

    /// A v3 code names the home, so the first session already goes through
    /// FTW Cloud: the service admits the new phone by its proof, the box
    /// pairs it inside the session, and the band says the tunnel carries.
    @Test func aV3CodePairsAndStreamsThroughFTWCloudWithTheRelayUnreachable() async throws {
        let world = World(throughCloud: true)
        world.simulated.moreCaps = [Contract.capCloudTun]
        let app = world.app()
        let pair = PairModel(app: app)
        let task = Task { await pair.pair(world.qr(home: World.home)) }
        await world.run(500)
        await task.value
        let site = try #require(app.site)
        #expect(site.session.phase == .streaming)
        #expect(site.carrier == .tunnel)
        #expect(site.freshness(noCarrier: false).message == "Live, encrypted via FTW Cloud")
        #expect(world.relayDials.isEmpty)
        #expect(world.service.pending.isEmpty)
        #expect(world.tunnelBox?.paired.count == 1)
        #expect(app.sites.get(try #require(site.siteId))?.cloudHome == World.home)

        // Back from the background: the box said it takes the tunnel, so
        // the tunnel again, without the proof. The box's next roster lists
        // the phone.
        world.service.roster = try #require(world.tunnelBox?.paired)
        app.suspend()
        await world.run(100)
        app.setVisible(true)
        await world.run(500)
        #expect(site.session.phase == .streaming)
        #expect(site.carrier == .tunnel)
        #expect(world.relayDials.isEmpty)
        #expect(world.service.nowBodies.count == 2)
        #expect(world.service.nowBodies.last?["pair"] == nil)
    }

    /// A box whose hello does not say `cloud.tun` is reached through the
    /// relay, though the phone knows the home: no wait on a tunnel it
    /// cannot have.
    @Test func aBoxWithoutTunIsReachedThroughTheRelay() async throws {
        let world = World(throughCloud: false)
        let app = world.app()
        let pair = PairModel(app: app)
        let task = Task { await pair.pair(world.qr(home: nil)) }
        await world.run(500)
        await task.value
        let site = try #require(app.site)
        #expect(site.session.phase == .streaming)
        #expect(site.carrier == .relay)
        // No home id from a v2 code and none from this box: no FTW Cloud.
        #expect(world.service.dialled.isEmpty)

        app.sites.update(try #require(site.siteId)) { $0.cloudHome = World.home }
        app.suspend()
        app.setVisible(true)
        await world.run(500)
        #expect(site.session.phase == .streaming)
        #expect(site.carrier == .relay)
        #expect(world.service.tunsFromPhone.isEmpty)
    }

    /// FTW Cloud refuses the session: the relay carries, at once.
    @Test func aRefusingCloudFallsBackToTheRelay() async throws {
        let world = World(throughCloud: false)
        let app = world.app()
        let pair = PairModel(app: app)
        let task = Task { await pair.pair(world.qr(home: World.home)) }
        await world.run(500)
        await task.value
        let site = try #require(app.site)
        #expect(world.service.dialled.count >= 1)
        #expect(site.session.phase == .streaming)
        #expect(site.carrier == .relay)
        #expect(world.relayDials.count == 1)
    }
}
