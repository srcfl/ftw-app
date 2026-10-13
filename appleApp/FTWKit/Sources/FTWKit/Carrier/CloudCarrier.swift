import Foundation
import FTWShared

/// The phone's session with FTW Cloud: one WebSocket, Noise IK as initiator
/// to the service's key, the home id in the prologue.
///
/// Message 1 says whether the phone is looking, message 2 brings the copy the
/// service holds in memory, and every change the box sends after that comes
/// down the same socket. What arrives is the box's own signed envelopes; this
/// file moves them and checks nothing about them. `CloudView` checks every
/// signature with the key the box gave this phone over Noise.
///
/// The service reads and never controls. Nothing sent here can change the
/// house: a command still goes to the box over the relay.
@MainActor
public final class CloudCarrier {
    public enum Status: Equatable, Sendable {
        case connecting
        case open(sinceMs: Double)
        /// `retrying` is false once another session of this phone took
        /// over: asking again would only take it back.
        case closed(code: Int, retrying: Bool)

        public var isOpen: Bool {
            if case .open = self { return true }
            return false
        }
    }

    static let backoffBaseMs: Double = 500
    static let backoffCapMs: Double = 60_000
    /// A refusal changes only when the box's roster or grant does, or when
    /// a service that just restarted has heard from the box again. Asked
    /// again slowly, and at once on `wake`.
    static let refusedBaseMs: Double = 15_000
    static let refusedCapMs: Double = 300_000
    /// Message 2 is one round trip after message 1; a service this slow is
    /// not one to wait on.
    static let handshakeTimeoutMs: Double = 10_000

    public private(set) var status: Status = .connecting

    private let endpoint: CloudEndpoint
    private let home: String
    private let deviceKey: Primitives.KeyPair
    private let scheduler: Scheduler
    private let makeSocket: WebSocketFactory
    private var looking: Bool

    private var socket: WebSocketConnection?
    private var generation = 0
    private var handshake: HandshakeState?
    private var transport: NoiseTransport?
    /// Which of the app's service keys this dial uses. A refusal right after
    /// message 1 may be a rotated key; the next one gets one try.
    private var keyIndex = 0
    private var attempt = 0
    private var refusals = 0
    private var retry: Cancellable?
    private var deadline: Cancellable?
    private var shutdown = false

    private var onSnapshot: @MainActor (CloudWire.Snapshot, Double) -> Void = { _, _ in }
    private var onEnvelope: @MainActor (CloudWire.Envelope, Double) -> Void = { _, _ in }
    private var onStatus: @MainActor (Status) -> Void = { _ in }

    public init(endpoint: CloudEndpoint, home: String, deviceKey: Primitives.KeyPair, looking: Bool, scheduler: Scheduler, makeSocket: @escaping WebSocketFactory) {
        self.endpoint = endpoint
        self.home = home
        self.deviceKey = deviceKey
        self.looking = looking
        self.scheduler = scheduler
        self.makeSocket = makeSocket
    }

    /// One owner: the site model. `start` dials once the handlers are set.
    public func setHandlers(
        onSnapshot: @escaping @MainActor (CloudWire.Snapshot, Double) -> Void,
        onEnvelope: @escaping @MainActor (CloudWire.Envelope, Double) -> Void,
        onStatus: @escaping @MainActor (Status) -> Void
    ) {
        self.onSnapshot = onSnapshot
        self.onEnvelope = onEnvelope
        self.onStatus = onStatus
    }

    public func start() {
        guard !shutdown, socket == nil, retry == nil else { return }
        dial()
    }

    /// Whether anyone can see the home. While someone can, the service keeps
    /// the box at one update a second. A closed session takes the change
    /// with it into message 1 of the next.
    public func setLooking(_ on: Bool) {
        guard on != looking else { return }
        looking = on
        send(CloudWire.msgWatch, .map([("hz", .int(on ? CloudWire.hzLooking : CloudWire.hzAway))]))
    }

    /// An owner suspends a device at FTW Cloud, or lifts it. It only narrows
    /// what the box's roster allows. False when the session is not open and
    /// nothing went out.
    @discardableResult
    public func suspend(deviceID: String, _ on: Bool) -> Bool {
        send(on ? CloudWire.msgSuspend : CloudWire.msgUnsuspend, .map([("deviceId", .text(deviceID))]))
    }

    /// Tell the service where Apple can reach this phone, for alerts. The
    /// service binds the token to this phone's roster entry, so a phone
    /// that may not read events registers nothing, and keeps one row per
    /// token, so sending it again changes nothing. False when the session
    /// is not open and nothing went out.
    @discardableResult
    public func pushRegister(apnsToken: Data, environment: PushEnvironment) -> Bool {
        send(CloudWire.msgPushRegister, .map([
            ("apnsToken", .bytes(Bytes(apnsToken))), ("environment", .text(environment.rawValue)), ("kind", .text(CloudWire.pushKindAlert)),
        ]))
    }

    /// The app came to the front or the network changed: dial now if the
    /// session is not open, after a refusal too.
    public func wake() {
        guard !shutdown, !status.isOpen else { return }
        retry?.cancel()
        retry = nil
        attempt = 0
        refusals = 0
        keyIndex = 0
        drop()
        dial()
    }

    public func close() {
        guard !shutdown else { return }
        shutdown = true
        retry?.cancel()
        deadline?.cancel()
        drop()
        onSnapshot = { _, _ in }
        onEnvelope = { _, _ in }
        onStatus = { _ in }
    }

