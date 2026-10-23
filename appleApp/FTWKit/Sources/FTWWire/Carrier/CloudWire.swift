import Foundation
import FTWShared

/// The FTW Cloud wire, as a phone reads it.
///
/// FTW Cloud keeps a box-signed copy of a home and serves it to that home's
/// phones. The service cannot sign for the box, so this file is what lets
/// the phone check the box's bytes itself: the unpadded frame, the envelope
/// and what its signature covers, the home id, and the bodies of the classes
/// a phone reads. srcfl/ftw `docs/protocol-cloud.md` is the normative text
/// and `go/protocol/cloudwire` the reference; its golden vectors replay in
/// `CloudWireTests` byte for byte.
///
/// Bodies are read as Go's decoder reads them: unknown keys are ignored,
/// null reads as absent, and a known key of the wrong type refuses the body,
/// so the phone never keeps a message the reference would drop.
public enum CloudWire {
    // MARK: - Constants

    /// Byte 0 of every frame.
    public static let version: UInt8 = 1
    /// Byte 1 of every frame. Lane 1 without the app protocol's bulk
    /// buckets: the service reads the content, so padding would hide little.
    public static let lane: UInt8 = 1
    /// ver, lane, flags, rsvd and a u16 length.
    public static let headerBytes = 6
    public static let maxPayload = 0xffff

    /// "ftw.cloud.v1" and a zero byte. Starts every signed input.
    public static let signTag = Bytes("ftw.cloud.v1\0".utf8)
    /// Starts the hash a home id is cut from.
    public static let homeTag = Bytes("ftw.cloud.home.v1".utf8)
    /// Starts the app session's Noise prologue; the home id follows.
    public static let appPrologueTag = Bytes("ftw.cloud.v1:".utf8)
    /// The app session's ALPN over QUIC (srcfl/ftw `docs/protocol-cloud.md`,
    /// "QUIC").
    public static let alpnApp = "ftw-cloud-app/1"

    /// ES256 as r ‖ s, each 32 bytes big-endian.
    public static let sigBytes = 64
    /// An uncompressed SEC1 P-256 point: the box key as the phone holds it.
    public static let publicKeyBytes = 65
    public static let bootBytes = 16

    // MARK: - Message types

    // The classes a phone may read. hb goes to every device in the roster;
    // the service forwards the rest by the device's scope.
    public static let msgLive = "live"
    public static let msgLP = "lp"
    public static let msgPrices = "prices"
    public static let msgPlan = "plan"
    public static let msgHealth = "health"
    public static let msgEvent = "event"
    public static let msgTiles = "tiles"
    public static let msgHB = "hb"
    /// Each car's level and goal, by opaque id (srcfl/ftw `docs/cars.md`).
    public static let msgCar = "car"

    /// Everything else the box sends (hello, roster, bye, notice) is the
    /// service's alone and never reaches a phone as a class.
    public static let phoneClasses: Set<String> = [msgLive, msgLP, msgCar, msgPrices, msgPlan, msgHealth, msgEvent, msgTiles, msgHB]

    // The app session's own types. All unsigned.
    /// Handshake message 1, `{hz}`.
    public static let msgNow = "now"
    /// Handshake message 2: what the service holds.
    public static let msgSnapshot = "snapshot"
    /// Phone to service, `{hz}`: whether the phone can see the home.
    public static let msgWatch = "watch"
    /// An owner's, `{deviceId}`. They only narrow access.
    public static let msgSuspend = "suspend"
    public static let msgUnsuspend = "unsuspend"
    /// Phone to service, `{apnsToken, environment, kind}`: where Apple can
    /// reach this phone. The service binds it to the phone's roster entry.
    public static let msgPushRegister = "push.register"
    /// The only kind of push registration so far.
    package static let pushKindAlert = "alert"
    /// Both ways, `{sid, d}`: one message of the phone's own session with
    /// its box, which the service carries and cannot read (`Tun`).
    public static let msgTun = "tun"

    public static let hzLooking = 1
    public static let hzAway = 0

