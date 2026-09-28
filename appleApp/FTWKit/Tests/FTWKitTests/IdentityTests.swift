import Foundation
import Testing
@testable import FTWKit

/// Vectors produced by running the web app's own identity code
/// (src/lib/identity and src/lib/carrier/rendezvous in srcfl/ftw-webapp).
struct IdentityVectors: Decodable {
    struct Handle: Decodable { let epoch: Int64; let handle: String }
    struct Rendezvous: Decodable { let secret: String; let handles: [Handle] }
    struct PRFVector: Decodable {
        let output: String
        let credentialId: String
        let lookupId: String
        let writeKey: String
        let signedMessage: String
        let signature: String
    }
    struct Home: Decodable { let siteId: String; let label: String; let boxStaticKey: String; let rendezvousSecret: String }
    struct Blob: Decodable { let escrowVersion: UInt32; let sealed: String; let deviceScalar: String; let homes: [Home] }
    struct VaultCopy: Decodable { let publicKey: String; let iv: String; let ct: String; let scalar: String }
    struct EnrollmentVector: Decodable {
        let url: String
        let boxStaticPublic: String
        let pairingCode: String
        let lanHint: String
        let rendezvousSecret: String
        let siteId: String
        let fingerprint: String
        let deviceIdOnBox: String
    }

    let rendezvous: Rendezvous
    let prf: PRFVector
    let recoveryBlob: Blob
    let vaultCopy: VaultCopy
    let enrollment: EnrollmentVector

    static func load() throws -> IdentityVectors {
        guard let url = Bundle.module.url(forResource: "identity-vectors", withExtension: "json", subdirectory: "Resources") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(IdentityVectors.self, from: Data(contentsOf: url))
    }
}

@Suite struct CrossImplementationTests {
    @Test func rendezvousHandlesMatchTheWebApp() throws {
        let v = try IdentityVectors.load()
        for h in v.rendezvous.handles {
            #expect(try Rendezvous.handle(secret: Bytes(hex: v.rendezvous.secret), epoch: h.epoch) == h.handle)
        }
        #expect(Rendezvous.epoch(nowMs: 0) == 0)
        #expect(Rendezvous.epoch(nowMs: Rendezvous.epochMs - 1) == 0)
        #expect(Rendezvous.epoch(nowMs: Rendezvous.epochMs) == 1)
    }

    @Test func passkeyDerivationsMatchTheWebApp() throws {
        let v = try IdentityVectors.load()
        let wrapping = PRF.wrappingKey(credentialID: v.prf.credentialId, prfOutput: Bytes(hex: v.prf.output))
        let keys = try #require(wrapping.escrow)
        #expect(keys.lookupID == v.prf.lookupId)
        #expect(keys.writeKey.hex == v.prf.writeKey)
        // The web app's signature verifies under the key derived here.
        #expect(Primitives.ed25519Verify(publicKey: keys.writeKey, signature: Bytes(hex: v.prf.signature), message: Bytes(hex: v.prf.signedMessage)))
        // And the signature made here verifies under the web app's key.
        let mine = try keys.sign(Bytes(hex: v.prf.signedMessage))
        #expect(Primitives.ed25519Verify(publicKey: Bytes(hex: v.prf.writeKey), signature: mine, message: Bytes(hex: v.prf.signedMessage)))
    }

    @Test func aRecoveryCopyTheWebAppSealedOpensHere() throws {
        let v = try IdentityVectors.load()
        let keys = try #require(PRF.wrappingKey(credentialID: v.prf.credentialId, prfOutput: Bytes(hex: v.prf.output)).escrow)
        let sealed = Bytes(hex: v.recoveryBlob.sealed)
        #expect(sealed.count == RecoveryBlob.maxBytes)
        let contents = try RecoveryBlob.open(key: keys.sealKey, sealed, escrowVersion: v.recoveryBlob.escrowVersion)
        #expect(contents.deviceScalar.hex == v.recoveryBlob.deviceScalar)
        #expect(contents.homes.map(\.siteId) == v.recoveryBlob.homes.map(\.siteId))
        #expect(contents.homes.map(\.label) == v.recoveryBlob.homes.map(\.label))
        #expect(contents.homes.map { $0.boxStaticKey.hex } == v.recoveryBlob.homes.map(\.boxStaticKey))
        #expect(contents.homes.map { $0.rendezvousSecret.hex } == v.recoveryBlob.homes.map(\.rendezvousSecret))

        // The version is bound in: the same bytes under another number fail.
        #expect(throws: RecoveryBlob.BlobError.self) {
            _ = try RecoveryBlob.open(key: keys.sealKey, sealed, escrowVersion: v.recoveryBlob.escrowVersion + 1)
        }
    }

    @Test func aVaultCopyTheWebAppSealedOpensUnderTheSamePasskey() throws {
        let v = try IdentityVectors.load()
        let wrapping = PRF.wrappingKey(credentialID: v.prf.credentialId, prfOutput: Bytes(hex: v.prf.output))
        let plain = try Primitives.aesGCMOpen(key: wrapping.key, nonce: Bytes(hex: v.vaultCopy.iv), ciphertext: Bytes(hex: v.vaultCopy.ct))
        #expect(plain == Vault.pkcs8Prefix + Bytes(hex: v.vaultCopy.scalar))
    }

    @Test func pairingURLAndNamesMatchTheWebApp() throws {
        let v = try IdentityVectors.load()
        let e = try Enrollment.parse(scanned: v.enrollment.url)
        #expect(e.boxStaticPublic.hex == v.enrollment.boxStaticPublic)
        #expect(e.pairingCode.hex == v.enrollment.pairingCode)
        #expect(e.lanHint == v.enrollment.lanHint)
        #expect(e.rendezvousSecret.hex == v.enrollment.rendezvousSecret)
        #expect(e.url() == v.enrollment.url)
        #expect(SiteList.siteID(e.boxStaticPublic) == v.enrollment.siteId)
        #expect(SiteList.fingerprint(e.boxStaticPublic) == v.enrollment.fingerprint)
        let pub = Bytes(hex: v.vaultCopy.publicKey)
        #expect(String(Base64url.encode(pub).prefix(8)) == v.enrollment.deviceIdOnBox)
    }
}

