import Foundation

/// Rendezvous handles: the name the box and the app use to find each other
/// on the relay, and the one piece of metadata the relay unavoidably sees.
///
///     handle = HKDF-SHA256(secret, info = "ftw/rendezvous/v1/<epoch>")[0..16]
///
/// The secret arrives optically in the QR and never travels through
/// Sourceful. Without it two epochs' handles are unrelated strings, so the
/// relay cannot follow a household across months from an identifier.
public enum Rendezvous {
    /// An hour: short enough not to be a household identifier, long enough
    /// that rotations are rare beside ordinary reconnects.
    public static let epochMs: Double = 3_600_000
    public static let handleBytes = 16

    /// The epoch this device's clock guesses. The relay corrects a wrong one.
    public static func epoch(nowMs: Double) -> Int64 {
        Int64((nowMs / epochMs).rounded(.down))
    }

    public static func handle(secret: Bytes, epoch: Int64) throws -> String {
        guard secret.count >= 16 else {
            throw Primitives.CryptoFailure(message: "rendezvous secret is too short to be a secret")
        }
        return Primitives.hkdf(ikm: secret, salt: [], info: Array("ftw/rendezvous/v1/\(epoch)".utf8), length: handleBytes).hex
    }
}
