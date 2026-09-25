import Foundation
import FTWKit
import Security

/// The secure store on Apple platforms: generic passwords, readable after
/// first unlock, never synced and never migrated to another device. Cold
/// start reads it without Face ID, which is what lets the cache paint first.
@MainActor
final class KeychainStore: SecureStore {
    private let service = "energy.ftw.app"
    /// The data protection keychain on the Mac, the one iOS always uses. A
    /// build without a signing team cannot reach it, and falls back to the
    /// login keychain rather than failing to remember anything.
    private var dataProtection = true

    func get(_ key: String) -> Bytes? {
        var query = base(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = run { SecItemCopyMatching(query.merging(self.flavour) { $1 } as CFDictionary, &result) }
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data.byteArray
    }

    func put(_ key: String, _ value: Bytes) {
        let query = base(key)
        let update: [String: Any] = [kSecValueData as String: Data(value)]
        let status = run { SecItemUpdate(query.merging(self.flavour) { $1 } as CFDictionary, update as CFDictionary) }
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(value)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            _ = run { SecItemAdd(item.merging(self.flavour) { $1 } as CFDictionary, nil) }
        }
    }

    func remove(_ key: String) {
        let query = base(key)
        _ = run { SecItemDelete(query.merging(self.flavour) { $1 } as CFDictionary) }
    }

    private func base(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    private var flavour: [String: Any] {
        #if os(macOS)
        return dataProtection ? [kSecUseDataProtectionKeychain as String: true] : [:]
        #else
        return [:]
        #endif
    }

    private func run(_ call: () -> OSStatus) -> OSStatus {
        let status = call()
        if status == errSecMissingEntitlement, dataProtection {
            dataProtection = false
            return call()
        }
        return status
    }
}
