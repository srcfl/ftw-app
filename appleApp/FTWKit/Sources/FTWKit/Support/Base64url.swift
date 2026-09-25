import Foundation

/// Unpadded base64url, strict on the way in.
///
/// Strict because every value decoded here came off a QR code or a box, and
/// a lenient decoder turns a misread character into a different key rather
/// than into an error anyone would see.
public enum Base64url {
    public struct DecodeError: Error, Equatable {
        public let message: String
    }

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)

    private static let lookup: [Int8] = {
        var table = [Int8](repeating: -1, count: 256)
        for (i, c) in alphabet.enumerated() { table[Int(c)] = Int8(i) }
        return table
    }()

    public static func encode(_ bytes: Bytes) -> String {
        var out = [UInt8]()
        out.reserveCapacity((bytes.count * 4 + 2) / 3)
        var i = 0
        while i + 3 <= bytes.count {
            let n = UInt32(bytes[i]) << 16 | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2])
            out.append(alphabet[Int(n >> 18 & 63)])
            out.append(alphabet[Int(n >> 12 & 63)])
            out.append(alphabet[Int(n >> 6 & 63)])
            out.append(alphabet[Int(n & 63)])
            i += 3
        }
        let rest = bytes.count - i
        if rest == 1 {
            let n = UInt32(bytes[i]) << 16
            out.append(alphabet[Int(n >> 18 & 63)])
            out.append(alphabet[Int(n >> 12 & 63)])
        } else if rest == 2 {
            let n = UInt32(bytes[i]) << 16 | UInt32(bytes[i + 1]) << 8
            out.append(alphabet[Int(n >> 18 & 63)])
            out.append(alphabet[Int(n >> 12 & 63)])
            out.append(alphabet[Int(n >> 6 & 63)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    public static func decode(_ text: String) throws -> Bytes {
        let chars = Array(text.utf8)
        if chars.count % 4 == 1 {
            throw DecodeError(message: "length \(chars.count) is not a base64url length")
        }
        var values = [UInt8]()
        values.reserveCapacity(chars.count)
        for c in chars {
            let v = lookup[Int(c)]
            if v < 0 { throw DecodeError(message: "character \(Character(UnicodeScalar(c))) is not base64url") }
            values.append(UInt8(v))
        }
        var out = Bytes()
        out.reserveCapacity(values.count * 3 / 4)
        var i = 0
        while i + 4 <= values.count {
            let n = UInt32(values[i]) << 18 | UInt32(values[i + 1]) << 12 | UInt32(values[i + 2]) << 6 | UInt32(values[i + 3])
            out.append(UInt8(n >> 16 & 0xff))
            out.append(UInt8(n >> 8 & 0xff))
            out.append(UInt8(n & 0xff))
            i += 4
        }
        let rest = values.count - i
        if rest == 2 {
            let n = UInt32(values[i]) << 18 | UInt32(values[i + 1]) << 12
            // Bits past the last whole byte must be zero, or two strings
            // decode to the same bytes and the encoding stops being unique.
            if n & 0xffff != 0 { throw DecodeError(message: "trailing bits are not zero") }
            out.append(UInt8(n >> 16 & 0xff))
        } else if rest == 3 {
            let n = UInt32(values[i]) << 18 | UInt32(values[i + 1]) << 12 | UInt32(values[i + 2]) << 6
            if n & 0xff != 0 { throw DecodeError(message: "trailing bits are not zero") }
            out.append(UInt8(n >> 16 & 0xff))
            out.append(UInt8(n >> 8 & 0xff))
        }
        return out
    }
}
