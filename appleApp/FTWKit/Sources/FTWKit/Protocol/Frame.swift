import Foundation

/// The frame codec.
///
/// Each Noise transport message carries exactly one frame:
///
///     offset  field    type     note
///     0       ver      u8       frame layout version
///     1       lane     u8       0 = telemetry/control, 1 = bulk
///     2       flags    u8       0x02 TRUNC
///     3       rsvd     u8       0
///     4       len      u16 BE   payload bytes
///     6       payload  u8[len]  CBOR
///     6+len   pad      u8[]     zeros to the bucket size
///
/// The padding is a privacy control. A 1 Hz power stream whose frame length
/// varied with what happened in the house would hand the relay operator the
/// household's load pattern through perfect encryption, so lane 0 frames are
/// always exactly one bucket and never fragment.
public enum Frame {
    public static let version: UInt8 = 1
    public static let headerBytes = 6
    public static let maxPayload = 0xffff

    public static let laneControl: UInt8 = 0
    public static let laneBulk: UInt8 = 1

    /// The delta did not fit its bucket; the rest follows next tick.
    public static let flagTrunc: UInt8 = 0x02

    /// Lane 0 is one fixed size for the life of a session.
    public static let controlBuckets = [256, 512]
    /// Lane 1 steps, because bulk already leaks that a transfer is happening.
    public static let bulkBuckets = [1024, 4096, 16384]

    public struct Decoded: Equatable, Sendable {
        public var lane: UInt8
        public var flags: UInt8
        public var envelope: Envelope

        public var truncated: Bool { flags & Frame.flagTrunc != 0 }
    }

    public struct FrameError: Error, Equatable {
        public let code: String
        public let message: String
    }

    /// Encode one frame, zero-padded to `bucket`.
    ///
    /// Throws rather than growing the bucket: a larger frame than asked for
    /// would defeat the padding entirely.
    public static func encode(lane: UInt8, flags: UInt8 = 0, envelope: Envelope, bucket: Int) throws -> Bytes {
        let payload = encodeCBOR(envelope.cbor)
        if payload.count > maxPayload {
            throw FrameError(code: "E_FRAME_TOO_LARGE", message: "payload \(payload.count) exceeds u16 length field")
        }
        let needed = headerBytes + payload.count
        if needed > bucket {
            throw FrameError(code: "E_FRAME_EXCEEDS_BUCKET", message: "frame needs \(needed) bytes, bucket is \(bucket)")
        }
        var out = Bytes(repeating: 0, count: bucket)
        out[0] = version
        out[1] = lane
        out[2] = flags
        out[3] = 0
        out[4] = UInt8(payload.count >> 8)
        out[5] = UInt8(payload.count & 0xff)
        out.replaceSubrange(headerBytes..<needed, with: payload)
        return out
    }

    /// The smallest bulk bucket the envelope fits, encoded.
    public static func encodeBulk(envelope: Envelope) throws -> Bytes {
        let payload = encodeCBOR(envelope.cbor)
        guard let bucket = bulkBuckets.first(where: { $0 >= payload.count + headerBytes }) else {
            throw FrameError(code: "E_FRAME_EXCEEDS_BUCKET", message: "bulk payload exceeds the largest bucket")
        }
        return try encode(lane: laneBulk, envelope: envelope, bucket: bucket)
    }

    /// Decode one frame. Everything past `len` is ignored without inspection:
    /// the padding is already covered by the AEAD, so checking it would only
    /// add a way to reject a frame that is fine.
    public static func decode(_ bytes: Bytes) throws -> Decoded {
        guard bytes.count >= headerBytes else {
            throw FrameError(code: "E_FRAME_SHORT", message: "frame is \(bytes.count) bytes")
        }
        guard bytes[0] == version else {
            throw FrameError(code: "E_FRAME_VERSION", message: "unsupported frame version \(bytes[0])")
        }
        let len = Int(bytes[4]) << 8 | Int(bytes[5])
        guard headerBytes + len <= bytes.count else {
            throw FrameError(code: "E_FRAME_TRUNCATED", message: "declared length \(len) overruns the frame")
        }
        let value: CBOR
        do {
            value = try decodeCBOR(Array(bytes[headerBytes..<headerBytes + len]))
        } catch {
            throw FrameError(code: "E_FRAME_CBOR", message: "payload is not valid CBOR")
        }
        guard let envelope = Envelope(value) else {
            throw FrameError(code: "E_FRAME_ENVELOPE", message: "envelope must be a map with a string type")
        }
        return Decoded(lane: bytes[1], flags: bytes[2], envelope: envelope)
    }
}

/// One message: a type, an optional request id, an optional body.
public struct Envelope: Equatable, Sendable {
    public var t: String
    public var id: UInt32?
    public var b: CBOR?

    public init(t: String, id: UInt32? = nil, b: CBOR? = nil) {
        self.t = t
        self.id = id
        self.b = b
    }

    /// Unknown keys are ignored: that rule is what lets a newer box talk to
    /// an older app and the reverse.
    init?(_ value: CBOR) {
        guard let t = value["t"]?.string else { return nil }
        self.t = t
        if let raw = value["id"]?.int64, raw >= 0, raw <= Int64(UInt32.max) {
            id = UInt32(raw)
        }
        b = value["b"]
    }

    /// Keys in the web app's order: t, id, b.
    var cbor: CBOR {
        var pairs: [(String, CBOR)] = [("t", .text(t))]
        if let id { pairs.append(("id", .unsigned(UInt64(id)))) }
        if let b { pairs.append(("b", b)) }
        return .map(pairs)
    }
}
