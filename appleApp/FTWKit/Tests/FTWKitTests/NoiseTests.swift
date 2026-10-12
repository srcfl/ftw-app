import Foundation
import Testing
@testable import FTWKit

@Suite struct NoiseTests {
    /// Cacophony vector for Noise_IK_25519_ChaChaPoly_SHA256, the same one
    /// the web app and the Kotlin client test against.
    let vector = [
        "init_prologue": "4a6f686e2047616c74",
        "init_static": "e61ef9919cde45dd5f82166404bd08e38bceb5dfdfded0a34c8df7ed542214d1",
        "init_ephemeral": "893e28b9dc6ca8d611ab664754b8ceb7bac5117349a4439a6b0569da977c464a",
        "init_remote_static": "31e0303fd6418d2f8c0e78b91f22e8caed0fbe48656dcf4767e4834f701b8f62",
        "resp_prologue": "4a6f686e2047616c74",
        "resp_static": "4a3acbfdb163dec651dfa3194dece676d437029c62a408b4c5ea9114246e4893",
        "resp_ephemeral": "bbdb4cdbd309f1a1f2e1456967fe288cadd6f712d65dc7b7793d5e63da6b375b",
        "handshake_hash": "0b0f68fb0c27e03ce9b97565995ed4838cc0581b762ef72b062f6a546419fad7",
    ]

    let messages: [(String, String)] = [
        ("4c756477696720766f6e204d69736573",
         "ca35def5ae56cec33dc2036731ab14896bc4c75dbb07a61f879f8e3afa4c7944718da798efbcd91528520204f904b9bd6c7413dccdc214d951e15253e39987f18146e8cd0873654207148333479d4d16c289f0294b29960a72f48e0b7bba2e89083169825e59642148d492020664ccf7"),
        ("4d757272617920526f746862617264",
         "95ebc60d2b1fa672c1f46a8aa265ef51bfe38e7ccb39ec5be34069f1448088435361e70b2ed446e6c9ec387d1d6b3b840f194e373979d241b203c4acafccf5"),
        ("462e20412e20486179656b", "050e9f3c8fac16b68dbce8f8c4bfbf6617c897f9ada4aa29aa19c8"),
        ("4361726c204d656e676572", "344233a6cabb7141d80f3da2fedc311d9646bbb0f505afe403a667"),
        ("4a65616e2d426170746973746520536179", "62cdeeb172ad7ade7aa7d9e069da5790f12331bfa00177787a1d0810c67dc3b2b4"),
        ("457567656e2042f6686d20766f6e2042617765726b",
         "029bead1b40992327044d409d9a1f3ad8f36c3c452775d557e18bbeb2e8dfcead32d514024"),
    ]

    func key(_ name: String) throws -> Primitives.KeyPair {
        try Primitives.keyPair(fromSecret: Bytes(hex: vector[name]!))
    }

    @Test func namesTheProtocol() {
        #expect(Noise.protocolName == "Noise_IK_25519_ChaChaPoly_SHA256")
        #expect(Array(Noise.protocolName.utf8).count == 32)
    }

    @Test func cacophonyHandshakeAndTransport() throws {
        let initiator = try HandshakeState.initiator(
            staticKey: key("init_static"),
            remoteStatic: Bytes(hex: vector["init_remote_static"]!),
            prologue: Bytes(hex: vector["init_prologue"]!),
            ephemeral: key("init_ephemeral")
        )
        let responder = HandshakeState.responder(
            staticKey: try key("resp_static"),
            prologue: Bytes(hex: vector["resp_prologue"]!),
            ephemeral: try key("resp_ephemeral")
        )

        let m1 = try initiator.writeMessage(Bytes(hex: messages[0].0))
        #expect(m1.hex == messages[0].1)
        #expect(try responder.readMessage(m1).hex == messages[0].0)

        let m2 = try responder.writeMessage(Bytes(hex: messages[1].0))
        #expect(m2.hex == messages[1].1)
        #expect(try initiator.readMessage(m2).hex == messages[1].0)

        let a = try initiator.split()
        let b = try responder.split()
        #expect(a.handshakeHash.hex == vector["handshake_hash"])
        #expect(b.handshakeHash.hex == vector["handshake_hash"])
        #expect(a.remoteStatic.hex == vector["init_remote_static"])
        #expect(b.remoteStatic == (try key("init_static")).publicKey)

        for (i, msg) in messages.dropFirst(2).enumerated() {
            let fromInitiator = i % 2 == 0
            let sender = fromInitiator ? a.send : b.send
            let receiver = fromInitiator ? b.recv : a.recv
            let ct = try sender.encrypt(ad: [], Bytes(hex: msg.0))
            #expect(ct.hex == msg.1)
            #expect(try receiver.decrypt(ad: [], ct).hex == msg.0)
        }
    }

    @Test func splitTwiceIsRefused() throws {
        let box = Primitives.generateKeyPair()
        let app = Primitives.generateKeyPair()
        let i = try HandshakeState.initiator(staticKey: app, remoteStatic: box.publicKey)
        let r = HandshakeState.responder(staticKey: box)
        _ = try r.readMessage(try i.writeMessage())
        _ = try i.readMessage(try r.writeMessage())
        _ = try i.split()
        #expect(throws: Noise.NoiseError.self) { try i.split() }
    }

