import Foundation

/// The passkey as a key derivation function.
///
/// There is no account and nothing verifies an assertion. The credential
/// exists because the PRF extension hands back a secret only after the user
/// verifies, and that secret is turned into keys here, the same way the web
/// app turns it into keys. Same RP ID, same salt, same HKDF: a passkey that
/// wraps a device key in the web app unwraps it in this app, and the
/// reverse.
public enum PRF {
    /// One fixed salt, forever. The authenticator is only ever asked for it.
    public static let vaultSalt = Array("ftw.prf.v1.vault".utf8)

    static let wrapInfo = Array("ftw.wrap.v1".utf8)

    /// The AES-256-GCM key that wraps the device key, from one PRF output.
    public static func wrappingKey(credentialID: String, prfOutput: Bytes) -> WrappingKey {
        WrappingKey(
            credentialID: credentialID,
            source: .prf,
            key: Primitives.hkdf(ikm: prfOutput, salt: vaultSalt, info: wrapInfo, length: 32)
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
