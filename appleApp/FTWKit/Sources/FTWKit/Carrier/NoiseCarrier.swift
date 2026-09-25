import Foundation

/// The carrier that makes every other carrier private.
///
/// Wraps an inner carrier and runs the Noise IK handshake across it before a
/// single application frame moves. Above, an ordinary carrier; below, opaque
/// bytes. That is the whole reason the relay can be blind without the
/// session knowing a relay exists.
///
/// Nothing here is on the first-frame path: the handshake is two round
/// trips and runs behind cached readings already on screen.
@MainActor
public final class NoiseCarrier: Carrier {
    /// The box answers a refused handshake with silence, on purpose, so this
    /// is the only thing that tells "not yet" from "never".
    static let handshakeDeadlineMs: Double = 12_000
    /// A foreground person should never wait out the ordinary window.
    static let foregroundHandshakeDeadlineMs: Double = 3_000
    static let handshakeBackoffBaseMs: Double = 3_000
    static let handshakeBackoffCapMs: Double = 60_000
    /// Message 2 of IK: an ephemeral key and one tag over an empty payload.
    static let message2Bytes = Noise.dhBytes + Noise.tagBytes
    /// Failures an inbound frame that is not ours can cause. The relay
    /// broadcasts a box frame to every phone in its room, so these are
    /// routine routing misses, not errors.
    static let foreignFrameErrors: Set<String> = ["E_NOISE_AUTH", "E_NOISE_REPLAY", "E_NOISE_MESSAGE", "E_NOISE_NONCE_EXHAUSTED"]

    private let inner: Carrier
    private let staticKey: Primitives.KeyPair
    private let remoteStatic: Bytes
    private let prologue: Bytes
    private let payload: Bytes
    private let scheduler: Scheduler

    private var handshake: HandshakeState?
    private var transport: NoiseTransport?
    public private(set) var status: CarrierStatus = .connecting
    private var closed = false
    private var awaitingReply = false
    private var deadline: Cancellable?
    private var retry: Cancellable?
    private var attempt = 0
    private var foregroundAttempt = false

    private var onFrame: @MainActor (Bytes) -> Void = { _ in }
    private var onStatus: @MainActor (CarrierStatus) -> Void = { _ in }

    /// `handshakePayload` is the single-use pairing code, sent encrypted in
    /// message 1. The box spends it once and remembers the key it came with.
    public init(inner: Carrier, staticKey: Primitives.KeyPair, remoteStatic: Bytes, prologue: Bytes, handshakePayload: Bytes = [], scheduler: Scheduler) {
        self.inner = inner
        self.staticKey = staticKey
        self.remoteStatic = remoteStatic
        self.prologue = prologue
        self.payload = handshakePayload
        self.scheduler = scheduler
        inner.setHandlers(
            onFrame: { [weak self] bytes in self?.onInnerFrame(bytes) },
            onStatus: { [weak self] status in self?.onInnerStatus(status) }
        )
        if inner.status.isOpen { beginHandshake() }
    }

    /// Binds a session to its box, so a captured handshake cannot be
    /// replayed into another one.
    public static func prologue(boxStaticKey: Bytes) -> Bytes {
        Array("ftw.session.v1:".utf8) + boxStaticKey
    }

    public var kind: CarrierKind { inner.kind }

    public func setHandlers(onFrame: @escaping @MainActor (Bytes) -> Void, onStatus: @escaping @MainActor (CarrierStatus) -> Void) {
        self.onFrame = onFrame
        self.onStatus = onStatus
    }

    public func send(_ frame: Bytes) {
        // Before the handshake there is no key, and sending in the clear to
        // keep a caller happy would be worse than dropping.
        guard let transport, status.isOpen else { return }
        do {
            inner.send(try transport.encrypt(frame))
        } catch {
            // Nonce exhaustion or a destroyed cipher: continuing would risk
            // reusing a (key, nonce) pair.
            fail("encryption failed", retryable: true)
        }
    }

    /// Abandon a session the OS may have frozen, and start a fresh one.
    public func wake() {
        if closed { return }
        attempt = 0
        foregroundAttempt = true
        resetSession()
        retry?.cancel()
        retry = nil
        setStatus(.closed(reason: "reconnecting after wake", retryable: true))
        inner.wake()
        if inner.status.isOpen { beginHandshake() }
    }

