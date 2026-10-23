import Foundation
import Testing
@testable import FTWKit

/// FTW Cloud's app endpoint, as `ftwcloudd` answers it, behind fake sockets:
/// Noise IK as responder, a phone admitted only by a key in its roster, the
/// snapshot in message 2, then pushes.
@MainActor
final class FakeCloudService {
    let scheduler: ManualScheduler
    let staticKey = Primitives.generateKeyPair()
    var roster: Set<Bytes> = []
    var held: [CloudWire.Envelope] = []
    /// The box's tiles the service holds, as it answers `tiles.get`.
    var tiles: [CloudWire.Envelope] = []
    var online = true
    var latencyMs: Double = 10
    /// Refuse every handshake made with this key, as a service that has
    /// moved to another key would.
    var refuseKey: Bytes?
    /// The box behind the service, for the tunnel. Nil: no box takes `tun`,
    /// and the service ends each box session a phone starts.
    var tunBox: FakeTunnelBox?
    /// The roster lists the phone without `tun`, as an older box's does:
    /// the service passes nothing on and says nothing.
    var silentTun = false
    /// Pairing hashes the box lists while its QR shows. Each admits one
    /// session.
    var pending: Set<Bytes> = []
    private(set) var dialled: [URL] = []
    private(set) var nows: [Int] = []
    /// Message 1's `now` bodies, whole.
    private(set) var nowBodies: [CBOR] = []
    /// Every `tun` a phone sent, from message 1 or the stream.
    private(set) var tunsFromPhone: [CloudWire.Tun] = []
    private(set) var received: [CloudWire.Envelope] = []
    private var sessions: [FakeCloudSocket] = []

    init(scheduler: ManualScheduler) {
        self.scheduler = scheduler
    }

    var endpoint: CloudEndpoint {
        CloudEndpoint(url: URL(string: "wss://cloud.test/v1/app")!, serviceKeys: [staticKey.publicKey])
    }

    var factory: WebSocketFactory {
        { [unowned self] url, events in
            self.dialled.append(url)
            let socket = FakeCloudSocket(service: self, url: url, events: events)
            self.sessions.append(socket)
            _ = self.scheduler.after(self.latencyMs) {
                guard !socket.closed else { return }
                events.onOpen()
            }
            return socket
        }
    }

    var current: FakeCloudSocket? { sessions.last(where: { !$0.closed }) }

    func push(_ env: CloudWire.Envelope) {
        held.append(env)
        current?.push(env)
    }

    func close(code: Int) {
        guard let s = current else { return }
        s.closed = true
        s.events.onClose(code, "")
    }

    fileprivate func receive(_ bytes: Bytes, on socket: FakeCloudSocket) {
        if let transport = socket.transport {
            guard let frame = try? transport.decrypt(bytes), let payload = try? CloudWire.decodeFrame(frame),
                  let env = try? CloudWire.Envelope.decode(payload) else {
                socket.closeFromService(CloudWire.closeProtocol)
                return
            }
            received.append(env)
            if env.t == CloudWire.msgTun, let tun = try? CloudWire.Tun(body: env.b) { phoneTun(tun, on: socket) }
            if env.t == CloudWire.msgTilesGet { answerTiles(env, on: socket) }
            return
        }
        let home = URLComponents(url: socket.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "home" }?.value ?? ""
        let key = refuseKey == staticKey.publicKey ? Primitives.generateKeyPair() : staticKey
        let hs = HandshakeState.responder(staticKey: key, prologue: CloudWire.appPrologue(home: home))
        guard let payload = try? hs.readMessage(bytes),
              let now = try? CloudWire.Envelope.decode(payload), now.t == CloudWire.msgNow else {
            socket.closeFromService(CloudWire.closeDenied)
            return
        }
        let body = (try? decodeCBOR(now.b)) ?? .null
        nowBodies.append(body)
        nows.append(body["hz"]?.int ?? -1)
        guard let msg2 = try? hs.writeMessage(snapshotPayload()), let keys = try? hs.split() else {
            socket.closeFromService(CloudWire.closeDenied)
            return
        }
        var admitted = roster.contains(keys.remoteStatic)
        if !admitted, let pair = body["pair"]?.byteString, pending.remove(pair) != nil { admitted = true }
        guard admitted else {
            socket.closeFromService(CloudWire.closeDenied)
            return
        }
        socket.transport = NoiseTransport(keys)
        socket.device = keys.remoteStatic
        socket.deliver(msg2)
        if let t = body["tun"], let tun = try? CloudWire.Tun(body: encodeCBOR(t)) { phoneTun(tun, on: socket) }
    }

