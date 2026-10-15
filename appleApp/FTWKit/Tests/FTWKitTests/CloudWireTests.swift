import CryptoKit
import Foundation
import Testing
@testable import FTWKit

/// srcfl/ftw `go/protocol/cloudwire/testdata/cloud-vectors.json`, copied
/// unchanged: fixed keys, every message type and the exact bytes Go makes.
/// ECDSA signatures are randomised, so the stored ones are checked by
/// verifying them.
struct CloudVectors: Decodable {
    struct Key: Decodable {
        let d: String
        let pk: String
        let home: String?
    }

    struct OpaqueID: Decodable {
        let kind: String
        let name: String
        let id: String
    }

    struct Message: Decodable {
        let name: String
        /// "box", "service", or empty for unsigned.
        let signer: String
        let t: String
        let body: String
        let signedInputSha256: String
        let sig: String
        let envelope: String
        let frame: String
    }

    let boxKey: Key
    let serviceKey: Key
    let grantKey: String
    let ids: [OpaqueID]
    let messages: [Message]

    var home: String { boxKey.home ?? "" }

    static func load() throws -> CloudVectors {
        guard let url = Bundle.module.url(forResource: "cloud-vectors", withExtension: "json", subdirectory: "Resources") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(CloudVectors.self, from: Data(contentsOf: url))
    }

    func message(_ name: String) throws -> Message {
        try #require(messages.first { $0.name == name }, "no vector \(name)")
    }

    func envelope(_ name: String) throws -> CloudWire.Envelope {
        try CloudWire.Envelope.decode(Bytes(hex: message(name).envelope))
    }

    /// The box's signing key, for tests that need the box to say more.
    func boxSigner() throws -> P256.Signing.PrivateKey {
        try P256.Signing.PrivateKey(rawRepresentation: Bytes(hex: boxKey.d))
    }
}

/// srcfl/ftw `go/protocol/cloudwire/testdata/cloud-app-vectors.json`: one app
/// session frozen byte for byte, which the phone replays as the initiator.
struct CloudAppVectors: Decodable {
    struct Step: Decodable {
        let from: String
        let name: String
        let frame: String
        let message: String
    }

    let serviceStatic: String
    let servicePublic: String
    let serviceEphemeral: String
    let phoneStatic: String
    let phonePublic: String
    let phoneEphemeral: String
    let home: String
    let prologue: String
    let msg1Payload: String
    let msg1: String
    let msg2Payload: String
    let msg2: String
    let handshakeHash: String
    let snapshot: [String]
    let transport: [Step]
    let pairing: Pairing

    /// A new phone's proof: the code it scanned, the hash the roster lists
    /// and `now.pair` carries, message 1 with and without the box session's
    /// message 1 riding along, and the device id the service names it by.
    struct Pairing: Decodable {
        let code: String
        let hash: String
        let msg1Now: String
        let msg1NowTun: String
        let deviceId: String
    }

    static func load() throws -> CloudAppVectors {
        guard let url = Bundle.module.url(forResource: "cloud-app-vectors", withExtension: "json", subdirectory: "Resources") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(CloudAppVectors.self, from: Data(contentsOf: url))
    }
}

/// ES256 over the signed input, as the box signs. The phone never signs;
/// only tests do.
func cloudSign(_ key: P256.Signing.PrivateKey, home: String, t: String, b: Bytes) throws -> Bytes {
    Bytes(try key.signature(for: SHA256.hash(data: CloudWire.signedInput(home: home, t: t, b: b))).rawRepresentation)
}

