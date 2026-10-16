import Foundation
import Network
import Security

/// The phone's FTW Cloud socket over QUIC (srcfl/ftw `docs/protocol-cloud.md`,
/// "QUIC"). The WebSocket's messages go on a control stream that starts with
/// the target; the box's bulk comes on a stream the service opens; the
/// readable copy's `hb` and `live` may come as datagrams. It is one
/// `WebSocketConnection`, so `CloudCarrier` runs on it unchanged, and the
/// Noise session inside does not know which transport carries it.
///
/// A QUIC connection follows the phone from Wi-Fi to cellular without a new
/// handshake. A keepalive every 15 s holds the mapping in a NAT, and 45 s of
/// silence ends the connection, as the service's ping does for a WebSocket.
@MainActor
public final class QUICCloudSocket: WebSocketConnection {
    public nonisolated static let alpn = CloudWire.alpnApp
    nonisolated static let keepAliveSeconds = 15
    nonisolated static let idleTimeoutMs = 45_000
    /// The largest message the service sends a phone: a tun around the
    /// box's largest bulk frame, in a Noise message.
    nonisolated static let maxMessage = 1 << 20

    public var transportName: String { Contract.transportQUIC }

    private let events: WebSocketEvents
    private var task: Task<Void, Never>?
    private var outbox: AsyncStream<Bytes>.Continuation?
    private var opened = false
    private var closed = false

    public static func factory(anchor: SecCertificate? = nil) -> WebSocketFactory {
        { url, events in QUICCloudSocket(url: url, events: events, anchor: anchor) }
    }

    /// `url` is the WebSocket's: QUIC goes to the same host and port over
    /// UDP, and its path and query are the target. `anchor` trusts one root
    /// and nothing else, for tests against a local service.
    public init(url: URL, events: WebSocketEvents, anchor: SecCertificate? = nil) {
        self.events = events
        guard let host = url.host, let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 443)) else {
            closed = true
            Task { @MainActor in events.onClose(1006, "") }
            return
        }
        var target = url.path
        if let query = url.query { target += "?" + query }
        let (stream, outbox) = AsyncStream<Bytes>.makeStream(bufferingPolicy: .unbounded)
        self.outbox = outbox
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: port)
        task = Task { [weak self] in
            let code = await Self.run(endpoint: endpoint, target: Array(target.utf8), anchor: anchor, outbox: stream,
                                      opened: { self?.didOpen() }, received: { self?.didReceive($0) },
                                      datagram: { self?.didReceiveDatagram($0) })
            self?.didClose(code)
        }
    }

    public func send(_ data: Bytes) {
        guard !closed else { return }
        outbox?.yield(data)
    }

    public func close() {
        guard !closed else { return }
        closed = true
        outbox?.finish()
        task?.cancel()
        task = nil
    }

    private func didOpen() {
        guard !closed, !opened else { return }
        opened = true
        events.onOpen()
    }

    private func didReceive(_ bytes: Bytes) {
        guard !closed, opened else { return }
        events.onBinary(bytes)
    }

    private func didReceiveDatagram(_ bytes: Bytes) {
        guard !closed, opened else { return }
        if let onDatagram = events.onDatagram { onDatagram(bytes) } else { events.onBinary(bytes) }
    }

    private func didClose(_ code: Int) {
        guard !closed else { return }
        closed = true
        outbox?.finish()
        events.onClose(code, "")
    }

    // MARK: The connection

    /// Runs one connection until it ends and returns the close code: the
    /// service's application error, or 1006 when the path just went.
    nonisolated private static func run(
        endpoint: NWEndpoint, target: Bytes, anchor: SecCertificate?, outbox: AsyncStream<Bytes>,
        opened: @escaping @MainActor () -> Void, received: @escaping @MainActor (Bytes) -> Void,
        datagram: @escaping @MainActor (Bytes) -> Void
    ) async -> Int {
        let connection = NetworkConnection(to: endpoint) {
            QUIC(alpn: [alpn])
                .idleTimeout(idleTimeoutMs)
                .maxDatagramFrameSize(65_535)
                .initialMaxUnidirectionalStreams(1)
                .tls.certificateValidator { _, trust in
                    guard let anchor else { return Self.systemTrust(trust) }
                    return Self.pinned(trust, anchor)
                }
        }
        connection.keepalive = .seconds(keepAliveSeconds)
        do {
            let control = try await connection.openStream()
            try await control.send(Data(QUICFraming.message(target)))
            await opened()
            // The control stream and the writer carry the session; the bulk
            // streams and the datagrams only add to it, so their end, as
            // against a service that offers none, ends nothing.
            try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    for await msg in outbox {
                        try await control.send(Data(QUICFraming.message(msg)))
                    }
                    return true
                }
                group.addTask {
                    while true {
                        let msg = try await QUICFraming.read(control, max: maxMessage)
                        await received(msg)
                    }
                }
                group.addTask {
                    try? await connection.inboundStreams { stream in
                        while true {
                            let msg = try await QUICFraming.read(stream, max: maxMessage)
                            await received(msg)
                        }
                    }
                    return false
                }
                group.addTask {
                    guard let datagrams = try? await connection.datagrams else { return false }
                    while let d = try? await datagrams.receive() {
                        await datagram(Bytes(d.content))
                    }
                    return false
                }
                while let carries = try await group.next() {
                    if carries { break }
                }
                group.cancelAll()
            }
        } catch {}
        // The service's close code, as the WebSocket's would be. Network
        // reports none as zero or as all ones.
        let code = connection.applicationError.code
        return code == 0 || code > 0xffff ? 1006 : Int(code)
    }

    nonisolated private static func systemTrust(_ trust: sec_trust_t) -> Bool {
        let ref = sec_trust_copy_ref(trust).takeRetainedValue()
        return SecTrustEvaluateWithError(ref, nil)
    }

    nonisolated private static func pinned(_ trust: sec_trust_t, _ anchor: SecCertificate) -> Bool {
        let ref = sec_trust_copy_ref(trust).takeRetainedValue()
        SecTrustSetAnchorCertificates(ref, [anchor] as CFArray)
        SecTrustSetAnchorCertificatesOnly(ref, true)
        return SecTrustEvaluateWithError(ref, nil)
    }
}

