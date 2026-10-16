import Foundation

/// The grant offer (docs/agents.md in srcfl/ftw, The grant offer): what FTW
/// Cloud's consent page asks the owner to grant, signed by FTW Cloud's offer
/// key, which this app pins. The universal link carries it in its fragment;
/// the short code on the page finds it once at FTW Cloud.
public struct GrantOffer: Equatable, Sendable {
    public static let version: UInt64 = 1
    /// The longest an offer may live.
    public static let ttlMs: Int64 = 10 * 60 * 1000

    public var v: UInt64 = 0
    /// Empty: the owner picks the home.
    public var home = ""
    /// The agent's X25519 key, made by FTW Cloud's keys part.
    public var key: Bytes = []
    public var role = ""
    /// The name the client gives itself. Its own word, never checked.
    public var client = ""
    public var clientId = ""
    /// The host of the client's metadata document or redirect URI.
    public var clientHost = ""
    /// FTW Cloud knows the client from its own list.
    public var verified = false
    public var scopes: [String] = []
    public var ops: [String] = []
    public var caps = Caps()
    public var ttlS: UInt64 = 0
    public var ticket = ""
    /// What the consent page shows, for the owner to type or compare.
    public var code = ""
    /// Wall-clock ms when the offer stops being good.
    public var expMs: Int64 = 0

    public init() {}

    /// The offer's own deterministic CBOR, as FTW Cloud signs it.
    public var cbor: CBOR {
        .map([
            ("v", .unsigned(v)), ("home", .text(home)), ("key", .bytes(key)), ("role", .text(role)),
            ("client", .text(client)), ("clientId", .text(clientId)), ("clientHost", .text(clientHost)),
            ("verified", .bool(verified)), ("scopes", .array(scopes.map { .text($0) })),
            ("ops", .array(ops.map { .text($0) })), ("caps", caps.cbor), ("ttlS", .unsigned(ttlS)),
            ("ticket", .text(ticket)), ("code", .text(code)), ("exp", .int(expMs)),
        ]).deterministic
    }

    /// Strict, as the box reads it: a key it does not know, a key twice or
    /// a value of the wrong kind is no offer.
    init(strict c: CBOR) throws {
        guard let entries = c.entries else { throw OfferError.malformed }
        for e in entries {
            guard let k = e.key.string else { throw OfferError.malformed }
            let v = e.value
            switch k {
            case "v": self.v = try Self.need(v.uint)
            case "home": home = try Self.need(v.string)
            case "key": key = try Self.need(v.byteString)
            case "role": role = try Self.need(v.string)
            case "client": client = try Self.need(v.string)
            case "clientId": clientId = try Self.need(v.string)
            case "clientHost": clientHost = try Self.need(v.string)
            case "verified": verified = try Self.need(v.bool)
            case "scopes": scopes = try Self.texts(v)
            case "ops": ops = try Self.texts(v)
            case "caps": caps = try Self.caps(v)
            case "ttlS": ttlS = try Self.need(v.uint)
            case "ticket": ticket = try Self.need(v.string)
            case "code": code = try Self.need(v.string)
            case "exp": expMs = try Self.need(v.int64)
            default: throw OfferError.malformed
            }
        }
    }

    private static func need<T>(_ v: T?) throws -> T {
        guard let v else { throw OfferError.malformed }
        return v
    }

    private static func texts(_ v: CBOR) throws -> [String] {
        if v.isNull { return [] }
        guard let items = v.array else { throw OfferError.malformed }
        return try items.map { try need($0.string) }
    }

    private static func caps(_ v: CBOR) throws -> Caps {
        guard let entries = v.entries else { throw OfferError.malformed }
        var c = Caps()
        for e in entries {
            switch e.key.string {
            case "holdS": c.holdS = try need(e.value.uint)
            case "maxW": c.maxW = try need(e.value.uint)
            case "perMin": c.perMin = try need(e.value.uint)
            default: throw OfferError.malformed
            }
        }
        return c
    }

    public var isSupport: Bool { role == AccessWire.roleSupport }
    /// It asks to hold a charger or to ask for durable changes.
    public var asksControl: Bool { !AccessWire.controlScopes.isDisjoint(with: scopes) }
}

/// Why an offer does not reach Face ID. Each says what happens now.
public enum OfferError: Error, Equatable, Sendable {
    /// This build pins no offer key: it opens no offer.
    case noPinnedKey
    /// No pinned key signed it.
    case unsigned
    case expired
    case malformed
    /// A support or release offer from a client that is not Sourceful's.
    case notFromSourceful
    /// The client's host is written in letters that could imitate another
    /// address.
    case strangeHost
    /// The owner already answered this offer, here or elsewhere.
    case used
    /// For a home this phone does not have.
    case unknownHome
    /// The code typed is not the offer's.
    case wrongCode
    /// FTW Cloud has no offer under that code or link, or it was used.
    case notFound
    /// FTW Cloud could not be reached.
    case unreachable
}

