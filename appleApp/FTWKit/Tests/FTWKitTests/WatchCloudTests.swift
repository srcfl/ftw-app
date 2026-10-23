import CryptoKit
import Foundation
import Testing
@testable import FTWKit
@testable import FTWWire

// The watch's own door through FTW Cloud: the one-shot request, the box's
// exchange carried as x, and what one read becomes on the wrist. The bytes
// come from srcfl/ftw's golden vectors, so Swift and Go agree on each.

private func vectors<T: Decodable>(_ name: String, as _: T.Type) throws -> T {
    guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Resources") else {
        throw CocoaError(.fileNoSuchFile)
    }
    return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
}

/// `go/protocol/cloudwire/testdata/cloud-once-vectors.json`.
private struct OnceVectors: Decodable {
    struct Step: Decodable {
        let name: String
        let frame: String
    }

    let servicePublic: String
    let watchStatic: String
    let watchEphemeral: String
    let home: String
    let msg1Payload: String
    let request: String
    let msg2Payload: String
    let following: [Step]
    let answer: String
}

/// `go/protocol/cloudwire/testdata/cloud-once-x-vectors.json`.
private struct OnceXVectors: Decodable {
    let servicePublic: String
    let watchStatic: String
    let watchEphemeral: String
    let home: String
    let msg1Payload: String
    let request: String
    let msg2Payload: String
    let answer: String
}

/// `go/internal/appuplink/testdata/exchange-vectors.json` in srcfl/ftw.
private struct ExchangeVectors: Decodable {
    struct Step: Decodable {
        let name: String
        let frames: [String]
        let body: String
    }

    let boxStaticPublic: String
    let watchStatic: String
    let watchEphemeral: String
    let steps: [Step]

    func step(_ name: String) throws -> Step { try #require(steps.first { $0.name == name }) }
}

private func key(_ secretHex: String) throws -> Primitives.KeyPair {
    try Primitives.keyPair(fromSecret: Bytes(hex: secretHex))
}

@Suite struct CloudOnceTests {
    /// The read: message 1 byte for byte, and the answer opens into the
    /// snapshot and the envelope that followed it.
    @Test func aReadMatchesTheVectors() throws {
        let v = try vectors("cloud-once-vectors", as: OnceVectors.self)
        let req = try CloudOnce.Request(home: v.home, serviceKey: Bytes(hex: v.servicePublic), staticKey: key(v.watchStatic),
                                        payload: Bytes(hex: v.msg1Payload), ephemeral: key(v.watchEphemeral))
        #expect(req.body == Bytes(hex: v.request))
        let (payload, following) = try req.answer(Bytes(hex: v.answer))
        #expect(payload == Bytes(hex: v.msg2Payload))
        #expect(following == v.following.map { Array(Bytes(hex: $0.frame).dropFirst(CloudWire.headerBytes)) })
        let snap = try CloudOnce.snapshot(payload: payload, following: following)
        #expect(snap.envelopes.count == 3)
    }

    /// An exchange request: x {d} in message 1, the box's d back in
    /// message 2.
    @Test func anExchangeRequestMatchesTheVectors() throws {
        let v = try vectors("cloud-once-x-vectors", as: OnceXVectors.self)
        let d = Bytes(repeating: 0x5a, count: Noise.message1Overhead + 512)
        #expect(CloudOnce.x(d) == Bytes(hex: v.msg1Payload))
        let req = try CloudOnce.Request(home: v.home, serviceKey: Bytes(hex: v.servicePublic), staticKey: key(v.watchStatic),
                                        payload: CloudOnce.x(d), ephemeral: key(v.watchEphemeral))
        #expect(req.body == Bytes(hex: v.request))
        let (payload, following) = try req.answer(Bytes(hex: v.answer))
        #expect(following.isEmpty)
        #expect(try CloudOnce.xAnswer(payload: payload) == Bytes(repeating: 0xa5, count: Noise.message2Overhead + 1024))
    }

