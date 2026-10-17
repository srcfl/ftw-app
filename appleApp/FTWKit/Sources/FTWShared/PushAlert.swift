import CryptoKit
import Foundation

// A push from FTW Cloud, as the phone checks it. The box signs every event;
// the service wraps the box's envelope, unchanged, in an APNs alert. The
// phone's notification extension checks the signature with the box key it
// holds (CloudKeys), writes its own text from the kind (PushText) and picks
// the buttons from a verified kind alone (PushActions). The service picks
// nothing: not the words, not the buttons, not the priority.
//
// This is a port of ReadAlert in srcfl/ftw, go/protocol/cloudwire/push.go,
// and docs/protocol-cloud.md, "Push", is the normative text. The tests
// replay the Go side's push vectors case by case.

/// The kinds in the push catalogue (`protocol/push-catalogue.yaml`).
public enum PushKind {
    public static let chargingConnected = "charging.connected"
    public static let chargingSessionComplete = "charging.session_complete"
    public static let chargingGoalAtRisk = "charging.goal_at_risk"
    public static let chargingInterrupted = "charging.interrupted"
    public static let updateInstalled = "update.installed"
    public static let driverOffline = "driver.offline"
    public static let fuseOverLimit = "fuse.over_limit"
    /// The one alert the service writes itself: a box that cannot reach the
    /// service cannot sign one.
    public static let boxUnreachable = "box.unreachable"
    public static let cloudGranted = "cloud.granted"
    public static let cloudRevoked = "cloud.revoked"
    /// Access from outside the house, for every owner (docs/agents.md in
    /// srcfl/ftw). They come as the box's `notice`, never as an event, and
    /// FTW Cloud brings them with the readable copy on or off.
    public static let agentAdded = "agent.added"
    public static let agentRequest = "agent.request"
    public static let agentExpiring = "agent.expiring"
    public static let approvalKeySet = "approval.key.set"
    public static let ownerAdded = "owner.added"
    /// The box asks which car is on a charger. The buttons, one per car,
    /// come with the car app (docs/cars.md in srcfl/ftw).
    public static let carWhich = "car.which"

    /// In the catalogue's order.
    public static let all = [
        chargingConnected, chargingSessionComplete, chargingGoalAtRisk, chargingInterrupted, updateInstalled,
        driverOffline, fuseOverLimit, boxUnreachable, cloudGranted, cloudRevoked,
        agentAdded, agentRequest, agentExpiring, approvalKeySet, ownerAdded, carWhich,
    ]

    /// The kinds only owners may read. A box sends them as a `notice`; an
    /// `event` that names one reaches viewers too, so it reads as generic.
    public static let notices: Set<String> = [agentAdded, agentRequest, agentExpiring, approvalKeySet, ownerAdded]
}

/// What a push says once checked. Only `read` makes one, so a kind that has
/// not been verified cannot reach the text or the buttons.
public struct PushAlert: Sendable, Equatable {
    public enum Verdict: String, Sendable {
        /// Signed by the box, anchored in time and fresh, of a kind the
        /// catalogue has. The phone writes its text and offers its buttons.
        case event
        /// The service's box.unreachable. Its own text, no buttons.
        case unreachable
        /// Anything else: the generic line, no buttons.
        case generic
    }

    public let verdict: Verdict
    /// The home the payload names. Empty when the payload could not be read.
    public let home: String
    // The rest is set only for `.event`.
    public let kind: String
    public let args: [String: String]
    /// The opaque id of the device the event concerns.
    public let src: String?
    /// The opaque id of the loadpoint it concerns.
    public let lp: String?
    /// The opaque ids of the cars a `car.which` offers, in the box's order.
    public let cars: [String]
    public let boot: Data?
    public let seq: UInt64
    /// When it happened by the phone's reading of the box clock, less rule
    /// U's drift margin when rule U dates it: never later than it arrived.
    public let atMs: Int64

    init(_ verdict: Verdict, home: String, kind: String = "", args: [String: String] = [:], src: String? = nil, lp: String? = nil, cars: [String] = [], boot: Data? = nil, seq: UInt64 = 0, atMs: Int64 = 0) {
        self.verdict = verdict
        self.home = home
        self.kind = kind
        self.args = args
        self.src = src
        self.lp = lp
        self.cars = cars
        self.boot = boot
        self.seq = seq
        self.atMs = atMs
    }

    /// The payload key the alert sits under, beside Apple's "aps".
    public static let key = "ftw"
    static let version = 1
    /// How far ahead of the phone a box clock may run before the phone
    /// stops trusting it.
    static let clockLeadMs: Int64 = 2_000
    /// How old an event may be and still get its text and buttons.
    static let maxAgeMs: Int64 = 10 * 60_000
    /// How old a notice may be: a day.
    static let noticeMaxAgeMs: Int64 = 24 * 60 * 60_000
    /// How long rule U's anchor stays usable after it was last learned.
    static let ruleULifetimeMs: Int64 = 24 * 60 * 60_000
    /// Rule U's drift margin: 0.01 % of the time since it was learned.
    static let ruleUDriftDivisor: Int64 = 10_000

