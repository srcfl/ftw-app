import Foundation

/// Noise_IK_25519_ChaChaPoly_SHA256.
///
/// IK because the initiator already knows the responder's static key: the
/// app reads it optically off the box's QR code, so the trust anchor never
/// travels through Sourceful's cloud. A hostile relay can drop frames but
/// cannot present itself as a box.
///
///     IK:
///       <- s
///       ...
///       -> e, es, s, ss
///       <- e, ee, se
///
/// Byte-identical to the TypeScript client and the Go box, and checked
/// against the Cacophony vectors and the shared interop vectors in the tests.
public enum Noise {
    public static let protocolName = "Noise_IK_25519_ChaChaPoly_SHA256"
    public static let dhBytes = 32
    public static let hashBytes = 32
    public static let tagBytes = 16
    /// 2^64 - 1 is reserved by the spec and must never encrypt.
    public static let maxNonce = UInt64.max

    public static let message1Overhead = dhBytes + dhBytes + tagBytes + tagBytes
    public static let message2Overhead = dhBytes + tagBytes

    /// Failures here are local: they never cross the wire. The carrier maps
    /// them to prose; this layer only says which thing went wrong.
    public struct NoiseError: Error, Equatable {
        public let code: String
        public let message: String
    }

    /// Noise HKDF: one extract over the chaining key, then expand with empty
    /// info. Splitting one expand is byte-identical to the chained HMACs.
    static func hkdf2(_ chainingKey: Bytes, _ ikm: Bytes) -> (Bytes, Bytes) {
        let prk = Primitives.hmacSHA256(key: chainingKey, ikm)
        let t1 = Primitives.hmacSHA256(key: prk, [1])
        let t2 = Primitives.hmacSHA256(key: prk, t1 + [2])
        return (t1, t2)
    }

    static func dh(_ secret: Bytes, _ peer: Bytes) throws -> Bytes {
        do {
            return try Primitives.x25519(secret: secret, peer: peer)
        } catch {
            throw NoiseError(code: "E_NOISE_DH", message: "X25519 failed")
        }
    }

    /// ChaChaPoly's 96-bit nonce, Noise-encoded: four zero bytes, then the
    /// 64-bit counter little-endian.
    static func nonceBytes(_ n: UInt64) -> Bytes {
        var out = Bytes(repeating: 0, count: 12)
        for i in 0..<8 { out[4 + i] = UInt8(truncatingIfNeeded: n >> (8 * UInt64(i))) }
        return out
    }
}

/// One direction's key and counter.
///
/// The counter never wraps. Reusing a (key, nonce) pair under
/// ChaCha20-Poly1305 hands an observer the XOR of two plaintexts and makes the
/// authenticator forgeable, so exhaustion throws and the session dies.
public final class CipherState {
    private var key: Bytes?
    public private(set) var nonce: UInt64 = 0
    private var destroyed = false

    public init(key: Bytes? = nil) {
        self.key = key
    }

    public var hasKey: Bool { key != nil }

    /// Jump the counter, for a carrier that may reorder or drop. Replay
    /// protection lives in the transport, which decides what is acceptable.
    public func setNonce(_ n: UInt64) throws {
        guard n < Noise.maxNonce else {
            throw Noise.NoiseError(code: "E_NOISE_NONCE_EXHAUSTED", message: "nonce \(n) is out of range")
        }
        nonce = n
    }

    public func encrypt(ad: Bytes, _ plaintext: Bytes) throws -> Bytes {
        try assertUsable()
        // Before the first mixKey there is no key and the spec passes data
        // through. A destroyed cipher is a separate flag so it can never
        // quietly emit plaintext.
        guard let key else { return plaintext }
        let n = try take()
        return try Primitives.chachaSeal(key: key, nonce: Noise.nonceBytes(n), ad: ad, plaintext: plaintext)
    }

    public func decrypt(ad: Bytes, _ ciphertext: Bytes) throws -> Bytes {
        try assertUsable()
        guard let key else { return ciphertext }
        let n = try take()
        do {
            return try Primitives.chachaOpen(key: key, nonce: Noise.nonceBytes(n), ad: ad, ciphertext: ciphertext)
        } catch {
            // Never say more than this. Which check failed is exactly what a
            // chosen-ciphertext attacker is probing for.
            throw Noise.NoiseError(code: "E_NOISE_AUTH", message: "authentication failed")
        }
    }

    func copy() -> CipherState {
        let c = CipherState(key: key)
        c.nonce = nonce
        c.destroyed = destroyed
        return c
    }

