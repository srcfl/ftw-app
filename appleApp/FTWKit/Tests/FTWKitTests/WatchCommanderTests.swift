import Foundation
import Testing
@testable import FTWKit
@testable import FTWWire

// A command the watch sends its box by itself, through FTW Cloud, against a
// box that keeps a command log and a service that may stay silent, refuse,
// or be busy. Time is a fake monotonic clock that pauses move.

/// Milliseconds on a monotonic clock that only the test moves.
private final class FakeTime: @unchecked Sendable {
    private let lock = NSLock()
    private var ms: Double = 0

    var now: Double { lock.withLock { ms } }

    func pass(_ d: Double) { lock.withLock { ms += d } }
}

/// The box's exchange as FTW Cloud carries it: Noise IK under the exchange
/// prologue, `hello_ok` with its clock, and a command log by `cmdId` that a
/// restart forgets. `script` says what happens to the n-th request (from 1)
/// on its way.
private final class FakeExchangeBox: @unchecked Sendable {
    enum Way {
        /// The service answers nothing; the box never sees it.
        case silence
        /// The box acts on it, and its answer is lost.
        case lost
        /// The box acts, its answer is lost, and it restarts.
        case lostThenRestart
        /// 403.
        case refused
        /// 429.
        case busy
        /// The request takes this long and arrives.
        case slow(Double)
    }

    /// What the box does with a command it has not seen.
    enum Act {
        case apply
        /// Acks it and does not settle it.
        case ack
        case reject(String)
        case expire
        /// Answers with frames this build cannot read.
        case garble
    }

    let key: Primitives.KeyPair
    let time: FakeTime
    var act: Act = .apply
    var script: [Int: Way] = [:]
    /// What one request takes on the way.
    var tripMs: Double = 200
    private(set) var requests = 0
    /// Commands that reached the box.
    private(set) var cmds = 0
    /// How often the box ran each command.
    private(set) var runs: [String: Int] = [:]
    private var bootAtMs: Double = -60_000
    private var transport: NoiseTransport?
    private var log: [String: Envelope] = [:]
    private let lock = NSLock()

    init(time: FakeTime) throws {
        self.time = time
        key = try Primitives.keyPair(fromSecret: Bytes(repeating: 7, count: 32))
    }

    func carry(_ message: Bytes) throws -> Bytes {
        try lock.withLock {
            requests += 1
            let way = script[requests]
            switch way {
            case .slow(let ms): time.pass(ms)
            default: time.pass(tripMs)
            }
            switch way {
            case .silence: return []
            case .refused: throw WatchCommander.Refused.notListed
            case .busy: throw WatchCommander.Refused.busy
            default: break
            }
            let answer = try receive(message)
            switch way {
            case .lost: return []
            case .lostThenRestart:
                transport = nil
                log = [:]
                bootAtMs = time.now
                return []
            default: return answer
            }
        }
    }

    private func receive(_ message: Bytes) throws -> Bytes {
        if message.count == ExchangeSession.openBytes {
            let hs = HandshakeState.responder(staticKey: key, prologue: ExchangeSession.prologueTag + key.publicKey)
            let hello = try Frame.decode(try hs.readMessage(message)).envelope
            guard hello.t == "hello" else { return [] }
            let ok = Envelope(t: "hello_ok", b: .map([
                ("clock", .map([("uptimeMs", .int(Int64(time.now - bootAtMs)))])),
                ("rev", .unsigned(7)),
                ("role", .text("watch")),
                ("scopes", .array([.text("ftw.dispatch.write")])),
            ]))
            let m2 = try hs.writeMessage(try Frame.encode(lane: Frame.laneControl, envelope: ok, bucket: ExchangeSession.helloOKBytes))
            transport = NoiseTransport(try hs.split())
            return m2
        }
        // A session the box no longer has: silence.
        guard let transport, let open = try? transport.decrypt(message) else { return [] }
        let env = try Frame.decode(open).envelope
        guard env.t == "cmd", let id = env.b?["cmdId"]?.string else { return [] }
        cmds += 1
        let ack = Envelope(t: "cmd.ack", b: .map([("cmdId", .text(id))]))
        let tick = Envelope(t: "tick", b: .map([("uptimeMs", .int(1))]))
        if let done = log[id] { return try seal([ack, done]) }
        func result(_ state: String, _ more: [(String, CBOR)] = []) -> Envelope {
            Envelope(t: "cmd.result", b: .map([("cmdId", .text(id)), ("state", .text(state))] + more))
        }
        switch act {
        case .apply:
            runs[id, default: 0] += 1
            log[id] = result("applied")
            return try seal([ack, result("applied")])
        case .ack:
            return try seal([ack, tick])
        case .reject(let code):
            let r = result("rejected", [("error", .map([("code", .text(code))]))])
            log[id] = r
            return try seal([ack, r])
        case .expire:
            return try seal([ack, result("expired")])
        case .garble:
            return try seal([tick, tick])
        }
    }