    @Test func aStrayMessageTwoLeavesTheHandshakeWaiting() throws {
        // Two phones in one relay room read each other's 48-byte replies. A
        // reply that does not authenticate must not poison the state.
        let box = Primitives.generateKeyPair()
        let app = Primitives.generateKeyPair()
        let i = try HandshakeState.initiator(staticKey: app, remoteStatic: box.publicKey)
        let r = HandshakeState.responder(staticKey: box)
        _ = try r.readMessage(try i.writeMessage())
        let genuine = try r.writeMessage()
        #expect(throws: Noise.NoiseError.self) { _ = try i.readMessage(randomBytes(48)) }
        _ = try i.readMessage(genuine)
        #expect(i.isComplete)
    }

    @Test func aPinnedKeyThatIsNotTheBoxFailsAtTheFirstDecryption() throws {
        let box = Primitives.generateKeyPair()
        let impostor = Primitives.generateKeyPair()
        let app = Primitives.generateKeyPair()
        let i = try HandshakeState.initiator(staticKey: app, remoteStatic: box.publicKey)
        let r = HandshakeState.responder(staticKey: impostor)
        let m1 = try i.writeMessage()
        #expect(throws: Noise.NoiseError.self) { _ = try r.readMessage(m1) }
    }

    @Test func sharedInteropVectors() throws {
        let v = try InteropVectors.load()
        #expect(v.protocolName == Noise.protocolName)
        let hs = v.handshake
        let appStatic = try Primitives.keyPair(fromSecret: Bytes(hex: hs.initiatorStatic))
        let boxStatic = try Primitives.keyPair(fromSecret: Bytes(hex: hs.responderStatic))
        #expect(appStatic.publicKey.hex == hs.initiatorStaticPublic)
        #expect(boxStatic.publicKey.hex == hs.responderStaticPublic)

        let app = try HandshakeState.initiator(
            staticKey: appStatic,
            remoteStatic: boxStatic.publicKey,
            prologue: Bytes(hex: hs.prologue),
            ephemeral: try Primitives.keyPair(fromSecret: Bytes(hex: hs.initiatorEphemeral))
        )
        let box = HandshakeState.responder(
            staticKey: boxStatic,
            prologue: Bytes(hex: hs.prologue),
            ephemeral: try Primitives.keyPair(fromSecret: Bytes(hex: hs.responderEphemeral))
        )
        let m1 = try app.writeMessage(Bytes(hex: hs.message1Payload))
        #expect(m1.hex == hs.message1)
        #expect(try box.readMessage(m1).hex == hs.message1Payload)
        let m2 = try box.writeMessage(Bytes(hex: hs.message2Payload))
        #expect(m2.hex == hs.message2)
        #expect(try app.readMessage(m2).hex == hs.message2Payload)

        let appSide = NoiseTransport(try app.split())
        let boxSide = NoiseTransport(try box.split())
        #expect(appSide.handshakeHash.hex == hs.handshakeHash)

        let frames = Dictionary(uniqueKeysWithValues: v.frames.map { ($0.name, Bytes(hex: $0.bytes)) })
        for step in v.transport {
            let frame = try #require(frames[step.frame])
            if step.from == "app" {
                #expect(appSide.nextSeq == step.seq)
                let wire = try appSide.encrypt(frame)
                #expect(wire.hex == step.wire, "app frame \(step.frame) at \(step.seq)")
                #expect(try boxSide.decrypt(wire) == frame)
            } else {
                let wire = Bytes(hex: step.wire)
                #expect(try appSide.decrypt(wire) == frame, "box frame \(step.frame) at \(step.seq)")
            }
        }
    }

    @Test func replayWindowRefusesARepeatAndAcceptsLateFrames() throws {
        let box = Primitives.generateKeyPair()
        let appKey = Primitives.generateKeyPair()
        let i = try HandshakeState.initiator(staticKey: appKey, remoteStatic: box.publicKey)
        let r = HandshakeState.responder(staticKey: box)
        _ = try r.readMessage(try i.writeMessage())
        _ = try i.readMessage(try r.writeMessage())
        let app = NoiseTransport(try i.split())
        let boxSide = NoiseTransport(try r.split())

        let w0 = try boxSide.encrypt([0])
        let w1 = try boxSide.encrypt([1])
        let w2 = try boxSide.encrypt([2])
        #expect(try app.decrypt(w2) == [2])
        #expect(try app.decrypt(w0) == [0])
        #expect(throws: Noise.NoiseError.self) { _ = try app.decrypt(w0) }
        #expect(try app.decrypt(w1) == [1])

        // A forged frame does not move the window.
        var forged = try boxSide.encrypt([3])
        forged[forged.count - 1] ^= 1
        #expect(throws: Noise.NoiseError.self) { _ = try app.decrypt(forged) }
    }
}