/// An offer as it travels: `o` is the offer's deterministic CBOR, `sig` FTW
/// Cloud's offer key's signature over `["ftw.offer.v1", o]`, and `kid`
/// names that key.
public struct SignedOffer: Equatable, Sendable {
    public static let tag = "ftw.offer.v1"

    public var o: Bytes
    public var kid: String
    public var sig: Bytes

    public init(o: Bytes, kid: String, sig: Bytes) {
        self.o = o
        self.kid = kid
        self.sig = sig
    }

    /// Base64url without padding, as the link's fragment and the code
    /// lookup carry it.
    public init(base64url text: String) throws {
        guard let raw = try? Base64url.decode(text), let c = try? decodeCBOR(raw),
              let entries = c.entries, entries.count == 3,
              let o = c["o"]?.byteString, let kid = c["kid"]?.string, let sig = c["sig"]?.byteString else {
            throw OfferError.malformed
        }
        self.init(o: o, kid: kid, sig: sig)
    }

    public var base64url: String {
        Base64url.encode(encodeDeterministic(.map([("o", .bytes(o)), ("kid", .text(kid)), ("sig", .bytes(sig))])))
    }

    /// What the offer key signs.
    public static func signedBytes(_ o: Bytes) -> Bytes {
        encodeDeterministic(.array([.text(tag), .bytes(o)]))
    }

    /// The offer, if a pinned key signed it and it is still good. A support
    /// offer counts only from Sourceful's own client, and a release offer
    /// from none yet: no release client is pinned. A client host must be
    /// plain ASCII, so no look-alike letter can pass for a known address.
    public func open(keys: OfferKeys, nowMs: Int64) throws -> GrantOffer {
        guard !keys.isEmpty else { throw OfferError.noPinnedKey }
        guard let pub = keys.pub(kid), Approval.verify(pub: pub, message: Self.signedBytes(o), sig: sig) else {
            throw OfferError.unsigned
        }
        guard let c = try? decodeCBOR(o) else { throw OfferError.malformed }
        let offer = try GrantOffer(strict: c)
        guard offer.v == GrantOffer.version, offer.key.count == 32,
              [AccessWire.roleAgent, AccessWire.roleSupport, AccessWire.roleRelease].contains(offer.role) else {
            throw OfferError.malformed
        }
        guard nowMs < offer.expMs, offer.expMs <= nowMs + GrantOffer.ttlMs else { throw OfferError.expired }
        if offer.isSupport, offer.clientId != AccessWire.supportClientID { throw OfferError.notFromSourceful }
        if offer.role == AccessWire.roleRelease { throw OfferError.notFromSourceful }
        guard Self.plainHost(offer.clientHost) else { throw OfferError.strangeHost }
        return offer
    }

    /// ASCII letters, digits, hyphens and dots, and a port: a host no
    /// look-alike letter can hide in. Punycode stays as it is, `xn--`.
    static func plainHost(_ host: String) -> Bool {
        !host.isEmpty && host.utf8.count <= 253 && host.utf8.allSatisfy { c in
            (0x41...0x5a).contains(c) || (0x61...0x7a).contains(c) || (0x30...0x39).contains(c) || c == 0x2d || c == 0x2e || c == 0x3a
        }
    }
}

/// The offer keys this build pins, kid → SEC1 P-256 point, as it pins the
/// service's Noise key. A build that pins none opens no offer. An entry
/// whose kid is not its key's is dropped, as the box drops one.
///
/// FTW Cloud's keys part makes the key on its host and publishes it at
/// `https://cloud.ftw.energy/.well-known/ftw-offer-key`; a release pins it
/// here. None is pinned yet: the keys part is not running. Only a debug
/// build may pin another, for a local `ftwcloudd`:
///
///     -FTWOfferKeys <kid>:<base64url pub>[,<kid>:<pub>]
public struct OfferKeys: Equatable, Sendable {
    /// Release pins, `kid:pub`. Empty until FTW Cloud's offer key exists.
    static let releasePins: [String] = []

    let keys: [String: Bytes]

    public init(pins: [String]) {
        var out = [String: Bytes]()
        for pin in pins {
            let parts = pin.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let pub = try? Base64url.decode(parts[1]), pub.count == Approval.pubBytes,
                  Self.kid(pub) == parts[0] else { continue }
            out[parts[0]] = pub
        }
        keys = out
    }

    public var isEmpty: Bool { keys.isEmpty }
    func pub(_ kid: String) -> Bytes? { keys[kid] }

    /// The first 16 characters of base64url of SHA-256 over the SEC1 point.
    public static func kid(_ pub: Bytes) -> String {
        String(Base64url.encode(Primitives.sha256(pub)).prefix(16))
    }

