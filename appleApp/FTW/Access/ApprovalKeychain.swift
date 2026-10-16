import CryptoKit
import FTWKit
import LocalAuthentication
import Security

/// This phone's approval keys (docs/agents.md in srcfl/ftw, The approval
/// signature): one P-256 key per home in the Secure Enclave, usable only
/// after Face ID with the current enrolment. The key never leaves the
/// enclave; the Keychain keeps the enclave's wrapped handle to it, which
/// no other device can use.
///
/// One Face ID covers one approval: the context it evaluated signs every
/// message of it, so a first grant that also registers the key, or a
/// signature sent again with the box's clock, asks once. The context is
/// invalidated when the approval ends.
///
/// A replacement waits in a second slot until the box is known to hold it,
/// so neither key is stranded by an answer that never came.
///
/// The simulator has no Secure Enclave. There the key is a software key in
/// the Keychain, behind the same Face ID, which the simulator's Features
/// menu can match: enough to try the flow, never to ship.
@MainActor
final class ApprovalKeychain: ApprovalKeyring {
    private let store: SecureStore

    init(store: SecureStore) {
        self.store = store
    }

    func unlock(home: String, reason: String) async throws -> ApprovalUnlock {
        let context = LAContext()
        context.localizedCancelTitle = AccessWords.text("Cancel")
        var error: NSError?
        if !context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            throw Self.meaning(error ?? NSError(domain: LAError.errorDomain, code: LAError.biometryNotAvailable.rawValue))
        }
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
        } catch {
            throw Self.meaning(error)
        }
        return Unlock(store: store, home: home, context: context)
    }

    func forget(home: String) {
        store.remove(Self.account(home))
        store.remove(Self.pendingAccount(home))
    }

    static func account(_ home: String) -> String { "approval-\(home)" }
    static func pendingAccount(_ home: String) -> String { "approval-next-\(home)" }

    /// What an error from Face ID, the Keychain or the enclave means for the
    /// owner. Only a key the system no longer accepts is a lost key: a
    /// cancel is a cancel, a lockout a lockout.
    static func meaning(_ error: Error) -> Error {
        let ns = error as NSError
        if ns.domain == LAError.errorDomain {
            switch LAError.Code(rawValue: ns.code) {
            case .userCancel, .appCancel, .systemCancel, .userFallback, .notInteractive: return ApprovalCancelled()
            case .biometryLockout: return ApprovalLocked()
            case .biometryNotEnrolled, .biometryNotAvailable, .passcodeNotSet: return FaceIDMissing()
            default: return ApprovalSigningFailed()
            }
        }
        if ns.domain == NSOSStatusErrorDomain {
            switch OSStatus(ns.code) {
            case errSecUserCanceled: return ApprovalCancelled()
            // The enclave no longer takes the key: Face ID was enrolled
            // again, so the biometryCurrentSet key is void.
            case errSecAuthFailed, errSecItemNotFound, errSecInvalidKeyRef: return ApprovalKeyLost()
            default: return ApprovalSigningFailed()
            }
        }
        return ApprovalSigningFailed()
    }
}

/// Approving from this phone needs Face ID (or Touch ID) set up.
struct FaceIDMissing: HelpfulError {
    var help: String { AccessWords.format("Set up %@ on this phone to approve from it, or approve on your box's page.", AccessWords.biometry) }
}

/// What this phone unlocks with, for the words and the symbol.
@MainActor
enum Biometry {
    static let touchID: Bool = {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType == .touchID
    }()

    static var symbol: String { touchID ? "touchid" : "faceid" }

    /// Once at launch, so every sentence names the right one.
    static func name() {
        AccessWords.biometry = touchID ? "Touch ID" : "Face ID"
    }
}

@MainActor
private final class Unlock: ApprovalUnlock {
    let store: SecureStore
    let home: String
    let context: LAContext

    init(store: SecureStore, home: String, context: LAContext) {
        self.store = store
        self.home = home
        self.context = context
    }

    func existing() throws -> ApprovalSigner? {
        try signer(ApprovalKeychain.account(home))
    }

    func pending() throws -> ApprovalSigner? {
        try signer(ApprovalKeychain.pendingAccount(home))
    }

    private func signer(_ account: String) throws -> ApprovalSigner? {
        guard let blob = try store.read(account) else { return nil }
        #if targetEnvironment(simulator)
        return try SoftwareSigner(raw: blob)
        #else
        do {
            return EnclaveSigner(try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: Data(blob), authenticationContext: context))
        } catch {
            throw ApprovalKeychain.meaning(error)
        }
        #endif
    }

    func make() throws -> ApprovalSigner {
        #if targetEnvironment(simulator)
        return SoftwareSigner()
        #else
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet], &error
        ) else {
            throw ApprovalSigningFailed()
        }
        do {
            return EnclaveSigner(try SecureEnclave.P256.Signing.PrivateKey(accessControl: access, authenticationContext: context))
        } catch {
            throw ApprovalKeychain.meaning(error)
        }
        #endif
    }

    func keep(_ signer: ApprovalSigner) throws {
        try store.write(ApprovalKeychain.account(home), blob(signer))
    }

    func keepPending(_ signer: ApprovalSigner) throws {
        try store.write(ApprovalKeychain.pendingAccount(home), blob(signer))
    }

    func promote() throws {
        guard let next = try store.read(ApprovalKeychain.pendingAccount(home)) else { return }
        try store.write(ApprovalKeychain.account(home), next)
        store.remove(ApprovalKeychain.pendingAccount(home))
    }

    func dropPending() {
        store.remove(ApprovalKeychain.pendingAccount(home))
    }

    func end() {
        context.invalidate()
    }

    private func blob(_ signer: ApprovalSigner) throws -> Bytes {
        #if targetEnvironment(simulator)
        guard let s = signer as? SoftwareSigner else { throw ApprovalKeyNotKept() }
        return s.rawKey
        #else
        guard let s = signer as? EnclaveSigner else { throw ApprovalKeyNotKept() }
        return s.key.dataRepresentation.byteArray
        #endif
    }
}

/// A Secure Enclave key, signing under the context Face ID evaluated.
@MainActor
private final class EnclaveSigner: ApprovalSigner {
    let key: SecureEnclave.P256.Signing.PrivateKey

    init(_ key: SecureEnclave.P256.Signing.PrivateKey) {
        self.key = key
    }

    var publicKey: Bytes { key.publicKey.x963Representation.byteArray }

    func sign(_ message: Bytes) throws -> Bytes {
        do {
            return try key.signature(for: Data(message)).rawRepresentation.byteArray
        } catch {
            throw ApprovalKeychain.meaning(error)
        }
    }
}
