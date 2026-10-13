import Foundation
import FTWShared

/// What a phone holds for one home read through FTW Cloud, and how fresh it
/// is.
///
/// The service cannot sign, so it cannot make data look fresher than the box
/// graded it. It can only delay, drop or replay, and each of those must age
/// the data or mark it stale here. A port of Go's `cloudwire.View`
/// (srcfl/ftw `go/protocol/cloudwire/view.go`); `CloudViewTests` replays the
/// protocol's freshness cases against it.
///
/// A plain value with no clock of its own: the caller passes phone time in,
/// so a widget or an extension can run the same rules on what the app
/// stored. Everything it holds belongs to the current boot.
///
/// Assumes the phone's clock is close to true time. One that runs behind
/// lets a delaying service hide that much delay.
public struct CloudView: Sendable {
    /// How far ahead of the phone clock a box's `wallMs` may be before the
    /// phone stops trusting the box clock for that boot (rule N).
    public static let ruleNLeadMs: Int64 = 2_000
    /// How long an uptime offset learned over Noise stays usable (rule U).
    public static let ruleULifetimeMs: Int64 = 24 * 60 * 60 * 1000
    /// Rule U adds 0.01 % of the time since the offset was learned to every
    /// age, because box clocks drift.
    static let ruleUDriftDivisor: Int64 = 10_000

    /// Why a message was dropped. The view is unchanged after each.
    public enum AcceptError: Error, Equatable {
        /// It does not verify with the box key for this home.
        case signature
        /// The phone holds this class at the same or a higher seq, or the
        /// message is from another boot and not anchored later than what
        /// the phone holds.
        case notNewer
        /// The box sends it, but never to a phone.
        case notAClass(String)
        /// Signed by the box, but the body is not what the class says.
        case undecodable(String)
    }

    /// How a phone would show what it holds at one moment.
    public struct Grades: Equatable, Sendable {
        /// False when no send time can be trusted: "cloud, age unverified",
        /// at best stale and never live.
        public var anchored = false
        /// How old the anchor is now, drift margin included. Nil when
        /// unanchored.
        public var ageMs: Int64?
        /// Each source's effective state, keyed by opaque source id.
        public var sources: [String: SourceState] = [:]
        /// Each live field's state, keyed by field id as text.
        public var fields: [String: SourceState] = [:]
        /// Each loadpoint's state, keyed by opaque loadpoint id.
        public var loadpoints: [String: SourceState] = [:]
    }

    public let home: String
    /// The box's 65-byte public key, as the box gave it over Noise. Never
    /// one from the service.
    public let boxKey: Bytes

    /// Empty until the first message. Go compares boots with bytes.Equal,
    /// where nil and empty are one value, and so does this.
    private var currentBoot: Bytes = []
    private var seq: [String: UInt64] = [:]
    private var noRuleN = false
    /// The latest anchored send time held, phone clock. Survives a reboot,
    /// so an older boot cannot come back.
    private var newest: Int64 = 0
    private var m: Anchor?
    private var offsets: [Bytes: UptimeOffset] = [:]

    /// The source table and its revision.
    public private(set) var sources: [String: CloudWire.Source] = [:]
    public private(set) var srcRev: UInt64 = 0
    /// The sources each field's freshness follows, sent with the table.
    public private(set) var fieldSources: [String: [String]] = [:]
    /// The newest of each class this phone shows.
    public private(set) var live: CloudWire.Live?
    public private(set) var lp: CloudWire.LP?
    /// Kept for the screens and left out of `grade`, as in Go: a price
    /// window ages by its own slots, not by the box's sources.
    public private(set) var prices: CloudWire.Prices?
    public private(set) var hb: CloudWire.HB?

    /// M: the newest anchored live or hb.
    private struct Anchor: Sendable {
        var seq: UInt64
        var hb: Bool
        var boot: Bytes
        /// Send time by rule N, or nil.
        var wallSend: Int64?
        var uptimeMs: Int64
        var srcRev: UInt64
        var liveSeq: UInt64
        var lpSeq: UInt64
        var ages: [String: Int64]
    }