    public static var current: OfferKeys {
        #if DEBUG
        resolve(defaults: .standard, debug: true)
        #else
        resolve(defaults: .standard, debug: false)
        #endif
    }

    static func resolve(defaults: UserDefaults, debug: Bool) -> OfferKeys {
        if debug, let raw = defaults.string(forKey: "FTWOfferKeys") {
            return OfferKeys(pins: raw.split(separator: ",").map(String.init))
        }
        return OfferKeys(pins: releasePins)
    }
}

/// A link from the consent page, as FTW Cloud makes it and nothing else:
/// `https://app.ftw.energy/a#<request>.<offer>`. Both ride in the fragment,
/// which no server sees; a request id in a path would reach a server's log,
/// and alone it is worth asking FTW Cloud about.
public struct OfferLink: Hashable, Sendable, Identifiable {
    public var request: String
    /// Base64url of the signed offer.
    public var offer: String

    public var id: String { request }

    public init(request: String, offer: String) {
        self.request = request
        self.offer = offer
    }

    public static let host = "app.ftw.energy"
    public static let path = "/a"

    public init?(_ text: String) {
        guard let url = URLComponents(string: text), url.scheme == "https", url.host == Self.host else { return nil }
        guard url.path == Self.path, url.percentEncodedQuery == nil else { return nil }
        let parts = (url.percentEncodedFragment ?? "").split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, Self.isToken(parts[0]), Self.isToken(parts[1]) else { return nil }
        self.init(request: parts[0], offer: parts[1])
    }

    /// Base64url's alphabet, which has no dot.
    static func isToken(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.allSatisfy { c in
            (0x41...0x5a).contains(c) || (0x61...0x7a).contains(c) || (0x30...0x39).contains(c) || c == 0x2d || c == 0x5f
        }
    }
}

/// The short code on the consent page: eight letters and digits from an
/// alphabet with no look-alikes, shown as `ABCD-EFGH`.
public enum OfferCode {
    public static let length = 8
    static let alphabet = Set("ABCDEFGHJKMNPQRSTUVWXYZ23456789")

    /// The code as an owner may type it, or nil when it cannot be one.
    public static func normalize(_ typed: String) -> String? {
        let s = typed.uppercased().filter { $0 != "-" && $0 != " " }
        guard s.count == length, s.allSatisfy(alphabet.contains) else { return nil }
        return s
    }

    /// `ABCD-EFGH`.
    public static func show(_ code: String) -> String {
        guard code.count == length else { return code }
        return "\(code.prefix(length / 2))-\(code.suffix(length / 2))"
    }

    /// Whether what was typed is the offer's own code.
    public static func matches(_ typed: String, _ offer: GrantOffer) -> Bool {
        guard let t = normalize(typed), let o = normalize(offer.code) else { return false }
        return constantTimeEqual(Bytes(t.utf8), Bytes(o.utf8))
    }
}

/// Where a typed code finds its signed offer: FTW Cloud's code lookup
/// (`GET /oauth/requests?code=`, once per code). An offer that is no longer
/// waiting for the owner is none. A debug build may point at a local
/// `ftwcloudd` with `-FTWOfferURL https://127.0.0.1:18443`.
public struct OfferLookup: Sendable {
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, Int)

    public var base: URL
    var fetch: Fetch

    public init(base: URL, fetch: @escaping Fetch) {
        self.base = base
        self.fetch = fetch
    }

    public static let releaseBase = URL(string: "https://cloud.ftw.energy")!

    public static func current(session: URLSession = .shared) -> OfferLookup {
        var base = releaseBase
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: "FTWOfferURL"), let url = URL(string: raw), url.scheme == "https" || url.scheme == "http" {
            base = url
        }
        #endif
        return OfferLookup(base: base) { req in
            let (data, response) = try await session.data(for: req)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    public func byCode(_ code: String) async throws -> SignedOffer {
        var c = URLComponents(url: base.appendingPathComponent("oauth/requests"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "code", value: code)]
        return try await get(c.url!)
    }

    private func get(_ url: URL) async throws -> SignedOffer {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("https://\(OfferLink.host)", forHTTPHeaderField: "Origin")
        let data: Data
        let status: Int
        do {
            (data, status) = try await fetch(req)
        } catch {
            throw OfferError.unreachable
        }
        guard status == 200 else { throw status == 404 || status == 410 ? OfferError.notFound : OfferError.unreachable }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let offer = json["offer"] as? String else {
            throw OfferError.malformed
        }
        // Approved, denied or expired at FTW Cloud: answered already.
        if let status = json["status"] as? String, status != "pending" { throw OfferError.used }
        return try SignedOffer(base64url: offer)
    }
}
