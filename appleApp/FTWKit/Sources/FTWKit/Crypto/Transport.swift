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
    /// How far out of order a frame may arrive and still open. Through FTW
    /// Cloud lane 0 goes up to five a second, while the box's link holds a
    /// paced bulk frame at most about 9 s (srcfl/ftw `cloudlink.MaxBulkWait`).
    /// Over QUIC one session's frames also travel on two streams and in
    /// datagrams, so a burst of bulk frames, a few hundred at most, can
    /// overtake a frame on the control stream. 1024 covers both in 128
    /// bytes. The same as appwire.ReplayWindow in srcfl/ftw.
    public static let replayWindow: UInt64 = 1024
    private static let seenWords = Int(replayWindow / 64)

    public let handshakeHash: Bytes
    /// The box's static key as authenticated, not as claimed.
    public let remoteStatic: Bytes

    private let send: CipherState
    private let recv: CipherState
    private var highestSeq: UInt64?
    /// A bit for each sequence number in the window: bit i (word i/64, bit
    /// i%64) is highestSeq-i, set once that frame opened.
    private var seen = [UInt64](repeating: 0, count: NoiseTransport.seenWords)
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
        if (seen[Int(behind / 64)] >> (behind % 64)) & 1 == 1 {
            throw Noise.NoiseError(code: "E_NOISE_REPLAY", message: "sequence \(seq) was already accepted")
        }
    }

    private func markSeen(_ seq: UInt64) {
        guard let highest = highestSeq else {
            highestSeq = seq
            seen[0] = 1
            return
        }
        if seq > highest {
            shiftSeen(seq - highest)
            seen[0] |= 1
            highestSeq = seq
        } else {
            let behind = highest - seq
            seen[Int(behind / 64)] |= 1 << (behind % 64)
        }
    }

    /// Age the window by n: bit i moves to bit i+n, and bits that move past
    /// the window are gone.
    private func shiftSeen(_ n: UInt64) {
        guard n < Self.replayWindow else {
            seen = [UInt64](repeating: 0, count: Self.seenWords)
            return
        }
        let words = Int(n / 64), bits = n % 64
        for i in stride(from: Self.seenWords - 1, through: 0, by: -1) {
            var w: UInt64 = 0
            let j = i - words
            if j >= 0 {
                w = seen[j] << bits
                if bits > 0 && j > 0 {
                    w |= seen[j - 1] >> (64 - bits)
                }
            }
            seen[i] = w
        }
    }
}
