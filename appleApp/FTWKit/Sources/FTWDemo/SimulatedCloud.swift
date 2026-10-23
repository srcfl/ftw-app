#if DEBUG
import CryptoKit
import Foundation
import FTWKit

/// FTW Cloud for pictures of a box that goes away (`-FTWDemoBoxAway YES`):
/// the app session at the service, over loopback, through the real
/// handshake, frames and checks. It holds the demo house's tiles of the 48
/// hours before the box went away, signed with the key the demo box names as
/// its own in hello, and answers `tiles.get` as the service does. It holds
/// no readings: the box has gone.
@MainActor
public final class SimulatedCloud {
    /// The demo's one FTW Cloud, while a box that goes away has one.
    public private(set) static var current: SimulatedCloud?

    let box: SimulatedBox
    let scheduler: Scheduler
    /// When the box went away, by the phone's clock.
    var awayAtMs: Double?
    private let serviceKey = Primitives.generateKeyPair()
    private let boxKey = P256.Signing.PrivateKey()
    private var seq: UInt64 = 0

    init(box: SimulatedBox, scheduler: Scheduler) {
        self.box = box
        self.scheduler = scheduler
        Self.current = self
    }

    /// The box's key, as it names it in hello.
    var pk: Bytes { Bytes(boxKey.publicKey.x963Representation) }

    public var endpoint: CloudEndpoint {
        CloudEndpoint(url: URL(string: "wss://cloud.demo/v1/app")!, serviceKeys: [serviceKey.publicKey])
    }

    public var factory: WebSocketFactory {
        { [self] _, events in SimulatedCloudSocket(cloud: self, events: events) }
    }

    func handshake() -> HandshakeState {
        HandshakeState.responder(staticKey: serviceKey, prologue: CloudWire.appPrologue(home: CloudWire.homeID(pk: pk)))
    }

    /// The tiles of the 48 hours up to the last bucket that closed before
    /// the box went away: the closed ones, and the one still filling whole,
    /// each as the box signs it.
    func tiles() -> [CloudWire.Envelope] {
        let away = awayAtMs ?? scheduler.nowMs
        let step = 300_000.0, span = 43_200_000.0
        let end = ((away - 30_000) / step).rounded(.down) * step
        var out = [CloudWire.Envelope]()
        var start = HistoryGeometry.tileStart(.fiveMinutes, end - Double(CloudWire.tileKeepMs))
        while start < end {
            let columns = CloudWire.tileSeries.map { name in
                (0..<144).map { i -> Int32 in
                    let at = start + Double(i) * step
                    guard at + step <= end, let w = box.house.bucket(at, nowMs: away)?.value(name) else { return missingSample }
                    return Int32(w.rounded())
                }
            }
            let data = HistoryGeometry.pack(columns)
            seq += 1
            let body = encodeCBOR(.map([
                ("seq", .unsigned(seq)), ("boot", .bytes(Bytes(repeating: 0x0b, count: 16))), ("uptimeMs", .ms(box.uptimeMs)),
                ("wallMs", .ms(end + 30_000)),
                ("tileId", .text(HistoryGeometry.tileID(.fiveMinutes, stride: 1, startMs: start))), ("etag", .text(HistoryGeometry.etag(data))),
                ("res", .text("5m")), ("startMs", .ms(start)), ("stepMs", .ms(step)),
                ("series", .array(CloudWire.tileSeries.map { .text($0) })), ("data", .bytes(data)), ("partial", .bool(start + span > end)),
            ]))
            let home = CloudWire.homeID(pk: pk)
            if let sig = try? boxKey.signature(for: Data(CloudWire.signedInput(home: home, t: CloudWire.msgTiles, b: body))) {
                out.append(CloudWire.Envelope(t: CloudWire.msgTiles, b: body, sig: Bytes(sig.rawRepresentation)))
            }
            start += span
        }
        return out
    }
}

/// One phone's app session with the demo's FTW Cloud.
@MainActor
final class SimulatedCloudSocket: WebSocketConnection {
    private unowned let cloud: SimulatedCloud
    private let events: WebSocketEvents
    private var transport: NoiseTransport?
    private var closed = false
    private let latencyMs: Double = 40

    init(cloud: SimulatedCloud, events: WebSocketEvents) {
        self.cloud = cloud
        self.events = events
        cloud.scheduler.after(latencyMs) { [weak self] in
            guard let self, !self.closed else { return }
            self.events.onOpen()
        }
    }

    func send(_ data: Bytes) {
        guard !closed else { return }
        guard let transport else {
            let hs = cloud.handshake()
            let snapshot = CloudWire.encodeUnsigned(t: CloudWire.msgSnapshot, body: .map([
                ("envelopes", .array([])), ("lastSeenMs", .ms(cloud.awayAtMs ?? cloud.scheduler.nowMs)), ("online", .bool(false)), ("more", .int(0)),
            ]))
            guard (try? hs.readMessage(data)) != nil, let msg2 = try? hs.writeMessage(snapshot), let keys = try? hs.split() else { return }
            self.transport = NoiseTransport(keys)
            deliver(msg2)
            return
        }
        guard let frame = try? transport.decrypt(data), let payload = try? CloudWire.decodeFrame(frame),
              let env = try? CloudWire.Envelope.decode(payload), env.t == CloudWire.msgTilesGet else { return }
        var have = [String: String]()
        for e in (try? decodeCBOR(env.b))?["have"]?.entries ?? [] {
            if let k = e.key.string, let v = e.value.string { have[k] = v }
        }
        var n = 0
        for tile in cloud.tiles() {
            if let t = try? CloudWire.Tiles(body: tile.b), !t.partial, have[t.tileId] == t.etag { continue }
            push(tile.encode())
            n += 1
        }
        push(CloudWire.encodeUnsigned(t: CloudWire.msgTilesEnd, body: .map([("n", .int(n))])))
    }

    func close() { closed = true }

    private func push(_ envelope: Bytes) {
        guard let transport, let frame = try? CloudWire.encodeFrame(envelope), let msg = try? transport.encrypt(frame) else { return }
        deliver(msg)
    }

    private func deliver(_ bytes: Bytes) {
        cloud.scheduler.after(latencyMs) { [weak self] in
            guard let self, !self.closed else { return }
            self.events.onBinary(bytes)
        }
    }
}
#endif
