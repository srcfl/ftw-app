import Foundation
import Synchronization

// What the app leaves on disk for its widgets, and later for a notification
// extension: one home's prices and its car, each with where it came from
// and when. Widgets read this and nothing else. They never open the relay
// and never touch a key.
//
// The app writes and widgets read. Both go through the same records, so a
// widget cannot draw a reading the app never had.

/// The shape of something kept in the cache.
public protocol CacheValue: Codable, Sendable, Equatable {
    /// The record lives at "<name>-<siteId>".
    static var name: String { get }
    /// Bumped when the shape changes. A record of another shape is not read.
    static var version: Int { get }
}

/// One cached reading of one home.
///
/// Freshness is two fields here as everywhere. `carrier` is how the reading
/// reached the phone when it was taken, `srcState` whether the box's own
/// source was answering then. Read back, a record is always `.cache`
/// (`CacheRead.carrier`), so old data never looks live.
public struct CacheRecord<Value: CacheValue>: Codable, Sendable, Equatable {
    public var version: Int
    public var siteId: String
    public var carrier: CarrierKind
    public var srcState: SourceState
    /// Wall clock on the phone when the reading arrived.
    public var readAtMs: Double
    public var value: Value

    public init(siteId: String, carrier: CarrierKind, srcState: SourceState, readAtMs: Double, value: Value) {
        version = Value.version
        self.siteId = siteId
        self.carrier = carrier
        self.srcState = srcState
        self.readAtMs = readAtMs
        self.value = value
    }
}

/// Which source a record came from.
public enum CacheOrigin: String, Sendable {
    /// Written by the app, from its own session with the box.
    case app
    // FTW Cloud, the opt-in state cache, would be a second case here, read by
    // its own `CacheSource` into the same records.
}

/// Somewhere records can come from. The App Group files are the only source
/// today. A copy from FTW Cloud becomes one more source that reads into the
/// same `CacheRecord`, so nothing that reads the cache has to change.
public protocol CacheSource: Sendable {
    var origin: CacheOrigin { get }
    func read<Value: CacheValue>(_ type: Value.Type, siteId: String) -> CacheRecord<Value>?
    /// Homes with a record of this kind, most recently written first.
    func siteIDs<Value: CacheValue>(_ type: Value.Type) -> [String]
}

/// A record as a reader hands it out.
public struct CacheRead<Value: CacheValue>: Sendable {
    public let record: CacheRecord<Value>
    public let origin: CacheOrigin

    public init(record: CacheRecord<Value>, origin: CacheOrigin) {
        self.record = record
        self.origin = origin
    }

    public var value: Value { record.value }
    /// Always `.cache`. A file on this phone is not a connection to the box.
    public var carrier: CarrierKind { .cache }
    /// As it was when the reading arrived. Never better.
    public var srcState: SourceState { record.srcState }

    public func ageMs(nowMs: Double) -> Double { max(0, nowMs - record.readAtMs) }
}

/// Reads the newest record any source holds.
public struct CacheReader: Sendable {
    public let sources: [any CacheSource]

    public init(sources: [any CacheSource]) {
        self.sources = sources
    }

    /// The App Group files, when this process has the group.
    public static func shared(bundle: Bundle = .main) -> CacheReader? {
        AppGroupFiles.shared(bundle: bundle).map { CacheReader(sources: [$0]) }
    }

    public func read<Value: CacheValue>(_ type: Value.Type, siteId: String) -> CacheRead<Value>? {
        var best: CacheRead<Value>?
        for source in sources {
            guard let record = source.read(type, siteId: siteId) else { continue }
            if best == nil || record.readAtMs > best!.record.readAtMs {
                best = CacheRead(record: record, origin: source.origin)
            }
        }
        return best
    }

    /// The home most recently written: the one the app had open last.
    public func latestSiteID<Value: CacheValue>(_ type: Value.Type) -> String? {
        sources.lazy.compactMap { $0.siteIDs(type).first }.first
    }
}

/// Files in the App Group container, which the app and its widgets share.
///
/// Not sealed: prices are not secret and the car record says no more than
/// the charger's own app. Files carry `completeUntilFirstUserAuthentication`,
/// so a widget can read them while the phone is locked, but not after a
/// restart before the first unlock.
public struct AppGroupFiles: CacheSource {
    /// The Info.plist key that names the App Group. The build fills it from
    /// the same setting as the entitlements, so Swift never spells the name.
    public static let infoKey = "FTWAppGroup"

    public let directory: URL
    public var origin: CacheOrigin { .app }

    public init(directory: URL) {
        self.directory = directory
    }

    /// The container named in `bundle`'s Info.plist. Nil when the process has
    /// no such group: a test, or a build without the entitlement.
    public static func shared(bundle: Bundle = .main) -> AppGroupFiles? {
        guard let group = bundle.object(forInfoDictionaryKey: infoKey) as? String, !group.isEmpty,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return AppGroupFiles(directory: container.appendingPathComponent("Library/Application Support/cache", isDirectory: true))
    }

