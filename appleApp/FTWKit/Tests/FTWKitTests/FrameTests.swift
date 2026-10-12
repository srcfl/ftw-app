import Foundation
import Testing
@testable import FTWKit

@Suite struct FrameTests {
    @Test func everySharedFrameDecodesAndReencodesByteForByte() throws {
        let v = try InteropVectors.load()
        #expect(!v.frames.isEmpty)
        for want in v.frames {
            let wire = Bytes(hex: want.bytes)
            #expect(wire.count == want.bucket, "\(want.name)")
            let frame = try Frame.decode(wire)
            #expect(frame.lane == want.lane, "\(want.name)")
            #expect(frame.flags == want.flags, "\(want.name)")

            // The whole payload survives a round trip, unknown keys included,
            // because maps keep their order.
            let payload = Array(wire[Frame.headerBytes..<Frame.headerBytes + want.payloadLen])
            let value = try decodeCBOR(payload)
            #expect(encodeCBOR(value) == payload, "\(want.name)")
            #expect(value.entries?.compactMap { $0.key.string } == want.envelopeKeys, "\(want.name)")

            // Frames that carry only the envelope's own keys re-encode exactly.
            if Set(want.envelopeKeys).isSubset(of: ["t", "id", "b"]) {
                let again = try Frame.encode(lane: frame.lane, flags: frame.flags, envelope: frame.envelope, bucket: want.bucket)
                #expect(again == wire, "\(want.name)")
            }
        }
    }

    @Test func truncatedFlagIsRead() throws {
        let v = try InteropVectors.load()
        let delta = try #require(v.frames.first { $0.name == "delta_truncated" })
        #expect(try Frame.decode(Bytes(hex: delta.bytes)).truncated)
    }

    @Test func laneZeroIsAlwaysTheBucket() throws {
        for body: CBOR in [.map([:] as KeyValuePairs<String, CBOR>), .map(["seq": .int(1), "uptimeMs": .int(123_456_789)])] {
            let frame = try Frame.encode(lane: Frame.laneControl, envelope: Envelope(t: "tick", b: body), bucket: 512)
            #expect(frame.count == 512)
        }
    }

    @Test func refusesToGrowTheBucket() {
        let big = Envelope(t: "x", b: .bytes(Bytes(repeating: 7, count: 600)))
        #expect(throws: Frame.FrameError.self) { try Frame.encode(lane: 0, envelope: big, bucket: 512) }
    }

    @Test func bulkPicksTheSmallestBucket() throws {
        #expect(try Frame.encodeBulk(envelope: Envelope(t: "plan.get", id: 1)).count == 1024)
        #expect(try Frame.encodeBulk(envelope: Envelope(t: "x", b: .bytes(Bytes(repeating: 0, count: 2000)))).count == 4096)
    }

    @Test func junkIsRefusedWithACode() {
        #expect(throws: Frame.FrameError.self) { try Frame.decode([1, 0]) }
        #expect(throws: Frame.FrameError.self) { try Frame.decode([2, 0, 0, 0, 0, 0]) }
        #expect(throws: Frame.FrameError.self) { try Frame.decode([1, 0, 0, 0, 0, 9, 0xa0]) }
    }
}

@Suite struct CBORTests {
    // The web app's own bytes, as the Kotlin suite pinned them.
    @Test func encodesTheAppsOwnHello() {
        let hello = CBOR.map([
            ("t", .text("hello")),
            ("b", .map([
                ("proto", .map([("min", .int(0)), ("max", .int(1))])),
                ("app", .map([("build", .text("test")), ("ua", .text("pwa"))])),
                ("locales", .array([.text("sv")])),
            ])),
        ])
        #expect(encodeCBOR(hello).hex == "a261746568656c6c6f6162a36570726f746fa2636d696e00636d61780163617070a2656275696c64647465737462756163707761676c6f63616c657381627376")
    }

    @Test func encodesSub() {
        let sub = CBOR.map([("t", .text("sub")), ("b", .map([("bucket", .int(512)), ("hz", .number(1))]))])
        #expect(encodeCBOR(sub).hex == "a26174637375626162a2666275636b657419020062687a01")
    }

    @Test func floatsTakeTheShortestExactForm() {
        // What cbor2, the web app's encoder, writes for the same numbers.
        #expect(encodeCBOR(.map(["hz": .number(0.2)])).hex == "a162687afb3fc999999999999a")
        #expect(encodeCBOR(.map(["hz": .number(1.5)])).hex == "a162687af93e00")
        #expect(encodeCBOR(.map(["v": .number(0.5)])).hex == "a16176f93800")
        #expect(encodeCBOR(.map(["v": .number(-3)])).hex == "a1617622")
        #expect(encodeCBOR(.map(["v": .number(1e10)])).hex == "a161761b00000002540be400")
        #expect(encodeCBOR(.map(["v": .number(4_294_967_296)])).hex == "a161761b0000000100000000")
    }

    @Test func roundTripsEveryKind() throws {
        let value = CBOR.map([
            ("u", .int(Int64(UInt32.max) + 5)),
            ("n", .int(-1_000_000)),
            ("b", .bytes([0, 1, 2, 255])),
            ("s", .text("åäö")),
            ("a", .array([.bool(true), .bool(false), .null])),
            ("d", .double(0.1)),
            ("f", .double(3.5)),
        ])
        let decoded = try decodeCBOR(encodeCBOR(value))
        #expect(decoded == value)
        #expect(decoded["n"]?.int64 == -1_000_000)
        #expect(decoded["f"]?.double == 3.5)
    }

    @Test func refusesDuplicateKeysAndTrailingBytes() {
        #expect(throws: CBOR.DecodeError.self) { try decodeCBOR(Bytes(hex: "a2617401617402")) }
        #expect(throws: CBOR.DecodeError.self) { try decodeCBOR(Bytes(hex: "0102")) }
    }

    @Test func refusesLengthsPastTheInput() {
        #expect(throws: CBOR.DecodeError.self) { try decodeCBOR(Bytes(hex: "5bffffffffffffffff")) }
        #expect(throws: CBOR.DecodeError.self) { try decodeCBOR(Bytes(hex: "9bffffffffffffffff")) }
    }

    @Test func readsIndefiniteLengths() throws {
        #expect(try decodeCBOR(Bytes(hex: "9f0102ff")) == .array([.int(1), .int(2)]))
        #expect(try decodeCBOR(Bytes(hex: "bf616101ff"))["a"] == .int(1))
    }
}
