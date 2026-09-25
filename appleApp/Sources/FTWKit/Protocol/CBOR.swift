import Foundation

/// A CBOR value, as much of RFC 8949 as the box and the web app use.
///
/// Maps keep their order. The web app's encoder writes keys in insertion
/// order and the box accepts any order, so keeping order is what lets this
/// encoder produce the same bytes as the web app for the same message, and
/// the shared interop vectors prove it.
public indirect enum CBOR: Equatable, Sendable {
    case unsigned(UInt64)
    /// The value is `-1 - n`.
    case negative(UInt64)
    case bytes(Bytes)
    case text(String)
    case array([CBOR])
    case map([Entry])
    case tagged(UInt64, CBOR)
    case bool(Bool)
    case null
    case undefined
    case double(Double)

    public struct Entry: Equatable, Sendable {
        public var key: CBOR
        public var value: CBOR
        public init(_ key: CBOR, _ value: CBOR) {
            self.key = key
            self.value = value
        }
    }

    public struct DecodeError: Error, Equatable {
        public let message: String
    }
}

// MARK: - Building

extension CBOR {
    public static func int(_ v: Int64) -> CBOR {
        v >= 0 ? .unsigned(UInt64(v)) : .negative(UInt64(-1 - v))
    }

    public static func int(_ v: Int) -> CBOR { .int(Int64(v)) }

    public static let emptyMap = CBOR.map([Entry]())

    /// A number as JavaScript would put it on the wire: an integer when it is
    /// one, a double otherwise. The web app sends `hz: 1` and `hz: 0.2`, and
    /// the box reads either into a float.
    public static func number(_ v: Double) -> CBOR {
        if v.rounded() == v, abs(v) < 9_007_199_254_740_992 { return .int(Int64(v)) }
        return .double(v)
    }

    /// A text-keyed map, in the order given.
    public static func map(_ pairs: KeyValuePairs<String, CBOR>) -> CBOR {
        .map(pairs.map { Entry(.text($0.key), $0.value) })
    }

    public static func map(_ pairs: [(String, CBOR)]) -> CBOR {
        .map(pairs.map { Entry(.text($0.0), $0.1) })
    }
}

// MARK: - Reading

extension CBOR {
    /// The value under a text key, or nil. Unknown keys are simply never
    /// asked for, which is the protocol's forward-compatibility rule.
    public subscript(key: String) -> CBOR? {
        guard case .map(let entries) = self else { return nil }
        for e in entries where e.key == .text(key) { return e.value }
        return nil
    }

    public var int64: Int64? {
        switch self {
        case .unsigned(let u): return u <= UInt64(Int64.max) ? Int64(u) : nil
        case .negative(let n): return n <= UInt64(Int64.max) ? -1 - Int64(n) : nil
        case .double(let d): return d.rounded() == d && abs(d) < 9.2e18 ? Int64(d) : nil
        case .tagged(_, let inner): return inner.int64
        default: return nil
        }
    }

    public var int: Int? { int64.flatMap { Int(exactly: $0) } }

    public var double: Double? {
        switch self {
        case .unsigned(let u): return Double(u)
        case .negative(let n): return -1 - Double(n)
        case .double(let d): return d
        case .tagged(_, let inner): return inner.double
        default: return nil
        }
    }

    public var string: String? {
        if case .text(let s) = self { return s }
        return nil
    }

    public var byteString: Bytes? {
        if case .bytes(let b) = self { return b }
        return nil
    }

    public var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var array: [CBOR]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var entries: [Entry]? {
        if case .map(let m) = self { return m }
        return nil
    }

    public var isNull: Bool {
        self == .null || self == .undefined
    }

    /// A text-keyed map as a dictionary. Non-text keys are dropped; a
    /// duplicate keeps the first, though the box never sends one.
    public var textMap: [String: CBOR]? {
        guard case .map(let entries) = self else { return nil }
        var out = [String: CBOR]()
        for e in entries {
            if case .text(let k) = e.key, out[k] == nil { out[k] = e.value }
        }
        return out
    }

    public var stringArray: [String]? {
        array?.compactMap(\.string)
    }
}

// MARK: - Encoding

public func encodeCBOR(_ value: CBOR) -> Bytes {
    var out = Bytes()
    encode(value, into: &out)
    return out
}

private func head(_ major: UInt8, _ n: UInt64, into out: inout Bytes) {
    let m = major << 5
    switch n {
    case 0..<24:
        out.append(m | UInt8(n))
    case 24...0xff:
        out.append(m | 24)
        out.append(UInt8(n))
    case 0x100...0xffff:
        out.append(m | 25)
        out.append(UInt8(n >> 8))
        out.append(UInt8(n & 0xff))
    case 0x1_0000...0xffff_ffff:
        out.append(m | 26)
        for shift in stride(from: 24, through: 0, by: -8) { out.append(UInt8(truncatingIfNeeded: n >> UInt64(shift))) }
    default:
        out.append(m | 27)
        for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8(truncatingIfNeeded: n >> UInt64(shift))) }
    }
}