    private struct UptimeOffset: Sendable {
        var offsetMs: Int64
        var learnedAtMs: Int64
    }

    public init(home: String, boxKey: Bytes) {
        self.home = home
        self.boxKey = boxKey
    }

    /// M's box uptime and the age of each source's newest reading at M, so a
    /// screen can say how old a reading is. Nil before an anchored message.
    public var anchorReadings: (uptimeMs: Int64, ages: [String: Int64])? {
        m.map { ($0.uptimeMs, $0.ages) }
    }

    /// The boot the view holds, nil before the first message.
    public var boot: Bytes? { currentBoot.isEmpty ? nil : currentBoot }

    /// H: half the smallest `staleAfterMs`, between 2 and 15 s.
    public var heartbeatMs: Int64 { Self.heartbeat(for: sources) }

    /// H for a source table: clamp(smallest staleAfterMs ÷ 2, 2 s, 15 s),
    /// and 15 s when no source has a cadence.
    public static func heartbeat(for table: [String: CloudWire.Source]) -> Int64 {
        guard let smallest = table.values.map(\.staleAfterMs).filter({ $0 > 0 }).min() else { return 15_000 }
        return min(max(smallest / 2, 2_000), 15_000)
    }

    /// Rule U's anchor, from a Noise session with the box: phone time minus
    /// box uptime, the smallest seen per boot. Every call renews its 24
    /// hours.
    public mutating func learnOffset(boot: Bytes, phoneMs: Int64, uptimeMs: Int64) {
        let offset = phoneMs &- uptimeMs
        if let current = offsets[boot], current.offsetMs <= offset {
            offsets[boot]?.learnedAtMs = phoneMs
            return
        }
        offsets[boot] = UptimeOffset(offsetMs: offset, learnedAtMs: phoneMs)
    }

    /// Takes one box envelope that arrived at `arrivalMs` on the phone
    /// clock. Throws `AcceptError`, and changes nothing, for a message it
    /// drops. A snapshot's envelopes go in one at a time, in rising seq.
    public mutating func accept(_ envelope: CloudWire.Envelope, arrivalMs: Int64) throws {
        guard CloudWire.verify(boxKey: boxKey, home: home, envelope: envelope) else { throw AcceptError.signature }
        guard CloudWire.phoneClasses.contains(envelope.t) else { throw AcceptError.notAClass(envelope.t) }
        // Decoded in full before anything changes, so a body that does not
        // decode leaves the view as it was.
        let message: Message
        do {
            message = try Message(t: envelope.t, b: envelope.b)
        } catch {
            throw AcceptError.undecodable("\(envelope.t): \(error)")
        }
        let h = message.header
        let newBoot = h.boot != currentBoot
        let lead = Self.leads(h, arrivalMs: arrivalMs)
        let wall = Self.wallSend(h, arrivalMs: arrivalMs, off: lead || (!newBoot && noRuleN))
        let send = sendTime(boot: h.boot, wall: wall, uptimeMs: h.uptimeMs, nowMs: arrivalMs)

        // Another boot replaces this one only with an anchored message sent
        // after the newest one held, so a replay of an older boot cannot
        // wipe a newer one.
        if newBoot, !currentBoot.isEmpty {
            guard let send, send > newest else { throw AcceptError.notNewer }
        }
        guard h.seq > (newBoot ? 0 : seq[envelope.t, default: 0]) else { throw AcceptError.notNewer }

        if newBoot { reset(to: h.boot) }
        if lead { noRuleN = true }
        switch message {
        case .live(let l):
            live = l
            if let table = l.sources {
                sources = table
                srcRev = l.srcRev
                fieldSources = l.fieldSources ?? [:]
            }
            if send != nil {
                setM(Anchor(seq: h.seq, hb: false, boot: h.boot, wallSend: wall, uptimeMs: h.uptimeMs,
                            srcRev: l.srcRev, liveSeq: h.seq, lpSeq: 0, ages: l.ages))
            }
        case .lp(let p):
            lp = p
        case .prices(let p):
            prices = p
        case .hb(let b):
            hb = b
            if send != nil {
                setM(Anchor(seq: h.seq, hb: true, boot: h.boot, wallSend: wall, uptimeMs: h.uptimeMs,
                            srcRev: b.srcRev, liveSeq: b.liveSeq, lpSeq: b.lpSeq, ages: b.ages))
            }
        case .other:
            break
        }
        seq[envelope.t] = h.seq
        if let send, send > newest { newest = send }
    }

