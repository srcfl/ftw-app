import CryptoKit
import Foundation

/// The race for FTW Cloud's socket (srcfl/ftw `docs/protocol-cloud.md`,
/// "Racing the WebSocket"): QUIC starts first; after 250 ms without it open,
/// the WebSocket starts too, and the first to open carries the session. The
/// winner on each network goes first next time, and the other still gets
/// its 250 ms. Where UDP is blocked the session waits a quarter of a second
/// longer than it would on the WebSocket alone, and only the first time. A
/// QUIC session that fails soon after it opened demotes QUIC on that network
/// for a day.
@MainActor
public final class CloudTransportMemory {
    /// The network the phone is on now: its interfaces and gateways.
    private let network: @MainActor () -> String
    private let now: @MainActor () -> Double
    private let defaults: UserDefaults?
    /// Network, as a hash, to the winner ("t"), when it won ("at") and
    /// whether QUIC was demoted there ("d").
    private var winners: [String: [String: Any]] = [:]
    static let key = "ftw.cloud.transports"
    /// A winner holds for a day, so a network that blocked UDP once gets
    /// QUIC first again.
    static let holdsMs: Double = 24 * 3600 * 1000

    public init(network: @escaping @MainActor () -> String = { "" }, now: @escaping @MainActor () -> Double = { Date().timeIntervalSince1970 * 1000 },
                defaults: UserDefaults? = .standard) {
        self.network = network
        self.now = now
        self.defaults = defaults
        winners = defaults?.dictionary(forKey: Self.key) as? [String: [String: Any]] ?? [:]
    }

    /// The transport to start with on this network: QUIC unless the
    /// WebSocket won here within the last day.
    func first() -> String {
        guard let w = winners[here()], let t = w["t"] as? String, let at = w["at"] as? Double, now() - at < Self.holdsMs else {
            return Contract.transportQUIC
        }
        return t == Contract.transportWebSocket ? Contract.transportWebSocket : Contract.transportQUIC
    }

    /// The winner on this network. While QUIC is demoted here, a QUIC win
    /// does not move it first.
    func remember(_ transport: String) {
        let key = here()
        if transport == Contract.transportQUIC, let w = winners[key], w["d"] as? Bool == true,
           let at = w["at"] as? Double, now() - at < Self.holdsMs {
            return
        }
        store(key, ["t": transport, "at": now()])
    }

    /// QUIC failed here after its handshake: the WebSocket goes first for a
    /// day, whatever a QUIC dial wins meanwhile.
    func demote() {
        store(here(), ["t": Contract.transportWebSocket, "at": now(), "d": true])
    }

    /// Whether QUIC is demoted on this network now.
    func demoted() -> Bool {
        guard let w = winners[here()], w["d"] as? Bool == true, let at = w["at"] as? Double else { return false }
        return now() - at < Self.holdsMs
    }

    /// Writes one entry and drops those past a day, so the list holds only
    /// the networks of the last day.
    private func store(_ key: String, _ entry: [String: Any]) {
        let cutoff = now() - Self.holdsMs
        winners = winners.filter { ($0.value["at"] as? Double ?? 0) > cutoff }
        winners[key] = entry
        defaults?.set(winners, forKey: Self.key)
    }

