import Foundation

/// One request to FTW Cloud in one HTTPS POST: what a watch can do with
/// HTTPS and nothing lower (srcfl/ftw `docs/protocol-cloud.md`, "One-shot
/// read" and "Exchange").
///
/// The body is Noise IK message 1 to a service key, carrying one unsigned
/// envelope. The answer is message 2 and, for a read, the envelopes that did
/// not fit, each after its length as u16 big endian. The service keeps no
/// state after it, and neither does this: each request is its own handshake.
public enum CloudOnce {
    public static let path = "/v1/app/once"
    public static let prologueTag = Bytes("ftw.cloud.once.v1:".utf8)
    public static let contentType = "application/octet-stream"
    /// The service names the instance that holds a home with 421 and this
    /// header; the request goes there once.
    public static let shardHeader = "Ftw-Shard"
    public static let wrongShard = 421

    public static let msgRead = "read"
    public static let msgX = "x"

    /// The address of one home's one-shot request, beside the endpoint's
    /// app session: same host, HTTPS.
    public static func url(_ endpoint: CloudEndpoint, home: String, host: String? = nil) -> URL {
        var c = URLComponents(url: endpoint.url, resolvingAgainstBaseURL: false)!
        c.scheme = c.scheme == "ws" ? "http" : "https"
        if let host { c.host = host }
        c.path = path
        c.queryItems = [URLQueryItem(name: "home", value: home)]
        return c.url!
    }

    public static func prologue(home: String) -> Bytes { prologueTag + Bytes(home.utf8) }

    /// `read {have, hz}` with nothing held: the newest of each class. A
    /// snapshot is a few kilobytes, and a watch that reads only when it
    /// comes on screen gains little by naming what it holds.
    public static func read(looking: Bool) -> Bytes {
        CloudWire.encodeUnsigned(t: msgRead, body: .map([
            ("have", .map([(String, CBOR)]())),
            ("hz", .int(looking ? CloudWire.hzLooking : CloudWire.hzAway)),
        ]))
    }

    /// `x {d}`: one exchange message for the box.
    public static func x(_ d: Bytes) -> Bytes {
        CloudWire.encodeUnsigned(t: msgX, body: .map([("d", .bytes(d))]))
    }

    /// A request on its way: message 1 and the handshake that reads the
    /// answer.
    public struct Request {
        public let body: Bytes
        let handshake: HandshakeState

        /// Message 1 to `serviceKey` for `home`, carrying `payload`.
        public init(home: String, serviceKey: Bytes, staticKey: Primitives.KeyPair, payload: Bytes, ephemeral: Primitives.KeyPair? = nil) throws {
            handshake = try HandshakeState.initiator(staticKey: staticKey, remoteStatic: serviceKey, prologue: CloudOnce.prologue(home: home), ephemeral: ephemeral)
            body = try handshake.writeMessage(payload)
        }

        /// Message 2's payload, and the frames that followed it opened.
        public func answer(_ body: Bytes) throws -> (payload: Bytes, following: [Bytes]) {
            let parts = try CloudOnce.split(body)
            let payload = try handshake.readMessage(parts[0])
            guard parts.count > 1 else { return (payload, []) }
            let transport = NoiseTransport(try handshake.split())
            let following = try parts.dropFirst().map { try CloudWire.decodeFrame(try transport.decrypt($0)) }
            return (payload, following)
        }
    }

    /// A read's answer: message 2's snapshot with the envelopes that
    /// followed it, in the order the box sent them.
    public static func snapshot(payload: Bytes, following: [Bytes]) throws -> CloudWire.Snapshot {
        var snap = try CloudWire.parseSnapshot(payload: payload)
        snap.envelopes += try following.map { try CloudWire.Envelope.decode($0) }
        return snap
    }

    /// The box's exchange answer in message 2. Empty when none came: the box
    /// is away, kept silent, or did not answer in time.
    public static func xAnswer(payload: Bytes) throws -> Bytes {
        let env = try CloudWire.Envelope.decode(payload)
        guard env.t == msgX, env.sig.isEmpty, let d = try decodeCBOR(env.b)["d"]?.byteString else {
            throw CloudWire.WireError(code: "E_CLOUD_BODY", message: "message 2 is not an x")
        }
        return d
    }

    /// Message 2 and what follows, each after its length as u16 big endian.
    static func split(_ body: Bytes) throws -> [Bytes] {
        var out = [Bytes]()
        var i = 0
        while i < body.count {
            guard i + 2 <= body.count else { throw splitError("a length cut short") }
            let n = Int(body[i]) << 8 | Int(body[i + 1])
            guard i + 2 + n <= body.count else { throw splitError("a \(n)-byte message overruns the body") }
            out.append(Array(body[(i + 2)..<(i + 2 + n)]))
            i += 2 + n
        }
        guard !out.isEmpty else { throw splitError("an empty answer") }
        return out
    }

    private static func splitError(_ why: String) -> CloudWire.WireError {
        CloudWire.WireError(code: "E_CLOUD_FRAME", message: why)
    }
}