    /// No answer from the box is an empty d, not an error.
    @Test func anEmptyAnswerIsNoAnswer() throws {
        let payload = CloudWire.encodeUnsigned(t: CloudOnce.msgX, body: .map([("d", .bytes([]))]))
        #expect(try CloudOnce.xAnswer(payload: payload).isEmpty)
        #expect(throws: (any Error).self) { try CloudOnce.xAnswer(payload: CloudOnce.read(looking: true)) }
    }

    /// The one-shot address sits beside the app session's, over HTTPS, and a
    /// shard's host takes the place of the endpoint's.
    @Test func theAddressFollowsTheEndpoint() throws {
        let e = CloudEndpoint(url: URL(string: "wss://cloud.ftw.energy/v1/app")!, serviceKeys: [])
        #expect(CloudOnce.url(e, home: "h1").absoluteString == "https://cloud.ftw.energy/v1/app/once?home=h1")
        #expect(CloudOnce.url(e, home: "h1", host: "c2.ftw.energy").absoluteString == "https://c2.ftw.energy/v1/app/once?home=h1")
        let local = CloudEndpoint(url: URL(string: "ws://127.0.0.1:18080/v1/app")!, serviceKeys: [])
        #expect(CloudOnce.url(local, home: "h1").absoluteString == "http://127.0.0.1:18080/v1/app/once?home=h1")
    }
}

@Suite struct ExchangeTests {
    /// Every step of one exchange, against the box's own bytes: the hello
    /// in message 1, hello_ok, a command answered by its ack and result,
    /// and a read answered by now and a tick.
    @Test func anExchangeMatchesTheVectors() throws {
        let v = try vectors("exchange-vectors", as: ExchangeVectors.self)
        let session = try ExchangeSession(boxKey: Bytes(hex: v.boxStaticPublic), staticKey: key(v.watchStatic), ephemeral: key(v.watchEphemeral))
        let x1 = try v.step("x1.request")
        #expect(try session.open(build: "vectors") == Bytes(hex: x1.body))

        let opened = try session.opened(Bytes(hex: v.step("x1.answer").body))
        #expect(opened == ExchangeSession.Opened(uptimeMs: 60_000, rev: 7, role: "watch",
                                                 scopes: ["ftw.dispatch.write", "ftw.events.read", "ftw.live.read", "ftw.plan.read"]))

        let cmd = try v.step("cmd.request")
        #expect(try session.seal(Bytes(hex: cmd.frames[0])) == Bytes(hex: cmd.body))
        let answer = try session.answer(Bytes(hex: v.step("cmd.answer").body))
        #expect(answer.map(\.t) == ["cmd.ack", "cmd.result"])
        #expect(ExchangeSession.outcome(answer, cmdId: "0192f2a0-7c1e-7000-8000-0123456789ab") == .applied)

