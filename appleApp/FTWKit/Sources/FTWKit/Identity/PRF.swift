import Foundation

/// The passkey as a key derivation function.
///
/// There is no account and nothing verifies an assertion. The credential
/// exists because the PRF extension hands back a secret only after the user
/// verifies, and that secret is turned into keys here, the same way the web
/// app turns it into keys. Same RP ID, same salt, same HKDF: a passkey that
/// sealed a recovery copy in the web app opens it in this app, and the
/// reverse.
public enum PRF {
    /// One fixed salt per purpose, forever. The authenticator is only ever
    /// asked for the vault salt; the escrow salt is an HKDF salt.
    public static let vaultSalt = Array("ftw.prf.v1.vault".utf8)
    public static let escrowSalt = Array("ftw.prf.v1.escrow".utf8)

    static let wrapInfo = Array("ftw.wrap.v1".utf8)
    static let escrowIDInfo = Array("ftw.escrow.id.v1".utf8)
    static let escrowKeyInfo = Array("ftw.escrow.key.v1".utf8)
    static let escrowWriteInfo = Array("ftw.escrow.write.v1".utf8)

    /// The AES-256-GCM key that wraps the device key, from one PRF output.
    public static func wrappingKey(credentialID: String, prfOutput: Bytes) -> WrappingKey {
        WrappingKey(
            credentialID: credentialID,
            source: .prf,
            key: Primitives.hkdf(ikm: prfOutput, salt: vaultSalt, info: wrapInfo, length: 32),
            escrow: EscrowKeys(prfOutput: prfOutput)
        )
    }
}

/// Where a wrapping key came from. The UI states this; it never hides it.
public enum WrappingSource: String, Codable, Sendable {
    case prf
    case local
}

public struct WrappingKey: Sendable {
    /// base64url credential id, or `Vault.localCredentialID`.
    public let credentialID: String
    public let source: WrappingSource
    /// 32 bytes of AES-256-GCM key.
    let key: Bytes
    /// Present only where PRF is. The local key derives nothing that may
    /// leave this device.
    public let escrow: EscrowKeys?
}

/// What the escrow needs, as HKDF siblings of the vault key: the id says
/// nothing about the key, and neither can be produced from the other.
public struct EscrowKeys: Sendable {
    /// base64url of 32 bytes. The only name the service ever learns.
    public let lookupID: String
    let sealKey: Bytes
    /// Ed25519 public key the service pins on first write.
    public let writeKey: Bytes
    private let writeSeed: Bytes

    init(prfOutput: Bytes) {
        let salt = PRF.escrowSalt
        lookupID = Base64url.encode(Primitives.hkdf(ikm: prfOutput, salt: salt, info: PRF.escrowIDInfo, length: 32))
        sealKey = Primitives.hkdf(ikm: prfOutput, salt: salt, info: PRF.escrowKeyInfo, length: 32)
        writeSeed = Primitives.hkdf(ikm: prfOutput, salt: salt, info: PRF.escrowWriteInfo, length: 32)
        // A 32-byte seed is always a valid Ed25519 key.
        writeKey = (try? Primitives.ed25519PublicKey(seed: writeSeed)) ?? []
    }

    func sign(_ message: Bytes) throws -> Bytes {
        try Primitives.ed25519Sign(seed: writeSeed, message: message)
    }
}

/// The platform side of a passkey ceremony, injected so this package never
/// touches AuthenticationServices.
@MainActor
public protocol PasskeyAuthenticator: AnyObject {
    /// Register a new passkey and ask for PRF. `prfOutput` is nil when the
    /// platform registered the passkey but gave no PRF.
    func register(label: String, userHandle: Bytes, excludeCredentialIDs: [String]) async throws -> PasskeyOutcome
    /// Assert with PRF. An empty list means any discoverable credential for
    /// the RP, which is what a fresh install recovering its home needs.
    func assert(credentialIDs: [String]) async throws -> PasskeyOutcome
    /// Whether this device can run a ceremony at all.
    var isAvailable: Bool { get }
}

public struct PasskeyOutcome: Sendable {
    public let credentialID: String
    public let prfOutput: Bytes?
    /// At registration: the platform says PRF is supported even though it
    /// gave no output yet, so an assertion will produce one.
    public let prfEnabled: Bool

    public init(credentialID: String, prfOutput: Bytes?, prfEnabled: Bool = false) {
        self.credentialID = credentialID
        self.prfOutput = prfOutput
        self.prfEnabled = prfEnabled
    }
}

/// The person dismissed the sheet. A decline is an answer, not a fault, and
/// the two need different sentences.
public struct PasskeyCancelled: Error, Equatable {
    public init() {}
}
