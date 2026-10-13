import Foundation

/// The CBOR a push carries: the box's envelope and the event inside it.
///
/// The notification extension does not link FTWKit, so it reads with this
/// small reader instead. It is strict where FTWKit's is lenient: definite
/// lengths only, text must be UTF-8, a key may appear once, and nothing may
/// follow the value. The box writes core-deterministic CBOR, so a genuine
/// event never needs more; anything else is shown as the generic line.
indirect enum PushCBOR: Equatable, Sendable {
    case unsigned(UInt64)
    /// The value is `-1 - n`.
    case negative(UInt64)
    case bytes([UInt8])
    case text(String)
    case array([PushCBOR])
    case map([Entry])
    case tagged(UInt64, PushCBOR)
    /// Null and undefined. Go reads either as "not there".
    case null
    /// Booleans, floats and other simple values: skipped, never read.
    case simple

    struct Entry: Equatable, Sendable {
        var key: PushCBOR
        var value: PushCBOR
    }

    struct Malformed: Error {}

    /// Exactly one value, and nothing after it.
    static func decode(_ bytes: [UInt8]) throws -> PushCBOR {
        var r = Reader(bytes: bytes)
        let value = try r.read(depth: 0)
        guard r.at == bytes.count else { throw Malformed() }
        return value
    }

    /// A map whose keys are all text, as a dictionary. Nil for anything
    /// else; a duplicate key never gets this far.
    var textMap: [String: PushCBOR]? {
        guard case .map(let entries) = self else { return nil }
        var out = [String: PushCBOR]()
        for e in entries {
            guard case .text(let k) = e.key else { return nil }
            out[k] = e.value
        }
        return out
    }

    private struct Reader {
        let bytes: [UInt8]
        var at = 0

        /// Deeper than any event, shallow enough that a hostile one cannot
        /// exhaust the stack.
        static let maxDepth = 16

        mutating func byte() throws -> UInt8 {
            guard at < bytes.count else { throw Malformed() }
            defer { at += 1 }
            return bytes[at]
        }

        mutating func take(_ n: UInt64) throws -> [UInt8] {
            guard n <= UInt64(bytes.count - at) else { throw Malformed() }
            let end = at + Int(n)
            defer { at = end }
            return Array(bytes[at..<end])
        }

        mutating func argument(_ info: UInt8) throws -> UInt64 {
            switch info {
            case 0..<24: return UInt64(info)
            case 24: return UInt64(try byte())
            case 25: return try take(2).reduce(0) { $0 << 8 | UInt64($1) }
            case 26: return try take(4).reduce(0) { $0 << 8 | UInt64($1) }
            case 27: return try take(8).reduce(0) { $0 << 8 | UInt64($1) }
            // 28–30 are reserved; 31 is an indefinite length.
            default: throw Malformed()
            }
        }

        mutating func read(depth: Int) throws -> PushCBOR {
            guard depth < Self.maxDepth else { throw Malformed() }
            let initial = try byte()
            let major = initial >> 5
            let info = initial & 0x1f
            switch major {
            case 0: return .unsigned(try argument(info))
            case 1: return .negative(try argument(info))
            case 2: return .bytes(try take(try argument(info)))
            case 3:
                guard let s = String(validating: try take(try argument(info)), as: UTF8.self) else { throw Malformed() }
                return .text(s)
            case 4:
                let n = try argument(info)
                // Each item takes at least a byte.
                guard n <= UInt64(bytes.count - at) else { throw Malformed() }
                return .array(try (0..<n).map { _ in try read(depth: depth + 1) })
            case 5:
                let n = try argument(info)
                guard n <= UInt64(bytes.count - at) / 2 else { throw Malformed() }
                var entries = [Entry]()
                for _ in 0..<n {
                    let key = try read(depth: depth + 1)
                    // Two claims about one field: the box refuses these too.
                    guard !entries.contains(where: { $0.key == key }) else { throw Malformed() }
                    entries.append(Entry(key: key, value: try read(depth: depth + 1)))
                }
                return .map(entries)
            case 6:
                let tag = try argument(info)
                return .tagged(tag, try read(depth: depth + 1))
            default:
                switch info {
                case 22, 23: return .null
                case 0..<24: return .simple
                case 24: _ = try byte(); return .simple
                case 25: _ = try take(2); return .simple
                case 26: _ = try take(4); return .simple
                case 27: _ = try take(8); return .simple
                default: throw Malformed()
                }
            }
        }
    }
}

// MARK: - What the box signs

extension PushCBOR {
    /// The bytes an envelope's signature covers: "ftw.cloud.v1", a zero
    /// byte, then the deterministic array [home, t, b]. The home id is
    /// inside, so an event signed for one home never verifies for another.
    static func signedInput(home: String, t: String, b: [UInt8]) -> [UInt8] {
        var out = Array("ftw.cloud.v1\u{0}".utf8)
        out.append(0x83)
        head(3, UInt64(home.utf8.count), into: &out)
        out.append(contentsOf: home.utf8)
        head(3, UInt64(t.utf8.count), into: &out)
        out.append(contentsOf: t.utf8)
        head(2, UInt64(b.count), into: &out)
        out.append(contentsOf: b)
        return out
    }

    /// A head in its shortest form, as deterministic encoding asks.
    private static func head(_ major: UInt8, _ n: UInt64, into out: inout [UInt8]) {
        let m = major << 5
        switch n {
        case 0..<24: out.append(m | UInt8(n))
        case 24...0xff: out += [m | 24, UInt8(n)]
        case 0x100...0xffff: out += [m | 25, UInt8(n >> 8), UInt8(n & 0xff)]
        case 0x1_0000...0xffff_ffff: out += [m | 26] + (0..<4).reversed().map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) }
        default: out += [m | 27] + (0..<8).reversed().map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) }
        }
    }
}