    /// `tiles.get`: each tile held that the phone lacks, then `tiles.end`.
    private func answerTiles(_ ask: CloudWire.Envelope, on socket: FakeCloudSocket) {
        var have = [String: String]()
        for e in (try? decodeCBOR(ask.b))?["have"]?.entries ?? [] {
            if let k = e.key.string, let v = e.value.string { have[k] = v }
        }
        var n = 0
        for env in tiles {
            if let t = try? CloudWire.Tiles(body: env.b), !t.partial, have[t.tileId] == t.etag { continue }
            socket.push(env)
            n += 1
        }
        if let end = try? CloudWire.Envelope.decode(CloudWire.encodeUnsigned(t: CloudWire.msgTilesEnd, body: .map([("n", .int(n))]))) {
            socket.push(end)
        }
    }

    /// One `tun` from a phone: to the box, or ended at once when there is
    /// no box to take it.
    private func phoneTun(_ tun: CloudWire.Tun, on socket: FakeCloudSocket) {
        tunsFromPhone.append(tun)
        if silentTun { return }
        guard let box = tunBox else {
            if !tun.ended { socket.tun(CloudWire.Tun(sid: tun.sid, d: [])) }
            return
        }
        box.receive(tun, from: socket.device ?? []) { [weak socket] reply in socket?.tun(reply) }
    }

    func snapshotPayload(_ envelopes: [CloudWire.Envelope]? = nil) -> Bytes {
        let envs = (envelopes ?? held).map { e -> CBOR in .map([("b", .bytes(e.b)), ("t", .text(e.t)), ("sig", .bytes(e.sig))]) }
        return CloudWire.encodeUnsigned(t: CloudWire.msgSnapshot, body: .map([
            ("envelopes", .array(envs)), ("lastSeenMs", .int(Int64(scheduler.nowMs))), ("online", .bool(online)), ("more", .int(0)),
        ]))
    }

    var watches: [Int] {
        received.filter { $0.t == CloudWire.msgWatch }.compactMap { (try? decodeCBOR($0.b))?["hz"]?.int }
    }

    /// The APNs tokens the phone registered, in order.
    var registrations: [Bytes] {
        received.filter { $0.t == CloudWire.msgPushRegister }.compactMap { (try? decodeCBOR($0.b))?["apnsToken"]?.byteString }
    }
}

@MainActor
final class FakeCloudSocket: WebSocketConnection {
    unowned let service: FakeCloudService
    let url: URL
    let events: WebSocketEvents
    var closed = false
    var transport: NoiseTransport?
    /// The key message 1 proved.
    var device: Bytes?

    init(service: FakeCloudService, url: URL, events: WebSocketEvents) {
        self.service = service
        self.url = url
        self.events = events
    }

    func send(_ data: Bytes) {
        guard !closed else { return }
        _ = service.scheduler.after(service.latencyMs) { [weak self] in
            guard let self, !self.closed else { return }
            self.service.receive(data, on: self)
        }
    }

    func deliver(_ bytes: Bytes) {
        _ = service.scheduler.after(service.latencyMs) { [weak self] in
            guard let self, !self.closed else { return }
            self.events.onBinary(bytes)
        }
    }

    /// As a QUIC datagram.
    func deliverDatagram(_ bytes: Bytes) {
        _ = service.scheduler.after(service.latencyMs) { [weak self] in
            guard let self, !self.closed else { return }
            if let onDatagram = self.events.onDatagram { onDatagram(bytes) } else { self.events.onBinary(bytes) }
        }
    }

    func push(_ env: CloudWire.Envelope) {
        guard let transport, let frame = try? CloudWire.encodeFrame(env.encode()), let msg = try? transport.encrypt(frame) else { return }
        deliver(msg)
    }

