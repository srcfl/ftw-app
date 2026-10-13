import Foundation

/// What this phone holds about one home for FTW Cloud's pushes: the key the
/// box signs events with, which paired home it is, and the names behind the
/// opaque ids an event uses. The app writes it when the box describes its
/// FTW Cloud link over Noise; the notification extension reads it.
///
/// Nothing here is a secret. A public key checks signatures and cannot make
/// one, and the names are what the box's own page shows.
public struct CloudHome: Codable, Sendable, Equatable {
    /// The home's id at FTW Cloud: 26 characters of lowercase base32.
    public var home: String
    /// The paired home on this phone that it belongs to.
    public var siteId: String
    /// The box's cloud key, a 65-byte uncompressed P-256 point.
    public var boxKey: Data
    /// Opaque loadpoint id → the loadpoint's id at the box.
    public var loadpoints: [String: String]
    /// Opaque source id → the name the box shows for the device.
    public var sources: [String: String]

    public init(home: String, siteId: String, boxKey: Data, loadpoints: [String: String] = [:], sources: [String: String] = [:]) {
        self.home = home
        self.siteId = siteId
        self.boxKey = boxKey
        self.loadpoints = loadpoints
        self.sources = sources
    }

    /// The charger an event means. An event that names none means the only
    /// one, if the home has one. An id the table does not know is not
    /// guessed at: the table may predate a second charger.
    public func loadpointID(opaque: String?) -> String? {
        guard let opaque else { return loadpoints.count == 1 ? loadpoints.values.first : nil }
        return loadpoints[opaque]
    }

    public func sourceName(opaque: String?) -> String? {
        opaque.flatMap { sources[$0] }
    }
}

/// The App Group files that hold each home's `CloudHome`, beside the
/// widgets' cache, so signing out clears them with it. The app writes, the
/// notification extension reads. Like the cache they carry
/// `completeUntilFirstUserAuthentication`: a push that arrives while the
/// phone is locked can be checked, one before the first unlock cannot.
public struct CloudKeys: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// In the App Group container, when this process has the group.
    public static func shared(bundle: Bundle = .main) -> CloudKeys? {
        AppGroupFiles.shared(bundle: bundle).map { CloudKeys(directory: $0.directory) }
    }

    public struct Refused: Error, Equatable {
        public let reason: String
    }

    /// A home id as FTW Cloud cuts it. Anything else never becomes a file
    /// name: the id arrives in a push, and a push is not trusted.
    public static func isHomeID(_ s: String) -> Bool {
        s.utf8.count == 26 && s.utf8.allSatisfy { (0x61...0x7a).contains($0) || (0x32...0x37).contains($0) }
    }

    func url(_ home: String) -> URL {
        directory.appendingPathComponent("cloud-\(home)")
    }

    public func read(home: String) -> CloudHome? {
        guard Self.isHomeID(home),
              let data = try? Data(contentsOf: url(home)),
              let row = try? JSONDecoder().decode(CloudHome.self, from: data), row.home == home else { return nil }
        return row
    }

    /// The box key for a home, for `PushAlert.read`.
    public func boxKey(home: String) -> Data? {
        read(home: home)?.boxKey
    }

    /// Only the app writes. Atomic, so the extension never reads half a file.
    public func write(_ row: CloudHome) throws {
        guard Self.isHomeID(row.home) else { throw Refused(reason: "not a home id") }
        guard row.boxKey.count == 65, row.boxKey.first == 0x04 else { throw Refused(reason: "not an uncompressed P-256 key") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(row).write(to: url(row.home), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// FTW Cloud was turned off for this home, or the phone left it.
    public func remove(home: String) {
        guard Self.isHomeID(home) else { return }
        try? FileManager.default.removeItem(at: url(home))
    }
}
