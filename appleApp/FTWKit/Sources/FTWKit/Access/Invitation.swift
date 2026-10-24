import CryptoKit
import Foundation
import Observation

public enum InvitationWire {
    public static let create = "agent.invite.create"
    public static let list = "agent.invite.list"
    public static let cancel = "agent.invite.cancel"

    public static func hash(home: String, secret: Bytes) -> Bytes {
        Primitives.sha256(Bytes("ftw.agent.invite.v1\0".utf8) + Bytes(home.utf8) + [0] + secret)
    }

    public static func code(home: String, box: Bytes, secret: Bytes) -> String {
        Base64url.encode(
            encodeDeterministic(
                .map([
                    ("v", .unsigned(1)), ("home", .text(home)), ("box", .bytes(box)),
                    ("secret", .bytes(secret)),
                ])))
    }
}

public struct InvitationCreate: Equatable, Sendable {
    public var id, home, label: String
    public var hash: Bytes
    public var grant: Grant
    public var claimUntilMs, expiresAtMs, atMs: Int64
    public var sig: Bytes = []

    public init(
        id: String, home: String, label: String, hash: Bytes, grant: Grant, claimUntilMs: Int64,
        expiresAtMs: Int64, atMs: Int64
    ) {
        self.id = id
        self.home = home
        self.label = label
        self.hash = hash
        self.grant = grant
        self.claimUntilMs = claimUntilMs
        self.expiresAtMs = expiresAtMs
        self.atMs = atMs
    }

    public init?(_ c: CBOR) {
        guard let id = c["id"]?.string, let home = c["home"]?.string, let hash = c["hash"]?.byteString,
            let claim = c["claimUntilMs"]?.int64, let end = c["expiresAtMs"]?.int64,
            let at = c["atMs"]?.int64
        else { return nil }
        self.init(
            id: id, home: home, label: c["label"]?.string ?? "", hash: hash,
            grant: Grant(
                scopes: c["scopes"]?.stringArray ?? [], ops: c["ops"]?.stringArray ?? [],
                caps: Caps(c["caps"]), lengthMs: end - at), claimUntilMs: claim, expiresAtMs: end, atMs: at)
        sig = c["sig"]?.byteString ?? []
    }

    public func signedBytes(_ f: SignedFor) throws -> Bytes {
        try Approval.bytes(
            InvitationWire.create, f, atMs: atMs,
            [
                .text(home), .text(id), .bytes(hash), .text(label),
                Approval.sortedList(grant.scopes), Approval.sortedList(grant.ops), grant.caps.array,
                .int(claimUntilMs), .int(expiresAtMs),
            ])
    }

    public var cbor: CBOR {
        .map([
            ("id", .text(id)), ("home", .text(home)), ("hash", .bytes(hash)), ("label", .text(label)),
            ("scopes", .array(grant.scopes.map { .text($0) })),
            ("ops", .array(grant.ops.map { .text($0) })), ("caps", grant.caps.cbor),
            ("claimUntilMs", .int(claimUntilMs)), ("expiresAtMs", .int(expiresAtMs)),
            ("atMs", .int(atMs)), ("sig", .bytes(sig)),
        ]).deterministic
    }
}

public struct AgentInvitation: Identifiable, Equatable, Sendable {
    public let id, home, label, state, agentID, client: String
    public let box: Bytes
    public let scopes, ops: [String]
    public let claimUntilMs, expiresAtMs: Int64
    public let clockUnavailable: Bool

    public init?(_ c: CBOR) {
        guard let id = c["id"]?.string, let home = c["home"]?.string, let box = c["box"]?.byteString,
            box.count == 32,
            let state = c["state"]?.string, let claim = c["claimUntilMs"]?.int64,
            let end = c["expiresAtMs"]?.int64
        else { return nil }
        self.id = id
        self.home = home
        self.box = box
        self.state = state
        self.claimUntilMs = claim
        self.expiresAtMs = end
        label = c["label"]?.string ?? ""
        agentID = c["agentId"]?.string ?? ""
        client = c["client"]?.string ?? ""
        scopes = c["scopes"]?.stringArray ?? []
        ops = c["ops"]?.stringArray ?? []
        clockUnavailable = c["clockUnavailable"]?.bool ?? false
    }
}

// Only memory holds the code and the exact signed request. A lost reply
// never makes a new timestamp, id, signature or secret behind the owner's back.
@Observable @MainActor
public final class InvitationDraft {
    public let secret: Bytes
    public let id: String
    public var request: InvitationCreate?
    public var receipt: AgentInvitation?
    public var alias: InvitationAlias?
    public init(secret: Bytes? = nil, id: String? = nil) {
        self.secret = secret ?? SymmetricKey(size: .bits256).withUnsafeBytes { Bytes($0) }
        self.id = id ?? Base64url.encode(SymmetricKey(size: .bits128).withUnsafeBytes { Bytes($0) })
    }
    public var code: String? {
        guard let receipt, receipt.state == "pending" else { return nil }
        return alias?.code
    }
}