    // Close codes on /v1/app.
    /// The phone sent something the protocol does not allow.
    public static let closeProtocol = 4400
    /// Every refusal, without saying which: no such home, not in the
    /// roster, suspended, roster expired, grant off.
    public static let closeDenied = 4403
    /// A newer session from the same device took over.
    public static let closeReplaced = 4408
    /// The roster changed what this device may read. Reconnect at once.
    public static let closeChanged = 4409
    /// The home has as many sessions as the service allows, as on the relay.
    public static let closeBusy = 4429

    /// A frame, envelope or body this protocol does not send. Local only.
    public struct WireError: Error, Equatable {
        public let code: String
        public let message: String
    }

    // MARK: - Frames

    /// One envelope in one frame: lane 1, flags 0 and no padding, so the
    /// message is exactly 6 + len bytes.
    public static func encodeFrame(_ envelope: Bytes) throws -> Bytes {
        guard envelope.count <= maxPayload else {
            throw WireError(code: "E_CLOUD_FRAME", message: "\(envelope.count) bytes do not fit the length field")
        }
        return [version, lane, 0, 0, UInt8(envelope.count >> 8), UInt8(envelope.count & 0xff)] + envelope
    }

    /// The envelope bytes of one frame. Stricter than `Frame.decode`: lane 0,
    /// a flag, a reserved bit or a byte past the declared length is not a
    /// frame this protocol sends.
    public static func decodeFrame(_ message: Bytes) throws -> Bytes {
        func refuse(_ why: String) -> WireError { WireError(code: "E_CLOUD_FRAME", message: why) }
        guard message.count >= headerBytes else { throw refuse("\(message.count) bytes") }
        guard message[0] == version else { throw refuse("version \(message[0])") }
        guard message[1] == lane else { throw refuse("lane \(message[1])") }
        guard message[2] == 0, message[3] == 0 else { throw refuse("flags \(message[2]) \(message[3])") }
        let len = Int(message[4]) << 8 | Int(message[5])
        guard len == message.count - headerBytes else {
            throw refuse("declares \(len) bytes, carries \(message.count - headerBytes)")
        }
        return Array(message[headerBytes...])
    }

    // MARK: - Envelope

    /// One message, `{t, b, sig}`. `b` is the body's exact bytes, carried as
    /// a byte string so the signature covers what was sent and the service
    /// can forward it unchanged. `sig` is empty on whatever the box did not
    /// sign.
    public struct Envelope: Equatable, Sendable {
        public var t: String
        public var b: Bytes
        public var sig: Bytes

        public init(t: String, b: Bytes, sig: Bytes = []) {
            self.t = t
            self.b = b
            self.sig = sig
        }

        /// Parses one envelope. `t` must be text and `b` and `sig` byte
        /// strings, checked rather than converted: an envelope whose body is
        /// text is not the envelope that was signed. Unknown keys are
        /// ignored.
        public static func decode(_ raw: Bytes) throws -> Envelope {
            let value: CBOR
            do {
                value = try decodeCBOR(raw)
            } catch {
                throw envelopeError("\(error)")
            }
            return try Envelope(value)
        }

        /// An envelope embedded as a CBOR map, as in a snapshot.
        init(_ value: CBOR) throws {
            guard case .map(let entries) = value else { throw envelopeError("not a map") }
            var t: String?
            var b: Bytes?
            var sig: Bytes?
            for e in entries {
                guard case .text(let key) = e.key else { throw envelopeError("a key is not text") }
                switch (key, e.value) {
                case ("t", .text(let v)): t = v
                case ("b", .bytes(let v)): b = v
                case ("sig", .bytes(let v)): sig = v
                case ("t", _), ("b", _), ("sig", _): throw envelopeError("\(key) has the wrong type")
                default: continue
                }
            }
            guard let t, let b, let sig else { throw envelopeError("t, b and sig are all required") }
            guard !t.isEmpty else { throw envelopeError("empty type") }
            self.init(t: t, b: b, sig: sig)
        }

        /// A three-entry map in core deterministic key order, b, t, sig. An
        /// empty signature is an empty byte string, never null.
        public func encode() -> Bytes {
            encodeCBOR(.map([("b", .bytes(b)), ("t", .text(t)), ("sig", .bytes(sig))]))
        }
    }

