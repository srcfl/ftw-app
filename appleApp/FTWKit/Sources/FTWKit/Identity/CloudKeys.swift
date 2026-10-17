import Foundation

/// Where FTW Cloud is and the keys it answers with.
///
/// The address is fixed: `wss://cloud.ftw.energy/v1/app`, as the relay's is.
/// The app carries up to two of the service's Noise keys so the service can
/// rotate across an app release. Only a debug build may point elsewhere,
/// for a local `ftwcloudd`:
///
///     -FTWCloudURL wss://127.0.0.1:18443/v1/app -FTWCloudKey <base64url>
public struct CloudEndpoint: Equatable, Sendable {
    public var url: URL
    /// X25519 public keys, 32 bytes each, tried in order.
    public var serviceKeys: [Bytes]

    public init(url: URL, serviceKeys: [Bytes]) {
        self.url = url
        self.serviceKeys = serviceKeys
    }

    public static let releaseURL = URL(string: "wss://cloud.ftw.energy/v1/app")!

    /// The service's Noise keys, base64url of the X25519 public half. Up to
    /// two, so the key can rotate across an app release: ship the new key
    /// beside the old one, switch the service, then drop the old one. The
    /// one key is cloud.ftw.energy's, kept as `/ftw-cloud/noise-key` in
    /// Parameter Store (srcfl/ftw-cloud `deploy/noise.md`). Empty would mean
    /// a release build reads through the relay alone and offers no FTW Cloud.
    static let releaseKeyText = ["6-1WbbDzKvbwODSwhUN24MPemfLNRhcbMP2tpU_QAEk"]
    static let releaseKeys: [Bytes] = releaseKeyText.compactMap { try? Base64url.decode($0) }

    /// The endpoint this build uses, or nil when it has none.
    public static var current: CloudEndpoint? {
        #if DEBUG
        resolve(defaults: .standard, debug: true)
        #else
        resolve(defaults: .standard, debug: false)
        #endif
    }

    /// Debug builds read the override; every other build ignores it.
    static func resolve(defaults: UserDefaults, debug: Bool) -> CloudEndpoint? {
        if debug, let raw = defaults.string(forKey: "FTWCloudURL"), let url = URL(string: raw),
           url.scheme == "wss" || url.scheme == "ws",
           let raw = defaults.string(forKey: "FTWCloudKey"), let key = try? Base64url.decode(raw), key.count == Noise.dhBytes {
            return CloudEndpoint(url: url, serviceKeys: [key])
        }
        let keys = releaseKeys.filter { $0.count == Noise.dhBytes }.prefix(2)
        return keys.isEmpty ? nil : CloudEndpoint(url: releaseURL, serviceKeys: Array(keys))
    }

    /// The address for one home's session.
    func url(home: String) -> URL {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "home", value: home)]
        return c.url!
    }
}

/// What the box tells its phones about FTW Cloud, over their own Noise
/// session: the key it signs with, its home id, its current boot and the
/// names behind its anonymous ids. It never comes from the service, which
/// could otherwise sign for the box. Present only while the grant is on.
public struct CloudIdentity: Codable, Equatable, Sendable {
    /// The box's P-256 key, 65 bytes uncompressed.
    public var pk: Bytes
    /// Computed here from `pk`, never taken from the box's word for it.
    public var home: String
    public var boot: Bytes
    /// Anonymous source id to the driver name the box session uses.
    public var sources: [String: String]
    /// Anonymous loadpoint id to the loadpoint id the box session uses.
    public var loadpoints: [String: String]
    /// Anonymous car id to the car's id, from a box that keeps cars. Nil in
    /// what an older build kept.
    public var cars: [String: String]?

    public init(pk: Bytes, boot: Bytes, sources: [String: String] = [:], loadpoints: [String: String] = [:], cars: [String: String]? = nil) {
        self.pk = pk
        home = CloudWire.homeID(pk: pk)
        self.boot = boot
        self.sources = sources
        self.loadpoints = loadpoints
        self.cars = cars
    }

    /// hello_ok's `cloud`, or nil when it is absent or malformed. A home id
    /// that is not the hash of the key is refused.
    init?(_ c: CBOR?) {
        guard let c, let pk = c["pk"]?.byteString, pk.count == CloudWire.publicKeyBytes,
              let boot = c["boot"]?.byteString, boot.count == CloudWire.bootBytes else { return nil }
        self.init(pk: pk, boot: boot, sources: Self.names(c["sources"]), loadpoints: Self.names(c["loadpoints"]), cars: c["cars"] == nil ? nil : Self.names(c["cars"]))
        if let said = c["home"]?.string, said != home { return nil }
    }

    private static func names(_ c: CBOR?) -> [String: String] {
        var out = [String: String]()
        for e in c?.entries ?? [] {
            if let k = e.key.string, let v = e.value.string { out[k] = v }
        }
        return out
    }

    /// The same box and home, whatever its boot or names.
    func sameHome(_ other: CloudIdentity?) -> Bool {
        other?.pk == pk
    }

    /// Whether the owner has the readable copy on. The tables are cut with
    /// the grant's key, so they are empty while it is off
    /// (docs/protocol-cloud.md, Session information).
    var copyOn: Bool { !sources.isEmpty || !loadpoints.isEmpty }
}
