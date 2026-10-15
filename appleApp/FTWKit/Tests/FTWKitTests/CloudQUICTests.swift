import Foundation
import Testing
@testable import FTWKit

/// srcfl/ftw `go/protocol/cloudwire/testdata/cloud-quic-vectors.json`,
/// copied unchanged: the QUIC framing's bytes as Go makes them.
struct QUICVectors: Decodable {
    struct Varint: Decodable {
        let value: UInt64
        let hex: String
    }

    struct Message: Decodable {
        let len: Int
        let prefix: String
    }

    struct Target: Decodable {
        let name: String
        let target: String
        let message: String
    }

    let alpn: [String: String]
    let transports: [String]
    let varints: [Varint]
    let messages: [Message]
    let targets: [Target]

    static func load() throws -> QUICVectors {
        guard let url = Bundle.module.url(forResource: "cloud-quic-vectors", withExtension: "json", subdirectory: "Resources") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(QUICVectors.self, from: Data(contentsOf: url))
    }
}

struct QUICFramingTests {
    @Test func theFramingIsGosByteForByte() throws {
        let v = try QUICVectors.load()
        #expect(v.alpn["app"] == CloudWire.alpnApp)
        #expect(v.alpn["app"] == QUICCloudSocket.alpn)
        #expect(v.transports == Contract.cloudTransports)
        for varint in v.varints {
            #expect(QUICFraming.varint(varint.value) == Bytes(hex: varint.hex), "\(varint.value)")
            let read = try #require(QUICFraming.readVarint(Bytes(hex: varint.hex)))
            #expect(read.0 == varint.value && read.1 == varint.hex.count / 2)
        }
        for m in v.messages {
            #expect(QUICFraming.varint(UInt64(m.len)) == Bytes(hex: m.prefix), "\(m.len)")
        }
        let app = try #require(v.targets.first { $0.name == "app" })
        #expect(QUICFraming.message(Bytes(app.target.utf8)) == Bytes(hex: app.message))
        // The phone names the same target the WebSocket's URL does.
        let home = String(app.target.split(separator: "=").last ?? "")
        let url = CloudEndpoint.releaseURL.appending(queryItems: [URLQueryItem(name: "home", value: home)])
        #expect(url.path + "?" + (url.query ?? "") == app.target)
    }

    @Test func aVarintCutShortIsNotRead() {
        #expect(QUICFraming.readVarint([]) == nil)
        #expect(QUICFraming.readVarint([0x40]) == nil)
        #expect(QUICFraming.readVarint([0x80, 0, 0]) == nil)
    }
}

/// A socket the race drives by hand.
@MainActor
final class RaceSocket: WebSocketConnection {
    let kind: String
    let events: WebSocketEvents
    var closed = false
    var sent: [Bytes] = []
    var transportName: String { kind }

    init(kind: String, events: WebSocketEvents) {
        self.kind = kind
        self.events = events
    }

    func send(_ data: Bytes) { sent.append(data) }
    func close() { closed = true }
}

@MainActor
final class RaceRig {
    let scheduler = ManualScheduler()
    var made: [RaceSocket] = []
    let memory = CloudTransportMemory(network: { "" }, defaults: nil)
    var opened = 0
    var closes: [Int] = []
    var received: [Bytes] = []

    lazy var factory: WebSocketFactory = CloudSockets.racing(
        quic: { [unowned self] _, events in self.make(Contract.transportQUIC, events) },
        webSocket: { [unowned self] _, events in self.make(Contract.transportWebSocket, events) },
        scheduler: scheduler, memory: memory)

    func make(_ kind: String, _ events: WebSocketEvents) -> RaceSocket {
        let s = RaceSocket(kind: kind, events: events)
        made.append(s)
        return s
    }

    func dial() -> WebSocketConnection {
        factory(URL(string: "wss://cloud.test/v1/app?home=x")!, WebSocketEvents(
            onOpen: { [unowned self] in self.opened += 1 },
            onText: { _ in },
            onBinary: { [unowned self] in self.received.append($0) },
            onClose: { [unowned self] code, _ in self.closes.append(code) }))
    }

    func socket(_ kind: String) -> RaceSocket? { made.last { $0.kind == kind } }
}

@MainActor
struct CloudSocketRaceTests {
    @Test func quicThatOpensInItsLeadIsTheOnlyDial() throws {
        let rig = RaceRig()
        let conn = rig.dial()
        #expect(rig.made.map(\.kind) == [Contract.transportQUIC])
        rig.scheduler.advance(100)
        rig.socket(Contract.transportQUIC)!.events.onOpen()
        rig.scheduler.advance(1_000)
        #expect(rig.made.count == 1)
        #expect(rig.opened == 1)
        #expect(conn.transportName == Contract.transportQUIC)
        conn.send([1, 2])
        #expect(rig.socket(Contract.transportQUIC)!.sent == [[1, 2]])
    }