    /// The send time the phone trusts for one box message arriving at
    /// `arrivalMs`, or nil when neither rule anchors it. What an extension
    /// asks of an alert before it shows the event's own text.
    public func sentMs(_ header: CloudWire.Header, arrivalMs: Int64) -> Int64? {
        let off = Self.leads(header, arrivalMs: arrivalMs) || (header.boot == currentBoot && noRuleN)
        return sendTime(boot: header.boot, wall: Self.wallSend(header, arrivalMs: arrivalMs, off: off), uptimeMs: header.uptimeMs, nowMs: arrivalMs)
    }

    /// When the box sent M, by the phone clock, or nil while nothing
    /// anchored is held. The age on screen counts from here.
    public func anchorSentMs(nowMs: Int64) -> Int64? {
        guard let m else { return nil }
        return sendTime(boot: m.boot, wall: noRuleN ? nil : m.wallSend, uptimeMs: m.uptimeMs, nowMs: nowMs)
    }

    /// The protocol's state rules at `nowMs`. They can only make the box's
    /// own grades worse.
    public func grade(nowMs: Int64) -> Grades {
        var g = Grades()
        var t: Int64 = 0
        var anchor: Anchor?
        if let m, let send = anchorSentMs(nowMs: nowMs) {
            anchor = m
            t = max(0, nowMs &- send)
            if let u = ruleU(boot: m.boot, uptimeMs: m.uptimeMs, nowMs: nowMs), u == send, let off = offsets[m.boot] {
                t = t &+ (nowMs &- off.learnedAtMs) / Self.ruleUDriftDivisor
            }
            g.anchored = true
            g.ageMs = t
        }

        // 1. A table older than M names leaves every source stale until the
        //    new one arrives. 3 and 4. Otherwise each age moves on by t, and
        //    the worse of the box's grade and that one wins.
        let tableBehind = anchor.map { $0.srcRev > srcRev } ?? false
        for (id, s) in sources {
            var state = s.state
            if let anchor, !tableBehind {
                if let age = anchor.ages[id] { state = max(state, Self.ladder(ageMs: age &+ t, staleAfterMs: s.staleAfterMs)) }
            } else {
                state = max(state, .stale)
            }
            g.sources[id] = state
        }

        // 2. An hb that names a newer live or lp than the phone holds makes
        //    those values stale. 5. A field follows the worst of its sources;
        //    one with none is live while t ≤ 2H.
        if let live {
            let behind = anchor.map { $0.hb && $0.liveSeq > seq[CloudWire.msgLive, default: 0] } ?? true
            for f in live.fields.keys {
                var state = SourceState.live
                let srcs = fieldSources[f] ?? []
                if srcs.isEmpty, t > 2 * heartbeatMs { state = .stale }
                for s in srcs { state = max(state, g.sources[s] ?? .stale) }
                if behind { state = max(state, .stale) }
                g.fields[f] = state
            }
        }
        if let lp {
            let behind = anchor.map { $0.hb && $0.lpSeq > seq[CloudWire.msgLP, default: 0] } ?? true
            for l in lp.loadpoints {
                var state = g.sources[l.src] ?? .stale
                if behind { state = max(state, .stale) }
                g.loadpoints[l.id] = state
            }
        }
        return g
    }