    /// One message of the phone's box session, from the box.
    func tun(_ t: CloudWire.Tun) {
        guard let env = try? CloudWire.Envelope.decode(CloudWire.encodeUnsigned(t: CloudWire.msgTun, body: t.body)) else { return }
        push(env)
    }

    func closeFromService(_ code: Int) {
        _ = service.scheduler.after(service.latencyMs) { [weak self] in
            guard let self, !self.closed else { return }
            self.closed = true
            self.events.onClose(code, "")
        }
    }

    func close() {
        closed = true
    }
}

/// A phone's carrier and the events it delivered.
@MainActor
final class CloudRig {
    let scheduler = ManualScheduler()
    let service: FakeCloudService
    let device = Primitives.generateKeyPair()
    var box: FakeCloudBox
    let carrier: CloudCarrier
    var snapshots: [CloudWire.Snapshot] = []
    var envelopes: [CloudWire.Envelope] = []
    var statuses: [CloudCarrier.Status] = []

    init(looking: Bool = true, endpoint: ((FakeCloudService) -> CloudEndpoint)? = nil) throws {
        service = FakeCloudService(scheduler: scheduler)
        box = try FakeCloudBox(boot: 1)
        service.roster = [device.publicKey]
        carrier = CloudCarrier(endpoint: endpoint?(service) ?? service.endpoint, home: box.home, deviceKey: device, looking: looking, scheduler: scheduler, makeSocket: service.factory)
        carrier.setHandlers(
            onSnapshot: { [unowned self] s, _ in self.snapshots.append(s) },
            onEnvelope: { [unowned self] e, _ in self.envelopes.append(e) },
            onStatus: { [unowned self] s in self.statuses.append(s) }
        )
    }

    var at: Int64 { Int64(scheduler.nowMs) }

    func run(_ ms: Double) async {
        var left = ms
        while left > 0 {
            for _ in 0..<5 { await Task.yield() }
            scheduler.advance(min(10, left))
            left -= 10
        }
    }
}

@MainActor
@Suite struct CloudCarrierTests {
    /// One round trip after the socket opens, the service's copy is here;
    /// each later change follows on the same socket.
    @Test func theSnapshotComesInMessage2AndChangesFollow() async throws {
        let rig = try CloudRig()
        rig.box.start = rig.at - 60_000
        rig.service.held = [try rig.box.fullLive(rig.at, age: 500)]
        rig.carrier.start()
        await rig.run(50)
        #expect(rig.service.dialled.first?.absoluteString == "wss://cloud.test/v1/app?home=\(rig.box.home)")
        #expect(rig.service.nows == [CloudWire.hzLooking])
        #expect(rig.carrier.status.isOpen)
        #expect(rig.snapshots.count == 1)
        #expect(rig.snapshots.first?.envelopes == rig.service.held)

        let hb = try rig.box.hb(rig.at, age: 900, liveSeq: 1)
        rig.service.push(hb)
        await rig.run(30)
        #expect(rig.envelopes == [hb])
    }

    @Test func lookingAwayAndBackIsSaid() async throws {
        let rig = try CloudRig(looking: false)
        rig.carrier.start()
        await rig.run(50)
        #expect(rig.service.nows == [CloudWire.hzAway])
        rig.carrier.setLooking(true)
        rig.carrier.setLooking(true)
        rig.carrier.setLooking(false)
        await rig.run(30)
        #expect(rig.service.watches == [1, 0])
    }

    /// A launch passes through inactive, so message 1 may say the phone
    /// looks away. The app comes to the front before message 2: the service
    /// hears it once the session opens, or the box stays at 5 s.
    @Test func lookingChangedDuringTheHandshakeIsSaidOnceOpen() async throws {
        let rig = try CloudRig(looking: false)
        rig.carrier.start()
        await rig.run(15)
        #expect(rig.service.nows == [])
        #expect(!rig.carrier.status.isOpen)
        rig.carrier.setLooking(true)
        await rig.run(50)
        #expect(rig.service.nows == [CloudWire.hzAway])
        #expect(rig.carrier.status.isOpen)
        #expect(rig.service.watches == [1])

        // And the other way: the phone looked when it dialled and looked
        // away before the session opened.
        let away = try CloudRig(looking: true)
        away.carrier.start()
        await away.run(15)
        away.carrier.setLooking(false)
        await away.run(50)
        #expect(away.service.nows == [CloudWire.hzLooking])
        #expect(away.service.watches == [0])
    }

