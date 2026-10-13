import CryptoKit
import Foundation
import Testing
@testable import FTWKit

// The freshness cases from srcfl/ftw docs/protocol-cloud.md, as
// go/protocol/cloudwire/view_test.go runs them, against CloudView. Times are
// ms on one clock unless a case moves the box's. Rule N with 100 ms in
// transit unless stated. The box signs with the golden vectors' box key.

private let transit: Int64 = 100
private let hour: Int64 = 3_600_000

/// A box that signs what it sends. `start` is the phone time at which its
/// uptime was zero; `clockLead` moves its wall clock against the phone's.
struct FakeCloudBox {
    let key: P256.Signing.PrivateKey
    let home: String
    let pk: Bytes
    var boot: Bytes
    var seq: UInt64 = 0
    var start: Int64 = 1_000_000
    var clockLead: Int64 = 0
    var noClock = false

    init(boot byte: UInt8) throws {
        let v = try CloudVectors.load()
        key = try v.boxSigner()
        home = v.home
        pk = Bytes(hex: v.boxKey.pk)
        boot = Bytes(repeating: byte, count: CloudWire.bootBytes)
    }

    mutating func header(_ at: Int64) -> [(String, CBOR)] {
        seq += 1
        var h: [(String, CBOR)] = [("seq", .unsigned(seq)), ("boot", .bytes(boot)), ("uptimeMs", .int(at - start))]
        if !noClock { h.append(("wallMs", .int(at + clockLead))) }
        return h
    }

    func seal(_ t: String, _ body: [(String, CBOR)]) throws -> CloudWire.Envelope {
        let b = encodeCBOR(CloudWire.deterministic(.map(body)))
        return CloudWire.Envelope(t: t, b: b, sig: try cloudSign(key, home: home, t: t, b: b))
    }

    /// A full live with one source "m", S = 10 s, read `age` ms before `at`.
    mutating func fullLive(_ at: Int64, age: Int64, state: String = "live", srcRev: UInt64 = 1) throws -> CloudWire.Envelope {
        let h = header(at)
        let m = CBOR.map([("kind", .text("driver")), ("state", .text(state)), ("lastOkMs", .int(at - start - age)), ("staleAfterMs", .int(10_000))])
        return try seal(CloudWire.msgLive, h + [
            ("fields", .map(["2": .int(1000), "1": .int(0)])),
            ("fieldSources", .map(["2": .array([.text("m")])])),
            ("sources", .map(["m": m])),
            ("srcRev", .unsigned(srcRev)),
            ("ages", .map(["m": .int(age)])),
            ("dispatchBlockedBy", .array([])),
        ])
    }

    mutating func hb(_ at: Int64, age: Int64, srcRev: UInt64 = 1, liveSeq: UInt64, lpSeq: UInt64 = 0) throws -> CloudWire.Envelope {
        let h = header(at)
        return try seal(CloudWire.msgHB, h + [
            ("clock", .text("ntp")), ("srcRev", .unsigned(srcRev)), ("liveSeq", .unsigned(liveSeq)),
            ("lpSeq", .unsigned(lpSeq)), ("ages", .map(["m": .int(age)])),
        ])
    }

    /// A message the service drops: it only uses up a seq.
    mutating func dropped(_ at: Int64) { _ = header(at) }

    func view() -> CloudView { CloudView(home: home, boxKey: pk) }
}

private func source(_ v: CloudView, _ at: Int64) -> SourceState? { v.grade(nowMs: at).sources["m"] }

/// The header of an hb the box signs at `at`, as the phone decodes it.
private func header(_ box: inout FakeCloudBox, at: Int64) throws -> CloudWire.Header {
    let h = box.header(at)
    return try CloudWire.Header(body: box.seal(CloudWire.msgHB, h).b)
}

