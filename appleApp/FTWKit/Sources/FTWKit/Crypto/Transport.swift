import Foundation

/// The encrypted channel once the handshake is done.
///
///     offset  field       note
///     0       seq   u64BE  cleartext, authenticated as associated data
///     8       body        ChaCha20-Poly1305 over the frame, tag included
///
/// The sequence number is on the wire so a carrier that reorders or drops
/// (the LAN path, later) costs one frame instead of the session. Eight bytes
/// of monotonic counter and nothing else, so frame size stays constant.
public final class NoiseTransport {
    public static let seqBytes = 8
    public static let overhead = seqBytes + Noise.tagBytes
    /// At 1 Hz on lane 0, 64 frames is a minute of tolerance and one word.
    public static let replayWindow: UInt64 = 64

    public let handshakeHash: Bytes
    /// The box's static key as authenticated, not as claimed.
    public let remoteStatic: Bytes

    private let send: CipherState
    private let recv: CipherState
    private var highestSeq: UInt64?
    private var seen: UInt64 = 0
    private var closed = false

    public init(_ result: HandshakeResult) {
        send = result.send
        recv = result.recv
        handshakeHash = result.handshakeHash
        remoteStatic = result.remoteStatic
    }

    public var nextSeq: UInt64 { send.nonce }

    public func encrypt(_ frame: Bytes) throws -> Bytes {
        try assertOpen()
        let seq = send.nonce.bigEndianBytes
        let body = try send.encrypt(ad: seq, frame)
        return seq + body
    }

    public func decrypt(_ bytes: Bytes) throws -> Bytes {
        try assertOpen()
        guard bytes.count >= Self.overhead else {
            throw Noise.NoiseError(code: "E_NOISE_MESSAGE", message: "transport message is \(bytes.count) bytes")
        }
        let seqBytes = Array(bytes[0..<Self.seqBytes])
        let seq = seqBytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        try checkReplay(seq)
        try recv.setNonce(seq)
        // The sequence number is authenticated with the frame, so nobody can
        // renumber a captured message into the window.
        let frame = try recv.decrypt(ad: seqBytes, Array(bytes[Self.seqBytes...]))
        // Only an authenticated frame moves the window; otherwise anyone who
        // can inject bytes could burn numbers and lock out the real box.
        markSeen(seq)
        return frame
    }

    /// Drop both keys. After this the session is unusable, which is the point.
    public func close() {
        closed = true
        send.destroy()
        recv.destroy()
    }

    private func assertOpen() throws {
        if closed { throw Noise.NoiseError(code: "E_NOISE_CLOSED", message: "session is closed") }
    }

    private func checkReplay(_ seq: UInt64) throws {
        guard let highest = highestSeq, seq <= highest else { return }
        let behind = highest - seq
        if behind >= Self.replayWindow {
            throw Noise.NoiseError(code: "E_NOISE_REPLAY", message: "sequence \(seq) is outside the replay window")
        }
        if (seen >> behind) & 1 == 1 {
            throw Noise.NoiseError(code: "E_NOISE_REPLAY", message: "sequence \(seq) was already accepted")
        }
    }

    private func markSeen(_ seq: UInt64) {
        guard let highest = highestSeq else {
            highestSeq = seq
            seen = 1
            return
        }
        if seq > highest {
            let shift = seq - highest
            seen = shift >= Self.replayWindow ? 1 : (seen << shift) | 1
            highestSeq = seq
        } else {
            seen |= 1 << (highest - seq)
        }
    }
}
