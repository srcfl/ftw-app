import Foundation
@testable import FTWKit

/// A passkey that always answers with the same PRF output, the way one
/// synced passkey answers on every device.
@MainActor
final class FakePasskeys: PasskeyAuthenticator {
    var prf: Bytes?
    var credentialID: String
    var isAvailable = true
    var cancel = false
    var fail = false
    var prfOnlyOnAssert = false
    private(set) var registrations = 0
    private(set) var assertions: [[String]] = []

    init(prf: Bytes? = Bytes(hex: "a0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebf"), credentialID: String = "Y3JlZC0x") {
        self.prf = prf
        self.credentialID = credentialID
    }

    func register(label: String, userHandle: Bytes, excludeCredentialIDs: [String]) async throws -> PasskeyOutcome {
        registrations += 1
        if cancel { throw PasskeyCancelled() }
        if fail { throw Primitives.CryptoFailure(message: "platform failed") }
        if prfOnlyOnAssert { return PasskeyOutcome(credentialID: credentialID, prfOutput: nil, prfEnabled: prf != nil) }
        return PasskeyOutcome(credentialID: credentialID, prfOutput: prf)
    }

    func assert(credentialIDs: [String]) async throws -> PasskeyOutcome {
        assertions.append(credentialIDs)
        if cancel { throw PasskeyCancelled() }
        if fail { throw Primitives.CryptoFailure(message: "platform failed") }
        return PasskeyOutcome(credentialID: credentialID, prfOutput: prf)
    }
}

/// The escrow service's rules, from escrow/src in the web app repository:
/// one length for every request, a signed write whose key is pinned on first
/// use, and a version that must be the immediate successor.
@MainActor
final class FakeEscrowService {
    struct Row {
        var version: UInt32
        var blob: Bytes
        var writeKey: Bytes
    }

    var rows: [String: Row] = [:]
    var offline = false
    private(set) var requests = 0

    var transport: Escrow.Transport {
        { [unowned self] body in try self.handle(body) }
    }

    func handle(_ body: Bytes) throws -> (status: Int, body: Bytes) {
        requests += 1
        if offline { throw URLError(.notConnectedToInternet) }
        guard body.count == Escrow.requestBytes,
              let json = try JSONSerialization.jsonObject(with: Data(body)) as? [String: Any],
              let id = json["id"] as? String else { return (400, []) }
        switch json["op"] as? String {
        case "get":
            guard let row = rows[id] else { return (404, []) }
            let answer: [String: Any] = ["version": row.version, "blob": Data(row.blob).base64EncodedString()]
            return (200, try JSONSerialization.data(withJSONObject: answer).byteArray)
        case "put":
            guard let version = (json["version"] as? NSNumber)?.uint32Value,
                  let blob = (json["blob"] as? String).flatMap({ Data(base64Encoded: $0) })?.byteArray,
                  blob.count == RecoveryBlob.maxBytes || blob.isEmpty,
                  let pub = (json["pub"] as? String).flatMap({ try? Base64url.decode($0) }),
                  let sig = (json["sig"] as? String).flatMap({ try? Base64url.decode($0) }) else { return (400, []) }
            guard Primitives.ed25519Verify(publicKey: pub, signature: sig, message: Escrow.writeMessage(lookupID: id, version: version, blob: blob)) else { return (403, []) }
            if let held = rows[id], held.writeKey != pub { return (403, []) }
            guard version == (rows[id]?.version ?? 0) + 1 else { return (409, []) }
            rows[id] = Row(version: version, blob: blob, writeKey: pub)
            return (200, Array(#"{"version":\#(version)}"#.utf8))
        default:
            return (400, [])
        }
    }
}
