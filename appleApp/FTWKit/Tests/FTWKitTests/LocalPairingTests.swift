import Foundation
import Testing
@testable import FTWKit

@Suite struct LocalPairingTests {
    @Test func acceptsAPastedCodeWithTheBoxAddress() throws {
        let input = try LocalPairing.input(address: "wrong.local", code: "http://192.168.1.42:8080#k7m2-9qrt")
        #expect(input.url.absoluteString == "http://192.168.1.42:8080/api/app-link/pairing")
        #expect(input.code == "K7M29QRT")
        #expect(try LocalPairing.input(address: "ftw.local:8080", code: "0000-OOIL").code == "00000011")
        #expect(try LocalPairing.input(address: "http://[fd00::1]:8080", code: "K7M2-9QRT").url.absoluteString == "http://[fd00::1]:8080/api/app-link/pairing")
    }

    @Test func refusesPublicTargetsAndCredentialsInAddresses() {
        for address in ["https://example.com", "http://8.8.8.8", "http://[2606:4700::1111]", "http://user:pass@ftw.local", "http://ftw.local/path", "http://ftw.local?code=secret", "ftp://ftw.local", "http://ftw.local:0"] {
            #expect(throws: LocalPairingError.address) { try LocalPairing.input(address: address, code: "K7M2-9QRT") }
        }
        #expect(throws: LocalPairingError.code) { try LocalPairing.input(address: "ftw.local", code: "1234") }
    }

    @Test func postsTheCodeLocallyThenReadsTheUnchangedV3Payload() async throws {
        // The Go-generated v3 vector also used by EnrollmentTests.
        let link = EnrollmentTests.v3
        let client = LocalPairing { request in
            #expect(request.url?.absoluteString == "http://ftw.local:8080/api/app-link/pairing")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer house-secret")
            let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: String]
            #expect(body == ["kind": "claim", "code": "K7M29QRT"])
            let data = try JSONSerialization.data(withJSONObject: ["url": link])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(try await client.redeem(address: "ftw.local:8080", code: "K7M2-9QRT", password: "house-secret") == link)
    }

    @Test func explainsARequiredPasswordAndARejectedOrExpiredCode() async {
        for (status, error) in [(401, LocalPairingError.password), (400, .code), (403, .unavailable), (302, .unavailable)] {
            let client = LocalPairing { request in
                (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            await #expect(throws: error) { try await client.redeem(address: "ftw.local", code: "K7M2-9QRT") }
        }
    }
}

@MainActor
@Suite struct LocalPairingFlowTests {
    @Test func aNewPhoneOpensItsHomeFromATypedCode() async throws {
        let world = ShellTests.World()
        let app = world.app()
        let model = PairModel(app: app)
        let link = world.pairingURL
        let client = LocalPairing { request in
            let data = try JSONSerialization.data(withJSONObject: ["url": link])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        model.enterCode()
        model.code = "K7M2-9QRT"
        let task = Task { await model.connectCode(using: client) }
        await world.run(1_000)
        await task.value
        #expect(app.site?.session.phase == .streaming)
        #expect(app.sites.current()?.boxStaticKey == Data(world.endpoint.staticKey.publicKey))
        #expect(model.message == nil)
    }

    @Test func aFailedCodeKeepsTheFormAndNeverStoresAHome() async {
        let world = ShellTests.World()
        let app = world.app()
        let model = PairModel(app: app)
        model.enterCode()
        model.code = "K7M2-9QRT"
        let client = LocalPairing { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }
        await model.connectCode(using: client)
        #expect(model.stage == .enteringCode && model.needsPassword)
        #expect(!model.codeBusy && app.sites.all().isEmpty)
        model.password = "house-secret"
        model.cancel()
        #expect(model.password.isEmpty && model.stage == .intro)
    }
}