    func url(_ name: String, _ siteId: String) -> URL {
        directory.appendingPathComponent("\(name)-\(siteId)")
    }

    public func read<Value: CacheValue>(_ type: Value.Type, siteId: String) -> CacheRecord<Value>? {
        guard let data = try? Data(contentsOf: url(Value.name, siteId)),
              let record = try? JSONDecoder().decode(CacheRecord<Value>.self, from: data),
              record.version == Value.version, record.siteId == siteId else { return nil }
        return record
    }

    public func siteIDs<Value: CacheValue>(_ type: Value.Type) -> [String] {
        let prefix = "\(Value.name)-"
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .map { (id: String($0.lastPathComponent.dropFirst(prefix.count)), at: (try? $0.resourceValues(forKeys: keys))?.contentModificationDate ?? .distantPast) }
            .sorted { $0.at > $1.at }
            .map(\.id)
    }

    /// Only the app writes. Atomic, so a widget never reads half a file.
    public func write<Value: CacheValue>(_ record: CacheRecord<Value>) throws {
        try Self.clears.withLock { _ in try store(record) }
    }

    /// Writes off the caller's thread. `asked` is `clearCount` when the write
    /// was asked for: a clear since then means the home was signed out, so
    /// the write is dropped rather than putting the home back. Returns
    /// whether it wrote.
    @concurrent
    public nonisolated func write<Value: CacheValue>(_ record: CacheRecord<Value>, asked: Int) async throws -> Bool {
        try Self.clears.withLock { counts in
            guard counts[directory, default: 0] == asked else { return false }
            try store(record)
            return true
        }
    }

    /// Everything, for signing out. A widget then has nothing to draw.
    public func removeAll() {
        Self.clears.withLock { counts in
            counts[directory, default: 0] += 1
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// How many times this process has cleared this cache. Writes and
    /// clears take the same lock, so they land in the order they were asked
    /// for.
    public var clearCount: Int { Self.clears.withLock { $0[directory, default: 0] } }
    private static let clears = Mutex<[URL: Int]>([:])

    private func store<Value: CacheValue>(_ record: CacheRecord<Value>) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(record)
        try data.write(to: url(Value.name, record.siteId), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

// MARK: - What is kept

/// One home's prices across today and tomorrow, as the box served them.
public struct PriceEntry: CacheValue {
    public static let name = "prices"
    public static let version = 1

    /// Local midnight the window starts at.
    public var fromMs: Double
    public var prices: Prices
    /// The household's time zone, as the box names it, so a widget reads the
    /// clock the way the home does. Nil in a record from before it was kept.
    public var timeZone: String?

    public init(fromMs: Double, prices: Prices, timeZone: String? = nil) {
        self.fromMs = fromMs
        self.prices = prices
        self.timeZone = timeZone
    }
}

extension Calendar {
    /// The household's calendar: the box's zone when a record names one,
    /// else the phone's.
    public static func household(_ identifier: String?) -> Calendar {
        var calendar = Calendar.current
        if let identifier, let zone = TimeZone(identifier: identifier) { calendar.timeZone = zone }
        return calendar
    }
}

/// The cars on one home's chargers, as the box last described them.
public struct CarEntry: CacheValue {
    public static let name = "car"
    public static let version = 1

    public struct Car: Codable, Sendable, Equatable {
        public var loadpointID: String
        public var pluggedIn: Bool
        /// Whole percent. Nil when the box has no level for the car.
        public var socPct: Double?
        /// Where the level came from, in the box's words: vehicle, inferred,
        /// assumed or completed. A level the box assumed is not a reading.
        public var socSource: String
        /// Wall clock of the level itself. For a level from the car, when
        /// the car reported it, which can be well before the record.
        public var socReadAtMs: Double?
        /// Charger power, site convention: positive while charging.
        public var powerW: Double
        /// The goal the box holds, whole percent.
        public var targetSocPct: Double?

        public init(loadpointID: String, pluggedIn: Bool, socPct: Double?, socSource: String, socReadAtMs: Double?, powerW: Double, targetSocPct: Double?) {
            self.loadpointID = loadpointID
            self.pluggedIn = pluggedIn
            self.socPct = socPct
            self.socSource = socSource
            self.socReadAtMs = socReadAtMs
            self.powerW = powerW
            self.targetSocPct = targetSocPct
        }
    }

    public var cars: [Car]

    public init(cars: [Car]) {
        self.cars = cars
    }

    /// The same cars at the same levels, whenever each level was read. A
    /// rewrite of that tells a widget nothing new.
    public func sameReading(_ other: CarEntry) -> Bool {
        func levels(_ e: CarEntry) -> [Car] { e.cars.map { var c = $0; c.socReadAtMs = nil; return c } }
        return levels(self) == levels(other)
    }
}
