import CryptoKit
import Foundation

/// The approval signature (docs/agents.md in srcfl/ftw, The approval
/// signature).
///
/// An owner phone approves an agent grant, a change to one, or an agent's
/// request with a P-256 key in its Secure Enclave, behind Face ID. What it
/// signs is the deterministic CBOR (RFC 8949, section 4.2.1) of one array:
///
///     ["ftw.approval.v1", what, boxKey, deviceId, atMs, ...fields]
///
/// built here exactly as `go/protocol/agents.go` builds it, so the box can
/// check it without trusting the app or FTW Cloud. `ApprovalTests` holds the
/// bytes to the box's golden vectors.
public enum Approval {
    public static let tag = "ftw.approval.v1"
    /// r ‖ s, 32 bytes each.
    public static let sigBytes = 64
    /// A SEC1 uncompressed P-256 point.
    public static let pubBytes = 65
    /// How far `atMs` may stray from the box's wall clock.
    public static let skewMs: Int64 = 10 * 60 * 1000

    public static let keySet = "approval.key.set"
    public static let add = "agent.add"
    public static let widen = "agent.widen"
    public static let confirm = "agent.confirm"

    /// A signed list must be sorted, with no repeats.
    public struct Unsorted: Error, Equatable {
        public let list: [String]
    }

    /// The bytes for `what`: the tag, the box, the phone, its clock, then
    /// the fields.
    public static func bytes(_ what: String, _ f: SignedFor, atMs: Int64, _ fields: [CBOR]) -> Bytes {
        let head: [CBOR] = [.text(tag), .text(what), .bytes(f.boxKey), .text(f.deviceID), .int(atMs)]
        return encodeDeterministic(.array(head + fields))
    }

    /// What `approval.key.set` signs: the key itself, as proof the phone
    /// holds its private half. A replacement's `prevSig` is the old key's
    /// signature over the same bytes.
    public static func keySetBytes(_ f: SignedFor, atMs: Int64, pub: Bytes) -> Bytes {
        bytes(keySet, f, atMs: atMs, [.bytes(pub)])
    }

    public static func addBytes(_ f: SignedFor, _ m: AgentAdd) throws -> Bytes {
        try bytes(add, f, atMs: m.atMs, [
            .bytes(m.key), .text(m.role), sortedList(m.scopes), sortedList(m.ops), m.caps.array,
            .int(m.expiresAtMs), .text(m.principal.client), .text(m.principal.clientId), .text(m.principal.ticket),
        ])
    }

    /// `key` is the row's whole key from `agent.list`: an id and an epoch
    /// alone could name another row that took the same id.
    public static func widenBytes(_ f: SignedFor, _ m: AgentWiden, key: Bytes) throws -> Bytes {
        try bytes(widen, f, atMs: m.atMs, [
            .text(m.id), .bytes(key), .unsigned(m.epoch), sortedList(m.scopes), sortedList(m.ops), m.caps.array,
            .int(m.expiresAtMs),
        ])
    }

    /// What approving a request signs: the request, the agent that asked,
    /// the op and the hash of its args as the phone received and showed them.
    public static func confirmBytes(_ f: SignedFor, reqId: String, atMs: Int64, request: AgentRequest) -> Bytes {
        bytes(confirm, f, atMs: atMs, [.text(reqId), .text(request.agent), .text(request.op), .bytes(argsHash(request.args))])
    }

    /// SHA-256 over the deterministic CBOR of a request's args.
    public static func argsHash(_ args: CBOR) -> Bytes {
        Primitives.sha256(encodeDeterministic(args.isNull ? .emptyMap : args))
    }

    static func sortedList(_ list: [String]) throws -> CBOR {
        guard isSortedUnique(list) else { throw Unsorted(list: list) }
        return .array(list.map { .text($0) })
    }

    /// Sorted as Go sorts strings, by their bytes, with no repeats.
    public static func isSortedUnique(_ list: [String]) -> Bool {
        zip(list, list.dropFirst()).allSatisfy { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
    }

    /// Sorted as Go sorts strings, with repeats gone.
    public static func sorted(_ list: some Sequence<String>) -> [String] {
        Array(Set(list)).sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
    }

    /// Whether `sig`, r ‖ s, is `pub`'s ECDSA P-256 signature over SHA-256
    /// of `message`.
    public static func verify(pub: Bytes, message: Bytes, sig: Bytes) -> Bool {
        guard pub.count == pubBytes, sig.count == sigBytes,
              let key = try? P256.Signing.PublicKey(x963Representation: pub),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: sig) else { return false }
        return key.isValidSignature(signature, for: Data(message))
    }
}

/// The box and the phone an approval belongs to: the box's X25519 static
/// key, as in the pairing QR code, and the signing phone's device id on that
/// box. A signature for one box is worth nothing at another.
public struct SignedFor: Equatable, Sendable {
    public var boxKey: Bytes
    public var deviceID: String

    public init(boxKey: Bytes, deviceID: String) {
        self.boxKey = boxKey
        self.deviceID = deviceID
    }
}

/// Something that signs approvals: the phone's Secure Enclave key behind
/// Face ID in the app, a software key in tests. `sign` returns r ‖ s and
/// hashes the bytes itself.
@MainActor
public protocol ApprovalSigner: AnyObject {
    /// SEC1 uncompressed, 65 bytes.
    var publicKey: Bytes { get }
    func sign(_ message: Bytes) throws -> Bytes
}

/// A P-256 key in memory. Tests, previews and the simulated box use it;
/// the app's own key lives in the Secure Enclave.
@MainActor
public final class SoftwareSigner: ApprovalSigner {
    let key: P256.Signing.PrivateKey

    public init(_ key: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) {
        self.key = key
    }

    public convenience init(raw: Bytes) throws {
        self.init(try P256.Signing.PrivateKey(rawRepresentation: raw))
    }

    public var publicKey: Bytes { key.publicKey.x963Representation.byteArray }

    public func sign(_ message: Bytes) throws -> Bytes {
        try key.signature(for: Data(message)).rawRepresentation.byteArray
    }
}

// MARK: - Deterministic CBOR

/// RFC 8949 section 4.2.1, as the box's encoder writes it: every map's keys
/// in the bytewise order of their own encoding, at every depth. The rest of
/// core deterministic encoding (shortest integers and lengths, the shortest
/// float that keeps the value, no indefinite lengths) is how `encodeCBOR`
/// always writes.
public func encodeDeterministic(_ value: CBOR) -> Bytes {
    encodeCBOR(value.deterministic)
}

extension CBOR {
    /// The same value with every map in deterministic order.
    public var deterministic: CBOR {
        switch self {
        case .array(let items):
            return .array(items.map(\.deterministic))
        case .map(let entries):
            let sorted = entries
                .map { (key: encodeCBOR($0.key.deterministic), entry: Entry($0.key.deterministic, $0.value.deterministic)) }
                .sorted { $0.key.lexicographicallyPrecedes($1.key) }
            return .map(sorted.map(\.entry))
        case .tagged(let tag, let inner):
            return .tagged(tag, inner.deterministic)
        default:
            return self
        }
    }
}
