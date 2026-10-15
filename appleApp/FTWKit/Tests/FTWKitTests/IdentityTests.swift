import CoreImage
import Foundation
import Testing
@testable import FTWKit

/// Vectors produced by running the web app's own identity code
/// (src/lib/identity and src/lib/carrier/rendezvous in srcfl/ftw-webapp).
struct IdentityVectors: Decodable {
    struct Handle: Decodable { let epoch: Int64; let handle: String }
    struct Rendezvous: Decodable { let secret: String; let handles: [Handle] }
    /// The file also holds the escrow's vectors; this app has no escrow
    /// yet and reads only what it uses.
    struct PRFVector: Decodable {
        let output: String
        let credentialId: String
    }
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

@Suite struct PairingImageTests {
    /// A QR as a PNG, the way a screenshot of the box's Settings page holds it.
    func png(_ text: String) throws -> Data {
        let filter = try #require(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        let code = try #require(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        // A quiet zone, as on a screen.
        let framed = code.composited(over: CIImage(color: .white).cropped(to: code.extent.insetBy(dx: -40, dy: -40)))
        return try #require(CIContext().pngRepresentation(of: framed, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
    }

    @Test func aPictureOfThePairingQRGivesTheLink() throws {
        let url = Enrollment(boxStaticPublic: Bytes(repeating: 7, count: 32), pairingCode: Bytes(repeating: 1, count: 16), lanHint: "", rendezvousSecret: Bytes(repeating: 9, count: 32)).url()
        #expect(PairingImage.link(in: try png(url)) == url)
    }

    @Test func anyOtherPictureGivesNothing() throws {
        #expect(PairingImage.link(in: try png("https://example.com/p#v2.nope")) == nil)
        #expect(PairingImage.link(in: Data("not a picture".utf8)) == nil)
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
            _ = try Enrollment.parse(scanned: url.replacingOccurrences(of: "#v2.", with: "#v4."))
            Issue.record("v4 parsed")
        } catch let e as EnrollmentError {
            #expect(e.help.contains("newer version of the app"))
        } catch { Issue.record("\(error)") }
    }

    /// v3 is v2 and the home id at FTW Cloud: the same code the box's
    /// `appenroll` makes, the web app's and Android's parsers read.
    static let v3 = "https://app.ftw.energy/p#v3.AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE.AgICAgICAgICAgICAgICAg.MTAuMC4wLjI6ODA4MA.AwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM.Zmp6eXI2N2J1enB5bmNxbWpsaXdnZXp2ZGU"

    @Test func readsAV3CodeAndTheHomeItNames() throws {
        let e = try Enrollment.parse(scanned: Self.v3)
        var expected = good
        expected.home = "fjzyr67buzpyncqmjliwgezvde"
        #expect(e == expected)
        #expect(e.url() == Self.v3)
        // v2 stays as it was, with no home.
        #expect(try Enrollment.parse(scanned: good.url()).home == nil)
        #expect(good.url().contains("#v2."))
    }

    @Test func aV3CodeMustNameAHome() throws {
        let segments = Self.v3.split(separator: ".").map(String.init)
        let cases: [(String, String)] = [
            (segments.dropLast().joined(separator: "."), "E_QR_SHAPE"),
            (Self.v3 + ".AA", "E_QR_SHAPE"),
            (good.url() + "." + segments.last!, "E_QR_SHAPE"),
            ((segments.dropLast() + [Base64url.encode(Array("NOT-A-HOME-AT-ALL-12345678".utf8))]).joined(separator: "."), "E_QR_HOME"),
            ((segments.dropLast() + [Base64url.encode(Array("fjzyr67buzpyncqmjliwgezvd".utf8))]).joined(separator: "."), "E_QR_HOME"),
            ((segments.dropLast() + ["!!"]).joined(separator: "."), "E_QR_ENCODING"),
        ]
        for (url, code) in cases {
            do {
                _ = try Enrollment.parse(scanned: url)
                Issue.record("parsed \(url)")
            } catch let e as EnrollmentError {
                #expect(e.code == code, "\(url)")
            } catch { Issue.record("\(error)") }
        }
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
        let local = try vault.localWrappingKey()
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