@Suite struct EnrollmentTests {
    let good = Enrollment(boxStaticPublic: Bytes(repeating: 1, count: 32), pairingCode: Bytes(repeating: 2, count: 16), lanHint: "10.0.0.2:8080", rendezvousSecret: Bytes(repeating: 3, count: 32))

    @Test func acceptsAURLAndABareFragment() throws {
        let url = good.url()
        #expect(try Enrollment.parse(scanned: url) == good)
        #expect(try Enrollment.parse(scanned: "  " + url + "\n") == good)
        let fragment = String(url[url.firstIndex(of: "#")!...])
        #expect(try Enrollment.parse(scanned: fragment) == good)
    }

    @Test func refusesAnotherHostOrPath() {
        let url = good.url()
        for bad in [url.replacingOccurrences(of: "app.ftw.energy", with: "app.ftw.energy.evil.example"),
                    url.replacingOccurrences(of: "https://", with: "http://"),
                    url.replacingOccurrences(of: "/p#", with: "/q#"),
                    "https://example.com/p" + url[url.firstIndex(of: "#")!...]] {
            #expect(throws: EnrollmentError.self) { _ = try Enrollment.parse(scanned: bad) }
        }
    }

    @Test func versionErrorsNameTheSideThatIsBehind() {
        let url = good.url()
        do {
            _ = try Enrollment.parse(scanned: url.replacingOccurrences(of: "#v2.", with: "#v1."))
            Issue.record("v1 parsed")
        } catch let e as EnrollmentError {
            #expect(e.code == "E_QR_VERSION")
            #expect(e.help.contains("box needs a software update"))
        } catch { Issue.record("\(error)") }
        do {
            _ = try Enrollment.parse(scanned: url.replacingOccurrences(of: "#v2.", with: "#v3."))
            Issue.record("v3 parsed")
        } catch let e as EnrollmentError {
            #expect(e.help.contains("newer version of the app"))
        } catch { Issue.record("\(error)") }
    }

    @Test func refusesNonCanonicalBase64AndWrongLengths() {
        var short = good
        short.rendezvousSecret = Bytes(repeating: 3, count: 16)
        #expect(throws: EnrollmentError.self) { _ = try Enrollment.parse(scanned: short.url()) }
        // A final character with bits set past the last byte.
        #expect(throws: Base64url.DecodeError.self) { _ = try Base64url.decode("AB") }
        #expect((try? Base64url.decode("AA")) == [0])
    }
}

@Suite struct BoxCodeTests {
    // Produced by the box's Go encoder, as the web app's suite pins them.
    let vectors = [
        ("0000000000", "0000-0000"),
        ("ffffffffff", "ZZZZ-ZZZZ"),
        ("0000000001", "0000-0001"),
        ("0123456789", "04HM-ASW9"),
        ("deadbeef42", "VTPV-XVT2"),
        ("8f1c00a57b", "HWE0-19BV"),
        ("1084210842", "2222-2222"),
    ]

    @Test func decodesWhatTheBoxDrew() throws {
        for (hex, code) in vectors {
            #expect(try BoxCode.decode(code).hex == hex, "\(code)")
        }
    }

