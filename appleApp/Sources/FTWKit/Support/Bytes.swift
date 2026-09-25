import Foundation

/// Raw bytes. `[UInt8]` rather than `Data` inside the protocol, because
/// indexing a `Data` slice by absolute offset is the classic way to read the
/// wrong byte, and every layer here indexes.
public typealias Bytes = [UInt8]

extension Array where Element == UInt8 {
    public init(hex: String) {
        var out = Bytes()
        out.reserveCapacity(hex.count / 2)
        var high: UInt8?
        for ch in hex.utf8 {
            let v: UInt8
            switch ch {
            case 0x30...0x39: v = ch - 0x30
            case 0x61...0x66: v = ch - 0x61 + 10
            case 0x41...0x46: v = ch - 0x41 + 10
            default: continue
            }
            if let h = high {
                out.append(h << 4 | v)
                high = nil
            } else {
                high = v
            }
        }
        self = out
    }

    public var hex: String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(count * 2)
        for b in self {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    public var data: Data { Data(self) }
}

extension Data {
    public var bytes: Bytes { Bytes(self) }
}

/// Concatenate byte runs without an intermediate array per step.
public func concat(_ parts: Bytes...) -> Bytes {
    var out = Bytes()
    out.reserveCapacity(parts.reduce(0) { $0 + $1.count })
    for p in parts { out.append(contentsOf: p) }
    return out
}

/// Cryptographically random bytes from the system generator.
public func randomBytes(_ count: Int) -> Bytes {
    var rng = SystemRandomNumberGenerator()
    return (0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) }
}

/// Overwrite a buffer that held key material. Best effort: Swift may have
/// copied it before this runs, and the comment says so rather than promising.
public func wipe(_ bytes: inout Bytes) {
    for i in bytes.indices { bytes[i] = 0 }
}

/// Constant-time comparison, for anything that compares secrets.
public func constantTimeEqual(_ a: Bytes, _ b: Bytes) -> Bool {
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for i in a.indices { diff |= a[i] ^ b[i] }
    return diff == 0
}

extension UInt64 {
    var bigEndianBytes: Bytes {
        (0..<8).map { UInt8(truncatingIfNeeded: self >> (8 * (7 - $0))) }
    }
}