private func encode(_ value: CBOR, into out: inout Bytes) {
    switch value {
    case .unsigned(let u): head(0, u, into: &out)
    case .negative(let n): head(1, n, into: &out)
    case .bytes(let b):
        head(2, UInt64(b.count), into: &out)
        out.append(contentsOf: b)
    case .text(let s):
        let utf8 = Array(s.utf8)
        head(3, UInt64(utf8.count), into: &out)
        out.append(contentsOf: utf8)
    case .array(let items):
        head(4, UInt64(items.count), into: &out)
        for i in items { encode(i, into: &out) }
    case .map(let entries):
        head(5, UInt64(entries.count), into: &out)
        for e in entries {
            encode(e.key, into: &out)
            encode(e.value, into: &out)
        }
    case .tagged(let tag, let inner):
        head(6, tag, into: &out)
        encode(inner, into: &out)
    case .bool(let b): out.append(b ? 0xf5 : 0xf4)
    case .null: out.append(0xf6)
    case .undefined: out.append(0xf7)
    case .double(let d):
        // Shortest form that keeps the value exactly, as preferred
        // serialisation asks. Lengths never matter to lane 0 — it is padded —
        // but agreeing with the other encoders byte for byte is what makes a
        // vector test worth having.
        let f = Float(d)
        if Double(f) == d || d.isNaN {
            let half = Float16Bits(f)
            if let h = half {
                out.append(0xf9)
                out.append(UInt8(h >> 8))
                out.append(UInt8(h & 0xff))
            } else {
                out.append(0xfa)
                let bits = f.bitPattern
                for shift in stride(from: 24, through: 0, by: -8) { out.append(UInt8(truncatingIfNeeded: bits >> UInt32(shift))) }
            }
        } else {
            out.append(0xfb)
            let bits = d.bitPattern
            for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift))) }
        }
    }
}

/// The IEEE half-precision bits for a float that half precision holds
/// exactly, or nil when it would lose anything.
private func Float16Bits(_ f: Float) -> UInt16? {
    if f.isNaN { return 0x7e00 }
    let bits = f.bitPattern
    let sign = UInt16((bits >> 16) & 0x8000)
    let exp = Int((bits >> 23) & 0xff)
    let mant = bits & 0x7f_ffff
    if exp == 0xff { return sign | 0x7c00 } // infinity
    if exp == 0 && mant == 0 { return sign }
    let e = exp - 127
    if e >= -14 && e <= 15 {
        // Normal half: 10 mantissa bits.
        if mant & 0x1fff != 0 { return nil }
        return sign | UInt16(e + 15) << 10 | UInt16(mant >> 13)
    }
    if e >= -24 && e < -14 {
        // Subnormal half.
        let full = mant | 0x80_0000
        let shift = UInt32(-e - 14 + 13)
        if full & ((1 << shift) - 1) != 0 { return nil }
        return sign | UInt16(full >> shift)
    }
    return nil
}

// MARK: - Decoding

/// Decode exactly one value. Trailing bytes are an error: a frame's payload
/// length is explicit, so anything left over means the length was wrong.
public func decodeCBOR(_ bytes: Bytes) throws -> CBOR {
    var reader = CBORReader(bytes: bytes)
    let value = try reader.read(depth: 0)
    if reader.at != bytes.count {
        throw CBOR.DecodeError(message: "\(bytes.count - reader.at) trailing bytes")
    }
    return value
}

private struct CBORReader {
    let bytes: Bytes
    var at = 0

    /// Deep enough for every message in the protocol, shallow enough that a
    /// hostile frame cannot exhaust the stack.
    static let maxDepth = 64

    mutating func byte() throws -> UInt8 {
        guard at < bytes.count else { throw CBOR.DecodeError(message: "unexpected end") }
        defer { at += 1 }
        return bytes[at]
    }

    mutating func take(_ n: Int) throws -> Bytes {
        guard n >= 0, at + n <= bytes.count else { throw CBOR.DecodeError(message: "unexpected end") }
        defer { at += n }
        return Array(bytes[at..<at + n])
    }

    mutating func argument(_ info: UInt8) throws -> UInt64 {
        switch info {
        case 0..<24: return UInt64(info)
        case 24: return UInt64(try byte())
        case 25: return try take(2).reduce(0) { $0 << 8 | UInt64($1) }
        case 26: return try take(4).reduce(0) { $0 << 8 | UInt64($1) }
        case 27: return try take(8).reduce(0) { $0 << 8 | UInt64($1) }
        default: throw CBOR.DecodeError(message: "reserved additional info \(info)")
        }
    }