    /// An envelope the phone says itself: the body in core deterministic
    /// encoding and an empty `sig`. The same bytes as Go's
    /// `cloudwire.Unsigned` for the same body.
    public static func encodeUnsigned(t: String, body: CBOR) -> Bytes {
        Envelope(t: t, b: encodeCBOR(deterministic(body))).encode()
    }

    /// RFC 8949 core deterministic order: each map's keys sorted by the bytes
    /// of their own encoding, which puts shorter text keys first. The encoder
    /// already writes every head in its shortest form.
    static func deterministic(_ value: CBOR) -> CBOR {
        switch value {
        case .array(let items):
            return .array(items.map(deterministic))
        case .map(let entries):
            return .map(entries
                .map { CBOR.Entry(deterministic($0.key), deterministic($0.value)) }
                .sorted { encodeCBOR($0.key).lexicographicallyPrecedes(encodeCBOR($1.key)) })
        case .tagged(let tag, let inner):
            return .tagged(tag, deterministic(inner))
        default:
            return value
        }
    }

    // MARK: - Signatures

    /// What a signature covers: `signTag`, then the CBOR array
    /// `[home, t, b]`. The home id is inside, so a message signed for one
    /// home never verifies for another.
    public static func signedInput(home: String, t: String, b: Bytes) -> Bytes {
        signTag + encodeCBOR(.array([.text(home), .text(t), .bytes(b)]))
    }

    /// Whether `envelope` carries an ES256 signature by `boxKey` for `home`,
    /// over the bytes received, never a re-encoding. The key is the one the
    /// box gave this phone over Noise, never one from the service. The
    /// notification extension's check, so a push and a reading are checked
    /// alike.
    public static func verify(boxKey: Bytes, home: String, envelope: Envelope) -> Bool {
        PushAlert.verify(boxKey: boxKey, home: home, t: envelope.t, b: envelope.b, sig: envelope.sig)
    }

    // MARK: - Ids

    /// The home's name at the service: lowercase base32 without padding of
    /// the first 16 bytes of SHA-256(`homeTag` ‖ pk), 26 characters. A hash
    /// of the key, so no other box can claim the home.
    public static func homeID(pk: Bytes) -> String {
        base32(Array(Primitives.sha256(homeTag + pk).prefix(16)))
    }

    /// A source's opaque id: the first 8 bytes of
    /// HMAC-SHA256(grantKey, "src\0" ‖ driver), base64url without padding.
    /// The phone maps these to names from the table the box sends over
    /// Noise; computing one here is for the vectors.
    static func sourceID(grantKey: Bytes, driver: String) -> String {
        opaqueID(grantKey, "src\0", driver)
    }

    /// A loadpoint's opaque id, cut the same way with "lp\0".
    static func loadpointID(grantKey: Bytes, loadpoint: String) -> String {
        opaqueID(grantKey, "lp\0", loadpoint)
    }

    /// A car's opaque id, cut the same way with "car\0" from the id the
    /// owner's app minted, so it differs per home.
    static func carID(grantKey: Bytes, car: String) -> String {
        opaqueID(grantKey, "car\0", car)
    }

    private static func opaqueID(_ key: Bytes, _ tag: String, _ name: String) -> String {
        Base64url.encode(Array(Primitives.hmacSHA256(key: key, Bytes(tag.utf8) + Bytes(name.utf8)).prefix(8)))
    }

    /// The Noise prologue of one home's app session. The phone learned the
    /// home id from the box, so a service that answers for another home
    /// fails the handshake.
    public static func appPrologue(home: String) -> Bytes {
        appPrologueTag + Bytes(home.utf8)
    }

    private static func base32(_ bytes: Bytes) -> String {
        let alphabet = Bytes("abcdefghijklmnopqrstuvwxyz234567".utf8)
        var out = Bytes()
        var buffer: UInt32 = 0
        var bits = 0
        for byte in bytes {
            buffer = buffer << 8 | UInt32(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[Int(buffer >> UInt32(bits - 5) & 31)])
                bits -= 5
            }
        }
        if bits > 0 { out.append(alphabet[Int(buffer << UInt32(5 - bits) & 31)]) }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: - App session

