import CryptoKit
import Foundation
import Testing
@testable import FTWShared

/// The push check against srcfl/ftw's own vectors: every case in
/// push-vectors.json, as the Go reference reads it, and every message in
/// cloud-vectors.json for the envelope and the bytes a signature covers.
/// Then the edges the vectors do not reach, signed here with the vector box
/// key.
@Suite struct PushAlertTests {
    struct PushFile: Decodable {
        struct Key: Decodable { var home: String; var pk: String }
        struct Want: Decodable {
            var verdict: String
            var home: String
            var kind: String?
            var args: [String: String]?
            var src: String?
            var lp: String?
            var boot: String?
            var seq: UInt64?
            var atMs: Int64?
        }
        struct Offset: Decodable {
            var home: String
            var boot: String
            var offsetMs: Int64
            var learnedAtMs: Int64
        }
        struct Case: Decodable {
            var name: String
            var payload: String
            var offset: Offset?
            var nowMs: Int64
            var want: Want
        }
        var keys: [Key]
        var cases: [Case]
    }

    struct CloudFile: Decodable {
        struct Key: Decodable { var d: String?; var pk: String; var home: String? }
        struct Message: Decodable {
            var name: String
            var signer: String
            var t: String
            var body: String
            var signedInputSha256: String
            var sig: String
            var envelope: String
        }
        var boxKey: Key
        var serviceKey: Key
        var messages: [Message]
    }

