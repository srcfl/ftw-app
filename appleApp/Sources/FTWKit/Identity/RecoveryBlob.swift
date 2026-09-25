import Foundation

/// The sealed copy of a household: the bytes, and nothing about where they
/// are kept. The same format the web app writes, so a copy either one
/// sealed opens in the other.
///
///     sealed:  [version 1][nonce 12][ciphertext + tag]
///     plain:   [device scalar 32][home count 1]
///              per home: [id len 1][id][name len 1][name][box key 32][rendezvous secret 32]
///              then zeros out to the fixed plaintext length
///     AAD:     [version 1][escrow version 4, big-endian]
///
/// Padded to one length so whoever holds the ciphertext cannot count homes.
/// The escrow version is bound in as additional data, so a service that pairs
/// an old blob with a new number gets a refusal here rather than a household
/// getting back a home it had removed.
public enum RecoveryBlob {
    public static let maxBytes = 512
    public static let version: UInt8 = 2
    public static let escrowVersionNone: UInt32 = 0
    static let nonceBytes = 12
    static let headerBytes = 1 + nonceBytes
    static let tagBytes = 16
    public static let plainBytes = maxBytes - headerBytes - tagBytes
    /// The name is for telling two homes apart, not a record.
    public static let maxNameChars = 32

    public struct Home: Equatable, Sendable {
        public var siteId: String
        public var label: String
        public var boxStaticKey: Bytes
        public var rendezvousSecret: Bytes

        public init(siteId: String, label: String, boxStaticKey: Bytes, rendezvousSecret: Bytes) {
            self.siteId = siteId
            self.label = label
            self.boxStaticKey = boxStaticKey
            self.rendezvousSecret = rendezvousSecret
        }
    }

    public struct Contents: Equatable, Sendable {
        public var deviceScalar: Bytes
        public var homes: [Home]
    }

    public struct BlobError: Error, Equatable, HelpfulError {
        public let code: String
        public let message: String
        public let help: String
    }

    static func format(_ message: String) -> BlobError {
        BlobError(code: "E_BLOB_FORMAT", message: message, help: "The saved copy of this home could not be read. Open your box's local dashboard, then Settings → FTW app → Show pairing code, and scan a new QR instead.")
    }

    public static func encode(_ contents: Contents) throws -> Bytes {
        guard contents.deviceScalar.count == 32 else { throw format("device key is not 32 bytes") }
        guard contents.homes.count <= 0xff else { throw format("more homes than a byte counts") }
        var out = Bytes()
        out.reserveCapacity(plainBytes)
        out += contents.deviceScalar
        out.append(UInt8(contents.homes.count))
        for home in contents.homes {
            guard home.boxStaticKey.count == Enrollment.boxKeyBytes else { throw format("box key is not 32 bytes") }
            guard home.rendezvousSecret.count == Enrollment.rendezvousSecretBytes else { throw format("rendezvous secret is not 32 bytes") }
            let id = Array(home.siteId.utf8)
            // Whole characters: a cut between the halves of an emoji would
            // keep one of them.
            let name = Array(String(String.UnicodeScalarView(home.label.unicodeScalars.prefix(maxNameChars))).utf8)
            guard id.count <= 0xff, name.count <= 0xff else { throw format("a name is longer than a byte") }
            out.append(UInt8(id.count))
            out += id
            out.append(UInt8(name.count))
            out += name
            out += home.boxStaticKey
            out += home.rendezvousSecret
        }
        guard out.count <= plainBytes else {
            throw BlobError(code: "E_BLOB_TOO_BIG", message: "payload is \(out.count) bytes", help: "There are more homes on this phone than a saved copy can carry. They all still work here.")
        }
        out += Bytes(repeating: 0, count: plainBytes - out.count)
        return out
    }

    /// Strict: anything short, long or unaccounted for is refused rather than
    /// read half-way.
    public static func decode(_ plain: Bytes) throws -> Contents {
        guard plain.count == plainBytes else { throw format("payload is \(plain.count) bytes") }
        let scalar = Array(plain[0..<32])
        var at = 32
        let count = Int(plain[at])
        at += 1
        var homes = [Home]()

        func slice() throws -> Bytes {
            guard at < plain.count else { throw format("payload ends in the middle of a home") }
            let n = Int(plain[at])
            at += 1
            guard at + n <= plain.count else { throw format("payload ends in the middle of a name") }
            defer { at += n }
            return Array(plain[at..<at + n])
        }

        for _ in 0..<count {
            let id = String(decoding: try slice(), as: UTF8.self)
            let label = String(decoding: try slice(), as: UTF8.self)
            guard at + 64 <= plain.count else { throw format("payload ends in the middle of a home") }
            let box = Array(plain[at..<at + 32])
            let secret = Array(plain[at + 32..<at + 64])
            at += 64
            homes.append(Home(siteId: id, label: label, boxStaticKey: box, rendezvousSecret: secret))
        }
        // The tail is padding and has to look like it.
        guard plain[at...].allSatisfy({ $0 == 0 }) else { throw format("bytes after the last home are not padding") }
        return Contents(deviceScalar: scalar, homes: homes)
    }

    static func aad(_ escrowVersion: UInt32) -> Bytes {
        [version, UInt8(escrowVersion >> 24), UInt8(escrowVersion >> 16 & 0xff), UInt8(escrowVersion >> 8 & 0xff), UInt8(escrowVersion & 0xff)]
    }

    public static func seal(key: Bytes, _ contents: Contents, escrowVersion: UInt32) throws -> Bytes {
        var plain = try encode(contents)
        defer { wipe(&plain) }
        let nonce = randomBytes(nonceBytes)
        let ct = try Primitives.aesGCMSeal(key: key, nonce: nonce, ad: aad(escrowVersion), plaintext: plain)
        return [version] + nonce + ct
    }

    public static func open(key: Bytes, _ sealed: Bytes, escrowVersion: UInt32) throws -> Contents {
        guard sealed.count > headerBytes else { throw format("blob is too short to be sealed") }
        guard sealed[0] == version else { throw format("blob version \(sealed[0])") }
        var plain: Bytes
        do {
            plain = try Primitives.aesGCMOpen(key: key, nonce: Array(sealed[1..<headerBytes]), ad: aad(escrowVersion), ciphertext: Array(sealed[headerBytes...]))
        } catch {
            throw BlobError(code: "E_BLOB_LOCKED", message: "the derived key does not open this blob under that version", help: "The saved copy of this home could not be opened. Open your box's local dashboard, then Settings → FTW app → Show pairing code, and scan a new QR instead.")
        }
        defer { wipe(&plain) }
        return try decode(plain)
    }
}
