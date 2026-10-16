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
    /// The value, or nil when it is absent or could not be read.
    func get(_ key: String) -> Bytes?
    /// The value, nil only when it is absent, and an error when the store
    /// could not answer, as before the first unlock. Anything that would
    /// create a value on nil must use this: a store that cannot answer does
    /// not mean the value is gone.
    func read(_ key: String) throws -> Bytes?
    func put(_ key: String, _ value: Bytes)
    /// As `put`, and an error when the store did not keep it: anything a
    /// box will hold this phone to, such as an approval key, must know.
    func write(_ key: String, _ value: Bytes) throws
    func remove(_ key: String)
}

/// The store could not answer, so nothing may be written on its word.
public struct SecureStoreUnavailable: Error, Equatable {
    public let status: Int32

    public init(status: Int32) {
        self.status = status
    }
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
    /// A store that cannot fail to answer, such as `MemoryStore`.
    public func read(_ key: String) throws -> Bytes? { get(key) }

    /// A store that cannot fail to keep, such as `MemoryStore`.
    public func write(_ key: String, _ value: Bytes) throws { put(key, value) }

    func getJSON<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let raw = get(key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(raw))
    }

    func putJSON<T: Encodable>(_ key: String, _ value: T) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        put(key, data.byteArray)
    }
}