    /// Wipe the key. A closed session must not leave one reachable.
    public func destroy() {
        if var k = key { wipe(&k) }
        key = nil
        destroyed = true
    }

    private func assertUsable() throws {
        if destroyed { throw Noise.NoiseError(code: "E_NOISE_CLOSED", message: "cipher was destroyed") }
    }

    private func take() throws -> UInt64 {
        guard nonce < Noise.maxNonce else {
            throw Noise.NoiseError(code: "E_NOISE_NONCE_EXHAUSTED", message: "nonce space exhausted")
        }
        defer { nonce += 1 }
        return nonce
    }
}

/// Chaining key, handshake hash, and the cipher over handshake payloads.
final class SymmetricState {
    var ck: Bytes
    var h: Bytes
    var cipher = CipherState()

    init() {
        let name = Array(Noise.protocolName.utf8)
        // The name is exactly 32 bytes, so it is used verbatim; a longer one
        // would be hashed.
        h = name.count <= Noise.hashBytes ? name + Bytes(repeating: 0, count: Noise.hashBytes - name.count) : Primitives.sha256(name)
        ck = h
    }

    func mixHash(_ data: Bytes) {
        h = Primitives.sha256(h + data)
    }

    func mixKey(_ ikm: Bytes) {
        let (next, temp) = Noise.hkdf2(ck, ikm)
        ck = next
        cipher = CipherState(key: temp)
    }

    func encryptAndHash(_ plaintext: Bytes) throws -> Bytes {
        let ct = try cipher.encrypt(ad: h, plaintext)
        mixHash(ct)
        return ct
    }

    func decryptAndHash(_ ciphertext: Bytes) throws -> Bytes {
        let pt = try cipher.decrypt(ad: h, ciphertext)
        mixHash(ciphertext)
        return pt
    }

    func copy() -> SymmetricState {
        let c = SymmetricState()
        c.ck = ck
        c.h = h
        c.cipher = cipher.copy()
        return c
    }

    func split() -> (CipherState, CipherState) {
        let (k1, k2) = Noise.hkdf2(ck, [])
        return (CipherState(key: k1), CipherState(key: k2))
    }
}

public struct HandshakeResult {
    /// Encrypts what we send.
    public let send: CipherState
    /// Decrypts what we receive.
    public let recv: CipherState
    public let handshakeHash: Bytes
    /// The peer's static key, now authenticated rather than merely claimed.
    public let remoteStatic: Bytes
}

/// The IK state machine. Anything out of order throws rather than producing
/// a message the peer cannot read.
public final class HandshakeState {
    private enum Step { case write1, read1, write2, read2, done, split }

    private var sym = SymmetricState()
    private let s: Primitives.KeyPair
    private var e: Primitives.KeyPair?
    private var rs: Bytes?
    private var re: Bytes?
    private let initiator: Bool
    private let fixedEphemeral: Primitives.KeyPair?
    private var step: Step

    /// `ephemeral` is for test vectors only: generating it is the whole
    /// source of forward secrecy.
    public static func initiator(staticKey: Primitives.KeyPair, remoteStatic: Bytes, prologue: Bytes = [], ephemeral: Primitives.KeyPair? = nil) throws -> HandshakeState {
        guard remoteStatic.count == Noise.dhBytes else {
            throw Noise.NoiseError(code: "E_NOISE_KEY", message: "IK needs the responder static key up front")
        }
        return HandshakeState(initiator: true, staticKey: staticKey, remoteStatic: remoteStatic, prologue: prologue, ephemeral: ephemeral)
    }

    public static func responder(staticKey: Primitives.KeyPair, prologue: Bytes = [], ephemeral: Primitives.KeyPair? = nil) -> HandshakeState {
        HandshakeState(initiator: false, staticKey: staticKey, remoteStatic: nil, prologue: prologue, ephemeral: ephemeral)
    }

    private init(initiator: Bool, staticKey: Primitives.KeyPair, remoteStatic: Bytes?, prologue: Bytes, ephemeral: Primitives.KeyPair?) {
        self.initiator = initiator
        s = staticKey
        fixedEphemeral = ephemeral
        step = initiator ? .write1 : .read1
        sym.mixHash(prologue)
        // IK's pre-message `<- s`: both ends hash the responder's static key
        // before a byte moves, so a relay substituting its own key fails at
        // the first decryption.
        if initiator, let remoteStatic {
            rs = remoteStatic
            sym.mixHash(remoteStatic)
        } else {
            sym.mixHash(staticKey.publicKey)
        }
    }

