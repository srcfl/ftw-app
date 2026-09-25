import Foundation

/// The box code: eight characters somebody reads out loud from the box's
/// screen. They decode to the same five bytes a scanned code's payload
/// carries and are spent in the same place, handshake message 1.
///
/// Crockford base32 without I, L, O and U. Every fold happens here, before an
/// attempt is spent: the box burns a code after five wrong tries, so a typo
/// this file could have normalised must never cost the household its code.
/// Mirrors DecodeSpokenCode in the box's appenroll/boxcode.go.
public enum BoxCode {
    public static let bytes = 5
    public static let chars = 8

    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    static let ignored: Set<Character> = [" ", "-", "\t"]

    public struct BoxCodeError: Error, Equatable, HelpfulError {
        public let message: String
        public let help: String
    }

    static let notACode = "That is not a code from your box. It is eight characters, like 04HM-ASW9."

    private static func fold(_ c: Character) -> Character {
        switch c {
        case "I", "L": return "1"
        case "O": return "0"
        default: return c
        }
    }

    /// Fold what someone typed onto the alphabet, dropping what does not
    /// belong. For the input field, on every keystroke.
    public static func fold(_ typed: String) -> String {
        var out = ""
        for raw in typed.uppercased() {
            if ignored.contains(raw) { continue }
            let c = fold(raw)
            if alphabet.contains(c) { out.append(c) }
        }
        return String(out.prefix(chars))
    }

    /// XXXX-XXXX. The hyphen is for the reader.
    public static func group(_ folded: String) -> String {
        folded.count > 4 ? "\(folded.prefix(4))-\(folded.dropFirst(4))" : folded
    }

    /// The five bytes the box drew. A character outside the alphabet means
    /// the person is reading the wrong line, so it is refused rather than
    /// dropped. Nothing here reaches the box.
    public static func decode(_ typed: String) throws -> Bytes {
        var chars = [Character]()
        for raw in typed.uppercased() {
            if ignored.contains(raw) { continue }
            let c = fold(raw)
            guard alphabet.contains(c) else {
                throw BoxCodeError(message: "\(raw) is not in the alphabet", help: notACode)
            }
            chars.append(c)
        }
        guard chars.count == Self.chars else {
            throw BoxCodeError(message: "\(chars.count) characters, expected \(Self.chars)", help: notACode)
        }
        var n: UInt64 = 0
        for c in chars { n = n << 5 | UInt64(alphabet.firstIndex(of: c)!) }
        return (0..<bytes).map { UInt8(truncatingIfNeeded: n >> UInt64(8 * (bytes - 1 - $0))) }
    }
}
