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
        let answer = try await perform(request)
        return PasskeyOutcome(credentialID: Base64url.encode(answer.credentialID.byteArray), prfOutput: answer.prf?.byteArray, prfEnabled: answer.prfSupported)
    }

    func assert(credentialIDs: [String]) async throws -> PasskeyOutcome {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: Origin.rpID)
        let request = provider.createCredentialAssertionRequest(challenge: Data(randomBytes(32)))
        request.userVerificationPreference = .required
        request.allowedCredentials = descriptors(credentialIDs)
        request.prf = .inputValues(.init(saltInput1: Data(PRF.vaultSalt)))
        let answer = try await perform(request)
        return PasskeyOutcome(credentialID: Base64url.encode(answer.credentialID.byteArray), prfOutput: answer.prf?.byteArray)
    }

    private func descriptors(_ ids: [String]) -> [ASAuthorizationPlatformPublicKeyCredentialDescriptor] {
        ids.compactMap { try? Base64url.decode($0) }.map { ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: Data($0)) }
    }

    private func perform(_ request: ASAuthorizationRequest) async throws -> CeremonyAnswer {
        // One sheet at a time; a second ask while one is up is the same ask.
        pending?.cancel()
        let ceremony = Ceremony(request)
        pending = ceremony
        defer { if pending === ceremony { pending = nil } }
        return try await ceremony.run()
    }
}

/// The platform answered with a credential of a kind this app never asked for.
private struct UnexpectedCredential: Error {}

/// What a ceremony produced, copied out of the platform's credential on the
/// main actor so only plain values cross back to the caller.
private struct CeremonyAnswer: Sendable {
    let credentialID: Data
    let prf: Data?
    /// At registration: the platform will evaluate PRF on an assertion even
    /// when it gave no output yet.
    let prfSupported: Bool

    init(_ credential: ASAuthorizationCredential) throws {
        if let created = credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration {
            credentialID = created.credentialID
            prf = created.prf?.first.map(Self.data)
            prfSupported = created.prf?.isSupported ?? false
        } else if let asserted = credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion {
            credentialID = asserted.credentialID
            prf = asserted.prf.map { Self.data($0.first) }
            prfSupported = asserted.prf != nil
        } else {
            throw UnexpectedCredential()
        }
    }

    private static func data(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }
}

/// One authorization controller and the continuation it answers.
@MainActor
private final class Ceremony: NSObject {
    private let controller: ASAuthorizationController
    private var continuation: CheckedContinuation<CeremonyAnswer, Error>?

    init(_ request: ASAuthorizationRequest) {
        controller = ASAuthorizationController(authorizationRequests: [request])
        super.init()
        controller.delegate = self
        controller.presentationContextProvider = self
    }

    func run() async throws -> CeremonyAnswer {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    func cancel() {
        controller.cancel()
    }

    fileprivate func finish(_ result: Result<CeremonyAnswer, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

extension Ceremony: ASAuthorizationControllerDelegate {
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        finish(Result { try CeremonyAnswer(authorization.credential) })
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

extension Ceremony: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        #if os(iOS)
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first ?? ASPresentationAnchor()
        #else
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #endif
    }
}