    @Test func aSilentQUICGivesTheWebSocketItsTurnAfter250ms() throws {
        let rig = RaceRig()
        let conn = rig.dial()
        rig.scheduler.advance(249)
        #expect(rig.made.count == 1)
        rig.scheduler.advance(1)
        #expect(rig.made.map(\.kind) == [Contract.transportQUIC, Contract.transportWebSocket])
        rig.socket(Contract.transportWebSocket)!.events.onOpen()
        #expect(conn.transportName == Contract.transportWebSocket)
        // The QUIC dial goes on a while, only to learn about UDP here, and
        // is closed after.
        #expect(!rig.socket(Contract.transportQUIC)!.closed)
        rig.scheduler.advance(CloudSockets.learnMs)
        #expect(rig.socket(Contract.transportQUIC)!.closed, "the loser is closed")
        // A late QUIC open or message changes nothing.
        rig.socket(Contract.transportQUIC)!.events.onOpen()
        rig.socket(Contract.transportQUIC)!.events.onBinary([9])
        #expect(rig.opened == 1 && rig.received.isEmpty)
        rig.socket(Contract.transportWebSocket)!.events.onBinary([7])
        #expect(rig.received == [[7]])

        // The next dial on this network starts with the winner, and QUIC
        // still gets the same lead.
        let again = rig.dial()
        #expect(rig.made.last?.kind == Contract.transportWebSocket)
        rig.scheduler.advance(250)
        #expect(rig.made.last?.kind == Contract.transportQUIC)
        again.close()
    }

    /// One unlucky QUIC handshake loses to the WebSocket, then opens: the
    /// session stays on the WebSocket, and QUIC goes first next time.
    @Test func aLateQUICTeachesThatUDPGetsThrough() {
        let rig = RaceRig()
        let conn = rig.dial()
        rig.scheduler.advance(250)
        rig.socket(Contract.transportWebSocket)!.events.onOpen()
        rig.scheduler.advance(400)
        rig.socket(Contract.transportQUIC)!.events.onOpen()
        #expect(conn.transportName == Contract.transportWebSocket)
        #expect(rig.socket(Contract.transportQUIC)!.closed)
        let next = rig.dial()
        #expect(rig.made.last?.kind == Contract.transportQUIC, "QUIC goes first again")
        next.close()
        conn.close()
    }

    @Test func aRefusedQUICStartsTheWebSocketAtOnce() {
        let rig = RaceRig()
        let conn = rig.dial()
        rig.socket(Contract.transportQUIC)!.events.onClose(1006, "")
        #expect(rig.made.map(\.kind) == [Contract.transportQUIC, Contract.transportWebSocket])
        #expect(rig.closes.isEmpty, "one transport failing is not the end")
        rig.socket(Contract.transportWebSocket)!.events.onClose(1006, "")
        #expect(rig.closes == [1006])
        conn.close()
    }

    @Test func theWinnersCloseIsTheSessionsClose() {
        let rig = RaceRig()
        let conn = rig.dial()
        rig.socket(Contract.transportQUIC)!.events.onOpen()
        rig.socket(Contract.transportQUIC)!.events.onClose(CloudWire.closeDenied, "")
        #expect(rig.closes == [CloudWire.closeDenied])
        conn.close()
    }

    @Test func eachNetworkRemembersItsOwnWinnerForADay() {
        var here = "wifi"
        var now: Double = 1_790_000_000_000
        let memory = CloudTransportMemory(network: { here }, now: { now }, defaults: nil)
        memory.remember(Contract.transportWebSocket)
        #expect(memory.first() == Contract.transportWebSocket)
        here = "cellular"
        #expect(memory.first() == Contract.transportQUIC)
        here = "wifi"
        now += CloudTransportMemory.holdsMs
        #expect(memory.first() == Contract.transportQUIC, "a day on, QUIC goes first again")
    }

    @Test func noNetworkNameIsKeptInTheClear() {
        let defaults = UserDefaults(suiteName: "ftw-quic-test-\(UUID().uuidString)")!
        let memory = CloudTransportMemory(network: { "wifi,192.168.1.1" }, defaults: defaults)
        memory.remember(Contract.transportQUIC)
        let kept = defaults.dictionary(forKey: CloudTransportMemory.key) ?? [:]
        #expect(kept.count == 1)
        #expect(!kept.keys.contains { $0.contains("192.168") })
    }
}

@MainActor
struct CloudCarrierOverQUICTests {
    /// Over QUIC a datagram can come after many newer messages, past the
    /// Noise window. It is old news: the carrier drops it and the session
    /// goes on, where a broken message still ends it.
    @Test func aMessagePastTheWindowIsDroppedAndTheSessionGoesOn() async throws {
        let rig = try CloudRig()
        rig.carrier.start()
        await rig.run(50)
        let socket = try #require(rig.service.current)
        let transport = try #require(socket.transport)
        let hb = try rig.box.hb(rig.at, age: 900, liveSeq: 1)
        let frame = try CloudWire.encodeFrame(hb.encode())
        let late = try transport.encrypt(frame)
        for _ in 0..<70 { socket.deliver(try transport.encrypt(frame)) }
        socket.deliver(late)
        await rig.run(30)
        #expect(rig.carrier.status.isOpen, "a late message closed the session")
        #expect(rig.envelopes.count == 70)

        socket.deliver([0, 1, 2, 3])
        await rig.run(30)
        #expect(!rig.carrier.status.isOpen, "a broken message must still end it")
    }

    /// The session says how it travels: here the fake's WebSocket.
    @Test func theCarrierSaysItsTransport() async throws {
        let rig = try CloudRig()
        #expect(rig.carrier.transportName == nil)
        rig.carrier.start()
        await rig.run(50)
        #expect(rig.carrier.transportName == Contract.transportWebSocket)
    }
}
