import AuthenticationServices
import CryptoKit
import Foundation
import Shared
import UIKit

/// PasskeyHost for FTW. RP ID app.ftw.energy, PRF salt ftw.prf.v1.vault.
final class IosPasskey: NSObject, PasskeyHost {
    var rpId: String { "app.ftw.energy" }
    var rpName: String { "FTW" }
    var prfSalt: KotlinByteArray { Data("ftw.prf.v1.vault".utf8).kotlinByteArray }

    func enroll(label: String) -> WrappingKey {
        bridge { try await IosPasskey.enroll(label: label) }
    }

    func unlock(label: String) -> WrappingKey {
        bridge { try await IosPasskey.unlock(label: label) }
    }

    @MainActor
    static func enroll(label: String = "FTW") async throws -> WrappingKey {
        try await ceremony(register: true, label: label)
    }

    @MainActor
    static func unlock(label: String = "FTW") async throws -> WrappingKey {
        try await ceremony(register: false, label: label)
    }

    @MainActor
    private static func ceremony(register: Bool, label: String) async throws -> WrappingKey {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: "app.ftw.energy")
        let challenge = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let salt = Data("ftw.prf.v1.vault".utf8)
        let request: ASAuthorizationRequest
        if register {
            let userId = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
            let create = provider.createCredentialRegistrationRequest(
                challenge: challenge,
                name: label,
                userID: userId
            )
            create.userVerificationPreference = .required
            if #available(iOS 18.0, *) {
                create.prf = .inputValues(.init(saltInput1: salt))
            }
            request = create
        } else {
            let get = provider.createCredentialAssertionRequest(challenge: challenge)
            get.userVerificationPreference = .required
            if #available(iOS 18.0, *) {
                get.prf = .inputValues(.init(saltInput1: salt))
            }
            request = get
        }
        let controller = ASAuthorizationController(authorizationRequests: [request])
        let delegate = Delegate()
        controller.delegate = delegate
        controller.presentationContextProvider = delegate
        return try await withCheckedThrowingContinuation { cont in
            delegate.cont = cont
            controller.performRequests()
        }
    }

    private func bridge(_ work: @escaping () async throws -> WrappingKey) -> WrappingKey {
        let slot = Slot()
        Task { @MainActor in
            do {
                slot.value = try await work()
            } catch {
                slot.error = error
            }
            slot.done = true
        }
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline && !slot.done {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        if let value = slot.value { return value }
        let reason = slot.error?.localizedDescription ?? "timed out"
        preconditionFailure("passkey ceremony failed: \(reason)")
    }
}

private final class Slot {
    var value: WrappingKey?
    var error: Error?
    var done = false
}

private final class Delegate: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    var cont: CheckedContinuation<WrappingKey, Error>?

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        var prf: Data?
        var credId = Data()
        if #available(iOS 18.0, *) {
            if let cred = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration {
                credId = cred.credentialID
                prf = cred.prf?.first?.rawData
            }
            if let cred = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion {
                credId = cred.credentialID
                if let out = cred.prf { prf = out.first.rawData }
            }
        } else if let cred = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration {
            credId = cred.credentialID
        } else if let cred = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion {
            credId = cred.credentialID
        }
        let key = prf ?? Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let source: WrappingSource = prf == nil ? .local : .prf
        cont?.resume(
            returning: WrappingKey(
                credentialId: credId.base64EncodedString(),
                source: source,
                key: key.kotlinByteArray
            )
        )
        cont = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        cont?.resume(throwing: error)
        cont = nil
    }
}

private extension SymmetricKey {
    var rawData: Data {
        withUnsafeBytes { Data($0) }
    }
}

private extension Data {
    var kotlinByteArray: KotlinByteArray {
        let arr = KotlinByteArray(size: Int32(count))
        enumerated().forEach { i, b in arr.set(index: Int32(i), value: Int8(bitPattern: b)) }
        return arr
    }
}