        let now = try v.step("now.request")
        #expect(try session.seal(Bytes(hex: now.frames[0])) == Bytes(hex: now.body))
        #expect(try session.answer(Bytes(hex: v.step("now.answer").body)).map(\.t) == ["now", "tick"])
    }

    /// A request is one lane 0 frame, whatever it carries, so the service
    /// cannot tell a command from a read by its length.
    @Test func aRequestHasOneLength() throws {
        let v = try vectors("exchange-vectors", as: ExchangeVectors.self)
        let other = try ExchangeSession(boxKey: Bytes(hex: v.boxStaticPublic), staticKey: key(v.watchStatic))
        #expect(try other.open(build: "a longer build name").count == ExchangeSession.openBytes)
        let session = try ExchangeSession(boxKey: Bytes(hex: v.boxStaticPublic), staticKey: key(v.watchStatic), ephemeral: key(v.watchEphemeral))
        _ = try session.open(build: "vectors")
        try session.opened(Bytes(hex: v.step("x1.answer").body))
        let c = WatchCommand(op: .chargeNow(loadpointID: "garage"), home: "site", sentAtMs: 1_000)
        let opened = try #require(session.opened)
        let cmd = try #require(ExchangeSession.cmd(c, link: link, opened: opened, leftMs: 29_800))
        #expect(try session.request(cmd).count == ExchangeSession.requestBytes)
        #expect(try session.request(Envelope(t: "now", b: .map([(String, CBOR)]()))).count == ExchangeSession.requestBytes)
    }

    private var link: WatchLink {
        WatchLink(site: "site", cloudHome: "home", boxKey: Data(count: 32), cloudKey: nil, sources: [:], loadpoints: [:],
                  watchKey: Data(count: 32), chargeNow: ["garage": .init(powerW: 11_000, phaseMode: "3p")], timeZone: nil)
    }

    /// The watch sends what the phone's car view sends, under the watch's
    /// own cmdId, and expires in box uptime. The mode and which car stay
    /// with the phone, and a tap past its life is not sent.
    @Test func theCommandIsThePhones() throws {
        let opened = ExchangeSession.Opened(uptimeMs: 500_000, rev: 9, role: "watch", scopes: [])
        let c = WatchCommand(op: .chargeNow(loadpointID: "garage"), home: "site", sentAtMs: 10_000)
        let env = try #require(ExchangeSession.cmd(c, link: link, opened: opened, leftMs: 27_500))
        let b = try #require(env.b)
        #expect(env.t == "cmd")
        #expect(b["cmdId"]?.string == c.id)
        #expect(b["op"]?.string == Contract.opLoadpointHold)
        #expect(b["args"]?["power_w"]?.double == 11_000)
        #expect(b["args"]?["phase_mode"]?.string == "3p")
        #expect(b["args"]?["hold_s"]?.int == 0)
        #expect(b["expect"]?["rev"]?.int == 9)
        // 500 s of uptime at hello_ok, and 27.5 s of the tap's 30 s left.
        #expect(b["notValidAfterMs"]?.int == 527_500)

        let pause = try #require(ExchangeSession.cmd(WatchCommand(op: .pause(loadpointID: "garage"), home: "site", sentAtMs: 10_000), link: link, opened: opened, leftMs: 27_500))
        #expect(pause.b?["args"]?["power_w"]?.int == 0)
        let back = try #require(ExchangeSession.cmd(WatchCommand(op: .backToPlan(loadpointID: "garage"), home: "site", sentAtMs: 10_000), link: link, opened: opened, leftMs: 27_500))
        #expect(back.b?["args"]?["clear"]?.bool == true)

        #expect(ExchangeSession.cmd(WatchCommand(op: .mode("charge"), home: "site", sentAtMs: 10_000), link: link, opened: opened, leftMs: 27_500) == nil)
        #expect(ExchangeSession.cmd(WatchCommand(op: .chargeNow(loadpointID: "other"), home: "site", sentAtMs: 10_000), link: link, opened: opened, leftMs: 27_500) == nil)
        #expect(ExchangeSession.cmd(c, link: link, opened: opened, leftMs: 0) == nil)
    }

    /// What one answer says, frame by frame.
    @Test func theAnswerSaysWhatTheBoxDid() {
        func frame(_ t: String, _ b: [(String, CBOR)]) -> Envelope { Envelope(t: t, b: .map(b)) }
        let ack = frame("cmd.ack", [("cmdId", .text("c1"))])
        let tick = frame("tick", [("uptimeMs", .int(1))])
        #expect(ExchangeSession.outcome([ack, frame("cmd.result", [("cmdId", .text("c1")), ("state", .text("applied"))])], cmdId: "c1") == .applied)
        #expect(ExchangeSession.outcome([ack, tick], cmdId: "c1") == .pending)
        #expect(ExchangeSession.outcome([ack, frame("cmd.result", [("cmdId", .text("c1")), ("state", .text("rejected")),
                                                                    ("error", .map([("code", .text("E_SCOPE_DENIED"))]))])], cmdId: "c1") == .refused(.mayNot))
        #expect(ExchangeSession.outcome([ack, frame("cmd.result", [("cmdId", .text("c1")), ("state", .text("rejected")),
                                                                    ("error", .map([("code", .text("E_CONFLICT"))]))])], cmdId: "c1") == .refused(.changed))
        #expect(ExchangeSession.outcome([ack, frame("cmd.result", [("cmdId", .text("c1")), ("state", .text("expired"))])], cmdId: "c1") == .refused(.tooLate))
        #expect(ExchangeSession.outcome([frame("error", [("code", .text("E_UNKNOWN_OP"))]), tick], cmdId: "c1") == .refused(.mayNot))
        #expect(ExchangeSession.outcome([tick, tick], cmdId: "c1") == .unread)
        // Another command's ack is not this one's.
        #expect(ExchangeSession.outcome([frame("cmd.ack", [("cmdId", .text("c2"))]), tick], cmdId: "c1") == .unread)
    }
}