    /// Handshake message 2: for each class the device may read, the newest
    /// envelope the service holds, the newest live that carried sources and
    /// the newest hb, in rising seq. `lastSeenMs` and `online` are the
    /// service's own word, unsigned, and never shown as a reading. `more`
    /// counts envelopes that did not fit and follow as ordinary frames.
    public struct Snapshot: Equatable, Sendable {
        public var envelopes: [Envelope]
        public var lastSeenMs: Int64
        public var online: Bool
        public var more: Int
    }

    /// Reads message 2's payload. Each entry is a box envelope embedded as
    /// a map; its `b` is the box's exact bytes, so it verifies as sent.
    public static func parseSnapshot(payload: Bytes) throws -> Snapshot {
        let env = try Envelope.decode(payload)
        guard env.t == msgSnapshot else { throw envelopeError("message 2 is \(env.t), not a snapshot") }
        let f = try Fields(body: env.b)
        return Snapshot(
            envelopes: try f.list("envelopes") { try Envelope($0) },
            lastSeenMs: try f.int("lastSeenMs"),
            online: try f.bool("online"),
            more: Int(try f.int("more"))
        )
    }

    // MARK: - Tunnel

    /// One message of the phone's session with its box, `ftw.session.v1`,
    /// as it rides the app session: `d` byte for byte as it would cross the
    /// relay, and an empty `d` ends the session `sid` names. The service
    /// adds the device from its own handshake on the way to the box, so this
    /// side never names one.
    public struct Tun: Equatable, Sendable {
        /// The phone's number for one session with the box, drawn at random
        /// for each, so the late end of an older one never ends a newer one.
        public var sid: UInt32
        public var d: Bytes

        public init(sid: UInt32, d: Bytes) {
            self.sid = sid
            self.d = d
        }

        public var ended: Bool { d.isEmpty }

        package var body: CBOR { .map([("sid", .unsigned(UInt64(sid))), ("d", .bytes(d))]) }

        public init(body: Bytes) throws {
            let f = try Fields(body: body)
            let sid = try f.uint("sid")
            guard sid <= UInt64(UInt32.max) else { throw bodyError("sid", "below 2^32") }
            self.init(sid: UInt32(sid), d: try f.bytes("d"))
        }
    }

    /// The largest `d`: one transport message around the app protocol's
    /// largest bulk frame.
    public static let tunDataMax = 16_384 + 24

    /// Starts the hash a pending pairing is listed by.
    public static let pairingTag = Bytes("ftw.cloud.pair.v1\0".utf8)

    /// What a new phone proves in message 1 so the service admits it before
    /// the roster lists it: SHA-256(`pairingTag` ‖ home ‖ code). The code
    /// itself rides inside the box session's message 1, encrypted to the
    /// box, so the service never sees it.
    public static func pairingHash(home: String, code: Bytes) -> Bytes {
        Primitives.sha256(pairingTag + Bytes(home.utf8) + code)
    }

    /// The box's name for a paired device: the first 8 characters of its
    /// Noise static key in base64url. The roster names devices this way.
    public static func deviceID(key: Bytes) -> String {
        String(Base64url.encode(key).prefix(8))
    }

