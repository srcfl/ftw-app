import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// The five primitives the protocol needs, over CryptoKit.
///
/// Every one of them is the platform's, not ours. The Kotlin client carries
/// hand-written X25519, ChaCha20-Poly1305 and SHA-256; here those are
/// CryptoKit on Apple platforms and swift-crypto, the same API, on Linux.
public enum Primitives {
    public struct CryptoFailure: Error, Equatable {
        public let message: String
    }

    // MARK: SHA-256 and HMAC

    public static func sha256(_ data: Bytes) -> Bytes {
        Bytes(SHA256.hash(data: data))
    }

    public static func hmacSHA256(key: Bytes, _ data: Bytes) -> Bytes {
        Bytes(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    /// RFC 5869 HKDF with SHA-256. An empty salt is a salt of zeros, as the
    /// RFC and WebCrypto both say.
    public static func hkdf(ikm: Bytes, salt: Bytes, info: Bytes, length: Int) -> Bytes {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: info,
            outputByteCount: length
        )
        return key.withUnsafeBytes { Bytes($0) }
    }

    // MARK: X25519

    public struct KeyPair: Sendable {
        public let secretKey: Bytes
        public let publicKey: Bytes
    }

    public static func generateKeyPair() -> KeyPair {
        let key = Curve25519.KeyAgreement.PrivateKey()
        return KeyPair(secretKey: Bytes(key.rawRepresentation), publicKey: Bytes(key.publicKey.rawRepresentation))
    }

    public static func keyPair(fromSecret secret: Bytes) throws -> KeyPair {
        guard secret.count == 32 else { throw CryptoFailure(message: "static key is \(secret.count) bytes, need 32") }
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: secret)
        return KeyPair(secretKey: secret, publicKey: Bytes(key.publicKey.rawRepresentation))
    }

    /// X25519. Throws on a low-order peer key, whose shared secret is all
    /// zeros: the spec permits accepting it and refusing is strictly safer.
    public static func x25519(secret: Bytes, peer: Bytes) throws -> Bytes {
        do {
            let mine = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: secret)
            let theirs = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer)
            let shared = try mine.sharedSecretFromKeyAgreement(with: theirs)
            let out = shared.withUnsafeBytes { Bytes($0) }
            if out.allSatisfy({ $0 == 0 }) { throw CryptoFailure(message: "low-order peer key") }
            return out
        } catch let e as CryptoFailure {
            throw e
        } catch {
            throw CryptoFailure(message: "X25519 failed")
        }
    }

    // MARK: ChaCha20-Poly1305

    public static func chachaSeal(key: Bytes, nonce: Bytes, ad: Bytes, plaintext: Bytes) throws -> Bytes {
        let box = try ChaChaPoly.seal(
            plaintext,
            using: SymmetricKey(data: key),
            nonce: try ChaChaPoly.Nonce(data: nonce),
            authenticating: ad
        )
        return Bytes(box.ciphertext) + Bytes(box.tag)
    }

    public static func chachaOpen(key: Bytes, nonce: Bytes, ad: Bytes, ciphertext: Bytes) throws -> Bytes {
        guard ciphertext.count >= 16 else { throw CryptoFailure(message: "ciphertext shorter than its tag") }
        let box = try ChaChaPoly.SealedBox(
            nonce: try ChaChaPoly.Nonce(data: nonce),
            ciphertext: ciphertext[..<(ciphertext.count - 16)],
            tag: ciphertext[(ciphertext.count - 16)...]
        )
        return Bytes(try ChaChaPoly.open(box, using: SymmetricKey(data: key), authenticating: ad))
    }

    // MARK: AES-256-GCM

    /// Ciphertext followed by the 16-byte tag, the layout WebCrypto returns,
    /// so a blob sealed by the web app opens here and the reverse.
    public static func aesGCMSeal(key: Bytes, nonce: Bytes, ad: Bytes = [], plaintext: Bytes) throws -> Bytes {
        let box = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: key),
            nonce: try AES.GCM.Nonce(data: nonce),
            authenticating: ad
        )
        return Bytes(box.ciphertext) + Bytes(box.tag)
    }

    public static func aesGCMOpen(key: Bytes, nonce: Bytes, ad: Bytes = [], ciphertext: Bytes) throws -> Bytes {
        guard ciphertext.count >= 16 else { throw CryptoFailure(message: "ciphertext shorter than its tag") }
        let box = try AES.GCM.SealedBox(
            nonce: try AES.GCM.Nonce(data: nonce),
            ciphertext: ciphertext[..<(ciphertext.count - 16)],
            tag: ciphertext[(ciphertext.count - 16)...]
        )
        return Bytes(try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: ad))
    }

    // MARK: Ed25519

    /// The public half of an RFC 8032 seed. Deterministic, so the same PRF
    /// output yields the same escrow write key here and in the web app.
    public static func ed25519PublicKey(seed: Bytes) throws -> Bytes {
        Bytes(try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation)
    }

    public static func ed25519Sign(seed: Bytes, message: Bytes) throws -> Bytes {
        Bytes(try Curve25519.Signing.PrivateKey(rawRepresentation: seed).signature(for: message))
    }

    public static func ed25519Verify(publicKey: Bytes, signature: Bytes, message: Bytes) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: message)
    }
}
