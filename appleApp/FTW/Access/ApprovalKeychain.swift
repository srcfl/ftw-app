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
/// signature sent again with the box's clock, asks once.
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
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw FaceIDMissing()
        }
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
        } catch let e as LAError where [.userCancel, .appCancel, .systemCancel, .userFallback].contains(e.code) {
            throw ApprovalCancelled()
        } catch let e as LAError where [.biometryNotEnrolled, .biometryNotAvailable, .passcodeNotSet].contains(e.code) {
            throw FaceIDMissing()
        }
        return Unlock(store: store, account: Self.account(home), context: context)
    }

    func forget(home: String) {
        store.remove(Self.account(home))
    }

    static func account(_ home: String) -> String { "approval-\(home)" }
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
    let account: String
    let context: LAContext

    init(store: SecureStore, account: String, context: LAContext) {
        self.store = store
        self.account = account
        self.context = context
    }

    func existing() throws -> ApprovalSigner? {
        guard let blob = try store.read(account) else { return nil }
        #if targetEnvironment(simulator)
        return try SoftwareSigner(raw: blob)
        #else
        do {
            return EnclaveSigner(try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: Data(blob), authenticationContext: context))
        } catch {
            // A new Face ID enrolment voids a biometryCurrentSet key.
            throw ApprovalKeyLost()
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
            throw error!.takeRetainedValue() as Error
        }
        return EnclaveSigner(try SecureEnclave.P256.Signing.PrivateKey(accessControl: access, authenticationContext: context))
        #endif
    }

    func keep(_ signer: ApprovalSigner) {
        #if targetEnvironment(simulator)
        if let s = signer as? SoftwareSigner { store.put(account, s.rawKey) }
        #else
        if let s = signer as? EnclaveSigner { store.put(account, s.key.dataRepresentation.byteArray) }
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
            throw ApprovalKeyLost()
        }
    }
}