@Suite struct CloudViewTests {
    // 1. A quiet live source stays live.
    @Test func aQuietLiveSourceStaysLive() throws {
        var box = try FakeCloudBox(boot: 1)
        var v = box.view()
        let t0: Int64 = 2_000_000
        try v.accept(box.fullLive(t0, age: 1_000), arrivalMs: t0 + transit)
        for at in stride(from: t0 + 5_000, through: t0 + 120_000, by: 5_000) {
            try v.accept(box.hb(at, age: 4_500, liveSeq: 1), arrivalMs: at + transit)
            for probe in stride(from: at + transit, to: at + 5_000 + transit, by: 500) {
                let g = v.grade(nowMs: probe)
                #expect(g.sources["m"] == .live, "at \(probe)")
                #expect(g.fields["2"] == .live, "at \(probe)")
                #expect(g.fields["1"] == .live, "at \(probe)")
            }
        }
    }

    // 2. A dead uplink ages on time.
    @Test func aDeadUplinkAgesOnTime() throws {
        var box = try FakeCloudBox(boot: 1)
        var v = box.view()
        let t0: Int64 = 2_000_000
        try v.accept(box.fullLive(t0, age: 1_000), arrivalMs: t0 + transit)
        let last = t0 + 5_000
        try v.accept(box.hb(last, age: 2_000, liveSeq: 1), arrivalMs: last + transit)
        // The send time is the box's wallMs, so t counts from `last`.
        #expect(source(v, last + 8_000) == .live)
        #expect(source(v, last + 8_001) == .lagging)
        #expect(source(v, last + 18_000) == .lagging)
        #expect(source(v, last + 18_001) == .stale)
        #expect(source(v, last + 58_000) == .stale)
        #expect(source(v, last + 58_001) == .down)
    }

    // 3. A replay ages out, and a phone that holds newer drops it.
    @Test func aReplayAgesOut() throws {
        var box = try FakeCloudBox(boot: 1)
        let t0: Int64 = 2_000_000
        let live = try box.fullLive(t0, age: 1_000)
        let hb = try box.hb(t0 + 5_000, age: 2_000, liveSeq: 1)

        var fresh = box.view()
        try fresh.accept(live, arrivalMs: t0 + hour)
        try fresh.accept(hb, arrivalMs: t0 + hour + 10)
        #expect(source(fresh, t0 + hour + 20) == .down)
        #expect(fresh.grade(nowMs: t0 + hour + 20).fields["2"] == .down)

        var current = box.view()
        try current.accept(live, arrivalMs: t0 + transit)
        try current.accept(hb, arrivalMs: t0 + 5_000 + transit)
        #expect(throws: CloudView.AcceptError.notNewer) { try current.accept(live, arrivalMs: t0 + hour) }
        #expect(throws: CloudView.AcceptError.notNewer) { try current.accept(hb, arrivalMs: t0 + hour) }
    }

    // 4. A withheld table goes stale until it arrives.
    @Test func aWithheldTableGoesStale() throws {
        var box = try FakeCloudBox(boot: 1)
        var v = box.view()
        let t0: Int64 = 2_000_000
        try v.accept(box.fullLive(t0, age: 1_000), arrivalMs: t0 + transit)
        _ = try box.fullLive(t0 + 3_000, age: 12_000, state: "lagging", srcRev: 2) // dropped by the service
        try v.accept(box.hb(t0 + 5_000, age: 1_000, srcRev: 2, liveSeq: 2), arrivalMs: t0 + 5_000 + transit)
        #expect(source(v, t0 + 5_200) == .stale)
        // The next full live brings revision 2, and the box's own grade.
        try v.accept(box.fullLive(t0 + 6_000, age: 15_000, state: "lagging", srcRev: 2), arrivalMs: t0 + 6_000 + transit)
        #expect(source(v, t0 + 6_200) == .lagging)
        #expect(v.srcRev == 2)
    }

    // 5. No anchor, never live.
    @Test func noAnchorIsNeverLive() throws {
        var box = try FakeCloudBox(boot: 1)
        box.noClock = true
        var v = box.view()
        let t0: Int64 = 2_000_000
        try v.accept(box.fullLive(t0, age: 1_000), arrivalMs: t0 + transit)
        try v.accept(box.hb(t0 + 5_000, age: 500, liveSeq: 1), arrivalMs: t0 + 5_000 + transit)
        let g = v.grade(nowMs: t0 + 5_200)
        #expect(!g.anchored)
        #expect(g.ageMs == nil)
        #expect(v.anchorSentMs(nowMs: t0 + 5_200) == nil)
        #expect(g.sources["m"] == .stale)
        #expect(g.fields == ["1": .stale, "2": .stale])
    }

