import Foundation
import FTWShared

/// One command the watch sends its box itself, through the box's exchange
/// over FTW Cloud (srcfl/ftw ADR 0009, "Through FTW Cloud"). It holds the
/// rules and no carrier: `carry` takes one exchange message to the box and
/// returns the box's answer, empty when none came.
///
/// - Every mark after sending is the box's own answer.
/// - A command that got no answer is asked again under its `cmdId`, in a
///   new session if need be, and the box answers with what it did.
/// - The box forgets its `cmdId`s when it restarts. A new session whose
///   `hello_ok` clock is behind the first one's comes from a box that
///   restarted, and a command that has left is not sent to it again.
/// - Once a command has left, it ends in the box's answer or in "no
///   answer". "Too late" is the box's `E_CMD_EXPIRED`, or a command that
///   never left.
/// - The command's life runs on `clock`, a monotonic clock, from the tap.
public struct WatchCommander: Sendable {
    /// How FTW Cloud turned one message away. Any other error is a request
    /// that got no answer.
    public enum Refused: Error, Equatable, Sendable {
        /// 403: FTW Cloud does not know this watch for this home.
        case notListed
        /// 429: the service takes one request at a time per device.
        case busy
    }

    public static let sessions = 2
    /// Asks of one session, while the box has the command and has not
    /// settled it. The box keeps a session for four exchanges.
    public static let asks = 3
    public static let askAgainMs: Double = 1_500
    public static let busyWaitMs: Double = 1_000
    public static let busyTries = 3

    public var link: WatchLink
    public var key: Primitives.KeyPair
    public var build: String
    /// Milliseconds on a monotonic clock.
    public var clock: @Sendable () -> Double
    public var carry: @Sendable (Bytes) async throws -> Bytes
    public var pause: @Sendable (Double) async throws -> Void

    public init(link: WatchLink, key: Primitives.KeyPair, build: String, clock: @escaping @Sendable () -> Double,
                carry: @escaping @Sendable (Bytes) async throws -> Bytes,
                pause: @escaping @Sendable (Double) async throws -> Void) {
        self.link = link
        self.key = key
        self.build = build
        self.clock = clock
        self.carry = carry
        self.pause = pause
    }

    /// Run `c`, with `leftMs` of its life left now. `say` hears each step
    /// on the way; the last one is returned.
    public func run(_ c: WatchCommand, leftMs: Double, say: @Sendable (WatchReceipt.BoxStep) async -> Void) async -> WatchReceipt.BoxStep {
        let deadline = clock() + leftMs
        var sent = false
        var acked = false
        var firstUptime: Double?
        func left() -> Double { deadline - clock() }
        func gaveUp() -> WatchReceipt.BoxStep {
            if sent { return .noAnswer(acked: acked) }
            return left() > 0 ? .notReached : .refused(.tooLate)
        }

        guard ExchangeSession.args(c, link: link) != nil else { return .needsPhone }
        await say(.sending)
        sessions: for _ in 0..<Self.sessions {
            guard left() > 0 else { break }
            let session: ExchangeSession
            let opened: ExchangeSession.Opened
            do {
                session = try ExchangeSession(boxKey: Bytes(link.boxKey), staticKey: key)
                let hello = try await ask(session.open(build: build), left: left)
                guard !hello.isEmpty else { continue }
                opened = try session.opened(hello)
            } catch Refused.notListed {
                return sent ? .noAnswer(acked: acked) : .notListed
            } catch {
                continue
            }
            if sent, let first = firstUptime, opened.uptimeMs < first {
                // The box restarted and forgot the command's cmdId: sent
                // again, it could run twice.
                return .noAnswer(acked: acked)
            }
            firstUptime = firstUptime ?? opened.uptimeMs
            guard left() > 0 else { break }
            guard let cmd = ExchangeSession.cmd(c, link: link, opened: opened, leftMs: left()) else { break }

            for n in 0..<Self.asks {
                guard left() > 0 else { break sessions }
                let outcome: ExchangeSession.Outcome
                do {
                    let request = try session.request(cmd)
                    sent = true
                    let reply = try await ask(request, left: left)
                    // Silence: the session is gone, or the box away. A new
                    // session asks again.
                    guard !reply.isEmpty else { continue sessions }
                    outcome = ExchangeSession.outcome(try session.answer(reply), cmdId: c.id)
                } catch Refused.notListed {
                    return .noAnswer(acked: acked)
                } catch {
                    continue sessions
                }
                switch outcome {
                case .applied:
                    return .applied
                case .refused(let why):
                    return .refused(why)
                case .pending:
                    acked = true
                    await say(.pending)
                case .unread:
                    await say(acked ? .pending : .unread)
                }
                if n < Self.asks - 1 { try? await pause(min(Self.askAgainMs, max(0, left()))) }
            }
            break
        }
        return gaveUp()
    }

    /// One message, asked again after a moment while the service is busy.
    private func ask(_ message: Bytes, left: () -> Double) async throws -> Bytes {
        var tries = 0
        while true {
            do {
                return try await carry(message)
            } catch Refused.busy {
                tries += 1
                guard tries < Self.busyTries, left() > Self.busyWaitMs else { throw Refused.busy }
                try await pause(Self.busyWaitMs)
            }
        }
    }
}