    /// A change while the session is down rides in the next message 1, and
    /// nothing more is said.
    @Test func lookingChangedWhileClosedGoesInMessage1() async throws {
        let rig = try CloudRig(looking: true)
        rig.carrier.start()
        await rig.run(50)
        rig.service.close(code: 1006)
        rig.carrier.setLooking(false)
        await rig.run(600)
        #expect(rig.carrier.status.isOpen)
        #expect(rig.service.nows == [CloudWire.hzLooking, CloudWire.hzAway])
        #expect(rig.service.watches == [])
    }

    /// A refusal is asked again slowly, as after a service restart that has
    /// not heard from the box yet, and at once on the next foreground.
    @Test func aRefusalIsAskedAgainSlowly() async throws {
        let rig = try CloudRig()
        rig.service.roster = []
        rig.carrier.start()
        await rig.run(100)
        #expect(rig.carrier.status == .closed(code: CloudWire.closeDenied, retrying: true))
        await rig.run(10_000)
        #expect(rig.service.dialled.count == 1)
        await rig.run(10_000)
        #expect(rig.service.dialled.count == 2)
        rig.service.roster = [rig.device.publicKey]
        rig.carrier.wake()
        await rig.run(100)
        #expect(rig.carrier.status.isOpen)
    }

    /// Another session of this phone took over: this one stays closed.
    @Test func aReplacedSessionStaysClosed() async throws {
        let rig = try CloudRig()
        rig.carrier.start()
        await rig.run(50)
        rig.service.close(code: CloudWire.closeReplaced)
        await rig.run(120_000)
        #expect(rig.carrier.status == .closed(code: CloudWire.closeReplaced, retrying: false))
        #expect(rig.service.dialled.count == 1)
    }

    /// The roster changed what this phone may read: it asks again at once.
    @Test func aChangedRosterReconnectsAtOnce() async throws {
        let rig = try CloudRig()
        rig.carrier.start()
        await rig.run(50)
        rig.service.close(code: CloudWire.closeChanged)
        await rig.run(60)
        #expect(rig.service.dialled.count == 2)
        #expect(rig.carrier.status.isOpen)
    }

    /// Anything else heals by itself, with full jitter.
    @Test func aLostSocketRedialsWithBackoff() async throws {
        let rig = try CloudRig()
        rig.carrier.start()
        await rig.run(50)
        rig.service.close(code: 1006)
        #expect(rig.carrier.status == .closed(code: 1006, retrying: true))
        await rig.run(600)
        #expect(rig.carrier.status.isOpen)
        #expect(rig.service.dialled.count == 2)
    }

    /// The app carries two service keys so the service can rotate: a refusal
    /// right after message 1 tries the other key once.
    @Test func aRotatedServiceKeyIsTriedNext() async throws {
        let rig = try CloudRig(endpoint: { service in
            CloudEndpoint(url: URL(string: "wss://cloud.test/v1/app")!, serviceKeys: [Primitives.generateKeyPair().publicKey, service.staticKey.publicKey])
        })
        rig.carrier.start()
        await rig.run(100)
        #expect(rig.carrier.status.isOpen)
        #expect(rig.service.dialled.count == 2)
    }

    @Test func aMessageThatDoesNotDecryptEndsTheSession() async throws {
        let rig = try CloudRig()
        rig.carrier.start()
        await rig.run(50)
        rig.service.current?.deliver(randomBytes(40))
        await rig.run(20)
        #expect(!rig.carrier.status.isOpen)
        #expect(rig.envelopes.isEmpty)
        await rig.run(600)
        #expect(rig.carrier.status.isOpen)
    }