    func count(_ n: UInt64) throws -> Int {
        guard n <= UInt64(bytes.count - at) else { throw CBOR.DecodeError(message: "length \(n) overruns the input") }
        return Int(n)
    }

    mutating func read(depth: Int) throws -> CBOR {
        guard depth < Self.maxDepth else { throw CBOR.DecodeError(message: "nested too deeply") }
        let initial = try byte()
        let major = initial >> 5
        let info = initial & 0x1f

        if info == 31 {
            return try readIndefinite(major: major, depth: depth)
        }

        switch major {
        case 0: return .unsigned(try argument(info))
        case 1: return .negative(try argument(info))
        case 2: return .bytes(try take(try count(try argument(info))))
        case 3:
            let raw = try take(try count(try argument(info)))
            guard let s = String(bytes: raw, encoding: .utf8) else { throw CBOR.DecodeError(message: "text is not UTF-8") }
            return .text(s)
        case 4:
            let n = try argument(info)
            guard n <= UInt64(bytes.count - at) else { throw CBOR.DecodeError(message: "array overruns the input") }
            var items = [CBOR]()
            items.reserveCapacity(Int(n))
            for _ in 0..<n { items.append(try read(depth: depth + 1)) }
            return .array(items)
        case 5:
            let n = try argument(info)
            guard n <= UInt64(bytes.count - at) else { throw CBOR.DecodeError(message: "map overruns the input") }
            var entries = [CBOR.Entry]()
            entries.reserveCapacity(Int(n))
            for _ in 0..<n {
                let k = try read(depth: depth + 1)
                let v = try read(depth: depth + 1)
                // Two claims about one field, and no safe way to pick: the box
                // refuses these too.
                if entries.contains(where: { $0.key == k }) { throw CBOR.DecodeError(message: "duplicate map key") }
                entries.append(CBOR.Entry(k, v))
            }
            return .map(entries)
        case 6:
            let tag = try argument(info)
            return .tagged(tag, try read(depth: depth + 1))
        default:
            switch info {
            case 20: return .bool(false)
            case 21: return .bool(true)
            case 22: return .null
            case 23: return .undefined
            case 25:
                let raw = try take(2)
                return .double(Double(halfToFloat(UInt16(raw[0]) << 8 | UInt16(raw[1]))))
            case 26:
                let raw = try take(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                return .double(Double(Float(bitPattern: raw)))
            case 27:
                let raw = try take(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                return .double(Double(bitPattern: raw))
            case 24:
                _ = try byte()
                return .undefined
            default:
                if info < 20 { return .undefined }
                throw CBOR.DecodeError(message: "unsupported simple value \(info)")
            }
        }
    }

    mutating func readIndefinite(major: UInt8, depth: Int) throws -> CBOR {
        switch major {
        case 2, 3:
            var chunks = Bytes()
            while true {
                if at < bytes.count, bytes[at] == 0xff { at += 1; break }
                let chunk = try read(depth: depth + 1)
                switch (major, chunk) {
                case (2, .bytes(let b)): chunks.append(contentsOf: b)
                case (3, .text(let s)): chunks.append(contentsOf: Array(s.utf8))
                default: throw CBOR.DecodeError(message: "mixed chunk in an indefinite string")
                }
            }
            if major == 2 { return .bytes(chunks) }
            guard let s = String(bytes: chunks, encoding: .utf8) else { throw CBOR.DecodeError(message: "text is not UTF-8") }
            return .text(s)
        case 4:
            var items = [CBOR]()
            while true {
                if at < bytes.count, bytes[at] == 0xff { at += 1; break }
                items.append(try read(depth: depth + 1))
            }
            return .array(items)
        case 5:
            var entries = [CBOR.Entry]()
            while true {
                if at < bytes.count, bytes[at] == 0xff { at += 1; break }
                let k = try read(depth: depth + 1)
                let v = try read(depth: depth + 1)
                if entries.contains(where: { $0.key == k }) { throw CBOR.DecodeError(message: "duplicate map key") }
                entries.append(CBOR.Entry(k, v))
            }
            return .map(entries)
        default:
            throw CBOR.DecodeError(message: "indefinite length on major type \(major)")
        }
    }
}

private func halfToFloat(_ h: UInt16) -> Float {
    let sign: Float = h & 0x8000 != 0 ? -1 : 1
    let exp = Int(h >> 10 & 0x1f)
    let mant = Float(h & 0x3ff)
    if exp == 0 { return sign * mant * pow(2, -24) }
    if exp == 31 { return mant == 0 ? sign * .infinity : .nan }
    return sign * (1 + mant / 1024) * pow(2, Float(exp - 15))
}
