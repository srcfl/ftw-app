import Foundation
import Security
import Shared

/// Generic-password KeyValueStore. After first unlock, this device only — readable at cold start without Face ID.
final class KeychainStore: NSObject, KeyValueStore {
    private let service = "energy.ftw.app"

    func get(key: String) -> KotlinByteArray? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data.kotlinByteArray
    }

    func put(key: String, value: KotlinByteArray) {
        let data = value.data
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    func remove(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private extension Data {
    var kotlinByteArray: KotlinByteArray {
        let arr = KotlinByteArray(size: Int32(count))
        enumerated().forEach { i, b in arr.set(index: Int32(i), value: Int8(bitPattern: b)) }
        return arr
    }
}

private extension KotlinByteArray {
    var data: Data {
        Data((0..<Int(size)).map { UInt8(bitPattern: get(index: Int32($0))) })
    }
}