    /// The next moment `grade` would change with no message arriving: a
    /// source's age passing S, 2S or 6S, a field with no source passing 2H,
    /// or rule U's anchor lapsing. Nil while nothing anchored is held. It may
    /// come a little early, never late, so a clock can wait for exactly this.
    public func nextGradeChange(nowMs: Int64) -> Int64? {
        guard let m, let send = anchorSentMs(nowMs: nowMs) else { return nil }
        var next: Int64?
        func consider(_ at: Int64) {
            if at > nowMs, next.map({ at < $0 }) ?? true { next = at }
        }
        // Rule U's margin makes ages run a little fast; starting the wait
        // that much sooner keeps the clock from passing a change.
        var drift: Int64 = 0
        if let u = ruleU(boot: m.boot, uptimeMs: m.uptimeMs, nowMs: nowMs), u == send, let off = offsets[m.boot] {
            drift = (nowMs &- off.learnedAtMs) / Self.ruleUDriftDivisor
            consider(off.learnedAtMs &+ Self.ruleULifetimeMs &+ 1)
        }
        for (id, s) in sources where s.staleAfterMs > 0 {
            guard let age = m.ages[id] else { continue }
            for k: Int64 in [1, 2, 6] { consider(send &+ k &* s.staleAfterMs &- age &+ 1 &- drift) }
        }
        consider(send &+ 2 &* heartbeatMs &+ 1 &- drift)
        return next
    }

    /// Grades an age the way the box grades its own sources.
    static func ladder(ageMs age: Int64, staleAfterMs s: Int64) -> SourceState {
        if s <= 0 { return .never }
        if age <= s { return .live }
        if age <= 2 &* s { return .lagging }
        if age <= 6 &* s { return .stale }
        return .down
    }

    // MARK: - Private

    private enum Message {
        case live(CloudWire.Live)
        case lp(CloudWire.LP)
        case prices(CloudWire.Prices)
        case hb(CloudWire.HB)
        /// Classes the view only orders by seq.
        case other(CloudWire.Header)

        init(t: String, b: Bytes) throws {
            switch t {
            case CloudWire.msgLive: self = .live(try CloudWire.Live(body: b))
            case CloudWire.msgLP: self = .lp(try CloudWire.LP(body: b))
            case CloudWire.msgPrices: self = .prices(try CloudWire.Prices(body: b))
            case CloudWire.msgHB: self = .hb(try CloudWire.HB(body: b))
            default: self = .other(try CloudWire.Header(body: b))
            }
        }

        var header: CloudWire.Header {
            switch self {
            case .live(let l): return l.header
            case .lp(let p): return p.header
            case .prices(let p): return p.header
            case .hb(let b): return b.header
            case .other(let h): return h
            }
        }
    }

    private mutating func setM(_ a: Anchor) {
        if m.map({ a.seq > $0.seq }) ?? true { m = a }
    }

    /// When the boot changes, the phone drops what it held and waits for
    /// that boot's full live.
    private mutating func reset(to boot: Bytes) {
        currentBoot = boot
        seq = [:]
        noRuleN = false
        sources = [:]
        srcRev = 0
        fieldSources = [:]
        live = nil
        lp = nil
        prices = nil
        hb = nil
        m = nil
    }

    /// A `wallMs` this far ahead of the phone turns rule N off for its boot.
    private static func leads(_ h: CloudWire.Header, arrivalMs: Int64) -> Bool {
        h.wallMs.map { $0 > arrivalMs &+ ruleNLeadMs } ?? false
    }

    /// Rule N: the earlier of `wallMs` and arrival, so a fast box clock
    /// cannot make data look fresher. Nil without a wall time, with rule N
    /// off, or before 1970, which Go's -1 sentinel also refuses.
    private static func wallSend(_ h: CloudWire.Header, arrivalMs: Int64, off: Bool) -> Int64? {
        guard let wallMs = h.wallMs, !off else { return nil }
        let send = min(wallMs, arrivalMs)
        return send >= 0 ? send : nil
    }

    /// The earlier of rule N and rule U, or nil when neither applies at
    /// `nowMs`.
    private func sendTime(boot: Bytes, wall: Int64?, uptimeMs: Int64, nowMs: Int64) -> Int64? {
        guard let u = ruleU(boot: boot, uptimeMs: uptimeMs, nowMs: nowMs) else { return wall }
        guard let wall else { return u }
        return min(wall, u)
    }

    private func ruleU(boot: Bytes, uptimeMs: Int64, nowMs: Int64) -> Int64? {
        guard let off = offsets[boot], nowMs &- off.learnedAtMs <= Self.ruleULifetimeMs else { return nil }
        return off.offsetMs &+ uptimeMs
    }
}