@Suite struct WatchCloudTests {
    private let transit: Int64 = 100

    /// One read of a home with a battery, the sun and a car charging.
    private func snapshot(_ box: inout FakeCloudBox, at t0: Int64, sourceAge: Int64 = 1_000, blocked: [String] = []) throws -> CloudWire.Snapshot {
        let h = box.header(t0)
        let m = CBOR.map([("kind", .text("meter")), ("state", .text("live")), ("lastOkMs", .int(t0 - box.start - sourceAge)), ("staleAfterMs", .int(10_000))])
        let live = try box.seal(CloudWire.msgLive, h + [
            ("fields", .map(["1": .int(0), "2": .int(-1_200), "3": .int(-4_100), "4": .int(1_500), "5": .int(624), "6": .int(1_400), "10": .int(7_400)])),
            ("fieldSources", .map(["2": .array([.text("m")]), "3": .array([.text("m")]), "4": .array([.text("m")]), "6": .array([.text("m")]), "10": .array([.text("m")])])),
            ("sources", .map(["m": m])),
            ("srcRev", .unsigned(1)),
            ("ages", .map(["m": .int(sourceAge)])),
            ("dispatchBlockedBy", .array(blocked.map { .text($0) })),
        ])
        let h1 = box.header(t0 + 1), h2 = box.header(t0 + 2), h3 = box.header(t0 + 3)
        let lp = try box.seal(CloudWire.msgLP, h1 + [
            ("controlRev", .unsigned(4)),
            ("loadpoints", .array([.map([
                ("id", .text("lpA")), ("src", .text("m")), ("plugged", .bool(true)), ("socPermille", .unsigned(560)),
                ("socSource", .text("vehicle")), ("socAgeS", .unsigned(60)), ("targetPermille", .unsigned(800)), ("readyByMs", .null),
                ("recurring", .bool(false)), ("powerW", .int(7_400)), ("sessionWh", .unsigned(3_000)), ("session", .text("s1")),
                ("manual", .null), ("commandedW", .null), ("commandedReason", .text("")), ("surplusOnly", .bool(false)),
                ("gridDeferred", .bool(false)), ("planPending", .bool(false)), ("boost", .bool(false)),
                ("nextStartMs", .null), ("nextEndMs", .null), ("nextWh", .null),
            ])])),
            ("feedback", .array([])),
        ])
        let prices = try box.seal(CloudWire.msgPrices, h2 + [
            ("zone", .text("SE3")), ("currency", .text("SEK")), ("t0Ms", .int(1_791_756_000_000)), ("slotMs", .unsigned(900_000)),
            ("spotMinor", .array([.int(42), .int(40), .null])), ("totalMinor", .array([.int(120), .int(118), .null])),
        ])
        let hb = try box.seal(CloudWire.msgHB, h3 + [
            ("clock", .text("ntp")), ("srcRev", .unsigned(1)), ("liveSeq", .unsigned(1)), ("lpSeq", .unsigned(2)), ("ages", .map(["m": .int(sourceAge)])),
        ])
        return CloudWire.Snapshot(envelopes: [live, lp, prices, hb], lastSeenMs: t0, online: true, more: 0)
    }

    private func link(_ box: FakeCloudBox) -> WatchLink {
        WatchLink(site: "site-1", cloudHome: box.home, boxKey: Data(count: 32), cloudKey: Data(box.pk), sources: ["m": "meter"],
                  loadpoints: ["lpA": "garage"], watchKey: Data(count: 32), chargeNow: [:], timeZone: "Europe/Stockholm")
    }