    private func seal(_ frames: [Envelope]) throws -> Bytes {
        guard let transport else { return [] }
        return try frames.flatMap { try transport.encrypt(try Frame.encode(lane: Frame.laneControl, envelope: $0, bucket: ExchangeSession.frameBytes)) }
    }
}

/// The steps a run said, in order.
private actor Steps {
    var said: [WatchReceipt.BoxStep] = []
    func add(_ s: WatchReceipt.BoxStep) { said.append(s) }
}

@Suite struct WatchCommanderTests {
    private let link = WatchLink(site: "site", cloudHome: "home", boxKey: Data(), cloudKey: nil, sources: [:], loadpoints: [:],
                                 watchKey: Data(count: 32), chargeNow: ["garage": .init(powerW: 11_000, phaseMode: "3p")], timeZone: nil)

    private func rig(_ configure: (FakeExchangeBox) -> Void = { _ in }) throws -> (FakeExchangeBox, WatchCommander, FakeTime) {
        let time = FakeTime()
        let box = try FakeExchangeBox(time: time)
        configure(box)
        var l = link
        l.boxKey = Data(box.key.publicKey)
        let commander = WatchCommander(
            link: l, key: try Primitives.keyPair(fromSecret: Bytes(repeating: 9, count: 32)), build: "test",
            clock: { time.now }, carry: { try box.carry($0) }, pause: { time.pass($0) })
        return (box, commander, time)
    }

    private func run(_ commander: WatchCommander, _ c: WatchCommand, leftMs: Double = WatchCommand.lifeMs) async -> (WatchReceipt.BoxStep, [WatchReceipt.BoxStep]) {
        let steps = Steps()
        let end = await commander.run(c, leftMs: leftMs) { await steps.add($0) }
        return (end, await steps.said)
    }

    private var charge: WatchCommand { WatchCommand(op: .chargeNow(loadpointID: "garage"), home: "site", sentAtMs: 0) }

    @Test func theBoxAppliesItOnce() async throws {
        let (box, commander, _) = try rig()
        let c = charge
        let (end, said) = await run(commander, c)
        #expect(end == .applied)
        #expect(said == [.sending])
        #expect(box.runs[c.id] == 1)
        #expect(box.requests == 2)
    }

    /// The answer to the command was lost. A new session asks again under
    /// the same cmdId, and the box answers from its log: it ran once.
    @Test func silenceAfterTheCommandAsksAgainAndTheBoxRunsItOnce() async throws {
        let (box, commander, _) = try rig { $0.script = [2: .lost] }
        let c = charge
        let (end, _) = await run(commander, c)
        #expect(end == .applied)
        #expect(box.cmds == 2)
        #expect(box.runs[c.id] == 1)
    }

    /// The box restarted after it ran the command, and forgot its cmdId.
    /// The new session's clock is behind the first one's, so the command is
    /// not sent again: it could run twice.
    @Test func aRestartedBoxIsNotSentTheCommandAgain() async throws {
        let (box, commander, _) = try rig { $0.script = [2: .lostThenRestart] }
        let c = charge
        let (end, _) = await run(commander, c)
        #expect(end == .noAnswer(acked: false))
        #expect(box.cmds == 1)
        #expect(box.runs[c.id] == 1)
        #expect(box.requests == 3)
    }

