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
