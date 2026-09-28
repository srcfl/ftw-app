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

    private var key: Bytes {
        if let k = store.get(Self.keyName), k.count == 32 { return k }
        let k = randomBytes(32)
        store.put(Self.keyName, k)
        return k
    }

    private func url(_ name: String) -> URL {
        directory.appendingPathComponent(name.replacingOccurrences(of: "/", with: "_"))
    }

    public func write(_ name: String, _ plain: Bytes) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let nonce = randomBytes(12)
            let sealed = nonce + (try Primitives.aesGCMSeal(key: key, nonce: nonce, ad: Array(name.utf8), plaintext: plain))
            var options: Data.WritingOptions = [.atomic]
            #if os(iOS)
            options.insert(.completeFileProtectionUntilFirstUserAuthentication)
            #endif
            try Data(sealed).write(to: url(name), options: options)
        } catch {
            // A cache that could not be written costs a slower next start.
        }
    }

    public func read(_ name: String) -> Bytes? {
        guard let data = try? Data(contentsOf: url(name)), data.count > 28 else { return nil }
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
    }

    public func writeJSON<T: Encodable>(_ name: String, _ value: T) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        write(name, data.byteArray)
    }

    public func readJSON<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let raw = read(name) else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(raw))
    }
}

/// Closed history tiles, per home, so opening the chart paints at once and
/// the box sends only what changed.
@MainActor
public final class TileCache {
    struct Tile: Codable {
        var tileId: String
        var etag: String
        var res: String
        var startMs: Double
        var stepMs: Double
        var series: [String]
        var data: Data
    }

    private let files: SealedFiles?
    private let siteId: String
    private var tiles: [String: Tile]
    private var dirty = false

    public init(files: SealedFiles?, siteId: String) {
        self.files = files
        self.siteId = siteId
        tiles = files?.readJSON([String: Tile].self, "tiles-\(siteId)") ?? [:]
    }

    public func get(_ ids: [String]) -> [String: HistChunk] {
        var out = [String: HistChunk]()
        for id in ids {
            guard let t = tiles[id] else { continue }
            out[id] = HistChunk(tileId: t.tileId, etag: t.etag, res: Resolution(rawValue: t.res) ?? .fiveMinutes, startMs: t.startMs, stepMs: t.stepMs, series: t.series, data: t.data.byteArray, partial: false)
        }
        return out
    }

    /// The trailing tile is still filling and never cached.
    public func put(_ chunk: HistChunk) {
        guard !chunk.partial else { return }
        tiles[chunk.tileId] = Tile(tileId: chunk.tileId, etag: chunk.etag, res: chunk.res.rawValue, startMs: chunk.startMs, stepMs: chunk.stepMs, series: chunk.series, data: Data(chunk.data))
        dirty = true
    }

    /// Drop tiles past each resolution's retention, then write.
    public func flush(nowMs: Double) {
        let before = tiles.count
        tiles = tiles.filter { _, t in
            let res = Resolution(rawValue: t.res) ?? .fiveMinutes
            return t.startMs + HistoryGeometry.spec(res).tileSpanMs >= nowMs - HistoryGeometry.spec(res).retentionMs
        }
        if dirty || tiles.count != before {
            files?.writeJSON("tiles-\(siteId)", tiles)
            dirty = false
        }
    }
}