    /// The network's name as a hash, so no gateway address is kept.
    private func here() -> String {
        SHA256.hash(data: Data(network().utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
public enum CloudSockets {
    /// QUIC's lead over the WebSocket.
    public static let raceDelayMs: Double = 250
    /// How long a QUIC dial that lost may go on, only to learn whether UDP
    /// gets through here: one lost packet should not keep QUIC second for a
    /// day.
    public static let learnMs: Double = 3_000
    /// How long a QUIC session must last past its first message before the
    /// path dropping it stops counting as QUIC failing here. The same as
    /// cloudwire.QUICProvenAfter.
    public static let provenAfterMs: Double = 60_000

    /// Whether a QUIC session that ended with code counts as QUIC failing on
    /// its network: it ended before its first message, or within
    /// `provenAfterMs` of it, and not by a close the service sent on purpose,
    /// a code from 1000 up other than 1005 and 1006, which mean none.
    static func quicFailed(code: Int, firstMessageAtMs: Double?, nowMs: Double) -> Bool {
        if (1000...4999).contains(code), code != 1005, code != 1006 { return false }
        guard let first = firstMessageAtMs else { return true }
        return nowMs - first < provenAfterMs
    }

    /// A socket factory that races QUIC against the WebSocket.
    public static func racing(quic: @escaping WebSocketFactory, webSocket: @escaping WebSocketFactory,
                              scheduler: Scheduler, memory: CloudTransportMemory) -> WebSocketFactory {
        { url, events in RacingCloudSocket(url: url, events: events, quic: quic, webSocket: webSocket, scheduler: scheduler, memory: memory) }
    }
}

/// One race: two sockets until one opens, then that one.
@MainActor
final class RacingCloudSocket: WebSocketConnection {
    private let url: URL
    private let events: WebSocketEvents
    private let makers: [String: WebSocketFactory]
    private let memory: CloudTransportMemory
    private var order: [String]
    private var sockets: [String: WebSocketConnection] = [:]
    private var failed: Set<String> = []
    private var winner: String?
    private var lead: Cancellable?
    private var learning: Cancellable?
    private var closed = false
    /// When the winner's first message came, for `quicFailed`.
    private var firstMessageAtMs: Double?

    var transportName: String { winner ?? order[0] }

    private let scheduler: Scheduler

    init(url: URL, events: WebSocketEvents, quic: @escaping WebSocketFactory, webSocket: @escaping WebSocketFactory,
         scheduler: Scheduler, memory: CloudTransportMemory) {
        self.scheduler = scheduler
        self.url = url
        self.events = events
        self.makers = [Contract.transportQUIC: quic, Contract.transportWebSocket: webSocket]
        self.memory = memory
        let first = memory.first()
        order = [first, first == Contract.transportQUIC ? Contract.transportWebSocket : Contract.transportQUIC]
        start(order[0])
        lead = scheduler.after(CloudSockets.raceDelayMs) { [weak self] in self?.startSecond() }
    }

    func send(_ data: Bytes) {
        guard let winner else { return }
        sockets[winner]?.send(data)
    }

    func close() {
        guard !closed else { return }
        closed = true
        lead?.cancel()
        learning?.cancel()
        for s in sockets.values { s.close() }
        sockets = [:]
    }

    private func startSecond() {
        lead = nil
        guard !closed, winner == nil, sockets[order[1]] == nil, !failed.contains(order[1]) else { return }
        start(order[1])
    }

    private func start(_ transport: String) {
        guard let make = makers[transport] else { return }
        let socket = make(url, WebSocketEvents(
            onOpen: { [weak self] in
                guard let self else { return }
                if self.winner == nil { self.opened(transport) } else if transport != self.winner { self.learned(transport) }
            },
            onText: { [weak self] text in
                guard let self, self.winner == transport else { return }
                self.events.onText(text)
            },
            onBinary: { [weak self] bytes in
                guard let self, self.winner == transport else { return }
                self.heard()
                self.events.onBinary(bytes)
            },
            onClose: { [weak self] code, reason in self?.ended(transport, code, reason) },
            onDatagram: { [weak self] bytes in
                guard let self, self.winner == transport else { return }
                self.heard()
                if let onDatagram = self.events.onDatagram { onDatagram(bytes) } else { self.events.onBinary(bytes) }
            }
        ))
        sockets[transport] = socket
    }

    private func opened(_ transport: String) {
        guard !closed, winner == nil else { return }
        winner = transport
        lead?.cancel()
        lead = nil
        memory.remember(transport)
        // A QUIC dial still under way when the WebSocket opened goes on for
        // a while, only to learn whether UDP gets through here.
        if transport == Contract.transportWebSocket, let quic = sockets[Contract.transportQUIC] {
            learning = scheduler.after(CloudSockets.learnMs) { [weak self] in
                quic.close()
                self?.sockets[Contract.transportQUIC] = nil
            }
        }
        for (t, s) in sockets where t != transport && t != Contract.transportQUIC { s.close() }
        if transport == Contract.transportQUIC, let ws = sockets[Contract.transportWebSocket] { ws.close() }
        sockets = sockets.filter { $0.key == transport || (transport == Contract.transportWebSocket && $0.key == Contract.transportQUIC) }
        events.onOpen()
    }

    /// The losing QUIC dial opened after all: UDP gets through here, so QUIC
    /// goes first next time. This session stays where it is.
    private func learned(_ transport: String) {
        guard transport == Contract.transportQUIC, sockets[transport] != nil else { return }
        memory.remember(transport)
        learning?.cancel()
        sockets[transport]?.close()
        sockets[transport] = nil
    }

    private func heard() {
        if firstMessageAtMs == nil { firstMessageAtMs = scheduler.nowMs }
    }

    private func ended(_ transport: String, _ code: Int, _ reason: String) {
        guard !closed else { return }
        if winner == transport {
            if transport == Contract.transportQUIC,
               CloudSockets.quicFailed(code: code, firstMessageAtMs: firstMessageAtMs, nowMs: scheduler.nowMs) {
                memory.demote()
            }
            closed = true
            events.onClose(code, reason)
            return
        }
        guard winner == nil else {
            // The learning dial failed: the WebSocket stays first here.
            sockets[transport] = nil
            return
        }
        failed.insert(transport)
        sockets[transport] = nil
        if failed.count == order.count {
            closed = true
            lead?.cancel()
            events.onClose(code, reason)
        } else if transport == order[0] {
            // QUIC refused outright: no reason to wait out its lead.
            lead?.cancel()
            startSecond()
        }
    }
}
