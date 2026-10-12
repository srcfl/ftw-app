import Foundation
@testable import FTWKit

/// The box's end of Noise, around a `SimulatedBox`: what the Go box does in
/// front of its protocol handler.
@MainActor
final class NoiseBoxEndpoint {
    let box: SimulatedBox
    let staticKey = Primitives.generateKeyPair()
    private var handshake: HandshakeState?
    private var transport: NoiseTransport?
    var toApp: (@MainActor (Bytes) -> Void)?
    private(set) var handshakePayloads: [Bytes] = []
    /// Answer handshakes with silence, as a box does for a phone it refuses.
    var refuse = false

    init(box: SimulatedBox) {
        self.box = box
        box.send = { [weak self] frame in
            guard let self, let transport = self.transport, let wire = try? transport.encrypt(frame) else { return }
            self.toApp?(wire)
        }
    }

    var prologue: Bytes { NoiseCarrier.prologue(boxStaticKey: staticKey.publicKey) }

    func receive(_ bytes: Bytes) {
        if let transport, let frame = try? transport.decrypt(bytes) {
            box.receive(frame)
            return
        }
        // Anything else of the right length is a new handshake.
        guard bytes.count >= Noise.message1Overhead, !refuse else { return }
        let hs = HandshakeState.responder(staticKey: staticKey, prologue: prologue)
        guard let payload = try? hs.readMessage(bytes), let reply = try? hs.writeMessage() else { return }
        handshakePayloads.append(payload)
        transport = NoiseTransport(try! hs.split())
        toApp?(reply)
    }

    func dropSession() {
        transport = nil
    }
}

/// A relay room with one box in it, reached through fake sockets.
@MainActor
final class FakeRelay {
    let scheduler: ManualScheduler
    let endpoint: NoiseBoxEndpoint
    var latencyMs: Double = 10
    var boxOnline = true
    private(set) var dialled: [URL] = []
    private(set) var sockets: [FakeSocket] = []

    init(scheduler: ManualScheduler, endpoint: NoiseBoxEndpoint) {
        self.scheduler = scheduler
        self.endpoint = endpoint
        endpoint.toApp = { [weak self] bytes in
            guard let self, let socket = self.sockets.last(where: { !$0.closed }) else { return }
            _ = self.scheduler.after(self.latencyMs) { socket.deliver(bytes) }
        }
    }

    var factory: WebSocketFactory {
        { [unowned self] url, events in
            self.dialled.append(url)
            let socket = FakeSocket(relay: self, events: events)
            self.sockets.append(socket)
            _ = self.scheduler.after(self.latencyMs) {
                guard !socket.closed else { return }
                events.onOpen()
                if self.boxOnline { events.onText("ready") }
            }
            return socket
        }
    }

    var current: FakeSocket? { sockets.last(where: { !$0.closed }) }

    /// The relay closes the socket with a code, as it does on a rotation.
    func closeCurrent(code: Int, reason: String) {
        guard let socket = current else { return }
        socket.closed = true
        socket.events.onClose(code, reason)
    }

    func boxLeaves() {
        boxOnline = false
        current?.events.onText("gone")
    }

    func boxReturns() {
        boxOnline = true
        endpoint.dropSession()
        current?.events.onText("ready")
    }
}

@MainActor
final class FakeSocket: WebSocketConnection {
    unowned let relay: FakeRelay
    let events: WebSocketEvents
    var closed = false
    private(set) var sent: [Bytes] = []

    init(relay: FakeRelay, events: WebSocketEvents) {
        self.relay = relay
        self.events = events
    }

    func send(_ data: Bytes) {
        guard !closed else { return }
        sent.append(data)
        _ = relay.scheduler.after(relay.latencyMs) { [weak self] in
            guard let self, !self.closed else { return }
            self.relay.endpoint.receive(data)
        }
    }

    func deliver(_ bytes: Bytes) {
        guard !closed else { return }
        events.onBinary(bytes)
    }

    func close() {
        closed = true
    }
}

/// The whole stack, as the app builds it, against the simulated box.
@MainActor
struct Rig {
    let scheduler: ManualScheduler
    let box: SimulatedBox
    let endpoint: NoiseBoxEndpoint
    let relay: FakeRelay
    let relayCarrier: RelayCarrier
    let noise: NoiseCarrier
    let session: Session
    let pairingCode: Bytes

    init(requireStepUp: Bool = false, connect: Bool = true) {
        let scheduler = ManualScheduler()
        self.scheduler = scheduler
        box = SimulatedBox(scheduler: scheduler, requireStepUp: requireStepUp)
        endpoint = NoiseBoxEndpoint(box: box)
        relay = FakeRelay(scheduler: scheduler, endpoint: endpoint)
        pairingCode = randomBytes(16)
        relayCarrier = RelayCarrier(url: URL(string: "wss://relay.test")!, secret: Bytes(repeating: 9, count: 32), scheduler: scheduler, makeSocket: relay.factory)
        noise = NoiseCarrier(
            inner: relayCarrier,
            staticKey: Primitives.generateKeyPair(),
            remoteStatic: endpoint.staticKey.publicKey,
            prologue: endpoint.prologue,
            handshakePayload: pairingCode,
            scheduler: scheduler
        )
        session = Session(build: "test", ua: "test", scheduler: scheduler)
        if connect { session.connect(noise) }
    }

    /// Let spawned tasks reach their suspension points.
    func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    /// Advance in small steps, letting tasks run between them, so a request
    /// sent by a task is on the wire before its answer is due.
    func run(_ ms: Double, step: Double = 10) async {
        var left = ms
        while left > 0 {
            await settle()
            scheduler.advance(min(step, left))
            left -= step
        }
        await settle()
    }
}