    public var isComplete: Bool { step == .done }

    public func writeMessage(_ payload: Bytes = []) throws -> Bytes {
        if initiator && step == .write1 { return try writeMessage1(payload) }
        if !initiator && step == .write2 { return try writeMessage2(payload) }
        throw Noise.NoiseError(code: "E_NOISE_STATE", message: "cannot write at this step")
    }

    public func readMessage(_ message: Bytes) throws -> Bytes {
        if !initiator && step == .read1 { return try readMessage1(message) }
        if initiator && step == .read2 { return try readMessage2(message) }
        throw Noise.NoiseError(code: "E_NOISE_STATE", message: "cannot read at this step")
    }

    /// Ends the handshake and hands over the keys, once. Splitting twice
    /// would mint two send ciphers with the same key at nonce 0.
    public func split() throws -> HandshakeResult {
        guard step == .done else {
            throw Noise.NoiseError(code: "E_NOISE_STATE", message: step == .split ? "handshake already split" : "handshake is not done")
        }
        let (c1, c2) = sym.split()
        step = .split
        return HandshakeResult(
            send: initiator ? c1 : c2,
            recv: initiator ? c2 : c1,
            handshakeHash: sym.h,
            remoteStatic: rs ?? []
        )
    }

    // -> e, es, s, ss
    private func writeMessage1(_ payload: Bytes) throws -> Bytes {
        let e = fixedEphemeral ?? Primitives.generateKeyPair()
        self.e = e
        let rs = self.rs!
        sym.mixHash(e.publicKey)
        sym.mixKey(try Noise.dh(e.secretKey, rs))
        let encStatic = try sym.encryptAndHash(s.publicKey)
        sym.mixKey(try Noise.dh(s.secretKey, rs))
        let encPayload = try sym.encryptAndHash(payload)
        step = .read2
        return e.publicKey + encStatic + encPayload
    }

    private func readMessage1(_ message: Bytes) throws -> Bytes {
        let encStaticEnd = Noise.dhBytes + Noise.dhBytes + Noise.tagBytes
        guard message.count >= encStaticEnd + Noise.tagBytes else {
            throw Noise.NoiseError(code: "E_NOISE_MESSAGE", message: "handshake message 1 is \(message.count) bytes")
        }
        // Commit on success: a message that fails to authenticate must leave
        // no trace, or one stray frame ends every handshake still waiting.
        let sym = self.sym.copy()
        let re = Array(message[0..<Noise.dhBytes])
        sym.mixHash(re)
        sym.mixKey(try Noise.dh(s.secretKey, re))
        let rs = try sym.decryptAndHash(Array(message[Noise.dhBytes..<encStaticEnd]))
        sym.mixKey(try Noise.dh(s.secretKey, rs))
        let payload = try sym.decryptAndHash(Array(message[encStaticEnd...]))
        self.sym = sym
        self.re = re
        self.rs = rs
        step = .write2
        return payload
    }

    // <- e, ee, se
    private func writeMessage2(_ payload: Bytes) throws -> Bytes {
        let e = fixedEphemeral ?? Primitives.generateKeyPair()
        self.e = e
        sym.mixHash(e.publicKey)
        sym.mixKey(try Noise.dh(e.secretKey, re!))
        sym.mixKey(try Noise.dh(e.secretKey, rs!))
        let encPayload = try sym.encryptAndHash(payload)
        step = .done
        return e.publicKey + encPayload
    }

    private func readMessage2(_ message: Bytes) throws -> Bytes {
        guard message.count >= Noise.dhBytes + Noise.tagBytes else {
            throw Noise.NoiseError(code: "E_NOISE_MESSAGE", message: "handshake message 2 is \(message.count) bytes")
        }
        // Mixing runs against a copy that becomes the state only once the tag
        // verifies. Two phones connecting at once read each other's 48-byte
        // replies on a shared relay room; mixing a stray one would poison the
        // state and the genuine reply could never authenticate.
        let sym = self.sym.copy()
        let re = Array(message[0..<Noise.dhBytes])
        sym.mixHash(re)
        sym.mixKey(try Noise.dh(e!.secretKey, re))
        sym.mixKey(try Noise.dh(s.secretKey, re))
        let payload = try sym.decryptAndHash(Array(message[Noise.dhBytes...]))
        self.sym = sym
        self.re = re
        step = .done
        return payload
    }
}
