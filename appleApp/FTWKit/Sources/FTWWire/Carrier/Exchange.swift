import Foundation
import FTWShared

/// A watch's short session with its box: the box's exchange (srcfl/ftw ADR
/// 0009). Noise IK to the box's static key under a prologue of its own, so it
/// never stands in for the phone's stream. Each step is one request and one
/// answer, which FTW Cloud carries as `x`; this type holds neither the
/// carrier nor a clock.
///
/// Every frame is lane 0 in 512 bytes but `hello_ok`, so a read, a command
/// and a refusal have one length. The box keeps the session for four
/// exchanges, a minute without one, or three minutes.
public final class ExchangeSession {
    public static let prologueTag = Bytes("ftw.exchange.v1:".utf8)
    public static let frameBytes = 512
    public static let helloOKBytes = 1024
    /// Message 1 with a lane 0 hello.
    public static let openBytes = Noise.message1Overhead + frameBytes
    /// One transport message with one lane 0 frame.
    public static let requestBytes = NoiseTransport.overhead + frameBytes
    /// Every answer after the handshake carries two frames.
    public static let answerFrames = 2

    /// What the box said in `hello_ok`: its clock, the control revision a
    /// command expects, and what this watch may do.
    public struct Opened: Equatable, Sendable {
        public var uptimeMs: Double
        public var rev: UInt64
        public var role: String
        public var scopes: [String]
    }

    private let handshake: HandshakeState
    private var transport: NoiseTransport?
    public private(set) var opened: Opened?

    public init(boxKey: Bytes, staticKey: Primitives.KeyPair, ephemeral: Primitives.KeyPair? = nil) throws {
        handshake = try HandshakeState.initiator(staticKey: staticKey, remoteStatic: boxKey, prologue: Self.prologueTag + boxKey, ephemeral: ephemeral)
    }

    /// X1's request: message 1 with the watch's hello. A watch its phone
    /// added by key carries no code.
    public func open(build: String) throws -> Bytes {
        // In the box's own order, so the bytes match its vectors.
        let hello = Envelope(t: "hello", b: .map([
            ("app", .map([("ua", .text("watchos")), ("build", .text(build))])),
            ("proto", .map([("max", .int(Proto.max)), ("min", .int(Proto.min))])),
            ("locales", .null),
        ]))
        return try handshake.writeMessage(try Frame.encode(lane: Frame.laneControl, envelope: hello, bucket: Self.frameBytes))
    }

    /// X1's answer: message 2 with `hello_ok`.
    @discardableResult
    public func opened(_ message2: Bytes) throws -> Opened {
        let frame = try Frame.decode(try handshake.readMessage(message2))
        transport = NoiseTransport(try handshake.split())
        guard frame.envelope.t == "hello_ok", let b = frame.envelope.b,
              let uptime = b["clock"]?["uptimeMs"]?.double, let rev = b["rev"]?.int64 else {
            throw Self.error("message 2 carries \(frame.envelope.t), not a hello_ok")
        }
        let o = Opened(uptimeMs: uptime, rev: UInt64(max(0, rev)), role: b["role"]?.string ?? "", scopes: b["scopes"]?.stringArray ?? [])
        opened = o
        return o
    }

    /// One request, `cmd` or `now`, in one lane 0 frame.
    public func request(_ envelope: Envelope) throws -> Bytes {
        try seal(try Frame.encode(lane: Frame.laneControl, envelope: envelope, bucket: Self.frameBytes))
    }

    func seal(_ frame: Bytes) throws -> Bytes {
        guard let transport else { throw Self.error("the session is not open") }
        return try transport.encrypt(frame)
    }

    /// One answer: two transport messages of one length, a frame each.
    public func answer(_ reply: Bytes) throws -> [Envelope] {
        guard let transport else { throw Self.error("the session is not open") }
        guard reply.count == Self.answerFrames * Self.requestBytes else { throw Self.error("an answer of \(reply.count) bytes") }
        return try (0..<Self.answerFrames).map { i in
            try Frame.decode(try transport.decrypt(Array(reply[(i * Self.requestBytes)..<((i + 1) * Self.requestBytes)]))).envelope
        }
    }