    // 6. A fast box clock loses rule N, for the rest of the boot.
    @Test func aFastBoxClockLosesRuleN() throws {
        var box = try FakeCloudBox(boot: 1)
        box.clockLead = 3_000
        var v = box.view()
        let t0: Int64 = 2_000_000
        try v.accept(box.fullLive(t0, age: 1_000), arrivalMs: t0 + transit)
        let g = v.grade(nowMs: t0 + 200)
        #expect(!g.anchored)
        #expect(g.sources["m"] != .live)
        box.clockLead = 0
        try v.accept(box.hb(t0 + 5_000, age: 500, liveSeq: 1), arrivalMs: t0 + 5_000 + transit)
        #expect(!v.grade(nowMs: t0 + 5_200).anchored, "rule N came back within the boot")
    }

    // 7. A small clock lead gains nothing.
    @Test func aSmallClockLeadGainsNothing() throws {
        var box = try FakeCloudBox(boot: 1)
        box.clockLead = 1_500
        var v = box.view()
        let t0: Int64 = 2_000_000
        try v.accept(box.fullLive(t0, age: 2_000), arrivalMs: t0 + transit)
        // The send time is the arrival, t0+100: age 2000 + t reaches S at
        // t0+8100, not 1.5 s later.
        #expect(v.anchorSentMs(nowMs: t0 + 200) == t0 + transit)
        #expect(source(v, t0 + 8_100) == .live)
        #expect(source(v, t0 + 8_101) == .lagging)
    }

    // 8. A changed byte is dropped.
    @Test func aChangedByteIsDropped() throws {
        var box = try FakeCloudBox(boot: 1)
        var v = box.view()
        var env = try box.fullLive(2_000_000, age: 1_000)
        env.b[env.b.count - 1] ^= 1
        #expect(throws: CloudView.AcceptError.signature) { try v.accept(env, arrivalMs: 2_000_100) }
        #expect(v.live == nil && v.boot == nil)
    }

    // 9 and 10. A dropped live or a held-back lp goes stale.
    @Test func aDroppedLiveAndAHeldBackLPGoStale() throws {
        var box = try FakeCloudBox(boot: 1)
        var v = box.view()
        let t0: Int64 = 2_000_000
        try v.accept(box.fullLive(t0, age: 1_000), arrivalMs: t0 + transit)
        let h = box.header(t0 + 10)
        let car = CBOR.map([("id", .text("lp1")), ("src", .text("m")), ("plugged", .bool(true)), ("socPermille", .int(430))])
        try v.accept(box.seal(CloudWire.msgLP, h + [("loadpoints", .array([car]))]), arrivalMs: t0 + 10 + transit)
        #expect(v.grade(nowMs: t0 + 200).loadpoints["lp1"] == .live)
        let (heldLive, heldLP) = (box.seq - 1, box.seq)
        box.dropped(t0 + 3_000) // live
        box.dropped(t0 + 3_100) // lp
        try v.accept(box.hb(t0 + 5_000, age: 1_000, liveSeq: heldLive + 2, lpSeq: heldLP + 2), arrivalMs: t0 + 5_000 + transit)
        let g = v.grade(nowMs: t0 + 5_200)
        #expect(g.sources["m"] == .live)
        #expect(g.fields == ["1": .stale, "2": .stale])
        #expect(g.loadpoints == ["lp1": .stale])
    }