    public func close(reason: String = "closed by client") {
        if closed { return }
        closed = true
        deadline?.cancel()
        retry?.cancel()
        resetSession()
        inner.close(reason: reason)
        setStatus(.closed(reason: reason, retryable: false))
        onFrame = { _ in }
        onStatus = { _ in }
    }

    private func onInnerStatus(_ s: CarrierStatus) {
        if closed { return }
        if s.isOpen {
            attempt = 0
            retry?.cancel()
            retry = nil
            beginHandshake()
            return
        }
        // A Noise session cannot survive a gap: its keys belong to one
        // handshake and its counters to one stream. So a drop restarts.
        resetSession()
        retry?.cancel()
        retry = nil
        setStatus(s)
    }

    private func beginHandshake() {
        if closed || awaitingReply || transport != nil { return }
        // A fresh handshake per connection. Reusing one would mint a second
        // cipher pair from the same chaining key.
        let hs: HandshakeState
        do {
            hs = try HandshakeState.initiator(staticKey: staticKey, remoteStatic: remoteStatic, prologue: prologue)
        } catch {
            fail("the box key is not usable", retryable: false)
            return
        }
        handshake = hs
        awaitingReply = true
        setStatus(.connecting)

        // A refused handshake is answered with silence, so silence needs its
        // own ending or a revoked phone waits forever on an open socket.
        deadline?.cancel()
        let window = foregroundAttempt ? Self.foregroundHandshakeDeadlineMs : Self.handshakeDeadlineMs
        foregroundAttempt = false
        deadline = scheduler.after(window) { [weak self] in
            guard let self, !self.closed, self.awaitingReply else { return }
            self.fail("the box did not answer", retryable: true)
        }

        do {
            inner.send(try hs.writeMessage(payload))
        } catch {
            fail("handshake failed", retryable: true)
        }
    }

    private func onInnerFrame(_ bytes: Bytes) {
        if closed { return }
        if awaitingReply {
            // Only something the right shape is offered to the handshake. A
            // second phone in the house starts its handshake into a running
            // telemetry stream, and those frames are not message 2.
            if bytes.count == Self.message2Bytes { completeHandshake(bytes) }
            return
        }
        guard let transport else { return }
        do {
            let frame = try transport.decrypt(bytes)
            onFrame(frame)
        } catch let e as Noise.NoiseError where Self.foreignFrameErrors.contains(e.code) {
            return
        } catch {
            return
        }
    }

    private func completeHandshake(_ bytes: Bytes) {
        guard let hs = handshake else { return }
        do {
            _ = try hs.readMessage(bytes)
            deadline?.cancel()
            deadline = nil
            transport = NoiseTransport(try hs.split())
            awaitingReply = false
            handshake = nil
            attempt = 0
            setStatus(.open(sinceMs: scheduler.nowMs))
        } catch {
            // On a shared room another phone's frame can match the length by
            // coincidence. A frame that does not open is somebody else's; the
            // deadline ends a handshake that is truly going nowhere.
        }
    }

    private func setStatus(_ s: CarrierStatus) {
        status = s
        onStatus(s)
    }

    /// A retryable failure on a socket that still stands is retried from
    /// here, because nowhere else will: the inner carrier only re-emits open
    /// after a real reconnect.
    private func fail(_ reason: String, retryable: Bool) {
        if closed { return }
        resetSession()
        setStatus(.closed(reason: reason, retryable: retryable))
        guard retryable, inner.status.isOpen else { return }
        retry?.cancel()
        let ceiling = min(Self.handshakeBackoffCapMs, Self.handshakeBackoffBaseMs * pow(2, Double(attempt)))
        attempt = min(attempt + 1, 16)
        retry = scheduler.after(scheduler.random() * ceiling) { [weak self] in
            guard let self else { return }
            self.retry = nil
            self.beginHandshake()
        }
    }

    private func resetSession() {
        deadline?.cancel()
        deadline = nil
        transport?.close()
        transport = nil
        handshake = nil
        awaitingReply = false
    }
}
