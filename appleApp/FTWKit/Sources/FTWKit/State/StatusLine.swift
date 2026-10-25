import Foundation
import FTWShared

/// The mono line under Now's title: whether what is on screen is now, and
/// who controls the home. `● LIVE · FTW IN CONTROL`, `○ AS OF 14:05 · FTW IN
/// CONTROL`, `● LIVE · ▲ PAUSED · METER STALE`.
///
/// It never counts seconds. Live is a lit dot; anything else is a hollow
/// ring and the clock time of the oldest reading on screen, which holds
/// still. A mode change takes the second half of the line until the box has
/// answered, in the receipt log's words, then the line returns. Each part
/// is its own words, so a screen can keep the parts that stay and fade in
/// only the new one.
public struct StatusLine: Equatable, Sendable {
    public enum Dot: Equatable, Sendable { case lit, hollow }
    public enum Tone: Equatable, Sendable { case ink, live, alarm }

    public struct Part: Equatable, Sendable {
        public let text: String
        public let tone: Tone
        /// What stands between this part and the one before it: a dot, or
        /// a space between the steps of a receipt.
        public var joiner = " · "
    }

    /// Where a tap on the line leads.
    public enum Opens: Equatable, Sendable {
        /// The control sheet: the box's own answer to "Are we in control?".
        case control
        /// The box is out of reach: the same sheet, with what to do.
        case help
    }

    public let dot: Dot
    public let parts: [Part]
    public let opens: Opens

    /// The line as one string, for VoiceOver and a test.
    public var text: String {
        parts.enumerated().map { i, p in (i == 0 ? "" : p.joiner) + p.text }.joined() + (opens == .help ? " ›" : "")
    }

    // MARK: The facts it is made from

    /// How the readings reach this phone, as one word.
    public enum Reach: Equatable, Sendable {
        case live
        /// Connected, and what is on screen is not live: a quiet stream, a
        /// device that stopped, or a cache the box has not replaced yet.
        case settled
        case connecting
        case cantReach
        /// The phone itself has no network.
        case offline
        /// The relay serves as many phones as it can for this home.
        case busy
        case starting(Int?)
        case ended
        case demo
        /// The demo's simulated stream has gone quiet.
        case demoQuiet
    }

    /// Who runs the home, as the stream says it.
    public enum Control: Equatable, Sendable {
        case ftw
        /// A manual mode: FTW does not plan meanwhile.
        case you
        /// The box stopped dispatch because the site meter went quiet.
        case paused
        /// Devices the box reads stopped reporting.
        case quiet(Int)
        /// Nothing known yet.
        case unknown
    }

    /// How far the box has confirmed a mode change.
    public enum Receipt: Equatable, Sendable {
        case waiting, sent, accepted, confirmed, unconfirmed, refused
    }

    public struct Facts: Equatable, Sendable {
        public var reach: Reach
        public var control: Control
        public var receipt: Receipt?
        /// The oldest reading on screen, by the phone clock. Nil while live
        /// or before anything was read.
        public var asOfMs: Double?
        public var zone: TimeZone

        public init(reach: Reach, control: Control = .unknown, receipt: Receipt? = nil, asOfMs: Double? = nil, zone: TimeZone = .current) {
            self.reach = reach
            self.control = control
            self.receipt = receipt
            self.asOfMs = asOfMs
            self.zone = zone
        }
    }

    public static func make(_ f: Facts) -> StatusLine {
        var parts = [Part]()
        var dot = Dot.hollow
        var opens = Opens.control
        let asOf = f.asOfMs.map { ink(NodeWords.format("AS OF %@", AppWords.clock($0, zone: f.zone))) }
        // An old reading's time alone reads as now when it is a minute
        // old: where the rest of the line does not say what is wrong, it
        // says NOT LIVE first.
        let notLive = f.asOfMs == nil ? nil : ink(NodeWords.text("NOT LIVE"))
        // Whether the second half says who controls the home: only when the
        // first half is about the readings, not about reaching the box.
        var says = true
        switch f.reach {
        case .live:
            dot = .lit
            parts.append(ink(NodeWords.text("LIVE")))
        case .demo:
            dot = .lit
            parts.append(ink(NodeWords.text("DEMO")))
        case .demoQuiet:
            parts += [ink(NodeWords.text("DEMO")), notLive, asOf].compactMap { $0 }
            says = false
        case .settled:
            // Connected with nothing read yet is still connecting.
            if let asOf, let notLive { parts += [notLive, asOf] } else {
                parts.append(ink(NodeWords.text("CONNECTING…")))
                says = false
            }
        case .connecting:
            // With a cache on screen, the cache is the news; the handshake
            // is normal and needs no word.
            if let asOf, let notLive { parts += [notLive, asOf] } else {
                parts.append(ink(NodeWords.text("CONNECTING…")))
                says = false
            }
        case .cantReach:
            parts += [asOf, ink(NodeWords.text("CAN'T REACH THE BOX"))].compactMap { $0 }
            opens = .help
            says = false
        case .offline:
            parts += [asOf, ink(NodeWords.text("PHONE OFFLINE"))].compactMap { $0 }
            says = false
        case .busy:
            parts += [asOf, ink(NodeWords.text("FTW BUSY"))].compactMap { $0 }
            says = false
        case .starting(let pct):
            parts.append(ink(NodeWords.text("BOX STARTING")))
            if let pct { parts.append(ink(AppWords.percent(Double(pct)))) }
            says = false
        case .ended:
            parts.append(ink(NodeWords.text("ACCESS ENDED")))
            says = false
        }
        if let receipt = f.receipt, f.reach != .ended {
            parts += Self.receipt(receipt)
        } else if f.reach == .demo {
            parts.append(ink(NodeWords.text("SIMULATED HOME")))
        } else if says {
            parts += control(f.control)
        }
        return StatusLine(dot: dot, parts: parts, opens: opens)
    }