    /// Check a push as the notification extension receives it.
    /// `boxKey` is the key the phone holds for a home, nil when it holds
    /// none; `offset` is rule U's anchor for a home, nil when it holds none;
    /// `nowMs` is the phone's clock when the push arrived. Whether an event
    /// was seen before is `PushSeen`'s question, not this one's.
    public static func read(userInfo: [AnyHashable: Any], boxKey: (String) -> Data?, offset: (String) -> CloudHome.Offset? = { _ in nil }, nowMs: Int64) -> PushAlert {
        read(ftw: userInfo[key], boxKey: boxKey, offset: offset, nowMs: nowMs)
    }

    /// The same, from the payload's JSON as APNs sends it.
    public static func read(payload: Data, boxKey: (String) -> Data?, offset: (String) -> CloudHome.Offset? = { _ in nil }, nowMs: Int64) -> PushAlert {
        let top = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        return read(ftw: top?[key], boxKey: boxKey, offset: offset, nowMs: nowMs)
    }

    /// The service's part of the payload.
    private struct Wire: Decodable {
        var v: Int
        var home: String?
        /// The box's envelope, base64 with padding.
        var event: Data?
        var kind: String?
    }

    static func read(ftw: Any?, boxKey: (String) -> Data?, offset: (String) -> CloudHome.Offset?, nowMs: Int64) -> PushAlert {
        guard let ftw, JSONSerialization.isValidJSONObject(ftw),
              let json = try? JSONSerialization.data(withJSONObject: ftw),
              let a = try? JSONDecoder().decode(Wire.self, from: json), a.v == version else {
            return PushAlert(.generic, home: "")
        }
        let home = a.home ?? ""
        let generic = PushAlert(.generic, home: home)
        guard let event = a.event, !event.isEmpty else {
            return a.kind == PushKind.boxUnreachable ? PushAlert(.unreachable, home: home) : generic
        }
        // A notice reads as an event of its kind, with the client's name as
        // its one argument when it carries one.
        guard a.kind == nil || a.kind == "",
              let env = Envelope(Array(event)), env.t == "event" || env.t == "notice",
              let pk = boxKey(home), verify(pk, home: home, env),
              let ev = env.t == "event" ? Event(env.b) : Event(notice: env.b),
              var at = sendTime(ev, offset: offset(home), nowMs: nowMs) else {
            return generic
        }
        if let ts = ev.ts { at = min(at, ts) }
        let age = nowMs.subtractingReportingOverflow(at)
        // A notice kind comes only as a notice, and a notice states a
        // lasting fact, so it lasts a day.
        let notice = env.t == "notice"
        guard PushKind.all.contains(ev.kind), ev.kind != PushKind.boxUnreachable, PushKind.notices.contains(ev.kind) == notice,
              !age.overflow, age.partialValue <= (notice ? noticeMaxAgeMs : maxAgeMs) else {
            return generic
        }
        return PushAlert(.event, home: home, kind: ev.kind, args: ev.args, src: ev.src, lp: ev.lp, cars: ev.cars, boot: ev.boot.map { Data($0) }, seq: ev.seq, atMs: at)
    }

    /// When the event was sent, as the Go reference dates it: the earlier
    /// of rule N and rule U, and when rule U gives it, earlier by the drift
    /// margin so the margin counts against the age. A box clock more than
    /// `clockLeadMs` ahead gives no rule N. Nil when neither rule applies.
    /// Arithmetic wraps, as Go's does, so a hostile number cannot trap.
    static func sendTime(_ ev: Event, offset: CloudHome.Offset?, nowMs: Int64) -> Int64? {
        var at: Int64?
        if let wallMs = ev.wallMs, wallMs <= nowMs &+ clockLeadMs { at = min(wallMs, nowMs) }
        guard let offset, offset.boot == (ev.boot ?? []), nowMs &- offset.learnedAtMs <= ruleULifetimeMs else { return at }
        let u = min(offset.offsetMs &+ ev.uptimeMs, nowMs)
        if let n = at, u > n { return n }
        return u &- max(0, nowMs &- offset.learnedAtMs) / ruleUDriftDivisor
    }

    static func verify(_ pk: Data, home: String, _ env: Envelope) -> Bool {
        verify(boxKey: [UInt8](pk), home: home, t: env.t, b: env.b, sig: env.sig)
    }

    /// ES256 by a box's cloud key, over the bytes received, never over a
    /// re-encoding. The key is the box's 65-byte uncompressed P-256 point.
    /// The app's FTW Cloud session checks with this too, so there is one
    /// check.
    public static func verify(boxKey: [UInt8], home: String, t: String, b: [UInt8], sig: [UInt8]) -> Bool {
        guard boxKey.count == 65, boxKey.first == 0x04, sig.count == 64,
              let key = try? P256.Signing.PublicKey(x963Representation: boxKey),
              let sig = try? P256.Signing.ECDSASignature(rawRepresentation: sig) else { return false }
        return key.isValidSignature(sig, for: PushCBOR.signedInput(home: home, t: t, b: b))
    }