    // MARK: The wire

    private func dial() {
        guard !shutdown else { return }
        setStatus(.connecting)
        generation += 1
        let mine = generation
        handshake = nil
        transport = nil
        socket = makeSocket(endpoint.url(home: home), WebSocketEvents(
            onOpen: { [weak self] in
                guard let self, mine == self.generation else { return }
                self.sendMessage1()
            },
            onText: { _ in },
            onBinary: { [weak self] bytes in
                guard let self, mine == self.generation else { return }
                self.receive(bytes)
            },
            onClose: { [weak self] code, _ in
                guard let self, mine == self.generation else { return }
                self.closed(code: code)
            }
        ))
    }

    private func sendMessage1() {
        guard handshake == nil, transport == nil, let socket else { return }
        let keys = endpoint.serviceKeys
        guard keyIndex < keys.count,
              let hs = try? HandshakeState.initiator(staticKey: deviceKey, remoteStatic: keys[keyIndex], prologue: CloudWire.appPrologue(home: home)) else {
            shutdown = true
            drop()
            setStatus(.closed(code: CloudWire.closeDenied, retrying: false))
            return
        }
        let now = CloudWire.encodeUnsigned(t: CloudWire.msgNow, body: .map([("hz", .int(looking ? CloudWire.hzLooking : CloudWire.hzAway))]))
        guard let msg1 = try? hs.writeMessage(now) else { return }
        handshake = hs
        socket.send(msg1)
        deadline?.cancel()
        deadline = scheduler.after(Self.handshakeTimeoutMs) { [weak self] in
            guard let self, self.transport == nil else { return }
            self.fail(code: 1006, retrying: true)
        }
    }

    private func receive(_ bytes: Bytes) {
        let arrival = scheduler.nowMs
        if let transport {
            guard let frame = try? transport.decrypt(bytes),
                  let payload = try? CloudWire.decodeFrame(frame),
                  let env = try? CloudWire.Envelope.decode(payload) else {
                fail(code: CloudWire.closeProtocol, retrying: true)
                return
            }
            // Only a delivered message proves the path works.
            attempt = 0
            onEnvelope(env, arrival)
            return
        }
        guard let hs = handshake,
              let payload = try? hs.readMessage(bytes),
              let snapshot = try? CloudWire.parseSnapshot(payload: payload),
              let keys = try? hs.split() else {
            fail(code: CloudWire.closeProtocol, retrying: true)
            return
        }
        deadline?.cancel()
        handshake = nil
        transport = NoiseTransport(keys)
        attempt = 0
        refusals = 0
        setStatus(.open(sinceMs: arrival))
        onSnapshot(snapshot, arrival)
    }

    /// One message to the service, or false when the session is not open.
    @discardableResult
    private func send(_ t: String, _ body: CBOR) -> Bool {
        guard let transport, let socket, status.isOpen else { return false }
        let env = CloudWire.encodeUnsigned(t: t, body: body)
        guard let frame = try? CloudWire.encodeFrame(env), let msg = try? transport.encrypt(frame) else { return false }
        socket.send(msg)
        return true
    }

    private func closed(code: Int) {
        let beforeMessage2 = transport == nil
        socket = nil
        generation += 1
        deadline?.cancel()
        switch code {
        case CloudWire.closeDenied where beforeMessage2 && keyIndex + 1 < endpoint.serviceKeys.count:
            // Perhaps the service already runs on the app's other key.
            keyIndex += 1
            dial()
        case CloudWire.closeReplaced:
            setStatus(.closed(code: code, retrying: false))
        case CloudWire.closeDenied:
            keyIndex = 0
            setStatus(.closed(code: code, retrying: true))
            let ceiling = min(Self.refusedCapMs, Self.refusedBaseMs * pow(2, Double(refusals)))
            refusals = min(refusals + 1, 16)
            schedule(ceiling / 2 + scheduler.random() * ceiling / 2)
        case CloudWire.closeChanged:
            // The roster changed what this phone may read: ask again now,
            // once, to learn what that is.
            keyIndex = 0
            setStatus(.closed(code: code, retrying: true))
            if attempt == 0 {
                attempt = 1
                schedule(0)
            } else {
                schedule(backoff())
            }
        default:
            keyIndex = 0
            setStatus(.closed(code: code, retrying: true))
            schedule(backoff())
        }
    }

    private func fail(code: Int, retrying: Bool) {
        drop()
        setStatus(.closed(code: code, retrying: retrying))
        if retrying { schedule(backoff()) }
    }

    /// Full jitter, as the relay carrier and the box's uplink do.
    private func backoff() -> Double {
        let ceiling = min(Self.backoffCapMs, Self.backoffBaseMs * pow(2, Double(attempt)))
        attempt = min(attempt + 1, 16)
        return scheduler.random() * ceiling
    }

    private func schedule(_ delayMs: Double) {
        retry?.cancel()
        retry = scheduler.after(delayMs) { [weak self] in
            guard let self else { return }
            self.retry = nil
            self.dial()
        }
    }

    private func drop() {
        generation += 1
        socket?.close()
        socket = nil
        handshake = nil
        transport = nil
    }

    private func setStatus(_ next: Status) {
        guard next != status else { return }
        status = next
        onStatus(next)
    }
}