    @Test func foldsWhatListenersMishear() throws {
        #expect(try BoxCode.decode("IO1L-0000").hex == "0802100000")
        #expect(try BoxCode.decode("l0i1-oooo").hex == "0802100000")
        for typed in ["04hm-asw9", "04HMASW9", "04 HM AS W9", " 04hm asw9 ", "04HM\tASW9"] {
            #expect(try BoxCode.decode(typed).hex == "0123456789")
        }
        #expect(BoxCode.fold("04hm-asw9") == "04HMASW9")
        #expect(BoxCode.fold("04HMASW9ZZZZ") == "04HMASW9")
        #expect(BoxCode.group("04HMASW9") == "04HM-ASW9")
    }

    @Test func refusesWhatIsNotACode() {
        #expect(throws: BoxCode.BoxCodeError.self) { _ = try BoxCode.decode("UUUU-UUUU") }
        #expect(throws: BoxCode.BoxCodeError.self) { _ = try BoxCode.decode("04HM-ASW") }
        #expect(throws: BoxCode.BoxCodeError.self) { _ = try BoxCode.decode("04HM!ASW9") }
    }
}

@MainActor
@Suite struct VaultTests {
    @Test func enrollingMakesAPasskeyCopyAndALocalOne() async throws {
        let store = MemoryStore()
        let vault = Vault(store: store)
        let passkeys = FakePasskeys()
        let wrapping = try await vault.enrollWrappingKey(passkeys)
        #expect(wrapping.source == .prf)
        let pair = try vault.deviceKey(wrapping)
        try vault.ensureLocalCopy(wrapping)
        #expect(vault.credentialIDs.sorted() == ["Y3JlZC0x", "local"])
        #expect(vault.passkeyCredentialIDs == ["Y3JlZC0x"])

        // Reading needs no prompt at all.
        let silent = try #require(try vault.silentWrappingKey())
        #expect(try vault.deviceKey(silent).publicKey == pair.publicKey)
        #expect(vault.devicePublic == pair.publicKey)
    }

    @Test func aDeclineIsRethrownAndAFailureFallsBack() async throws {
        let vault = Vault(store: MemoryStore())
        let passkeys = FakePasskeys()
        passkeys.cancel = true
        await #expect(throws: PasskeyCancelled.self) { _ = try await vault.enrollWrappingKey(passkeys) }
        passkeys.cancel = false
        passkeys.fail = true
        #expect(try await vault.enrollWrappingKey(passkeys).source == .local)
    }

    @Test func prfThatArrivesOnlyOnAssertionCostsOneMorePrompt() async throws {
        let vault = Vault(store: MemoryStore())
        let passkeys = FakePasskeys()
        passkeys.prfOnlyOnAssert = true
        let wrapping = try await vault.enrollWrappingKey(passkeys)
        #expect(wrapping.source == .prf)
        #expect(passkeys.assertions == [["Y3JlZC0x"]])
    }

    @Test func restoreRefusesToOverwriteAnotherIdentity() async throws {
        let vault = Vault(store: MemoryStore())
        let local = vault.localWrappingKey()
        _ = try vault.deviceKey(local)
        #expect(throws: Vault.VaultError.self) { try vault.restoreDeviceKey(local, scalar: randomBytes(32)) }
    }

    @Test func theLastCopyCannotBeRemoved() throws {
        let vault = Vault(store: MemoryStore())
        _ = try vault.deviceKey(vault.localWrappingKey())
        #expect(throws: Vault.VaultError.self) { try vault.removeCredential(Vault.localCredentialID) }
    }

    @Test func stepUpNeverClaimsACeremonyThatDidNotHappen() async throws {
        let vault = Vault(store: MemoryStore())
        let passkeys = FakePasskeys()
        // Only a local copy: nothing to prompt with.
        _ = try vault.deviceKey(vault.localWrappingKey())
        #expect(await vault.stepUp(passkeys) == .unavailable)

        let other = Vault(store: MemoryStore())
        let wrapping = try await other.enrollWrappingKey(passkeys)
        _ = try other.deviceKey(wrapping)
        #expect(await other.stepUp(passkeys) == .done)
        passkeys.cancel = true
        #expect(await other.stepUp(passkeys) == .declined)
        passkeys.cancel = false
        passkeys.fail = true
        #expect(await other.stepUp(passkeys) == .unavailable)
    }
}

@MainActor
@Suite struct EscrowTests {
    func setUp() -> (Vault, SiteList, FakeEscrowService, Escrow, FakePasskeys) {
        let store = MemoryStore()
        let vault = Vault(store: store)
        let sites = SiteList(store: store)
        let service = FakeEscrowService()
        return (vault, sites, service, Escrow(vault: vault, sites: sites, transport: service.transport), FakePasskeys())
    }

    @Test func requestsArePaddedToOneLength() throws {
        let body = Escrow.padded([("op", .string("get")), ("id", .string("abc"))])
        #expect(body.count == 1024)
        let json = try JSONSerialization.jsonObject(with: Data(body)) as? [String: Any]
        #expect(json?["op"] as? String == "get")
    }

