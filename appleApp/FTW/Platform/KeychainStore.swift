import Foundation
import FTWKit
import Security

/// The secure store: generic passwords, readable after first unlock, never
/// synced and never migrated to another device. Cold start reads it without
/// Face ID, which is what lets the cache paint first.
///
/// No access group is named, so every item lives in the app's own default
/// group. The widget extension has a different one and can read none of it:
/// widgets get the App Group cache and no key.
@MainActor
final class KeychainStore: SecureStore {
    private let service = "energy.ftw.app"

    func get(_ key: String) -> Bytes? {
        (try? read(key)) ?? nil
    }

    /// Only errSecItemNotFound means absent. Before the first unlock the
    /// keychain answers errSecInteractionNotAllowed, and that must never
    /// lead to a new key written over the old one.
    func read(_ key: String) throws -> Bytes? {
        var query = base(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw SecureStoreUnavailable(status: status) }
            return data.byteArray
        case errSecItemNotFound:
            return nil
        default:
            throw SecureStoreUnavailable(status: status)
        }
    }

    func put(_ key: String, _ value: Bytes) {
        try? write(key, value)
    }

    /// Update or add, and say when neither kept the value.
    func write(_ key: String, _ value: Bytes) throws {
        let query = base(key)
        let update: [String: Any] = [kSecValueData as String: Data(value)]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(value)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SecureStoreUnavailable(status: status) }
    }

    func remove(_ key: String) {
        SecItemDelete(base(key) as CFDictionary)
    }

    private func base(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}
