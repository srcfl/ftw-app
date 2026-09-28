import Foundation

/// Small secrets and records, by name.
///
/// On Apple platforms this is the Keychain, readable after first unlock and
/// never synced or migrated to another device. Tests use `MemoryStore`.
///
/// Everything here is a cache of what the box holds, except the device key,
/// which is this phone's identity. Clearing the store is signing out.
@MainActor
public protocol SecureStore: AnyObject {
    func get(_ key: String) -> Bytes?
    func put(_ key: String, _ value: Bytes)
    func remove(_ key: String)
}

@MainActor
public final class MemoryStore: SecureStore {
    private var map: [String: Bytes] = [:]

    public init() {}

    public func get(_ key: String) -> Bytes? { map[key] }
    public func put(_ key: String, _ value: Bytes) { map[key] = value }
    public func remove(_ key: String) { map[key] = nil }

    public var keys: [String] { map.keys.sorted() }
}

extension SecureStore {
    func getJSON<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let raw = get(key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(raw))
    }

    func putJSON<T: Encodable>(_ key: String, _ value: T) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        put(key, data.byteArray)
    }
}