    /// A home id as the service cuts one: 26 characters of lowercase
    /// base32. Anything else in a QR is not a home.
    public static func validHome(_ s: String) -> Bool {
        s.utf8.count == 26 && s.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7a) || ($0 >= 0x32 && $0 <= 0x37) }
    }

    /// Message 1's payload: whether the phone looks, the pairing proof of a
    /// phone the roster does not list yet, and the box session's own
    /// message 1, so that session is up one round trip after TLS.
    public static func now(hz: Int, pair: Bytes? = nil, tun: Tun? = nil) -> Bytes {
        var body: [CBOR.Entry] = [CBOR.Entry(.text("hz"), .int(hz))]
        if let pair { body.append(CBOR.Entry(.text("pair"), .bytes(pair))) }
        if let tun { body.append(CBOR.Entry(.text("tun"), tun.body)) }
        return encodeUnsigned(t: msgNow, body: .map(body))
    }

    // MARK: - Bodies

    /// In every body the box sends.
    public struct Header: Equatable, Sendable {
        /// Starts at 1 and rises by 1 per message, per boot.
        public var seq: UInt64
        /// Drawn at random at each Core start.
        public var boot: Bytes
        /// Box monotonic time since start, at send.
        public var uptimeMs: Int64
        /// Box wall time at send, present only while NTP has synced it.
        public var wallMs: Int64?
    }

    /// The site's flows and the freshness of every source behind them.
    public struct Live: Equatable, Sendable {
        public var header: Header
        /// Frozen field ids 1–6 and 10, keyed as text as the app protocol's
        /// delta keys them. Field 1 is the mode index; the rest are watts.
        public var fields: [String: Int64]
        /// Present only when the source table changed and in every full
        /// message, as is `sources`.
        public var fieldSources: [String: [String]]?
        public var sources: [String: Source]?
        /// Rises by 1, per boot, each time the source table changes.
        public var srcRev: UInt64
        /// For each live or lagging source, the age of its newest reading at
        /// send, in ms of box uptime.
        public var ages: [String: Int64]
        public var dispatchBlockedBy: [String]
    }

    /// One source's freshness as the box grades it, keyed by opaque id.
    public struct Source: Equatable, Sendable {
        public var kind: String
        /// A state this build does not know ranks as never.
        public var state: SourceState
        /// Box uptime at the last good reading, when the table was sent.
        public var lastOkMs: Int64
        public var staleAfterMs: Int64
    }

    /// Loadpoint and control feedback state.
    public struct LP: Equatable, Sendable {
        public var header: Header
        public var controlRev: UInt64
        public var loadpoints: [Loadpoint]
        public var feedback: [Feedback]
    }

    /// One charger as the household sees it. Nil is the box's "not known".
    public struct Loadpoint: Equatable, Sendable {
        /// Opaque loadpoint id.
        public var id: String
        /// Opaque source id of the charger, whose freshness this follows.
        public var src: String
        public var plugged: Bool
        public var socPermille: Int64?
        /// vehicle, inferred or assumed; empty when unplugged.
        public var socSource: String
        /// Seconds since the level was confirmed, at send.
        public var socAgeS: Int64?
        public var targetPermille: Int64?
        /// Box wall time.
        public var readyByMs: Int64?
        public var recurring: Bool
        public var powerW: Int64
        public var sessionWh: Int64
        public var session: String
        public var manual: Manual?
        public var commandedW: Int64?
        public var commandedReason: String
        public var surplusOnly: Bool
        public var gridDeferred: Bool
        public var planPending: Bool
        public var boost: Bool
        public var nextStartMs: Int64?
        public var nextEndMs: Int64?
        public var nextWh: Int64?
        /// Opaque id of the session's car, the join to `Cars`. Empty while
        /// nothing is plugged in or the box does not know the car. With it,
        /// the level and goal fields above are views of that car, and where
        /// the two disagree the car class wins.
        public var carId: String = ""
        /// charger, car, only, tap, asking or none (`docs/cars.md`).
        public var carIdentifiedBy: String = ""
        public var carCorrected: Bool = false
        public var carCorrectedFrom: String = ""
        /// While asking: the cars a tap may pick, at most four.
        public var choose: [String] = []
    }

    /// Each car's level and goal on this box. Nothing here names a car; the
    /// names come from the box over Noise.
    public struct Cars: Equatable, Sendable {
        public var header: Header
        public var cars: [Car]

        /// The car with this opaque id, as a charger's `carId` names it.
        public func car(_ id: String) -> Car? {
            id.isEmpty ? nil : cars.first { $0.id == id }
        }
    }

    public struct Car: Equatable, Sendable {
        /// Opaque car id.
        public var id: String
        /// The car's level; the car's or a person's own number while
        /// `socEstimate` is false. Nil when the box has none.
        public var socPermille: Int64?
        /// vehicle, manual or assumed; empty without a level.
        public var socSource: String
        /// Seconds since the car reported the level or someone set it, at
        /// send.
        public var socAgeS: Int64?
        /// Energy into the car since then; negative after V2X.
        public var energySinceWh: Int64
        public var socEstimate: Bool
        public var chargeLimitPermille: Int64?
        public var goal: CarGoal?
        public var surplusOnly: Bool
    }

    public struct CarGoal: Equatable, Sendable {
        public var targetPermille: Int64
        /// Minutes after midnight in the box's time zone.
        public var readyByMin: Int64
        /// ISO weekday mask, Monday in bit 0; 0 is once, 127 every day.
        public var days: Int64
        public var finishAtLimit: Bool
    }

    /// A manual charging hold.
    public struct Manual: Equatable, Sendable {
        public var state: String
        public var sinceAgeMs: Int64
        public var requestedW: Int64?
        public var commandedW: Int64?
        public var reason: String
    }

    /// Core's verdict on whether one device function follows.
    public struct Feedback: Equatable, Sendable {
        public var kind: String
        public var src: String
        public var status: String
        public var reason: String
        public var severity: String
        public var evidence: String
        public var fresh: Bool
        public var actualW: Int64?
        /// Age of that reading by box uptime, at send.
        public var ageMs: Int64?
    }

    /// The price window, in columns. Nil where a slot has no price.
    public struct Prices: Equatable, Sendable {
        public var header: Header
        public var zone: String
        public var currency: String
        /// Box wall time the first slot starts.
        public var t0Ms: Int64
        public var slotMs: Int64
        /// Minor units per kWh.
        public var spotMinor: [Int64?]
        /// What the household pays, tariff and VAT included.
        public var totalMinor: [Int64?]
    }

    /// The box is there, and this is how old its readings are. It names the
    /// newest live and lp the box sent, so it never vouches for one the
    /// phone has not seen.
    public struct HB: Equatable, Sendable {
        public var header: Header
        public var clock: String
        public var srcRev: UInt64
        public var liveSeq: UInt64
        /// 0 if the box has sent no lp.
        public var lpSeq: UInt64
        public var ages: [String: Int64]
    }

    static func envelopeError(_ why: String) -> WireError { WireError(code: "E_CLOUD_ENVELOPE", message: why) }
    static func bodyError(_ key: String, _ want: String) -> WireError { WireError(code: "E_CLOUD_BODY", message: "\(key) is not \(want)") }
}