    /// A fresh read is live where the box says so, worded as the phone
    /// words Now, and dated by the box's send, never by the arrival.
    @Test func aFreshReadIsLiveAndDatedByTheBox() throws {
        var box = try FakeCloudBox(boot: 1)
        let t0: Int64 = 1_791_800_000_000
        let snap = try snapshot(&box, at: t0)
        let read = try #require(WatchCloud.read(snap, link: link(box), kept: nil, arrivalMs: Double(t0 + 3 + transit)))
        let now = try #require(read.context.now)
        #expect(now.carrier == .cloud)
        #expect(now.srcState == .live)
        #expect(now.readAtMs <= Double(t0 + 3))
        #expect(now.value.control == .inControl)
        #expect(now.value.reading(.grid)?.way == .selling)
        #expect(now.value.reading(.grid)?.watts == 1_200)
        #expect(now.value.reading(.solar)?.way == .making)
        #expect(now.value.reading(.battery)?.way == .charging)
        #expect(now.value.reading(.battery)?.levelPct == 62)
        #expect(now.value.reading(.car)?.levelPct == 56)
        #expect(now.value.readings.allSatisfy { $0.live })
        #expect((read.liveForMs ?? 0) > 0)

        let car = try #require(read.context.cars?.value.cars.first)
        #expect(car.loadpointID == "garage" && car.pluggedIn && car.socPct == 56 && car.targetSocPct == 80)
        let prices = try #require(read.context.prices)
        #expect(prices.value.prices.slots.count == 2)
        #expect(prices.value.timeZone == "Europe/Stockholm")
        #expect(read.context.home == "site-1")
        #expect(read.context.plan == nil)
    }

    /// A read whose sources are old is ink: stale, never live, and FTW's
    /// control is unknown.
    @Test func anOldReadIsNeverLive() throws {
        var box = try FakeCloudBox(boot: 1)
        let t0: Int64 = 1_791_800_000_000
        let snap = try snapshot(&box, at: t0, sourceAge: 25_000)
        let read = try #require(WatchCloud.read(snap, link: link(box), kept: nil, arrivalMs: Double(t0 + 3 + transit)))
        let now = try #require(read.context.now)
        #expect(now.srcState != .live)
        #expect(!now.value.readings.contains { $0.live })
        #expect(now.value.control == .unknown)
        #expect(read.liveForMs == nil)
    }

    /// A blocked dispatch says FTW is not in control.
    @Test func aBlockedDispatchIsNotInControl() throws {
        var box = try FakeCloudBox(boot: 1)
        let t0: Int64 = 1_791_800_000_000
        let snap = try snapshot(&box, at: t0, blocked: ["m"])
        let read = try #require(WatchCloud.read(snap, link: link(box), kept: nil, arrivalMs: Double(t0 + 3 + transit)))
        #expect(read.context.now?.value.control == .notInControl)
    }

    /// Envelopes the box key does not verify make nothing: a service cannot
    /// put a reading on the wrist.
    @Test func aServiceCannotForgeAReading() throws {
        var box = try FakeCloudBox(boot: 1)
        let t0: Int64 = 1_791_800_000_000
        let snap = try snapshot(&box, at: t0)
        var other = link(box)
        other.cloudKey = Data(P256.Signing.PrivateKey().publicKey.x963Representation)
        let read = try #require(WatchCloud.read(snap, link: other, kept: nil, arrivalMs: Double(t0 + 3 + transit)))
        #expect(read.context.now == nil && read.context.cars == nil && read.context.prices == nil)
        var noCopy = link(box)
        noCopy.cloudKey = nil
        #expect(WatchCloud.read(snap, link: noCopy, kept: nil, arrivalMs: Double(t0)) == nil)
    }

    /// The phone's link survives a context that does not carry it.
    @Test func theLinkIsKept() {
        var kept = WatchContext(home: "site-1", isDemo: false, sentAtMs: 1)
        kept.link = WatchLink(site: "site-1", cloudHome: "h", boxKey: Data(count: 32), cloudKey: nil, sources: [:], loadpoints: [:],
                              watchKey: Data(count: 32), chargeNow: [:], timeZone: nil)
        let next = WatchContext(home: "site-1", isDemo: false, sentAtMs: 2)
        #expect(WatchContext.merging(next, over: kept)?.link == kept.link)
    }
}