    static func control(_ c: Control) -> [Part] {
        switch c {
        case .ftw: return [ink(NodeWords.text("FTW IN CONTROL"))]
        case .you: return [ink(NodeWords.text("YOU'RE IN CONTROL"))]
        case .paused: return [alarm(NodeWords.text("▲ PAUSED")), alarm(NodeWords.text("METER STALE"))]
        case .quiet(let n): return [alarm(n == 1 ? NodeWords.text("▲ 1 DEVICE QUIET") : NodeWords.format("▲ %@ DEVICES QUIET", String(n)))]
        case .unknown: return []
        }
    }

    /// The receipt in the receipt log's own words, a part per step, so a
    /// step that stays keeps its place: `SENT ▸`, then `SENT ▸ ACCEPTED ▸`,
    /// then `SENT ▸ CONFIRMED`.
    static func receipt(_ r: Receipt) -> [Part] {
        let sent = ink(ReceiptLog.word(.sent) + " ▸")
        switch r {
        case .waiting: return [ink(NodeWords.text("SENDING…"))]
        case .sent: return [sent]
        case .accepted: return [sent, Part(text: ReceiptLog.word(.accepted) + " ▸", tone: .ink, joiner: " ")]
        case .confirmed: return [sent, Part(text: ReceiptLog.word(.confirmed), tone: .live, joiner: " ")]
        case .unconfirmed: return [alarm(NodeWords.text("▲ NOT CONFIRMED"))]
        case .refused: return [alarm("▲ " + ReceiptLog.refusedWord)]
        }
    }

    private static func ink(_ s: String) -> Part { Part(text: s, tone: .ink) }
    private static func alarm(_ s: String) -> Part { Part(text: s, tone: .alarm) }
}

extension StatusLine {
    /// The line for a home as the app has it now.
    ///
    /// - online: the phone has a network at all.
    /// - noCarrier: the app gave up connecting and holds a sentence of help.
    @MainActor
    public static func facts(site: SiteModel, mode: ModeModel, demo: Bool, online: Bool, noCarrier: Bool, receipt: Receipt?) -> Facts {
        let s = site.session
        let reach: Reach
        if demo {
            // Lit while the simulated stream runs, hollow once it has gone
            // quiet.
            let quiet = !site.isLive && [.lagging, .stale, .down].contains(site.srcState)
            reach = s.phase == .streaming ? (quiet ? .demoQuiet : .demo) : .connecting
        } else if s.phase == .terminated {
            reach = .ended
        } else if s.phase == .booting {
            reach = .starting(s.boot?.pct)
        } else if site.isLive {
            reach = .live
        } else {
            switch site.freshness(noCarrier: noCarrier).tone {
            case .live, .stale: reach = .settled
            case .reaching: reach = .connecting
            case .lost: reach = online ? .cantReach : .offline
            case .busy: reach = .busy
            }
        }
        var asOf: Double?
        if reach != .live, reach != .demo, !s.fields.isEmpty {
            // The oldest reading on screen, which holds still while the
            // clock moves: a cache's age grows with the clock.
            if let age = site.ageMs, age.isFinite {
                asOf = site.nowMs - age
            } else {
                asOf = site.readingAtMs ?? site.cachedAtMs
            }
        }
        return Facts(reach: reach, control: control(site: site, mode: mode), receipt: receipt, asOfMs: asOf, zone: site.householdZone)
    }

    @MainActor
    static func control(site: SiteModel, mode: ModeModel) -> Control {
        let s = site.session
        guard !s.fields.isEmpty || site.heardFromBox else { return .unknown }
        if !s.dispatchBlockedBy.isEmpty { return .paused }
        let quiet = s.sources.values.filter { $0.state == .stale || $0.state == .down }.count
        if quiet > 0 { return .quiet(quiet) }
        if let actual = mode.actual, !ModeWords.isPlan(actual) { return .you }
        return .ftw
    }

    /// How long an answer from the box holds the line before the line
    /// returns.
    public static let receiptShownMs: Double = 4_000

    /// How far the box has confirmed the last mode change: while it is on
    /// its way, and for a moment after the box answered. Nil when there is
    /// none or something else replaced it.
    @MainActor
    public static func receipt(_ mode: ModeModel, nowMs: Double) -> Receipt? {
        guard let change = mode.change else { return nil }
        if let at = change.settledAtMs, nowMs - at >= receiptShownMs { return nil }
        switch change.result {
        case nil: return change.waiting ? .waiting : (change.acked ? .accepted : .sent)
        case .applied?: return .confirmed
        case .unconfirmed?: return .unconfirmed
        case .refused?: return .refused
        case .superseded?: return nil
        }
    }
}