/// The QUIC framing: one message is its length as a QUIC variable-length
/// integer (RFC 9000 §16), then its bytes. `cloud-quic-vectors.json` holds
/// the bytes.
public enum QUICFraming {
    public static func varint(_ value: UInt64) -> Bytes {
        switch value {
        case ..<(1 << 6): return [UInt8(value)]
        case ..<(1 << 14): return [0x40 | UInt8(value >> 8), UInt8(value & 0xff)]
        case ..<(1 << 30): return [0x80 | UInt8(value >> 24), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
        default:
            return [0xc0 | UInt8((value >> 56) & 0x3f), UInt8((value >> 48) & 0xff), UInt8((value >> 40) & 0xff), UInt8((value >> 32) & 0xff),
                    UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
        }
    }

    public static func message(_ bytes: Bytes) -> Bytes { varint(UInt64(bytes.count)) + bytes }

    /// Reads a varint from the front of `bytes`: the value and how many
    /// bytes it took, or nil when `bytes` holds less than one whole varint.
    public static func readVarint(_ bytes: Bytes) -> (UInt64, Int)? {
        guard let first = bytes.first else { return nil }
        let n = 1 << Int(first >> 6)
        guard bytes.count >= n else { return nil }
        var v = UInt64(first & 0x3f)
        for b in bytes[1..<n] { v = v << 8 | UInt64(b) }
        return (v, n)
    }

    struct TooLarge: Error {}
    struct Ended: Error {}

    /// One message from a stream. Throws at the end of the stream, and on a
    /// length over `max`.
    nonisolated static func read(_ stream: QUIC.Stream<QUICStream>, max: Int) async throws -> Bytes {
        let head = try await exactly(1, from: stream)
        let n = 1 << Int(head[0] >> 6)
        let rest = n > 1 ? try await exactly(n - 1, from: stream) : []
        guard let (length, _) = readVarint(head + rest) else { throw TooLarge() }
        guard length <= UInt64(max) else { throw TooLarge() }
        return length == 0 ? [] : try await exactly(Int(length), from: stream)
    }

    /// Exactly `n` bytes, or `Ended` when the stream ends first.
    nonisolated private static func exactly(_ n: Int, from stream: QUIC.Stream<QUICStream>) async throws -> Bytes {
        let got = Bytes(try await stream.receive(exactly: n).content)
        guard got.count == n else { throw Ended() }
        return got
    }
}