    @Test func silenceBeforeTheCommandLeftIsNotReached() async throws {
        let (box, commander, _) = try rig { $0.script = [1: .silence, 2: .silence] }
        let (end, _) = await run(commander, charge)
        #expect(end == .notReached)
        #expect(box.cmds == 0)
    }

    /// 403 before the command left: FTW Cloud does not know this watch, and
    /// nothing was sent. After it left, the box may have it.
    @Test func aRefusalSaysWhetherAnythingLeft() async throws {
        let (before, first, _) = try rig { $0.script = [1: .refused] }
        #expect(await run(first, charge).0 == .notListed)
        #expect(before.requests == 1)

        let (after, second, _) = try rig { $0.script = [2: .lost, 3: .refused] }
        #expect(await run(second, charge).0 == .noAnswer(acked: false))
        #expect(after.cmds == 1)
    }

    /// 429 is asked again a moment later, and the command still runs once.
    @Test func aBusyServiceIsAskedAgain() async throws {
        let (box, commander, time) = try rig { $0.script = [1: .busy, 3: .busy] }
        let c = charge
        let (end, _) = await run(commander, c)
        #expect(end == .applied)
        #expect(box.runs[c.id] == 1)
        #expect(time.now >= 2 * WatchCommander.busyWaitMs)
    }

    /// A tap whose life ran out before the command left is too late, and
    /// nothing reached the box.
    @Test func expiryBeforeSendingIsTooLate() async throws {
        let (box, commander, _) = try rig { $0.script = [1: .slow(31_000)] }
        let (end, _) = await run(commander, charge)
        #expect(end == .refused(.tooLate))
        #expect(box.cmds == 0)
    }

    /// Once the command left, its life running out is "no answer", never
    /// "too late": the box may have run it. The box's ack is kept.
    @Test func expiryAfterSendingIsNoAnswerAndKeepsTheAck() async throws {
        let (box, commander, _) = try rig { $0.act = .ack; $0.script = [3: .slow(29_000)] }
        let (end, said) = await run(commander, charge)
        #expect(end == .noAnswer(acked: true))
        #expect(said.contains(.pending))
        #expect(box.cmds == 2)
    }

    /// A box that acks and never settles gets three asks, then "no
    /// answer", with its ack.
    @Test func anUnsettledCommandEndsWithItsAck() async throws {
        let (box, commander, _) = try rig { $0.act = .ack }
        let (end, said) = await run(commander, charge)
        #expect(end == .noAnswer(acked: true))
        #expect(said == [.sending, .pending, .pending, .pending])
        #expect(box.cmds == WatchCommander.asks)
    }

    @Test func theBoxSaysTooLateItself() async throws {
        let (_, commander, _) = try rig { $0.act = .expire }
        #expect(await run(commander, charge).0 == .refused(.tooLate))
    }

    /// A watch removed between the handshake and the command: the box
    /// refuses it.
    @Test func aRevokedGrantIsRefused() async throws {
        let (_, commander, _) = try rig { $0.act = .reject("E_GRANT_REVOKED") }
        #expect(await run(commander, charge).0 == .refused(.mayNot))
    }

    /// An answer this build cannot read has its own step, and is no ack.
    @Test func anUnreadAnswerHasItsOwnStep() async throws {
        let (_, commander, _) = try rig { $0.act = .garble }
        let (end, said) = await run(commander, charge)
        #expect(said.contains(.unread))
        #expect(end == .noAnswer(acked: false))
    }

    /// The mode is the phone's: nothing goes to FTW Cloud.
    @Test func whatOnlyThePhoneSendsCostsNoRequest() async throws {
        let (box, commander, _) = try rig()
        let (end, said) = await run(commander, WatchCommand(op: .mode("charge"), home: "site", sentAtMs: 0))
        #expect(end == .needsPhone)
        #expect(said.isEmpty)
        #expect(box.requests == 0)
    }

    /// A first refusal may be a read that beat the roster: half a minute.
    /// After that a quarter of an hour.
    @Test func aRefusedReadWaits() {
        #expect(WatchCloud.readWaitMs(refusals: 1) == 30_000)
        #expect(WatchCloud.readWaitMs(refusals: 2) == 15 * 60_000)
    }
}
