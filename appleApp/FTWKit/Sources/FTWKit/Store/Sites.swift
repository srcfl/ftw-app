import Foundation

/// One paired home, as this phone remembers it.
public struct StoredSite: Codable, Equatable, Sendable, Identifiable {
    public var siteId: String
    public var label: String
    /// Pinned optically. What stops the relay impersonating a box.
    public var boxStaticKey: Data
    /// Long-lived. The rotating relay handle is derived from it and only it.
    /// Nil for a home paired before the v2 payload, which cannot be reached.
    public var rendezvousSecret: Data?
    /// Single use, spent in the first handshake. Kept until then.
    public var pairingCode: Data?
    public var lanHint: String?
    /// Whether this household asked Sourceful to hold a sealed copy of it.
    public var escrow: Bool
    public var addedAtMs: Double
    public var lastSeenAtMs: Double

    public var id: String { siteId }

    public init(siteId: String, label: String, boxStaticKey: Data, rendezvousSecret: Data?, pairingCode: Data?, lanHint: String?, escrow: Bool, addedAtMs: Double, lastSeenAtMs: Double) {
        self.siteId = siteId
        self.label = label
        self.boxStaticKey = boxStaticKey
        self.rendezvousSecret = rendezvousSecret
        self.pairingCode = pairingCode
        self.lanHint = lanHint
        self.escrow = escrow
        self.addedAtMs = addedAtMs
        self.lastSeenAtMs = lastSeenAtMs
    }
}

/// The homes this phone is paired to, and which one it opens.
///
/// Storing a home is a fact; making it the one the app shows is a decision,
/// so the two are separate calls.
@MainActor
public final class SiteList {
    private let store: SecureStore
    static let sitesKey = "sites"
    static let currentKey = "current-site"

    public init(store: SecureStore) {
        self.store = store
    }

    public func all() -> [StoredSite] {
        store.getJSON([StoredSite].self, Self.sitesKey) ?? []
    }

    public func get(_ siteId: String) -> StoredSite? {
        all().first { $0.siteId == siteId }
    }

    public func put(_ site: StoredSite) {
        var rows = all().filter { $0.siteId != site.siteId }
        rows.append(site)
        store.putJSON(Self.sitesKey, rows)
    }

    public func update(_ siteId: String, _ change: (inout StoredSite) -> Void) {
        guard var row = get(siteId) else { return }
        change(&row)
        put(row)
    }

    /// The home the app opens: the pointer, else the first row. A pointer
    /// left behind after its row is gone is ignored rather than trusted.
    public func current() -> StoredSite? {
        let rows = all()
        if let id = store.get(Self.currentKey).map({ String(decoding: $0, as: UTF8.self) }),
           let row = rows.first(where: { $0.siteId == id }) {
            return row
        }
        return rows.first
    }

    public func setCurrent(_ siteId: String) {
        store.put(Self.currentKey, Array(siteId.utf8))
    }

    public func clear() {
        store.remove(Self.sitesKey)
        store.remove(Self.currentKey)
    }

    /// Six hex characters of the box key's digest, so two boxes look
    /// different. The same name the web app shows for the same box.
    public nonisolated static func fingerprint(_ boxStaticKey: Bytes) -> String {
        Array(Primitives.sha256(boxStaticKey).prefix(3)).hex.uppercased()
    }

    /// A local id for a box, never sent anywhere.
    public nonisolated static func siteID(_ boxStaticKey: Bytes) -> String {
        Array(Primitives.sha256(boxStaticKey).prefix(8)).hex
    }
}