// MARK: - Body decoding

extension CloudWire.Header {
    public init(body: Bytes) throws { try self.init(CloudWire.Fields(body: body)) }

    init(_ f: CloudWire.Fields) throws {
        self.init(seq: try f.uint("seq"), boot: try f.bytes("boot"), uptimeMs: try f.int("uptimeMs"), wallMs: try f.optionalInt("wallMs"))
    }
}

extension CloudWire.Live {
    public init(body: Bytes) throws {
        let f = try CloudWire.Fields(body: body)
        self.init(
            header: try CloudWire.Header(f),
            fields: try f.dictionary("fields") { try CloudWire.int($0, "fields") } ?? [:],
            fieldSources: try f.dictionary("fieldSources") { try CloudWire.texts($0, "fieldSources") },
            sources: try f.dictionary("sources") { try CloudWire.Source(CloudWire.Fields($0, "sources")) },
            srcRev: try f.uint("srcRev"),
            ages: try f.dictionary("ages") { try CloudWire.int($0, "ages") } ?? [:],
            dispatchBlockedBy: try f.list("dispatchBlockedBy") { try CloudWire.text($0, "dispatchBlockedBy") }
        )
    }
}

extension CloudWire.Source {
    init(_ f: CloudWire.Fields) throws {
        self.init(
            kind: try f.text("kind"),
            state: SourceState(rawValue: try f.text("state")) ?? .never,
            lastOkMs: try f.int("lastOkMs"),
            staleAfterMs: try f.int("staleAfterMs")
        )
    }
}

extension CloudWire.LP {
    public init(body: Bytes) throws {
        let f = try CloudWire.Fields(body: body)
        self.init(
            header: try CloudWire.Header(f),
            controlRev: try f.uint("controlRev"),
            loadpoints: try f.list("loadpoints") { try CloudWire.Loadpoint(CloudWire.Fields($0, "loadpoints")) },
            feedback: try f.list("feedback") { try CloudWire.Feedback(CloudWire.Fields($0, "feedback")) }
        )
    }
}