    @Test func closedMeansClosed() async throws {
        let rig = try CloudRig()
        rig.carrier.start()
        await rig.run(50)
        rig.carrier.close()
        rig.carrier.wake()
        await rig.run(120_000)
        #expect(rig.service.dialled.count == 1)
    }
}

@Suite struct CloudEndpointTests {
    /// Release builds read the fixed address and ignore any override.
    @Test func onlyADebugBuildMayPointElsewhere() throws {
        let defaults = try #require(UserDefaults(suiteName: "ftw-cloud-\(UUID().uuidString)"))
        let key = Base64url.encode(Primitives.generateKeyPair().publicKey)
        defaults.set("wss://127.0.0.1:18443/v1/app", forKey: "FTWCloudURL")
        defaults.set(key, forKey: "FTWCloudKey")
        let debug = try #require(CloudEndpoint.resolve(defaults: defaults, debug: true))
        #expect(debug.url.absoluteString == "wss://127.0.0.1:18443/v1/app")
        #expect(CloudEndpoint.resolve(defaults: defaults, debug: false)?.url ?? CloudEndpoint.releaseURL == CloudEndpoint.releaseURL)
        #expect(CloudEndpoint.releaseURL.absoluteString == "wss://cloud.ftw.energy/v1/app")
        defaults.set("not a key", forKey: "FTWCloudKey")
        #expect(CloudEndpoint.resolve(defaults: defaults, debug: true)?.url != debug.url)
    }

    /// A release build dials cloud.ftw.energy with its one Noise key, as a
    /// debug build does when nothing points it elsewhere.
    @Test func aReleaseBuildCarriesTheServicesKey() throws {
        #expect(CloudEndpoint.releaseKeys.count == 1)
        #expect(CloudEndpoint.releaseKeys.map(Base64url.encode) == CloudEndpoint.releaseKeyText)
        #expect(CloudEndpoint.releaseKeys.allSatisfy { $0.count == Noise.dhBytes })
        let defaults = try #require(UserDefaults(suiteName: "ftw-cloud-\(UUID().uuidString)"))
        for debug in [false, true] {
            let e = try #require(CloudEndpoint.resolve(defaults: defaults, debug: debug))
            #expect(e.url == CloudEndpoint.releaseURL)
            #expect(e.serviceKeys == CloudEndpoint.releaseKeys)
        }
    }

    /// A service that answers with any other key refuses message 1, so the
    /// phone never opens a session and holds no snapshot.
    @MainActor
    @Test func aServiceWithAnotherKeyIsNotTheCloud() async throws {
        let rig = try CloudRig { svc in CloudEndpoint(url: svc.endpoint.url, serviceKeys: CloudEndpoint.releaseKeys) }
        rig.box.start = rig.at - 60_000
        rig.service.held = [try rig.box.fullLive(rig.at, age: 500)]
        rig.carrier.start()
        await rig.run(100)
        #expect(!rig.carrier.status.isOpen)
        #expect(rig.snapshots.isEmpty)
        #expect(rig.statuses.contains(.closed(code: CloudWire.closeDenied, retrying: true)))
    }

    /// The identity comes from the box. A home that is not the hash of the
    /// key is refused.
    @Test func theHomeIsTheHashOfTheKey() throws {
        let v = try CloudVectors.load()
        let pk = Bytes(hex: v.boxKey.pk)
        let boot = Bytes(repeating: 0xb0, count: CloudWire.bootBytes)
        let good = CloudIdentity(.map([("pk", .bytes(pk)), ("home", .text(v.home)), ("boot", .bytes(boot)),
                                       ("sources", .map(["ACfHt4DWL7g": .text("p1meter")])), ("loadpoints", .map([:]))]))
        #expect(good?.home == v.home)
        #expect(good?.sources["ACfHt4DWL7g"] == "p1meter")
        #expect(CloudIdentity(.map([("pk", .bytes(pk)), ("home", .text("aaaaaaaaaaaaaaaaaaaaaaaaaa")), ("boot", .bytes(boot))])) == nil)
        #expect(CloudIdentity(.map([("pk", .bytes(Bytes(pk.prefix(33)))), ("boot", .bytes(boot))])) == nil)
        #expect(CloudIdentity(nil) == nil)
    }
}