    /// One message: {t, b, sig}. `b` is the body's exact bytes, so the
    /// signature covers what was sent.
    struct Envelope {
        var t: String
        var b: [UInt8]
        var sig: [UInt8]

        /// t must be text and b and sig byte strings; unknown keys are
        /// ignored.
        init?(_ raw: [UInt8]) {
            guard let m = (try? PushCBOR.decode(raw))?.textMap,
                  case .text(let t)? = m["t"], !t.isEmpty,
                  case .bytes(let b)? = m["b"],
                  case .bytes(let sig)? = m["sig"] else { return nil }
            self.t = t
            self.b = b
            self.sig = sig
        }
    }

    /// A notice's client name may be at most this many characters: the
    /// consent page keeps 64 and marks a cut name with "…", as in Go.
    static let noticeClientMaxRunes = 65

    /// A client name as Go's NoticeClientOK takes it: no control or format
    /// character, and not too long.
    static func clientOK(_ c: String) -> Bool {
        !c.isEmpty && c.unicodeScalars.count <= noticeClientMaxRunes &&
            !c.unicodeScalars.contains { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format }
    }

    /// The event body. A field may be missing or null; one of the wrong
    /// type makes the whole body unreadable, as it does in Go.
    struct Event {
        var seq: UInt64 = 0
        var boot: [UInt8]?
        var uptimeMs: Int64 = 0
        var wallMs: Int64?
        var ts: Int64?
        var kind = ""
        var args: [String: String] = [:]
        var src: String?
        var lp: String?
        var cars: [String] = []

        init?(_ b: [UInt8]) {
            guard let m = (try? PushCBOR.decode(b))?.textMap else { return nil }
            func field<T>(_ key: String, _ read: (PushCBOR) -> T?) throws -> T? {
                guard let v = m[key], v != .null else { return nil }
                guard let out = read(v) else { throw PushCBOR.Malformed() }
                return out
            }
            do {
                seq = try field("seq", \.uint) ?? 0
                boot = try field("boot", \.byteString)
                uptimeMs = try field("uptimeMs", \.int64) ?? 0
                wallMs = try field("wallMs", \.int64)
                _ = try field("eventId", \.text)
                ts = try field("ts", \.int64)
                kind = try field("kind", \.text) ?? ""
                _ = try field("severity", \.text)
                args = try field("args", \.textOfText) ?? [:]
                src = try field("src", \.text)
                lp = try field("lp", \.text)
                cars = try field("cars", \.textList) ?? []
            } catch {
                return nil
            }
        }

        /// A notice body, read as ReadNotice in Go reads it: the header, a
        /// notice kind and, on agent.added only, the client's name. Any
        /// other field makes it no notice, so it cannot carry a reading.
        init?(notice b: [UInt8]) {
            let allowed: Set<String> = ["seq", "boot", "uptimeMs", "wallMs", "kind", "client"]
            guard let m = (try? PushCBOR.decode(b))?.textMap, Set(m.keys).isSubset(of: allowed) else { return nil }
            func field<T>(_ key: String, _ read: (PushCBOR) -> T?) throws -> T? {
                guard let v = m[key], v != .null else { return nil }
                guard let out = read(v) else { throw PushCBOR.Malformed() }
                return out
            }
            do {
                seq = try field("seq", \.uint) ?? 0
                boot = try field("boot", \.byteString)
                uptimeMs = try field("uptimeMs", \.int64) ?? 0
                wallMs = try field("wallMs", \.int64)
                kind = try field("kind", \.text) ?? ""
                let client = try field("client", \.text) ?? ""
                guard PushKind.notices.contains(kind), boot?.count == 16, uptimeMs >= 0,
                      client.isEmpty || (kind == PushKind.agentAdded && PushAlert.clientOK(client)) else { return nil }
                if !client.isEmpty { args = ["client": client] }
            } catch {
                return nil
            }
        }
    }
}

extension PushCBOR {
    var uint: UInt64? {
        if case .unsigned(let u) = self { return u }
        return nil
    }

    var int64: Int64? {
        switch self {
        case .unsigned(let u): return Int64(exactly: u)
        case .negative(let n): return Int64(exactly: n).map { -1 - $0 }
        default: return nil
        }
    }

    var text: String? {
        if case .text(let s) = self { return s }
        return nil
    }

    var byteString: [UInt8]? {
        if case .bytes(let b) = self { return b }
        return nil
    }

    /// A list of text, as Go's []string.
    var textList: [String]? {
        guard case .array(let items) = self else { return nil }
        var out = [String]()
        for item in items {
            guard case .text(let s) = item else { return nil }
            out.append(s)
        }
        return out
    }

    /// A text-to-text map. A null value reads as empty text, as in Go.
    var textOfText: [String: String]? {
        guard let m = textMap else { return nil }
        var out = [String: String]()
        for (k, v) in m {
            switch v {
            case .text(let s): out[k] = s
            case .null: out[k] = ""
            default: return nil
            }
        }
        return out
    }
}
