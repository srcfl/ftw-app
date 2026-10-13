import Foundation

/// Sealed files for what the app caches between launches: the last readings
/// and the history tiles.
///
/// AES-GCM under a cache key kept in the secure store, and deliberately not
/// behind a passkey: a cold start must paint before any Face ID prompt. The
/// honest claim is that the files resist an offline read of the disk, not
/// someone holding the unlocked phone, who can open the app and look.
///
/// A file that will not open is treated as absent. Every file here is a
/// cache: the box holds the record.
@MainActor
public final class SealedFiles {
    static let keyName = "cache-key"
    private let directory: URL
    private let store: SecureStore
    /// The key, once read, so a write does not ask the keychain again.
    private var cachedKey: Bytes?
    /// The latest write off the main actor; each waits for the one before.
    private var writing: Task<Void, Never>?

    public init(directory: URL, store: SecureStore) {
        self.directory = directory
        self.store = store
    }

    /// The app's own cache directory, created on first use.
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("FTW", isDirectory: true)
    }

    /// The cache key, made only when the store says it has none. A store
    /// that cannot answer gives no key, and nothing is written or read.
    private var key: Bytes? {
        if let cachedKey { return cachedKey }
        let held: Bytes?
        do {
            held = try store.read(Self.keyName)
        } catch {
            return nil
        }
        if let held, held.count == 32 {
            cachedKey = held
            return held
        }
        let k = randomBytes(32)
        store.put(Self.keyName, k)
        cachedKey = k
        return k
    }

    private func url(_ name: String) -> URL {
        directory.appendingPathComponent(name.replacingOccurrences(of: "/", with: "_"))
    }

    public func write(_ name: String, _ plain: Bytes) {
        guard let key else { return }
        Self.seal(key: key, name: name, plain: plain, to: url(name), in: directory)
    }

    /// Seal and write off the main actor, in the order asked for. Returns
    /// the write, for a caller that must not end before it lands.
    @discardableResult
    public func writeLater(_ name: String, _ plain: Bytes) -> Task<Void, Never>? {
        guard let key else { return nil }
        let previous = writing
        let target = url(name), directory = directory
        let task = Task {
            await previous?.value
            await Self.sealOffMain(key: key, name: name, plain: plain, to: target, in: directory)
        }
        writing = task
        return task
    }

    @concurrent
    private nonisolated static func sealOffMain(key: Bytes, name: String, plain: Bytes, to target: URL, in directory: URL) async {
        seal(key: key, name: name, plain: plain, to: target, in: directory)
    }

    private nonisolated static func seal(key: Bytes, name: String, plain: Bytes, to target: URL, in directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let nonce = randomBytes(12)
            let sealed = nonce + (try Primitives.aesGCMSeal(key: key, nonce: nonce, ad: Array(name.utf8), plaintext: plain))
            var options: Data.WritingOptions = [.atomic]
            #if os(iOS)
            options.insert(.completeFileProtectionUntilFirstUserAuthentication)
            #endif
            try Data(sealed).write(to: target, options: options)
        } catch {
            // A cache that could not be written costs a slower next start.
        }
    }

    public func read(_ name: String) -> Bytes? {
        guard let key, let data = try? Data(contentsOf: url(name)), data.count > 28 else { return nil }
        let bytes = data.byteArray
        return try? Primitives.aesGCMOpen(key: key, nonce: Array(bytes[0..<12]), ad: Array(name.utf8), ciphertext: Array(bytes[12...]))
    }

    public func remove(_ name: String) {
        try? FileManager.default.removeItem(at: url(name))
    }

    /// Everything, and the key with it: a phone handed on must not paint the
    /// previous household's home.
    public func clear() {
        try? FileManager.default.removeItem(at: directory)
        store.remove(Self.keyName)
        cachedKey = nil
    }

    /// Encode here; with `wait` false the seal and the write happen off the
    /// main actor.
    public func writeJSON<T: Encodable>(_ name: String, _ value: T, wait: Bool = true) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        if wait {
            write(name, data.byteArray)
        } else {
            writeLater(name, data.byteArray)
        }
    }

    public func readJSON<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let raw = read(name) else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(raw))
    }
}
