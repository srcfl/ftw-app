import Foundation

/// The race for FTW Cloud's socket (srcfl/ftw `docs/protocol-cloud.md`,
/// "Racing the WebSocket"): QUIC starts first; after 250 ms without it open,
/// the WebSocket starts too, and the first to open carries the session. The
/// winner on each network goes first next time, and the other still gets
/// its 250 ms. Where UDP is blocked the session waits a quarter of a second
/// longer than it would on the WebSocket alone, and only the first time.
@MainActor
public final class CloudTransportMemory {
    /// The network the phone is on now: its interfaces and gateways.
    private let network: @MainActor () -> String
    private let defaults: UserDefaults?
    private var winners: [String: String] = [:]
    static let key = "ftw.cloud.transports"

    public init(network: @escaping @MainActor () -> String = { "" }, defaults: UserDefaults? = .standard) {
        self.network = network
        self.defaults = defaults
        winners = defaults?.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }

    /// The transport to start with on this network: QUIC unless the
    /// WebSocket won here last.
    func first() -> String {
        winners[network()] == Contract.transportWebSocket ? Contract.transportWebSocket : Contract.transportQUIC
    }

    func remember(_ transport: String) {
        let here = network()
        guard winners[here] != transport else { return }
        winners[here] = transport
        defaults?.set(winners, forKey: Self.key)
    }
}

@MainActor
public enum CloudSockets {
    /// QUIC's lead over the WebSocket.
    public static let raceDelayMs: Double = 250

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
    private var closed = false

    var transportName: String { winner ?? order[0] }

    init(url: URL, events: WebSocketEvents, quic: @escaping WebSocketFactory, webSocket: @escaping WebSocketFactory,
         scheduler: Scheduler, memory: CloudTransportMemory) {
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
            onOpen: { [weak self] in self?.opened(transport) },
            onText: { [weak self] text in
                guard let self, self.winner == transport else { return }
                self.events.onText(text)
            },
            onBinary: { [weak self] bytes in
                guard let self, self.winner == transport else { return }
                self.events.onBinary(bytes)
            },
            onClose: { [weak self] code, reason in self?.ended(transport, code, reason) }
        ))
        sockets[transport] = socket
    }

    private func opened(_ transport: String) {
        guard !closed, winner == nil else { return }
        winner = transport
        lead?.cancel()
        lead = nil
        for (t, s) in sockets where t != transport { s.close() }
        sockets = sockets.filter { $0.key == transport }
        memory.remember(transport)
        events.onOpen()
    }

    private func ended(_ transport: String, _ code: Int, _ reason: String) {
        guard !closed else { return }
        if winner == transport {
            closed = true
            events.onClose(code, reason)
            return
        }
        guard winner == nil else { return }
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
