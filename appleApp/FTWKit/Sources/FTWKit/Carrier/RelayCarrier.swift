import Foundation

/// A WebSocket to Sourceful's blind relay, wrapped so nothing above it ever
/// learns the network went away. There is no reconnect button in this app
/// and nowhere to put one: a lost connection is this file's problem, and
/// the person sees only the freshness stamp slipping while it is solved.
///
/// Frames are never queued across a reconnect: an old instruction arriving
/// as if new is what `notValidAfterMs` exists to prevent, so sending on a
/// carrier that is not open drops the frame. The session re-handshakes and
/// asks again.
///
/// The socket outlives the peer. When the box drops off the relay the socket
/// stays up and the carrier reports closed, then open again the moment the
/// relay says the box is back: an hour offline costs one connection.
@MainActor
public final class RelayCarrier: Carrier {
    public static let closeBadJoin = 4400
    public static let closeEpoch = 4409
    public static let closeRotated = 4410
    public static let closeBusy = 4429
    static let ctrlReady = "ready"
    static let ctrlGone = "gone"

    static let backoffBaseMs: Double = 500
    static let backoffCapMs: Double = 60_000
    /// Rejoin spread after a rotation, so the old handle and the new one are
    /// hard to line up by timing alone.
    static let rotateJitterMs: Double = 3_000
    static let correctionLimit = 2
    /// How far the relay may move our epoch. One hour covers a drifting
    /// clock; it does not cover a relay steering us onto handles it chose.
    static let maxEpochCorrection: Int64 = 1

    public let kind: CarrierKind = .relay
    public private(set) var status: CarrierStatus = .connecting

    private let url: URL
    private let secret: Bytes
    private let scheduler: Scheduler
    private let makeSocket: WebSocketFactory

    private var socket: WebSocketConnection?
    private var socketGeneration = 0
    private var dialledAtMs: Double = 0
    private var attempt = 0
    private var corrections = 0
    /// Epochs between the relay's clock and ours, learned from a correction.
    private var epochOffset: Int64 = 0
    private var retry: Cancellable?
    private var shutdown = false
    public private(set) var rttMs: Double?

    private var onFrame: @MainActor (Bytes) -> Void = { _ in }
    private var onStatus: @MainActor (CarrierStatus) -> Void = { _ in }

    public init(url: URL = Origin.relayURL, secret: Bytes, scheduler: Scheduler, makeSocket: @escaping WebSocketFactory = URLSessionWebSocket.factory()) {
        self.url = url
        self.secret = secret
        self.scheduler = scheduler
        self.makeSocket = makeSocket
        dial()
    }

    public func setHandlers(onFrame: @escaping @MainActor (Bytes) -> Void, onStatus: @escaping @MainActor (CarrierStatus) -> Void) {
        self.onFrame = onFrame
        self.onStatus = onStatus
    }

    public func send(_ frame: Bytes) {
        guard status.isOpen, let socket else { return }
        socket.send(frame)
    }

    /// Drop an apparently live socket and dial now, after a foreground wake.
    public func wake() {
        if shutdown { return }
        // A dial started within the last second is kept: the app's own wake
        // and the network's can land together.
        if status == .connecting, socket != nil, scheduler.nowMs - dialledAtMs < 1_000 { return }
        retry?.cancel()
        retry = nil
        attempt = 0
        rttMs = nil
        drop()
        dial()
    }

    /// The network came back: skip whatever backoff is running.
    public func networkAvailable() {
        guard !shutdown, retry != nil else { return }
        retry?.cancel()
        retry = nil
        attempt = 0
        dial()
    }

    public func close(reason: String = "closed by client") {
        if shutdown { return }
        shutdown = true
        retry?.cancel()
        retry = nil
        drop()
        setStatus(.closed(reason: reason, retryable: false))
        onFrame = { _ in }
        onStatus = { _ in }
    }

    private func dial() {
        if shutdown { return }
        let epoch = Rendezvous.epoch(nowMs: scheduler.nowMs) + epochOffset
        guard let handle = try? Rendezvous.handle(secret: secret, epoch: epoch) else {
            setStatus(.closed(reason: "rendezvous secret is missing", retryable: false))
            return
        }
        setStatus(.connecting)
        dialledAtMs = scheduler.nowMs
        socketGeneration += 1
        let generation = socketGeneration
        let target = url.appendingPathComponent("r").appendingPathComponent(String(epoch)).appendingPathComponent(handle).appendingPathComponent("app")
        socket = makeSocket(target, WebSocketEvents(
            onOpen: { [weak self] in
                guard let self, generation == self.socketGeneration else { return }
                self.rttMs = self.scheduler.nowMs - self.dialledAtMs
            },
            onText: { [weak self] text in
                guard let self, generation == self.socketGeneration else { return }
                self.onText(text)
            },
            onBinary: { [weak self] bytes in
                guard let self, generation == self.socketGeneration else { return }
                self.onBinary(bytes)
            },
            onClose: { [weak self] code, reason in
                guard let self, generation == self.socketGeneration else { return }
                self.onClose(code: code, reason: reason)
            }
        ))
    }

    private func onText(_ text: String) {
        if text == Self.ctrlReady {
            corrections = 0
            setStatus(.open(sinceMs: scheduler.nowMs))
        } else if text == Self.ctrlGone {
            // The box left. Keep the socket; the relay says when it is back.
            setStatus(.closed(reason: "box offline", retryable: true))
        }
    }

    private func onBinary(_ bytes: Bytes) {
        guard status.isOpen else { return }
        // Only a delivered frame proves the path works, so this is where the
        // dial backoff resets.
        attempt = 0
        onFrame(bytes)
    }

    private func onClose(code: Int, reason: String) {
        if shutdown { return }
        socket = nil
        socketGeneration += 1
        rttMs = nil

        let delayMs: Double
        switch code {
        case Self.closeRotated:
            adoptEpoch(reason)
            delayMs = scheduler.random() * Self.rotateJitterMs
        case Self.closeEpoch:
            adoptEpoch(reason)
            corrections += 1
            delayMs = corrections > Self.correctionLimit ? backoff() : 0
        default:
            delayMs = backoff()
        }
        setStatus(.closed(reason: Self.closeReason(code), retryable: true))
        schedule(delayMs)
    }

    /// Take the relay's epoch as a clock correction, never as an order. A
    /// relay that could name any epoch could make us publish handles of its
    /// choosing, so only a strict number within one hour of ours is taken.
    private func adoptEpoch(_ announced: String) {
        let trimmed = announced.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.hasPrefix("-") ? trimmed.dropFirst() : Substring(trimmed)
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber), let epoch = Int64(trimmed) else { return }
        let offset = epoch - Rendezvous.epoch(nowMs: scheduler.nowMs)
        guard abs(offset) <= Self.maxEpochCorrection else { return }
        epochOffset = offset
    }

    /// Full jitter: the whole delay is random, so peers never resynchronise.
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
        socketGeneration += 1
        socket?.close()
        socket = nil
    }

    private func setStatus(_ next: CarrierStatus) {
        switch (status, next) {
        case (.connecting, .connecting), (.open, .open):
            return
        case let (.closed(a, _), .closed(b, _)) where a == b:
            return
        default:
            status = next
            onStatus(next)
        }
    }

    static func closeReason(_ code: Int) -> String {
        switch code {
        case closeEpoch, closeRotated: return "rendezvous rotated"
        case closeBusy: return "relay is busy"
        case closeBadJoin: return "relay rejected the join"
        default: return "connection lost"
        }
    }
}
