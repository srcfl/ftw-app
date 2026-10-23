import CryptoKit
import Foundation
import FTWWire
import Security

/// The watch's own key: an X25519 static key for Noise IK, made once on
/// this watch and kept in its Keychain. It never leaves the watch. The
/// phone adds this watch to its box by the public half, and the watch
/// reaches the box and FTW Cloud with it, phone or not (ADR 0009).
///
/// The Keychain opens it only while the watch has a passcode, so a key
/// that works means a watch unlocked on a wrist, and taking the passcode
/// off deletes it.
enum WatchIdentity {
    static let service = "energy.ftw.app.watch"
    static let account = "noise-static"

    /// The public half, made on first use. Nil when this watch has no
    /// passcode, so the key cannot be kept.
    static func publicKey() -> Data? {
        if let raw = read() {
            return (try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw))?.publicKey.rawRepresentation
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        guard store(key.rawRepresentation) else { return nil }
        return key.publicKey.rawRepresentation
    }

    /// The key for a Noise handshake. Nil without a passcode, or before
    /// the key was made.
    static func keyPair() -> Primitives.KeyPair? {
        guard let raw = read() else { return nil }
        return try? Primitives.keyPair(fromSecret: Bytes(raw))
    }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private static func read() -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func store(_ raw: Data) -> Bool {
        var q = query
        q[kSecValueData as String] = raw
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        if status != errSecSuccess {
            WatchModel.log.notice("watch key not kept: \(status, privacy: .public); a watch without a passcode has no key of its own")
        }
        return status == errSecSuccess
    }
}
