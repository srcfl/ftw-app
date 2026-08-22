import AuthenticationServices
import Foundation
import Shared

/// Platform passkey ceremony. RP ID is app.ftw.energy; PRF salt is ftw.prf.v1.vault.
/// The Kotlin vault consumes the wrapping key this produces.
enum FtwPasskey {
    static let rpId = "app.ftw.energy"
    static let prfSalt = "ftw.prf.v1.vault".data(using: .utf8)!

    @MainActor
    static func enroll(label: String = "FTW") async throws -> WrappingKey {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpId)
        let challenge = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let userId = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let request = provider.createCredentialRegistrationRequest(
            challenge: challenge,
            name: label,
            userID: userId
        )
        request.userVerificationPreference = .required
        if #available(iOS 18.0, *) {
            request.prf = .inputValues(
                ASAuthorizationPublicKeyCredentialPRFRegistrationInput.InputValues(saltInput1: prfSalt)
            )
        }
        let controller = ASAuthorizationController(authorizationRequests: [request])
        let delegate = Delegate()
        controller.delegate = delegate
        return try await withCheckedThrowingContinuation { cont in
            delegate.cont = cont
            controller.performRequests()
        }
    }
}

private final class Delegate: NSObject, ASAuthorizationControllerDelegate {
    var cont: CheckedContinuation<WrappingKey, Error>?

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        var prf: Data?
        if #available(iOS 18.0, *),
           let cred = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration,
           let out = cred.prf?.first {
            prf = out
        }
        let id = (authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration)?.credentialID
            ?? Data()
        let key = prf ?? Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let source: WrappingSource = prf == nil ? .local : .prf
        cont?.resume(returning: WrappingKey(credentialId: id.base64EncodedString(), source: source, key: KotlinByteArray.from(data: key)))
        cont = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        cont?.resume(throwing: error)
        cont = nil
    }
}

private extension KotlinByteArray {
    static func from(data: Data) -> KotlinByteArray {
        let arr = KotlinByteArray(size: Int32(data.count))
        data.enumerated().forEach { i, b in arr.set(index: Int32(i), value: Int8(bitPattern: b)) }
        return arr
    }
}