    // 11. The byte budget runs out: the box stops sending live and hb, and
    //     the data ages as in case 2.
    @Test func aSpentByteBudgetAgesLikeADeadUplink() throws {
        var box = try FakeCloudBox(boot: 1)
        var v = box.view()
        let t0: Int64 = 2_000_000
        try v.accept(box.fullLive(t0, age: 1_000), arrivalMs: t0 + transit)
        let last = t0 + 30_000
        for at in stride(from: t0 + 5_000, through: last, by: 5_000) {
            try v.accept(box.hb(at, age: 4_500, liveSeq: 1), arrivalMs: at + transit)
        }
        #expect(source(v, last + 5_500) == .live)
        #expect(source(v, last + 5_501) == .lagging)
        #expect(source(v, last + 15_501) == .stale)
        #expect(source(v, last + 55_501) == .down)
        // The mode has no source and goes stale after 2H = 10 s.
        #expect(v.grade(nowMs: last + 10_000).fields["1"] == .live)
        #expect(v.grade(nowMs: last + 10_001).fields["1"] == .stale)
    }

    // 12. A reboot clears the old table.
    @Test func aRebootClearsTheOldTable() throws {
        var x = try FakeCloudBox(boot: 1)
        var v = x.view()
        let t0: Int64 = 2_000_000
        try v.accept(x.fullLive(t0, age: 1_000, srcRev: 9), arrivalMs: t0 + transit)

        var y = try FakeCloudBox(boot: 2)
        y.start = t0 + 30_000
        _ = try y.fullLive(t0 + 60_000, age: 1_000, srcRev: 3) // dropped
        try v.accept(y.hb(t0 + 61_000, age: 1_000, srcRev: 3, liveSeq: 1), arrivalMs: t0 + 61_000 + transit)
        let g = v.grade(nowMs: t0 + 61_200)
        #expect(g.anchored)
        #expect(g.sources.isEmpty && g.fields.isEmpty)
        #expect(v.boot == y.boot && v.live == nil && v.srcRev == 0)
        // An older message from boot X can no longer take the view back.
        #expect(throws: CloudView.AcceptError.notNewer) {
            try v.accept(x.hb(t0 + 1_000, age: 1_000, srcRev: 9, liveSeq: 1), arrivalMs: t0 + 61_300)
        }
        #expect(v.boot == y.boot)
    }

    // 13. Rule U drift counts against freshness, and the anchor lapses.
    @Test func ruleUDriftCountsAgainstFreshness() throws {
        var box = try FakeCloudBox(boot: 1)
        box.noClock = true
        var v = box.view()
        let learned: Int64 = 2_000_000
        v.learnOffset(boot: box.boot, phoneMs: learned, uptimeMs: learned - box.start)

        let at = learned + 10 * hour
        try v.accept(box.fullLive(at, age: 0), arrivalMs: at + transit)
        // The margin is 3.6 s: a reading sent with age 0 reaches S 3.6 s early.
        #expect(source(v, at + 6_400) == .live)
        #expect(source(v, at + 6_401) == .lagging)
        #expect(v.grade(nowMs: at + 6_400).ageMs == 10_000)
        #expect(!v.grade(nowMs: learned + CloudView.ruleULifetimeMs + 1).anchored, "rule U outlived its 24 hours")
    }

    // 14. A snapshot with mixed seq.
    @Test func aSnapshotWithMixedSeq() throws {
        var box = try FakeCloudBox(boot: 1)
        var v = box.view()
        let t0: Int64 = 2_000_000
        box.seq = 4
        let h = box.header(t0)
        let prices = try box.seal(CloudWire.msgPrices, h + [("zone", .text("SE3")), ("spotMinor", .array([.int(42), .null]))])
        box.seq = 2989
        try v.accept(box.fullLive(t0 + 10, age: 1_000), arrivalMs: t0 + 20)
        box.seq = 2999
        try v.accept(box.fullLive(t0 + 20, age: 1_000), arrivalMs: t0 + 30)
        try v.accept(prices, arrivalMs: t0 + 40)
        #expect(v.live?.header.seq == 3000)
        #expect(v.prices?.header.seq == 5)
        #expect(v.prices?.spotMinor == [42, nil])
    }

    // 15. An event replayed two hours late is anchored two hours old, past
    //     the ten minutes an alert may be for its own text and buttons, and a
    //     second copy of it is dropped.
    @Test func anOldAlertIsTwoHoursOld() throws {
        var box = try FakeCloudBox(boot: 1)
        var v = box.view()
        let sent: Int64 = 2_000_000
        let h = box.header(sent)
        let event = try box.seal(CloudWire.msgEvent, h + [("eventId", .text("e1")), ("kind", .text("driver.offline")), ("src", .text("m"))])
        let arrival = sent + 2 * hour
        let trusted = try #require(v.sentMs(CloudWire.Header(body: event.b), arrivalMs: arrival))
        #expect(arrival - trusted == 2 * hour)
        #expect(arrival - trusted > 10 * 60_000)
        try v.accept(event, arrivalMs: arrival)
        #expect(throws: CloudView.AcceptError.notNewer) { try v.accept(event, arrivalMs: arrival + 1) }

        box.noClock = true
        let unanchored = box.header(sent)
        #expect(v.sentMs(try CloudWire.Header(body: box.seal(CloudWire.msgEvent, unanchored).b), arrivalMs: arrival) == nil)
    }

    // 16. The box's state wins.
    @Test func theBoxStateWins() throws {
        var box = try FakeCloudBox(boot: 1)
        var v = box.view()
        let t0: Int64 = 2_000_000
        try v.accept(box.fullLive(t0, age: 0, state: "down"), arrivalMs: t0 + transit)
        #expect(source(v, t0 + 1_000) == .down)
    }

    @Test func theHeartbeatIsClamped() {
        func table(_ stale: [Int64]) -> [String: CloudWire.Source] {
            Dictionary(uniqueKeysWithValues: stale.enumerated().map {
                ("s\($0.offset)", CloudWire.Source(kind: "driver", state: .live, lastOkMs: 0, staleAfterMs: $0.element))
            })
        }
        #expect(CloudView.heartbeat(for: [:]) == 15_000)
        #expect(CloudView.heartbeat(for: table([10_000])) == 5_000)
        #expect(CloudView.heartbeat(for: table([1_000])) == 2_000)
        #expect(CloudView.heartbeat(for: table([120_000, 0])) == 15_000)
    }

    @Test func theGoldenSnapshotGradesThroughTheView() throws {
        let vectors = try CloudVectors.load()
        let grantKey = Bytes(hex: vectors.grantKey)
        let meter = CloudWire.sourceID(grantKey: grantKey, driver: "p1meter")
        let inverter = CloudWire.sourceID(grantKey: grantKey, driver: "sungrow")
        let charger = CloudWire.sourceID(grantKey: grantKey, driver: "easee")
        let garage = CloudWire.loadpointID(grantKey: grantKey, loadpoint: "garage")
        let wall: Int64 = 1_791_820_800_000

        var v = CloudView(home: vectors.home, boxKey: Bytes(hex: vectors.boxKey.pk))
        for name in ["live full", "live delta", "lp", "prices", "hb"] {
            let env = try vectors.envelope(name)
            let wallMs = try #require(try CloudWire.Header(body: env.b).wallMs)
            try v.accept(env, arrivalMs: wallMs + transit)
        }
        let hbSent = wall + 9_020
        #expect(v.anchorSentMs(nowMs: hbSent + transit) == hbSent)
        let g = v.grade(nowMs: hbSent + transit)
        #expect(g.anchored && g.ageMs == transit)
        // The charger has no age in hb, so it keeps the box's lagging.
        #expect(g.sources == [meter: .live, inverter: .live, charger: .lagging])
        #expect(g.fields == ["1": .live, "2": .live, "3": .live, "4": .live, "5": .live, "6": .lagging, "10": .lagging])
        #expect(g.loadpoints == [garage: .lagging])
        // The delta carried no table, so the full live's still holds.
        #expect(v.live?.header.seq == 4 && v.live?.fields["2"] == 1795)
        #expect(v.srcRev == 1 && v.fieldSources["6"] == [charger, inverter, meter])
        #expect(v.prices?.zone == "SE3" && v.hb?.lpSeq == 5 && v.lp?.controlRev == 812)
        // The meter's 1.4 s reading reaches its 10 s at hb + 8.6 s.
        #expect(v.grade(nowMs: hbSent + 8_600).sources[meter] == .live)
        #expect(v.grade(nowMs: hbSent + 8_601).sources[meter] == .lagging)
    }

    @Test func whatThePhoneNeverReadsIsRefused() throws {
        let vectors = try CloudVectors.load()
        var v = CloudView(home: vectors.home, boxKey: Bytes(hex: vectors.boxKey.pk))
        for name in ["hello", "roster", "bye"] {
            let env = try vectors.envelope(name)
            #expect(throws: CloudView.AcceptError.notAClass(env.t)) { try v.accept(env, arrivalMs: 0) }
        }
        // Signed for this home by another key, or for another home by this
        // key: the signature fails either way.
        var other = CloudView(home: "aaaaaaaaaaaaaaaaaaaaaaaaaa", boxKey: Bytes(hex: vectors.boxKey.pk))
        #expect(throws: CloudView.AcceptError.signature) { try other.accept(vectors.envelope("hb"), arrivalMs: 0) }
        var service = CloudView(home: vectors.home, boxKey: Bytes(hex: vectors.serviceKey.pk))
        #expect(throws: CloudView.AcceptError.signature) { try service.accept(vectors.envelope("hb"), arrivalMs: 0) }
    }

    @Test func aBodyThatDoesNotDecodeChangesNothing() throws {
        var x = try FakeCloudBox(boot: 1)
        var v = x.view()
        let t0: Int64 = 2_000_000
        try v.accept(x.fullLive(t0, age: 1_000), arrivalMs: t0 + transit)
        let before = v.grade(nowMs: t0 + 200)

        // Signed by the box, from a later boot, with a field that is text.
        var y = try FakeCloudBox(boot: 2)
        let h = y.header(t0 + 1_000)
        let bad = try y.seal(CloudWire.msgLive, h + [("fields", .map(["2": .text("1000")]))])
        #expect(throws: CloudView.AcceptError.self) { try v.accept(bad, arrivalMs: t0 + 1_000 + transit) }
        #expect(v.boot == x.boot)
        #expect(v.grade(nowMs: t0 + 200) == before)
    }

    @Test func aStateThisBuildDoesNotKnowRanksAsNever() throws {
        var box = try FakeCloudBox(boot: 1)
        var v = box.view()
        let t0: Int64 = 2_000_000
        try v.accept(box.fullLive(t0, age: 0, state: "melting"), arrivalMs: t0 + transit)
        let g = v.grade(nowMs: t0 + 200)
        #expect(g.sources["m"] == .never)
        #expect(g.fields["2"] == .never)
    }

    @Test func ruleUKeepsTheSmallestOffsetAndTheEarlierRuleWins() throws {
        var box = try FakeCloudBox(boot: 1)
        let v0 = box.view()
        var v = v0
        // Offsets of 1 000 000 and then 1 001 000: the smaller stays, and the
        // second call renews its lifetime.
        v.learnOffset(boot: box.boot, phoneMs: 2_000_000, uptimeMs: 1_000_000)
        v.learnOffset(boot: box.boot, phoneMs: 2_500_000, uptimeMs: 1_499_000)
        box.noClock = true
        let h = try header(&box, at: 3_000_000)
        #expect(v.sentMs(h, arrivalMs: 3_000_100) == 3_000_000)
        #expect(v.sentMs(h, arrivalMs: 2_500_000 + CloudView.ruleULifetimeMs) == 3_000_000)
        #expect(v.sentMs(h, arrivalMs: 2_500_001 + CloudView.ruleULifetimeMs) == nil)
        #expect(v0.sentMs(h, arrivalMs: 3_000_100) == nil)

        // With both rules, the earlier send time: here the box's wall clock
        // is 500 ms behind, so rule N gives the earlier time.
        box.noClock = false
        box.clockLead = -500
        let both = try header(&box, at: 3_000_000)
        #expect(v.sentMs(both, arrivalMs: 3_000_100) == 2_999_500)
        box.clockLead = 500
        let ahead = try header(&box, at: 3_000_000)
        #expect(v.sentMs(ahead, arrivalMs: 3_000_100) == 3_000_000)
    }
}