extension CloudWire.Loadpoint {
    init(_ f: CloudWire.Fields) throws {
        self.init(
            id: try f.text("id"),
            src: try f.text("src"),
            plugged: try f.bool("plugged"),
            socPermille: try f.optionalInt("socPermille"),
            socSource: try f.text("socSource"),
            socAgeS: try f.optionalInt("socAgeS"),
            targetPermille: try f.optionalInt("targetPermille"),
            readyByMs: try f.optionalInt("readyByMs"),
            recurring: try f.bool("recurring"),
            powerW: try f.int("powerW"),
            sessionWh: try f.int("sessionWh"),
            session: try f.text("session"),
            manual: try f.optional("manual").map(CloudWire.Manual.init),
            commandedW: try f.optionalInt("commandedW"),
            commandedReason: try f.text("commandedReason"),
            surplusOnly: try f.bool("surplusOnly"),
            gridDeferred: try f.bool("gridDeferred"),
            planPending: try f.bool("planPending"),
            boost: try f.bool("boost"),
            nextStartMs: try f.optionalInt("nextStartMs"),
            nextEndMs: try f.optionalInt("nextEndMs"),
            nextWh: try f.optionalInt("nextWh"),
            carId: try f.text("carId"),
            carIdentifiedBy: try f.text("carIdentifiedBy"),
            carCorrected: try f.bool("carCorrected"),
            carCorrectedFrom: try f.text("carCorrectedFrom"),
            choose: try CloudWire.texts(f["choose"], "choose")
        )
    }
}

extension CloudWire.Cars {
    public init(body: Bytes) throws {
        let f = try CloudWire.Fields(body: body)
        self.init(header: try CloudWire.Header(f),
                  cars: try f.list("cars") { try CloudWire.Car(CloudWire.Fields($0, "cars")) })
    }
}

extension CloudWire.Car {
    init(_ f: CloudWire.Fields) throws {
        self.init(
            id: try f.text("id"),
            socPermille: try f.optionalInt("socPermille"),
            socSource: try f.text("socSource"),
            socAgeS: try f.optionalInt("socAgeS"),
            energySinceWh: try f.int("energySinceWh"),
            socEstimate: try f.bool("socEstimate"),
            chargeLimitPermille: try f.optionalInt("chargeLimitPermille"),
            goal: try f.optional("goal").map { g in
                CloudWire.CarGoal(targetPermille: try g.int("targetPermille"), readyByMin: try g.int("readyByMin"),
                                  days: try g.int("days"), finishAtLimit: try g.bool("finishAtLimit"))
            },
            surplusOnly: try f.bool("surplusOnly")
        )
    }
}

extension CloudWire.Manual {
    init(_ f: CloudWire.Fields) throws {
        self.init(
            state: try f.text("state"),
            sinceAgeMs: try f.int("sinceAgeMs"),
            requestedW: try f.optionalInt("requestedW"),
            commandedW: try f.optionalInt("commandedW"),
            reason: try f.text("reason")
        )
    }
}

extension CloudWire.Feedback {
    init(_ f: CloudWire.Fields) throws {
        self.init(
            kind: try f.text("kind"),
            src: try f.text("src"),
            status: try f.text("status"),
            reason: try f.text("reason"),
            severity: try f.text("severity"),
            evidence: try f.text("evidence"),
            fresh: try f.bool("fresh"),
            actualW: try f.optionalInt("actualW"),
            ageMs: try f.optionalInt("ageMs")
        )
    }
}

extension CloudWire.Prices {
    public init(body: Bytes) throws {
        let f = try CloudWire.Fields(body: body)
        self.init(
            header: try CloudWire.Header(f),
            zone: try f.text("zone"),
            currency: try f.text("currency"),
            t0Ms: try f.int("t0Ms"),
            slotMs: try f.int("slotMs"),
            spotMinor: try f.list("spotMinor") { $0.isNull ? nil : try CloudWire.int($0, "spotMinor") },
            totalMinor: try f.list("totalMinor") { $0.isNull ? nil : try CloudWire.int($0, "totalMinor") }
        )
    }
}