@Suite struct CloudWireTests {
    @Test func everyGoldenMessageDecodesVerifiesAndReencodes() throws {
        let v = try CloudVectors.load()
        let boxPK = Bytes(hex: v.boxKey.pk)
        let servicePK = Bytes(hex: v.serviceKey.pk)
        #expect(v.messages.count == 22)

        for m in v.messages {
            let frame = Bytes(hex: m.frame)
            let payload = try CloudWire.decodeFrame(frame)
            #expect(payload.hex == m.envelope, "\(m.name)")
            #expect(try CloudWire.encodeFrame(payload) == frame, "\(m.name)")

            let env = try CloudWire.Envelope.decode(payload)
            #expect(env.t == m.t, "\(m.name)")
            #expect(env.b.hex == m.body, "\(m.name)")
            #expect(env.sig.hex == m.sig, "\(m.name)")
            #expect(env.encode() == payload, "\(m.name)")
            #expect(Primitives.sha256(CloudWire.signedInput(home: v.home, t: m.t, b: env.b)).hex == m.signedInputSha256, "\(m.name)")

            if m.signer.isEmpty {
                #expect(env.sig.isEmpty, "\(m.name)")
                #expect(CloudWire.encodeUnsigned(t: m.t, body: try decodeCBOR(env.b)) == payload, "\(m.name)")
                continue
            }
            let (key, other) = m.signer == "box" ? (boxPK, servicePK) : (servicePK, boxPK)
            #expect(CloudWire.verify(boxKey: key, home: v.home, envelope: env), "\(m.name)")
            #expect(!CloudWire.verify(boxKey: other, home: v.home, envelope: env), "\(m.name) verified with the wrong key")
            var changed = env
            changed.b[changed.b.count / 2] ^= 0x01
            #expect(!CloudWire.verify(boxKey: key, home: v.home, envelope: changed), "\(m.name) verified with a flipped byte")
        }
    }

    @Test func homeAndOpaqueIDsMatchGo() throws {
        let v = try CloudVectors.load()
        let boxPK = Bytes(hex: v.boxKey.pk)
        #expect(CloudWire.homeID(pk: boxPK) == v.home)
        #expect(Bytes(try v.boxSigner().publicKey.x963Representation) == boxPK)
        let service = try P256.Signing.PrivateKey(rawRepresentation: Bytes(hex: v.serviceKey.d))
        #expect(Bytes(service.publicKey.x963Representation).hex == v.serviceKey.pk)

        let grantKey = Bytes(hex: v.grantKey)
        #expect(v.ids.count == 4)
        for id in v.ids {
            let got = id.kind == "src"
                ? CloudWire.sourceID(grantKey: grantKey, driver: id.name)
                : CloudWire.loadpointID(grantKey: grantKey, loadpoint: id.name)
            #expect(got == id.id, "\(id.kind) \(id.name)")
        }
        // A loadpoint and a source with one name do not share an id.
        #expect(CloudWire.sourceID(grantKey: grantKey, driver: "garage") != CloudWire.loadpointID(grantKey: grantKey, loadpoint: "garage"))
    }