    static func load<T: Decodable>(_ name: String, as: T.Type) throws -> T {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Resources"))
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    // MARK: The Go side's vectors

    @Test func everyPushVectorReadsAsTheGoReferenceReadsIt() throws {
        let file = try Self.load("push-vectors", as: PushFile.self)
        #expect(file.cases.count == 28)
        let keys = Dictionary(uniqueKeysWithValues: file.keys.map { ($0.home, Data(hex: $0.pk)) })
        for c in file.cases {
            let payload = Data(c.payload.utf8)
            // Rule U's anchor, held for one home, as CloudKeys holds it.
            let offset = { (home: String) -> CloudHome.Offset? in
                guard let o = c.offset, o.home == home else { return nil }
                return CloudHome.Offset(boot: Array(Data(hex: o.boot)), offsetMs: o.offsetMs, learnedAtMs: o.learnedAtMs)
            }
            let fromJSON = PushAlert.read(payload: payload, boxKey: { keys[$0] }, offset: offset, nowMs: c.nowMs)
            // The extension gets userInfo, not the bytes: both roads agree.
            let userInfo = try #require(JSONSerialization.jsonObject(with: payload) as? [AnyHashable: Any])
            let fromUserInfo = PushAlert.read(userInfo: userInfo, boxKey: { keys[$0] }, offset: offset, nowMs: c.nowMs)
            #expect(fromJSON == fromUserInfo, "\(c.name)")

            let a = fromJSON
            let w = c.want
            #expect(a.verdict.rawValue == w.verdict, "\(c.name)")
            #expect(a.home == w.home, "\(c.name)")
            #expect(a.kind == (w.kind ?? ""), "\(c.name)")
            #expect(a.args == (w.args ?? [:]), "\(c.name)")
            #expect((a.src ?? "") == (w.src ?? ""), "\(c.name)")
            #expect((a.lp ?? "") == (w.lp ?? ""), "\(c.name)")
            #expect((a.boot?.hex ?? "") == (w.boot ?? ""), "\(c.name)")
            #expect(a.seq == (w.seq ?? 0), "\(c.name)")
            #expect(a.atMs == (w.atMs ?? 0), "\(c.name)")
        }
    }

    /// Every envelope parses, its body is the bytes carried, the signed
    /// input hashes as Go's does, and each signature verifies with its
    /// signer's key and with no other.
    @Test func everyCloudMessageVerifiesOverTheBytesItCarries() throws {
        let file = try Self.load("cloud-vectors", as: CloudFile.self)
        let home = try #require(file.boxKey.home)
        let keys = ["box": Data(hex: file.boxKey.pk), "service": Data(hex: file.serviceKey.pk)]
        #expect(file.messages.count == 27)
        for m in file.messages {
            let env = try #require(PushAlert.Envelope(Array(Data(hex: m.envelope))), "\(m.name)")
            #expect(env.t == m.t, "\(m.name)")
            #expect(Data(env.b) == Data(hex: m.body), "\(m.name)")
            #expect(Data(env.sig) == Data(hex: m.sig), "\(m.name)")
            let input = PushCBOR.signedInput(home: home, t: env.t, b: env.b)
            #expect(Data(SHA256.hash(data: input)) == Data(hex: m.signedInputSha256), "\(m.name)")
            for (signer, pk) in keys {
                #expect(PushAlert.verify(pk, home: home, env) == (signer == m.signer), "\(m.name) with the \(signer) key")
            }
            // Signed for another home, never valid.
            if let pk = keys[m.signer] {
                #expect(!PushAlert.verify(pk, home: "aaaaaaaaaaaaaaaaaaaaaaaaaa", env), "\(m.name)")
            }
            // The strict reader takes every body the box sends.
            #expect((try? PushCBOR.decode(env.b)) != nil, "\(m.name)")
        }
    }

    /// The three events of the shared vectors, delivered fresh, read as
    /// events, and session complete carries its energy.
    @Test func theSharedEventsReadAsEvents() throws {
        let file = try Self.load("cloud-vectors", as: CloudFile.self)
        let home = try #require(file.boxKey.home)
        let pk = Data(hex: file.boxKey.pk)
        for m in file.messages where m.t == "event" {
            let env = try #require(PushAlert.Envelope(Array(Data(hex: m.envelope))))
            let ev = try #require(PushAlert.Event(env.b))
            let now = try #require(ev.wallMs) + 1_200
            let a = PushAlert.read(payload: Self.payload(home: home, event: Data(hex: m.envelope)), boxKey: { $0 == home ? pk : nil }, nowMs: now)
            #expect(a.verdict == .event, "\(m.name)")
            #expect(a.kind == ev.kind)
            #expect(a.lp == "j3HZORNCWHs")
            #expect(a.src == "DUYWWQmn-Xg")
            #expect(a.boot == Data(repeating: 0xb0, count: 16))
            if ev.kind == PushKind.chargingSessionComplete {
                #expect(a.args == ["kwh": "18.4"])
                #expect(PushText.content(a, language: .en, decimalSeparator: ".").body == "18.4 kWh delivered — ready to go.")
                #expect(PushText.content(a, language: .sv, decimalSeparator: ",").body == "18,4 kWh laddat – redo att åka.")
            }
        }
    }

    // MARK: Edges, signed here with the vector box

    static let boxKey: P256.Signing.PrivateKey = {
        let file = try! load("cloud-vectors", as: CloudFile.self)
        return try! P256.Signing.PrivateKey(rawRepresentation: Data(hex: file.boxKey.d!))
    }()
    static var home: String { "fjzyr67buzpyncqmjliwgezvde" }
    static var pk: Data { boxKey.publicKey.x963Representation }
    static let wall: Int64 = 1_791_820_800_000

    static func body(_ extra: [(String, TestCBOR)] = [], drop: Set<String> = [], kind: String = PushKind.chargingConnected) -> [UInt8] {
        var fields: [(String, TestCBOR)] = [
            ("seq", .u(9)), ("boot", .b(Array(repeating: 0xb0, count: 16))), ("uptimeMs", .u(71_000)),
            ("wallMs", .u(UInt64(wall))), ("eventId", .t("Q2ZrMjR0dzVh")), ("kind", .t(kind)),
            ("severity", .t("info")), ("args", .m([])), ("lp", .t("j3HZORNCWHs")),
        ]
        fields.removeAll { drop.contains($0.0) || extra.map(\.0).contains($0.0) }
        return TestCBOR.m(fields + extra).encoded
    }

    static func envelope(_ body: [UInt8], t: String = "event", home: String = home) -> [UInt8] {
        let sig = try! boxKey.signature(for: PushCBOR.signedInput(home: home, t: t, b: body)).rawRepresentation
        return TestCBOR.m([("b", .b(body)), ("t", .t(t)), ("sig", .b(Array(sig)))]).encoded
    }

    static func payload(home: String = home, event: Data? = nil, kind: String? = nil) -> Data {
        var ftw: [String: Any] = ["v": 1, "home": home]
        if let event { ftw["event"] = event.base64EncodedString() }
        if let kind { ftw["kind"] = kind }
        let aps: [String: Any] = ["alert": ["title-loc-key": "push.title", "loc-key": "push.generic"], "mutable-content": 1, "sound": "default"]
        return try! JSONSerialization.data(withJSONObject: ["aps": aps, "ftw": ftw])
    }

    static func read(_ env: [UInt8], nowMs: Int64 = wall + 1_200, kind: String? = nil) -> PushAlert {
        PushAlert.read(payload: payload(event: Data(env), kind: kind), boxKey: { $0 == home ? pk : nil }, nowMs: nowMs)
    }

    @Test func aFreshSignedEventReads() {
        let a = Self.read(Self.envelope(Self.body()))
        #expect(a.verdict == .event)
        #expect(a.atMs == Self.wall)
        #expect(a.seq == 9)
        #expect(a.src == nil)
    }

    /// Access news is for owners only. A box sends it as a `notice`; as an
    /// `event` it also reaches viewers, so it reads as generic.
    @Test func accessNewsAsAnEventIsGeneric() {
        for kind in PushKind.notices {
            #expect(Self.read(Self.envelope(Self.body(kind: kind))).verdict == .generic, "\(kind)")
        }
    }

    /// Unknown keys are a newer box, not a fault.
    @Test func unknownKeysAreIgnored() {
        #expect(Self.read(Self.envelope(Self.body([("later", .m([("x", .u(1))]))]))).verdict == .event)
    }

    /// A field of the wrong type is not the event that was meant.
    @Test func aFieldOfTheWrongTypeIsGeneric() {
        for extra: (String, TestCBOR) in [("seq", .t("9")), ("wallMs", .t("now")), ("kind", .b([1])), ("args", .m([("kwh", .u(18))])), ("lp", .u(1)), ("ts", .neg(UInt64.max))] {
            #expect(Self.read(Self.envelope(Self.body([extra]))).verdict == .generic, "\(extra.0)")
        }
    }

    /// The box clock anchors the event; the phone's bounds it.
    @Test func theClockRules() {
        let b = Self.body()
        #expect(Self.read(Self.envelope(b), nowMs: Self.wall - 2_000).verdict == .event)
        #expect(Self.read(Self.envelope(b), nowMs: Self.wall - 2_001).verdict == .generic)
        #expect(Self.read(Self.envelope(b), nowMs: Self.wall - 2_000).atMs == Self.wall - 2_000)
        #expect(Self.read(Self.envelope(b), nowMs: Self.wall + 600_000).verdict == .event)
        #expect(Self.read(Self.envelope(b), nowMs: Self.wall + 600_001).verdict == .generic)
        // The event's own time, when earlier, is when it happened.
        let held = Self.body([("ts", .u(UInt64(Self.wall - 30_000)))])
        #expect(Self.read(Self.envelope(held)).atMs == Self.wall - 30_000)
        #expect(Self.read(Self.envelope(held), nowMs: Self.wall + 570_001).verdict == .generic)
        // No wall clock, no anchor.
        #expect(Self.read(Self.envelope(Self.body(drop: ["wallMs"]))).verdict == .generic)
    }

    /// The service's kind beside an event, or the box signing the one kind
    /// only the service may send, is generic.
    @Test func onlyTheServiceSaysUnreachableAndOnlyAlone() {
        #expect(Self.read(Self.envelope(Self.body()), kind: PushKind.boxUnreachable).verdict == .generic)
        #expect(Self.read(Self.envelope(Self.body(kind: PushKind.boxUnreachable))).verdict == .generic)
        let alone = PushAlert.read(payload: Self.payload(kind: PushKind.boxUnreachable), boxKey: { _ in nil }, nowMs: Self.wall)
        #expect(alone.verdict == .unreachable)
        #expect(alone.kind.isEmpty && alone.args.isEmpty)
    }

    /// Another type of message, signed by the same box, is not an event.
    @Test func onlyAnEventIsAnEvent() {
        #expect(Self.read(Self.envelope(Self.body(), t: "hb")).verdict == .generic)
    }

    @Test func aPayloadThatIsNotOursIsGenericWithoutAHome() {
        for json in [#"{"aps":{}}"#, #"{"ftw":{"v":2,"home":"x"}}"#, #"{"ftw":{"v":true,"home":"x"}}"#, #"{"ftw":{"v":1,"home":7}}"#, #"{"ftw":{"v":1,"home":"x","event":"not base64!"}}"#, #"{"ftw":null}"#, "[]", "nonsense"] {
            let a = PushAlert.read(payload: Data(json.utf8), boxKey: { _ in Self.pk }, nowMs: Self.wall)
            #expect(a == PushAlert(.generic, home: ""), "\(json)")
        }
    }

    /// The envelope's shape is checked byte by byte.
    @Test func theEnvelopeIsStrict() throws {
        let b = Self.body()
        let sig = Array(try Self.boxKey.signature(for: PushCBOR.signedInput(home: Self.home, t: "event", b: b)).rawRepresentation)
        let good = TestCBOR.m([("b", .b(b)), ("t", .t("event")), ("sig", .b(sig))]).encoded
        #expect(PushAlert.Envelope(good) != nil)
        // t as bytes, b as text, no sig, an empty t.
        #expect(PushAlert.Envelope(TestCBOR.m([("b", .b(b)), ("t", .b(Array("event".utf8))), ("sig", .b(sig))]).encoded) == nil)
        #expect(PushAlert.Envelope(TestCBOR.m([("b", .t("x")), ("t", .t("event")), ("sig", .b(sig))]).encoded) == nil)
        #expect(PushAlert.Envelope(TestCBOR.m([("b", .b(b)), ("t", .t("event"))]).encoded) == nil)
        #expect(PushAlert.Envelope(TestCBOR.m([("b", .b(b)), ("t", .t("")), ("sig", .b(sig))]).encoded) == nil)
        // A byte after the value, a key twice, an indefinite length.
        #expect(PushAlert.Envelope(good + [0x00]) == nil)
        #expect(PushAlert.Envelope(TestCBOR.m([("b", .b(b)), ("t", .t("event")), ("t", .t("event")), ("sig", .b(sig))]).encoded) == nil)
        var indefinite = good
        indefinite[0] = 0xbf
        #expect(PushAlert.Envelope(indefinite + [0xff]) == nil)
        // Truncated anywhere.
        for n in 0..<good.count {
            #expect(PushAlert.Envelope(Array(good.prefix(n))) == nil)
        }
    }

    @Test func aKeyThatIsNotAPointIsGeneric() {
        let env = Self.envelope(Self.body())
        for key in [Data(), Data(Self.pk.dropFirst()), Data([0x02]) + Self.pk.dropFirst().prefix(32), Data(repeating: 4, count: 65)] {
            let a = PushAlert.read(payload: Self.payload(event: Data(env)), boxKey: { _ in key }, nowMs: Self.wall + 1_200)
            #expect(a.verdict == .generic)
        }
    }
}

// MARK: - Test helpers

/// Just enough CBOR to write events, in the order given.
indirect enum TestCBOR {
    case u(UInt64)
    case neg(UInt64)
    case b([UInt8])
    case t(String)
    case m([(String, TestCBOR)])

    var encoded: [UInt8] {
        func head(_ major: UInt8, _ n: UInt64) -> [UInt8] {
            let m = major << 5
            switch n {
            case 0..<24: return [m | UInt8(n)]
            case 24...0xff: return [m | 24, UInt8(n)]
            case 0x100...0xffff: return [m | 25, UInt8(n >> 8), UInt8(n & 0xff)]
            case 0x1_0000...0xffff_ffff: return [m | 26] + (0..<4).reversed().map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) }
            default: return [m | 27] + (0..<8).reversed().map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) }
            }
        }
        switch self {
        case .u(let n): return head(0, n)
        case .neg(let n): return head(1, n)
        case .b(let b): return head(2, UInt64(b.count)) + b
        case .t(let s): return head(3, UInt64(s.utf8.count)) + Array(s.utf8)
        case .m(let pairs): return head(5, UInt64(pairs.count)) + pairs.flatMap { TestCBOR.t($0.0).encoded + $0.1.encoded }
        }
    }
}

extension Data {
    init(hex: String) {
        var out = Data()
        var it = hex.makeIterator()
        while let a = it.next(), let b = it.next() {
            out.append(UInt8(String([a, b]), radix: 16)!)
        }
        self = out
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