extension CloudWire.HB {
    public init(body: Bytes) throws {
        let f = try CloudWire.Fields(body: body)
        self.init(
            header: try CloudWire.Header(f),
            clock: try f.text("clock"),
            srcRev: try f.uint("srcRev"),
            liveSeq: try f.uint("liveSeq"),
            lpSeq: try f.uint("lpSeq"),
            ages: try f.dictionary("ages") { try CloudWire.int($0, "ages") } ?? [:]
        )
    }
}

extension CloudWire {
    /// A body's text keys. Absent and null both read as the zero value, as
    /// Go leaves a field it was not given.
    struct Fields {
        private let map: [String: CBOR]

        init(body: Bytes) throws {
            guard !body.isEmpty else { throw WireError(code: "E_CLOUD_BODY", message: "empty body") }
            let value: CBOR
            do {
                value = try decodeCBOR(body)
            } catch {
                throw WireError(code: "E_CLOUD_BODY", message: "\(error)")
            }
            try self.init(value, "body")
        }

        init(_ value: CBOR, _ key: String) throws {
            var map = [String: CBOR]()
            switch value {
            case .map(let entries):
                for e in entries {
                    if case .text(let k) = e.key { map[k] = e.value }
                }
            case .null, .undefined:
                break
            default:
                throw bodyError(key, "a map")
            }
            self.map = map
        }

        subscript(key: String) -> CBOR { map[key] ?? .null }

        func uint(_ key: String) throws -> UInt64 { try CloudWire.uint(self[key], key) }
        func int(_ key: String) throws -> Int64 { try CloudWire.int(self[key], key) }
        func text(_ key: String) throws -> String { try CloudWire.text(self[key], key) }
        func bool(_ key: String) throws -> Bool { try CloudWire.bool(self[key], key) }

        func bytes(_ key: String) throws -> Bytes {
            switch self[key] {
            case .bytes(let b): return b
            case .null, .undefined: return []
            default: throw bodyError(key, "a byte string")
            }
        }

        func optionalInt(_ key: String) throws -> Int64? {
            self[key].isNull ? nil : try CloudWire.int(self[key], key)
        }

        func optional(_ key: String) throws -> Fields? {
            self[key].isNull ? nil : try Fields(self[key], key)
        }

        func list<T>(_ key: String, _ element: (CBOR) throws -> T) throws -> [T] {
            switch self[key] {
            case .array(let items): return try items.map(element)
            case .null, .undefined: return []
            default: throw bodyError(key, "an array")
            }
        }

        /// Nil when absent, so "no table in this message" stays apart from
        /// an empty one.
        func dictionary<T>(_ key: String, _ value: (CBOR) throws -> T) throws -> [String: T]? {
            switch self[key] {
            case .map(let entries):
                var out = [String: T]()
                for e in entries {
                    guard case .text(let k) = e.key else { throw bodyError(key, "keyed by text") }
                    out[k] = try value(e.value)
                }
                return out
            case .null, .undefined: return nil
            default: throw bodyError(key, "a map")
            }
        }
    }

    static func uint(_ v: CBOR, _ key: String) throws -> UInt64 {
        switch v {
        case .unsigned(let u): return u
        case .null, .undefined: return 0
        default: throw bodyError(key, "an unsigned integer")
        }
    }

    static func int(_ v: CBOR, _ key: String) throws -> Int64 {
        switch v {
        case .unsigned(let u) where u <= UInt64(Int64.max): return Int64(u)
        case .negative(let n) where n <= UInt64(Int64.max): return -1 - Int64(n)
        case .null, .undefined: return 0
        default: throw bodyError(key, "a 64-bit integer")
        }
    }

    static func text(_ v: CBOR, _ key: String) throws -> String {
        switch v {
        case .text(let s): return s
        case .null, .undefined: return ""
        default: throw bodyError(key, "text")
        }
    }

    static func bool(_ v: CBOR, _ key: String) throws -> Bool {
        switch v {
        case .bool(let b): return b
        case .null, .undefined: return false
        default: throw bodyError(key, "a bool")
        }
    }

    static func texts(_ v: CBOR, _ key: String) throws -> [String] {
        switch v {
        case .array(let items): return try items.map { try text($0, key) }
        case .null, .undefined: return []
        default: throw bodyError(key, "an array of text")
        }
    }
}
