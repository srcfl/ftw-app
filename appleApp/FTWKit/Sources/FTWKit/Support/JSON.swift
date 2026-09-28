import Foundation

/// A JSON value, read tolerantly. The box's HTTP answers are read the way the
/// web app reads them: a missing or mistyped field becomes nil, never a
/// crash, so a newer box's extra fields and an older box's missing ones are
/// both ordinary.
///
/// Its own small parser rather than JSONSerialization, which reports
/// booleans as numbers differently on each platform.
public enum JSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    /// Keys in document order, so a body re-encodes as it came.
    case object([(String, JSON)])

    public static func == (a: JSON, b: JSON) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case let (.bool(x), .bool(y)): return x == y
        case let (.number(x), .number(y)): return x == y
        case let (.string(x), .string(y)): return x == y
        case let (.array(x), .array(y)): return x == y
        case let (.object(x), .object(y)):
            return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    public struct ParseError: Error, Equatable {
        public let offset: Int
    }

    public init(parsing bytes: Bytes) throws {
        var p = Parser(b: bytes)
        p.skip()
        self = try p.value(depth: 0)
        p.skip()
        guard p.i == bytes.count else { throw ParseError(offset: p.i) }
    }

    public subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o.first { $0.0 == key }?.1 }
        return nil
    }

    public subscript(index: Int) -> JSON? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }

    /// A finite number, or nil.
    public var number: Double? {
        if case .number(let n) = self, n.isFinite { return n }
        return nil
    }

    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var array: [JSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var object: [(String, JSON)]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var isNull: Bool { self == .null }

    public func encoded() -> Bytes { Array(text.utf8) }

    public var text: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n):
            guard n.isFinite else { return "null" }
            if n.rounded() == n, abs(n) < 9_007_199_254_740_992 { return String(Int64(n)) }
            return "\(n)"
        case .string(let s): return jsonString(s)
        case .array(let a): return "[" + a.map(\.text).joined(separator: ",") + "]"
        case .object(let o): return "{" + o.map { jsonString($0.0) + ":" + $0.1.text }.joined(separator: ",") + "}"
        }
    }

    /// A copy with one key set, keeping the others and their order.
    public func setting(_ key: String, _ value: JSON) -> JSON {
        guard case .object(var o) = self else { return self }
        if let i = o.firstIndex(where: { $0.0 == key }) {
            o[i].1 = value
        } else {
            o.append((key, value))
        }
        return .object(o)
    }

    private struct Parser {
        let b: Bytes
        var i = 0

        mutating func skip() {
            while i < b.count, b[i] == 0x20 || b[i] == 0x0a || b[i] == 0x0d || b[i] == 0x09 { i += 1 }
        }

        mutating func expect(_ c: UInt8) throws {
            guard i < b.count, b[i] == c else { throw ParseError(offset: i) }
            i += 1
        }

        mutating func literal(_ word: String) throws {
            for c in word.utf8 { try expect(c) }
        }

        mutating func value(depth: Int) throws -> JSON {
            guard depth < 128, i < b.count else { throw ParseError(offset: i) }
            switch b[i] {
            case UInt8(ascii: "{"):
                i += 1
                var out = [(String, JSON)]()
                skip()
                if i < b.count, b[i] == UInt8(ascii: "}") { i += 1; return .object(out) }
                while true {
                    skip()
                    let k = try string()
                    skip()
                    try expect(UInt8(ascii: ":"))
                    skip()
                    let v = try value(depth: depth + 1)
                    out.append((k, v))
                    skip()
                    guard i < b.count else { throw ParseError(offset: i) }
                    if b[i] == UInt8(ascii: ",") { i += 1; continue }
                    try expect(UInt8(ascii: "}"))
                    return .object(out)
                }
            case UInt8(ascii: "["):
                i += 1
                var out = [JSON]()
                skip()
                if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return .array(out) }
                while true {
                    skip()
                    out.append(try value(depth: depth + 1))
                    skip()
                    guard i < b.count else { throw ParseError(offset: i) }
                    if b[i] == UInt8(ascii: ",") { i += 1; continue }
                    try expect(UInt8(ascii: "]"))
                    return .array(out)
                }
            case UInt8(ascii: "\""):
                return .string(try string())
            case UInt8(ascii: "t"):
                try literal("true")
                return .bool(true)
            case UInt8(ascii: "f"):
                try literal("false")
                return .bool(false)
            case UInt8(ascii: "n"):
                try literal("null")
                return .null
            default:
                return .number(try number())
            }
        }

        mutating func number() throws -> Double {
            let start = i
            while i < b.count, "+-0123456789.eE".utf8.contains(b[i]) { i += 1 }
            guard i > start, let n = Double(String(decoding: b[start..<i], as: UTF8.self)) else { throw ParseError(offset: start) }
            return n
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= b.count, let v = UInt32(String(decoding: b[i..<i + 4], as: UTF8.self), radix: 16) else { throw ParseError(offset: i) }
            i += 4
            return v
        }

        mutating func string() throws -> String {
            try expect(UInt8(ascii: "\""))
            var out = Bytes()
            while true {
                guard i < b.count else { throw ParseError(offset: i) }
                let c = b[i]
                i += 1
                if c == UInt8(ascii: "\"") { break }
                if c != UInt8(ascii: "\\") { out.append(c); continue }
                guard i < b.count else { throw ParseError(offset: i) }
                let e = b[i]
                i += 1
                switch e {
                case UInt8(ascii: "n"): out.append(0x0a)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "r"): out.append(0x0d)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0c)
                case UInt8(ascii: "u"):
                    var scalar = try hex4()
                    if scalar >= 0xd800, scalar < 0xdc00, i + 6 <= b.count, b[i] == UInt8(ascii: "\\"), b[i + 1] == UInt8(ascii: "u") {
                        i += 2
                        let low = try hex4()
                        scalar = 0x10000 + ((scalar - 0xd800) << 10) + (low - 0xdc00)
                    }
                    out += Array(String(Character(UnicodeScalar(scalar) ?? "\u{fffd}")).utf8)
                default: out.append(e)
                }
            }
            return String(decoding: out, as: UTF8.self)
        }
    }
}

extension JSON: ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral, ExpressibleByStringLiteral, ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral, ExpressibleByNilLiteral {
    public init(dictionaryLiteral elements: (String, JSON)...) { self = .object(elements) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(nilLiteral: ()) { self = .null }
}
