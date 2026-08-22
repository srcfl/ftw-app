package energy.ftw.crypto

import energy.ftw.hexToBytes
import energy.ftw.toHex
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class NoiseTest {
    /**
     * Cacophony vector for Noise_IK_25519_ChaChaPoly_SHA256, copied from
     * ftw-webapp/src/lib/crypto/noise.test.ts (snow tests/vectors/cacophony.txt).
     */
    private val vector = mapOf(
        "init_prologue" to "4a6f686e2047616c74",
        "init_static" to "e61ef9919cde45dd5f82166404bd08e38bceb5dfdfded0a34c8df7ed542214d1",
        "init_ephemeral" to "893e28b9dc6ca8d611ab664754b8ceb7bac5117349a4439a6b0569da977c464a",
        "init_remote_static" to "31e0303fd6418d2f8c0e78b91f22e8caed0fbe48656dcf4767e4834f701b8f62",
        "resp_prologue" to "4a6f686e2047616c74",
        "resp_static" to "4a3acbfdb163dec651dfa3194dece676d437029c62a408b4c5ea9114246e4893",
        "resp_ephemeral" to "bbdb4cdbd309f1a1f2e1456967fe288cadd6f712d65dc7b7793d5e63da6b375b",
        "handshake_hash" to "0b0f68fb0c27e03ce9b97565995ed4838cc0581b762ef72b062f6a546419fad7",
    )

    private val messages = listOf(
        "4c756477696720766f6e204d69736573" to
            "ca35def5ae56cec33dc2036731ab14896bc4c75dbb07a61f879f8e3afa4c7944718da798efbcd91528520204f904b9bd6c7413dccdc214d951e15253e39987f18146e8cd0873654207148333479d4d16c289f0294b29960a72f48e0b7bba2e89083169825e59642148d492020664ccf7",
        "4d757272617920526f746862617264" to
            "95ebc60d2b1fa672c1f46a8aa265ef51bfe38e7ccb39ec5be34069f1448088435361e70b2ed446e6c9ec387d1d6b3b840f194e373979d241b203c4acafccf5",
        "462e20412e20486179656b" to "050e9f3c8fac16b68dbce8f8c4bfbf6617c897f9ada4aa29aa19c8",
        "4361726c204d656e676572" to "344233a6cabb7141d80f3da2fedc311d9646bbb0f505afe403a667",
        "4a65616e2d426170746973746520536179" to "62cdeeb172ad7ade7aa7d9e069da5790f12331bfa00177787a1d0810c67dc3b2b4",
        "457567656e2042f6686d20766f6e2042617765726b" to
            "029bead1b40992327044d409d9a1f3ad8f36c3c452775d557e18bbeb2e8dfcead32d514024",
    )

    @Test
    fun namesTheProtocol() {
        assertEquals("Noise_IK_25519_ChaChaPoly_SHA256", PROTOCOL_NAME)
    }

    @Test
    fun cacophonyHandshakeAndTransport() {
        val initiator = HandshakeState.initiator(
            staticKey = keyPairFromSecret(vector.getValue("init_static").hexToBytes()),
            remoteStatic = vector.getValue("init_remote_static").hexToBytes(),
            prologue = vector.getValue("init_prologue").hexToBytes(),
            ephemeral = keyPairFromSecret(vector.getValue("init_ephemeral").hexToBytes()),
        )
        val responder = HandshakeState.responder(
            staticKey = keyPairFromSecret(vector.getValue("resp_static").hexToBytes()),
            prologue = vector.getValue("resp_prologue").hexToBytes(),
            ephemeral = keyPairFromSecret(vector.getValue("resp_ephemeral").hexToBytes()),
        )

        val m1 = initiator.writeMessage(messages[0].first.hexToBytes())
        assertEquals(messages[0].second, m1.toHex())
        assertEquals(messages[0].first, responder.readMessage(m1).toHex())

        val m2 = responder.writeMessage(messages[1].first.hexToBytes())
        assertEquals(messages[1].second, m2.toHex())
        assertEquals(messages[1].first, initiator.readMessage(m2).toHex())

        val a = initiator.split()
        val b = responder.split()
        assertEquals(vector.getValue("handshake_hash"), a.handshakeHash.toHex())
        assertEquals(vector.getValue("handshake_hash"), b.handshakeHash.toHex())
        assertEquals(vector.getValue("init_remote_static"), a.remoteStatic.toHex())
        assertEquals(
            keyPairFromSecret(vector.getValue("init_static").hexToBytes()).publicKey.toHex(),
            b.remoteStatic.toHex(),
        )

        messages.drop(2).forEachIndexed { i, msg ->
            val fromInitiator = i % 2 == 0
            val sender = if (fromInitiator) a.send else b.send
            val receiver = if (fromInitiator) b.recv else a.recv
            val ciphertext = sender.encryptWithAd(ByteArray(0), msg.first.hexToBytes())
            assertEquals(msg.second, ciphertext.toHex())
            assertEquals(msg.first, receiver.decryptWithAd(ByteArray(0), ciphertext).toHex())
        }
    }

    @Test
    fun pairingCodeFitsInMessage1() {
        val app = generateKeyPair()
        val box = generateKeyPair()
        val initiator = HandshakeState.initiator(app, box.publicKey)
        val responder = HandshakeState.responder(box)
        val pairing = "QR-8842".encodeToByteArray()
        val m1 = initiator.writeMessage(pairing)
        assertEquals(MESSAGE_1_OVERHEAD + pairing.size, m1.size)
        assertTrue(responder.readMessage(m1).contentEquals(pairing))
    }
}

class X25519Test {
    @Test
    fun cacophonyResponderPublic() {
        val secret = "4a3acbfdb163dec651dfa3194dece676d437029c62a408b4c5ea9114246e4893".hexToBytes()
        val pub = "31e0303fd6418d2f8c0e78b91f22e8caed0fbe48656dcf4767e4834f701b8f62"
        assertEquals(pub, X25519.publicKey(secret).toHex())
    }
}

class Sha256Test {
    @Test
    fun empty() {
        assertEquals(
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            Sha256.hash(ByteArray(0)).toHex(),
        )
    }

    @Test
    fun abc() {
        assertEquals(
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            Sha256.hash("abc".encodeToByteArray()).toHex(),
        )
    }
}