    @Test func pairingHoldsASealedCopyAndANewPhoneGetsTheHomeBack() async throws {
        let (vault, sites, service, escrow, passkeys) = setUp()
        let pairing = Pairing(vault: vault, sites: sites, escrow: escrow, passkeys: passkeys, now: { 1_000 })
        let enrollment = Enrollment(boxStaticPublic: Primitives.generateKeyPair().publicKey, pairingCode: randomBytes(16), lanHint: "", rendezvousSecret: randomBytes(32))
        let paired = try await pairing.pair(scanned: enrollment.url())
        #expect(await paired.sealed.value == .saved)
        #expect(sites.get(paired.site.siteId)?.escrow == true)
        #expect(service.rows.count == 1)
        let devicePublic = try #require(vault.devicePublic)

        // A new phone: empty storage, the same synced passkey.
        let store2 = MemoryStore()
        let vault2 = Vault(store: store2)
        let sites2 = SiteList(store: store2)
        let escrow2 = Escrow(vault: vault2, sites: sites2, transport: service.transport)
        let found = try await escrow2.recover(passkeys)
        #expect(found.map(\.siteId) == [paired.site.siteId])
        #expect(found.first?.fingerprint == SiteList.fingerprint(enrollment.boxStaticPublic))
        try escrow2.adopt(try #require(found.first), nowMs: 2_000)
        // The same identity the box already trusts, with no pairing code.
        #expect(vault2.devicePublic == devicePublic)
        #expect(sites2.get(paired.site.siteId)?.pairingCode == nil)
        #expect(sites2.get(paired.site.siteId)?.rendezvousSecret?.byteArray == enrollment.rendezvousSecret)
        #expect(try vault2.silentWrappingKey() != nil)
        #expect(vault2.passkeyCredentialIDs == [passkeys.credentialID])
    }

    @Test func removingEmptiesTheCopyAndKeepsTheVersionGoing() async throws {
        let (vault, sites, service, escrow, passkeys) = setUp()
        let pairing = Pairing(vault: vault, sites: sites, escrow: escrow, passkeys: passkeys)
        let enrollment = Enrollment(boxStaticPublic: Primitives.generateKeyPair().publicKey, pairingCode: randomBytes(16), lanHint: "", rendezvousSecret: randomBytes(32))
        let paired = try await pairing.pair(scanned: enrollment.url())
        _ = await paired.sealed.value
        #expect(await escrow.remove(passkeys) == .removed)
        let row = try #require(service.rows.values.first)
        #expect(row.blob.isEmpty)
        #expect(row.version == 2)
        // Nothing held now reads as nothing held.
        let store2 = MemoryStore()
        #expect(try await Escrow(vault: Vault(store: store2), sites: SiteList(store: store2), transport: service.transport).recover(passkeys).isEmpty)
    }

    @Test func noOptInCostsNoPromptAndNoRequest() async {
        let (_, _, service, escrow, passkeys) = setUp()
        #expect(await escrow.remove(passkeys) == .nothingToRemove)
        #expect(passkeys.assertions.isEmpty)
        #expect(service.requests == 0)
    }

    @Test func offlineLeavesThePairingIntactAndUnmarked() async throws {
        let (vault, sites, service, escrow, passkeys) = setUp()
        service.offline = true
        let pairing = Pairing(vault: vault, sites: sites, escrow: escrow, passkeys: passkeys)
        let enrollment = Enrollment(boxStaticPublic: Primitives.generateKeyPair().publicKey, pairingCode: randomBytes(16), lanHint: "", rendezvousSecret: randomBytes(32))
        let paired = try await pairing.pair(scanned: enrollment.url())
        #expect(await paired.sealed.value == .unreachable)
        #expect(sites.get(paired.site.siteId)?.escrow == false)
        #expect(sites.get(paired.site.siteId) != nil)
    }

    @Test func aBoxCodeArmsAKnownHomeOnly() async throws {
        let (vault, sites, _, escrow, passkeys) = setUp()
        let pairing = Pairing(vault: vault, sites: sites, escrow: escrow, passkeys: passkeys)
        #expect(throws: BoxCode.BoxCodeError.self) { try pairing.redeemBoxCode(siteId: "nope", typed: "04HM-ASW9") }
        let enrollment = Enrollment(boxStaticPublic: Primitives.generateKeyPair().publicKey, pairingCode: randomBytes(16), lanHint: "", rendezvousSecret: randomBytes(32))
        let paired = try await pairing.pair(scanned: enrollment.url(), holdCopy: false)
        try pairing.redeemBoxCode(siteId: paired.site.siteId, typed: "04hm asw9")
        #expect(sites.get(paired.site.siteId)?.pairingCode?.byteArray.hex == "0123456789")
    }
}