    static func error(_ why: String) -> Noise.NoiseError {
        Noise.NoiseError(code: "E_EXCHANGE", message: why)
    }
}

extension ExchangeSession {
    /// The box's `cmd` for a command from the watch, as the phone's car view
    /// sends it, or nil for one the watch may only send through its phone.
    /// Its expiry is in box uptime: `leftMs` of the tap's life, on the
    /// watch's monotonic clock, counted from `hello_ok`, so the box's
    /// deadline falls before the watch's, never after.
    public static func cmd(_ c: WatchCommand, link: WatchLink, opened: Opened, leftMs: Double) -> Envelope? {
        guard leftMs > 0, let args = args(c, link: link) else { return nil }
        return Envelope(t: "cmd", b: .map([
            ("cmdId", .text(c.id)),
            ("op", .text(Contract.opLoadpointHold)),
            ("args", .map(args)),
            ("notValidAfterMs", .ms(opened.uptimeMs + leftMs)),
            ("expect", .map([("rev", .unsigned(opened.rev)), ("guards", .array([]))])),
        ]))
    }

    /// The hold's arguments, or nil when the watch may only send `c`
    /// through its phone: which car is on a charger needs what only an
    /// owner's session holds, Charge now needs the phone's power for that
    /// charger, and the mode changes in Plan on the phone alone.
    public static func args(_ c: WatchCommand, link: WatchLink) -> [(String, CBOR)]? {
        switch c.op {
        case .chargeNow(let id):
            guard let charge = link.chargeNow[id] else { return nil }
            return [("id", .text(id)), ("power_w", .number(charge.powerW)), ("hold_s", .int(0)), ("phase_mode", .text(charge.phaseMode))]
        case .pause(let id):
            return [("id", .text(id)), ("power_w", .int(0)), ("hold_s", .int(0))]
        case .backToPlan(let id):
            return [("id", .text(id)), ("clear", .bool(true))]
        case .mode, .chooseCar:
            return nil
        }
    }

    /// What one answer to a `cmd` says.
    public enum Outcome: Equatable, Sendable {
        /// The box applied it, or had already: the command log answers a
        /// `cmdId` it has seen with what it did then.
        case applied
        /// The box took it and has not settled it yet. Asking again with
        /// the same `cmdId` returns the result once there is one.
        case pending
        /// The box said no.
        case refused(WatchReceipt.Refusal)
        /// Neither an ack nor a refusal: an answer this build cannot read.
        case unread
    }

    /// A refusal's code as the watch says it.
    static func refusal(_ code: String?) -> WatchReceipt.Refusal {
        switch code {
        case "E_SCOPE_DENIED", "E_UNKNOWN_OP", "E_GRANT_REVOKED": return .mayNot
        case "E_CONFLICT", "E_PRECONDITION": return .changed
        case "E_CMD_EXPIRED": return .tooLate
        default: return .other
        }
    }

    public static func outcome(_ frames: [Envelope], cmdId: String) -> Outcome {
        var acked = false
        for f in frames {
            switch f.t {
            case "cmd.ack" where f.b?["cmdId"]?.string == cmdId:
                acked = true
            case "cmd.result":
                guard let b = f.b else { continue }
                let r = CmdResult(b)
                guard r.cmdId == cmdId else { continue }
                switch r.state {
                case .applied: return .applied
                case .unconfirmed: return .pending
                case .superseded: return .refused(.changed)
                case .expired: return .refused(.tooLate)
                case .rejected: return .refused(refusal(r.errorCode))
                }
            case "error":
                return .refused(refusal(f.b.map { ErrorMsg($0).code }))
            default:
                continue
            }
        }
        return acked ? .pending : .unread
    }
}