    @Test func goldenBodiesDecodeToTheirFields() throws {
        let v = try CloudVectors.load()
        let grantKey = Bytes(hex: v.grantKey)
        let meter = CloudWire.sourceID(grantKey: grantKey, driver: "p1meter")
        let inverter = CloudWire.sourceID(grantKey: grantKey, driver: "sungrow")
        let charger = CloudWire.sourceID(grantKey: grantKey, driver: "easee")
        let garage = CloudWire.loadpointID(grantKey: grantKey, loadpoint: "garage")
        let wall: Int64 = 1_791_820_800_000
        let boot = Bytes(repeating: 0xb0, count: CloudWire.bootBytes)

        let full = try CloudWire.Live(body: v.envelope("live full").b)
        #expect(full.header == CloudWire.Header(seq: 3, boot: boot, uptimeMs: 60_020, wallMs: wall + 20))
        #expect(full.fields == ["1": 0, "2": 1840, "3": -2310, "4": 950, "5": 612, "6": 1100, "10": 2100])
        #expect(full.fieldSources?["6"] == [charger, inverter, meter])
        #expect(full.sources?[charger] == CloudWire.Source(kind: "driver", state: .lagging, lastOkMs: 1_000, staleAfterMs: 30_000))
        #expect(full.sources?.count == 3)
        #expect(full.srcRev == 1)
        #expect(full.ages == [meter: 920, inverter: 2620, charger: 59_020])
        #expect(full.dispatchBlockedBy.isEmpty)

        // A delta carries no table, which is not the same as an empty one.
        let delta = try CloudWire.Live(body: v.envelope("live delta").b)
        #expect(delta.sources == nil)
        #expect(delta.fieldSources == nil)
        #expect(delta.fields["2"] == 1795)

        let lp = try CloudWire.LP(body: v.envelope("lp").b)
        #expect(lp.header.seq == 5)
        #expect(lp.controlRev == 812)
        let car = try #require(lp.loadpoints.first)
        #expect(lp.loadpoints.count == 1)
        #expect(car.id == garage && car.src == charger && car.plugged)
        #expect(car.socPermille == 430 && car.socSource == "inferred" && car.socAgeS == 1800)
        #expect(car.targetPermille == 800 && car.readyByMs == 1_791_867_600_000 && car.recurring)
        #expect(car.powerW == 2100 && car.sessionWh == 3400 && car.session == "s1")
        #expect(car.manual == nil)
        #expect(car.commandedW == 2070 && car.commandedReason == "plan")
        #expect(!car.surplusOnly && !car.gridDeferred && !car.planPending && !car.boost)
        #expect(car.nextStartMs == 1_791_850_000_000 && car.nextEndMs == 1_791_857_200_000 && car.nextWh == 7400)
        #expect(lp.feedback == [CloudWire.Feedback(kind: "ev", src: charger, status: "following", reason: "plan", severity: "ok",
                                                   evidence: "measured", fresh: true, actualW: 2100, ageMs: 900)])

        let prices = try CloudWire.Prices(body: v.envelope("prices").b)
        #expect(prices.zone == "SE3" && prices.currency == "SEK")
        #expect(prices.t0Ms == 1_791_820_800_000 && prices.slotMs == 900_000)
        #expect(prices.spotMinor == [42, 40, nil, -3])
        #expect(prices.totalMinor == [118, 115, nil, 71])

        let hb = try CloudWire.HB(body: v.envelope("hb").b)
        #expect(hb.header == CloudWire.Header(seq: 7, boot: boot, uptimeMs: 69_020, wallMs: wall + 9_020))
        #expect(hb.clock == "ntp" && hb.srcRev == 1 && hb.liveSeq == 4 && hb.lpSeq == 5)
        #expect(hb.ages == [meter: 1_400, inverter: 3_100])
    }

    @Test func unsignedEnvelopesPutTheirBodyInDeterministicOrder() throws {
        let v = try CloudVectors.load()
        // Keys given out of order come out as Go's core deterministic
        // encoder writes them: shorter first, then by bytes.
        let challenge = CBOR.map([("nonce", .bytes(Bytes(repeating: 0x11, count: 32))), ("v", .int(1))])
        #expect(CloudWire.encodeUnsigned(t: "challenge", body: challenge).hex == (try v.message("challenge").envelope))
        #expect(CloudWire.encodeUnsigned(t: CloudWire.msgWatch, body: .map(["hz": .int(1)])).hex == (try v.message("watch").envelope))
        #expect(CloudWire.encodeUnsigned(t: "resync", body: .map(["what": .array([.text("full")])])).hex == (try v.message("resync").envelope))
        let nested = CBOR.map([("zz", .map([("bb", .int(1)), ("a", .int(2))])), ("y", .array([.map([("cc", .int(3)), ("d", .int(4))])]))])
        // {"y": [{"d": 4, "cc": 3}], "zz": {"a": 2, "bb": 1}}
        #expect(encodeCBOR(CloudWire.deterministic(nested)).hex == "a2617981a261640462636303627a7aa261610262626201")
    }

    @Test func appSessionReplaysAsTheInitiator() throws {
        let v = try CloudAppVectors.load()
        let signed = try CloudVectors.load()
        let boxPK = Bytes(hex: signed.boxKey.pk)

        let phone = try Primitives.keyPair(fromSecret: Bytes(hex: v.phoneStatic))
        #expect(phone.publicKey.hex == v.phonePublic)
        #expect(try Primitives.keyPair(fromSecret: Bytes(hex: v.serviceStatic)).publicKey.hex == v.servicePublic)
        #expect(v.home == signed.home)
        let prologue = CloudWire.appPrologue(home: v.home)
        #expect(prologue.hex == v.prologue)

        let msg1Payload = CloudWire.encodeUnsigned(t: CloudWire.msgNow, body: .map(["hz": .int(CloudWire.hzLooking)]))
        #expect(msg1Payload.hex == v.msg1Payload)
        let handshake = try HandshakeState.initiator(
            staticKey: phone,
            remoteStatic: Bytes(hex: v.servicePublic),
            prologue: prologue,
            ephemeral: try Primitives.keyPair(fromSecret: Bytes(hex: v.phoneEphemeral))
        )
        #expect(try handshake.writeMessage(msg1Payload).hex == v.msg1)
        let msg2Payload = try handshake.readMessage(Bytes(hex: v.msg2))
        #expect(msg2Payload.hex == v.msg2Payload)

        let snapshot = try CloudWire.parseSnapshot(payload: msg2Payload)
        #expect(snapshot.online)
        #expect(snapshot.more == 0)
        #expect(snapshot.lastSeenMs == 1_791_820_869_000)
        #expect(snapshot.envelopes.count == v.snapshot.count)
        for (entry, name) in zip(snapshot.envelopes, v.snapshot) {
            #expect(entry == (try signed.envelope(name)), "\(name)")
            #expect(entry.encode().hex == (try signed.message(name).envelope), "\(name)")
            #expect(CloudWire.verify(boxKey: boxPK, home: v.home, envelope: entry), "\(name)")
        }

        let transport = NoiseTransport(try handshake.split())
        #expect(transport.handshakeHash.hex == v.handshakeHash)
        #expect(v.transport.count == 7)
        for step in v.transport {
            let frame = Bytes(hex: step.frame)
            if step.from == "service", step.name.hasPrefix("tun") {
                // The box session riding along: unsigned, opaque here.
                #expect(try transport.decrypt(Bytes(hex: step.message)) == frame, "\(step.name)")
                let env = try CloudWire.Envelope.decode(CloudWire.decodeFrame(frame))
                #expect(env.t == CloudWire.msgTun && env.sig.isEmpty, "\(step.name)")
                let tun = try CloudWire.Tun(body: env.b)
                #expect(tun.sid == 7, "\(step.name)")
                #expect(tun.d == (step.name == "tun end" ? [] : Bytes(repeating: 0x99, count: 112)), "\(step.name)")
                #expect(tun.ended == (step.name == "tun end"), "\(step.name)")
            } else if step.from == "service" {
                #expect(try transport.decrypt(Bytes(hex: step.message)) == frame, "\(step.name)")
                let env = try CloudWire.Envelope.decode(CloudWire.decodeFrame(frame))
                #expect(env == (try signed.envelope(step.name)), "\(step.name)")
                #expect(CloudWire.verify(boxKey: boxPK, home: v.home, envelope: env), "\(step.name)")
            } else {
                #expect(try transport.encrypt(frame).hex == step.message, "\(step.name)")
            }
        }
        // The phone's own frames are what encodeUnsigned writes.
        let away = try CloudWire.encodeFrame(CloudWire.encodeUnsigned(t: CloudWire.msgWatch, body: .map(["hz": .int(CloudWire.hzAway)])))
        let suspend = try CloudWire.encodeFrame(CloudWire.encodeUnsigned(t: CloudWire.msgSuspend, body: .map(["deviceId": .text("Zf09xQ2a")])))
        let tun = try CloudWire.encodeFrame(CloudWire.encodeUnsigned(t: CloudWire.msgTun, body: CloudWire.Tun(sid: 7, d: Bytes(repeating: 0x9a, count: 48)).body))
        #expect(v.transport.filter { $0.from == "phone" }.map(\.frame) == [away.hex, suspend.hex, tun.hex])
    }

    /// A new phone proves the code it scanned without showing it, and its
    /// box session's message 1 rides message 1: Go's bytes, exactly.
    @Test func aNewPhonesMessage1MatchesGo() throws {
        let v = try CloudAppVectors.load()
        let code = Bytes(hex: v.pairing.code)
        let hash = CloudWire.pairingHash(home: v.home, code: code)
        #expect(hash.hex == v.pairing.hash)
        #expect(CloudWire.now(hz: CloudWire.hzLooking, pair: hash).hex == v.pairing.msg1Now)
        let tun = CloudWire.Tun(sid: 1, d: Bytes(repeating: 0x9b, count: 112))
        #expect(CloudWire.now(hz: CloudWire.hzLooking, pair: hash, tun: tun).hex == v.pairing.msg1NowTun)
        #expect(CloudWire.now(hz: CloudWire.hzLooking).hex == v.msg1Payload)
        #expect(CloudWire.deviceID(key: Bytes(hex: v.phonePublic)) == v.pairing.deviceId)
    }

    /// The uplink's tun carries a device id the phone never sends; a phone
    /// reading one ignores it, as Go ignores unknown keys.
    @Test func tunBodiesReadAsGoWritesThem() throws {
        let signed = try CloudVectors.load()
        for name in ["tun down", "tun up", "tun end"] {
            let tun = try CloudWire.Tun(body: signed.envelope(name).b)
            #expect(tun.ended == (name == "tun end"), "\(name)")
            #expect(tun.sid != 0, "\(name)")
        }
        #expect(throws: CloudWire.WireError.self) { try CloudWire.Tun(body: encodeCBOR(.map([("sid", .text("7")), ("d", .bytes([1]))]))) }
        #expect(throws: CloudWire.WireError.self) { try CloudWire.Tun(body: encodeCBOR(.map([("sid", .unsigned(1 << 32)), ("d", .bytes([1]))]))) }
        #expect(CloudWire.validHome(signed.home))
        for bad in ["", String(signed.home.dropLast()), signed.home.uppercased(), signed.home.dropLast() + "1", signed.home + "a"] {
            #expect(!CloudWire.validHome(String(bad)), "\(bad)")
        }
    }

    @Test func framesRefuseWhatThisProtocolNeverSends() throws {
        let good: Bytes = [1, 1, 0, 0, 0, 2, 0xa0, 0xa0]
        let cases: [String: Bytes] = [
            "short": [1, 1, 0],
            "version": [2, 1, 0, 0, 0, 2, 0xa0, 0xa0],
            "lane 0": [1, 0, 0, 0, 0, 2, 0xa0, 0xa0],
            "flag": [1, 1, 2, 0, 0, 2, 0xa0, 0xa0],
            "reserved": [1, 1, 0, 1, 0, 2, 0xa0, 0xa0],
            "padding": good + [0],
            "overrun": [1, 1, 0, 0, 0, 9, 0xa0],
            "short length": [1, 1, 0, 0, 0, 1, 0xa0, 0xa0],
        ]
        for (name, msg) in cases {
            #expect(throws: CloudWire.WireError.self, "\(name)") { try CloudWire.decodeFrame(msg) }
        }
        #expect(try CloudWire.decodeFrame(good) == [0xa0, 0xa0])
        #expect(try CloudWire.encodeFrame([0xa3, 1, 2, 3]) == [1, 1, 0, 0, 0, 4, 0xa3, 1, 2, 3])
        #expect(throws: CloudWire.WireError.self) { try CloudWire.encodeFrame(Bytes(repeating: 0, count: CloudWire.maxPayload + 1)) }
    }

    @Test func anEmptySignatureIsAnEmptyByteString() throws {
        let raw = CloudWire.Envelope(t: CloudWire.msgWatch, b: [0xa1, 0x62, 0x68, 0x7a, 1]).encode()
        // {"b": h'a162687a01', "t": "watch", "sig": h''}
        #expect(raw.hex == "a3616245a162687a0161746577617463686373696740")
        let back = try CloudWire.Envelope.decode(raw)
        #expect(back.t == CloudWire.msgWatch && back.sig.isEmpty && back.b == [0xa1, 0x62, 0x68, 0x7a, 1])
    }

    @Test func envelopesRefuseTheWrongShapes() {
        func mk(_ pairs: [(String, CBOR)]) -> Bytes { encodeCBOR(.map(pairs)) }
        let cases: [String: Bytes] = [
            "not a map": encodeCBOR(.array([.int(1)])),
            "no type": mk([("b", .bytes([1])), ("sig", .bytes([]))]),
            "no body": mk([("t", .text("hb")), ("sig", .bytes([]))]),
            "no sig": mk([("t", .text("hb")), ("b", .bytes([1]))]),
            "text body": mk([("t", .text("hb")), ("b", .text("a0")), ("sig", .bytes([]))]),
            "bytes type": mk([("t", .bytes(Bytes("hb".utf8))), ("b", .bytes([1])), ("sig", .bytes([]))]),
            "empty type": mk([("t", .text("")), ("b", .bytes([1])), ("sig", .bytes([]))]),
            "text sig": mk([("t", .text("hb")), ("b", .bytes([1])), ("sig", .text(""))]),
            "null sig": mk([("t", .text("hb")), ("b", .bytes([1])), ("sig", .null)]),
            "integer body": mk([("t", .text("hb")), ("b", .int(5)), ("sig", .bytes([]))]),
            "integer key": encodeCBOR(.map([CBOR.Entry(.int(1), .int(1)), CBOR.Entry(.text("t"), .text("hb")),
                                            CBOR.Entry(.text("b"), .bytes([1])), CBOR.Entry(.text("sig"), .bytes([]))])),
            "garbage": [0xff, 0x00],
            "duplicate t": [0xa4, 0x61, 0x62, 0x41, 0, 0x61, 0x74, 0x61, 0x78, 0x61, 0x74, 0x61, 0x79, 0x63, 0x73, 0x69, 0x67, 0x40],
            "truncated": [0xa3, 0x61, 0x62],
            "trailing": mk([("t", .text("hb")), ("b", .bytes([1])), ("sig", .bytes([]))]) + [0],
        ]
        for (name, raw) in cases {
            #expect(throws: CloudWire.WireError.self, "\(name)") { try CloudWire.Envelope.decode(raw) }
        }
        // Unknown keys are ignored.
        let extra = mk([("b", .bytes([1])), ("t", .text("hb")), ("sig", .bytes([])), ("zz", .int(9))])
        #expect((try? CloudWire.Envelope.decode(extra)) == CloudWire.Envelope(t: "hb", b: [1]))
    }

    @Test func theSignatureCoversHomeTypeAndEveryBodyByte() throws {
        let v = try CloudVectors.load()
        let boxPK = Bytes(hex: v.boxKey.pk)
        let env = try v.envelope("hb")
        #expect(CloudWire.verify(boxKey: boxPK, home: v.home, envelope: env))
        for i in env.b.indices {
            var changed = env
            changed.b[i] ^= 0x01
            #expect(!CloudWire.verify(boxKey: boxPK, home: v.home, envelope: changed), "byte \(i)")
        }
        var other = env
        other.t = CloudWire.msgLive
        #expect(!CloudWire.verify(boxKey: boxPK, home: v.home, envelope: other))
        #expect(!CloudWire.verify(boxKey: boxPK, home: "aaaaaaaaaaaaaaaaaaaaaaaaaa", envelope: env))
        var short = env
        short.sig.removeLast()
        #expect(!CloudWire.verify(boxKey: boxPK, home: v.home, envelope: short))
        #expect(!CloudWire.verify(boxKey: Array(boxPK.dropLast()), home: v.home, envelope: env))
        var offCurve = boxPK
        offCurve[64] ^= 1
        #expect(!CloudWire.verify(boxKey: offCurve, home: v.home, envelope: env))
        // A signature this file makes verifies as Go's do.
        let mine = CloudWire.Envelope(t: env.t, b: env.b, sig: try cloudSign(v.boxSigner(), home: v.home, t: env.t, b: env.b))
        #expect(CloudWire.verify(boxKey: boxPK, home: v.home, envelope: mine))
    }

    @Test func aHomeIDIsTwentySixLowercaseCharacters() throws {
        let home = CloudWire.homeID(pk: Bytes(hex: try CloudVectors.load().boxKey.pk))
        #expect(home.count == 26)
        #expect(home.utf8.allSatisfy { (0x61...0x7a).contains($0) || (0x32...0x37).contains($0) })
        #expect(String(decoding: CloudWire.appPrologue(home: "fjzyr67buzpyncqmjliwgezvde"), as: UTF8.self) == "ftw.cloud.v1:fjzyr67buzpyncqmjliwgezvde")
    }

    @Test func aSnapshotIsTheOnlyMessageTwo() throws {
        let now = CloudWire.encodeUnsigned(t: CloudWire.msgNow, body: .map(["hz": .int(1)]))
        #expect(throws: CloudWire.WireError.self) { try CloudWire.parseSnapshot(payload: now) }
        let notEnvelopes = CloudWire.encodeUnsigned(t: CloudWire.msgSnapshot, body: .map(["envelopes": .array([.emptyMap])]))
        #expect(throws: CloudWire.WireError.self) { try CloudWire.parseSnapshot(payload: notEnvelopes) }
    }

    @Test func bodiesIgnoreUnknownKeysAndRefuseTheWrongTypes() throws {
        func body(_ pairs: [(String, CBOR)]) -> Bytes { encodeCBOR(.map(pairs)) }
        let hb = try CloudWire.HB(body: body([("seq", .int(4)), ("future", .text("x")), ("wallMs", .null), ("liveSeq", .int(3))]))
        #expect(hb.header.seq == 4 && hb.header.wallMs == nil && hb.liveSeq == 3 && hb.ages.isEmpty && hb.clock.isEmpty)

        let refused: [String: Bytes] = [
            "empty": [],
            "not a map": encodeCBOR(.array([])),
            "negative seq": body([("seq", .int(-1))]),
            "text seq": body([("seq", .text("1"))]),
            "float uptime": body([("seq", .int(1)), ("uptimeMs", .double(1.5))]),
            "text boot": body([("seq", .int(1)), ("boot", .text("b"))]),
            "too large": body([("seq", .int(1)), ("uptimeMs", .unsigned(UInt64(Int64.max) + 1))]),
        ]
        for (name, raw) in refused {
            #expect(throws: CloudWire.WireError.self, "\(name)") { try CloudWire.Header(body: raw) }
        }
        #expect(throws: CloudWire.WireError.self) { try CloudWire.Live(body: body([("fields", .map(["2": .text("1")]))])) }
        #expect(throws: CloudWire.WireError.self) { try CloudWire.Live(body: body([("sources", .array([]))])) }
        #expect(throws: CloudWire.WireError.self) { try CloudWire.LP(body: body([("loadpoints", .array([.map(["plugged": .int(1)])]))])) }

        // A state this build does not know ranks as never.
        let live = try CloudWire.Live(body: body([("sources", .map(["m": .map(["state": .text("melting")])]))]))
        #expect(live.sources?["m"]?.state == .never)
    }
}
