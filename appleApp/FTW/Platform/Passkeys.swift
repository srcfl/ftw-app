import AuthenticationServices
import CryptoKit
import FTWKit
import Foundation

/// The passkey ceremony, with PRF, against the web app's relying party. The
/// same passkey and the same salt give the same PRF output on the web and
/// here, which is what lets one passkey open a home in both apps.
@MainActor
final class Passkeys: PasskeyAuthenticator {
    private var pending: Ceremony?

    var isAvailable: Bool { true }

    func register(label: String, userHandle: Bytes, excludeCredentialIDs: [String]) async throws -> PasskeyOutcome {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: Origin.rpID)
        let request = provider.createCredentialRegistrationRequest(challenge: Data(randomBytes(32)), name: label, userID: Data(userHandle))
        request.userVerificationPreference = .required
        request.excludedCredentials = descriptors(excludeCredentialIDs)
        request.prf = .inputValues(.init(saltInput1: Data(PRF.vaultSalt)))
        let credential = try await perform(request)
        guard let created = credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration else {
            throw UnexpectedCredential()
        }
        return PasskeyOutcome(
            credentialID: Base64url.encode(created.credentialID.byteArray),
            prfOutput: created.prf?.first.map(bytes),
            prfEnabled: created.prf?.isSupported ?? false
        )
    }

    func assert(credentialIDs: [String]) async throws -> PasskeyOutcome {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: Origin.rpID)
        let request = provider.createCredentialAssertionRequest(challenge: Data(randomBytes(32)))
        request.userVerificationPreference = .required
        request.allowedCredentials = descriptors(credentialIDs)
        request.prf = .inputValues(.init(saltInput1: Data(PRF.vaultSalt)))
        let credential = try await perform(request)
        guard let asserted = credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
            throw UnexpectedCredential()
        }
        return PasskeyOutcome(
            credentialID: Base64url.encode(asserted.credentialID.byteArray),
            prfOutput: asserted.prf.map { bytes($0.first) }
        )
    }

    private func descriptors(_ ids: [String]) -> [ASAuthorizationPlatformPublicKeyCredentialDescriptor] {
        ids.compactMap { try? Base64url.decode($0) }.map { ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: Data($0)) }
    }

    private func bytes(_ key: SymmetricKey) -> Bytes {
        key.withUnsafeBytes { Bytes($0) }
    }

    private func perform(_ request: ASAuthorizationRequest) async throws -> ASAuthorizationCredential {
        // One sheet at a time; a second ask while one is up is the same ask.
        pending?.cancel()
        let ceremony = Ceremony(request)
        pending = ceremony
        defer { if pending === ceremony { pending = nil } }
        return try await ceremony.run()
    }
}

/// The platform answered with a credential of the other ceremony's kind.
private struct UnexpectedCredential: Error {}

/// One authorization controller and the continuation it answers.
@MainActor
private final class Ceremony: NSObject {
    private let controller: ASAuthorizationController
    private var continuation: CheckedContinuation<ASAuthorizationCredential, Error>?

    init(_ request: ASAuthorizationRequest) {
        controller = ASAuthorizationController(authorizationRequests: [request])
        super.init()
        controller.delegate = self
        controller.presentationContextProvider = self
    }

    func run() async throws -> ASAuthorizationCredential {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    func cancel() {
        controller.cancel()
    }

    fileprivate func finish(_ result: Result<ASAuthorizationCredential, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

extension Ceremony: @preconcurrency ASAuthorizationControllerDelegate {
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        finish(.success(authorization.credential))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        // A dismissed sheet is an answer, not a fault, and gets its own type.
        if let e = error as? ASAuthorizationError, e.code == .canceled {
            finish(.failure(PasskeyCancelled()))
        } else {
            finish(.failure(error))
        }
    }
}

extension Ceremony: @preconcurrency ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        #if os(iOS)
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first ?? ASPresentationAnchor()
        #else
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #endif
    }
}
