import Foundation
import FTWShared
import Observation

/// How the home is run, and changing it. The box reports its mode on lane 0
/// (field 1, an index into the catalogue it sent at hello), so the mode on
/// screen needs no request. The planning style and whether the battery may
/// sell are the household's planner preferences, read once with
/// `GET /api/planner/prefs`.
///
/// A change is a command (`site.mode.set` or `planner.prefs.set`), followed
/// from tap to outcome. The screen shows the choice while it is on its way,
/// and what the box reports once it has answered: a refusal snaps back, and
/// a change the box never confirmed shows the box's mode with a warning,
/// because nothing here overrides what the box said.
@Observable
@MainActor
public final class ModeModel {
    /// The household's planning styles, as Core's web/plan-prefs.js names
    /// them: how much margin the planner leaves against the forecast.
    public struct Style: Equatable, Sendable, Identifiable {
        public let key: String
        public let name: String
        public let k: Double
        public let help: String
        public var id: String { key }
    }

    public nonisolated static let styles: [Style] = [
        Style(key: "very_careful", name: "Very careful", k: 1, help: "Plans for a poor day: much less sun and more use than forecast. Keeps the most in the battery."),
        Style(key: "careful", name: "Careful", k: 0.6, help: "Plans for less sun and more use than forecast."),
        Style(key: "balanced", name: "Balanced", k: 0.3, help: "Plans for a little less sun and a little more use than forecast. A good start for most homes."),
        Style(key: "bold", name: "Bold", k: 0.15, help: "Plans close to the forecast."),
        Style(key: "very_bold", name: "Very bold", k: 0, help: "Plans on the forecast as it is. Earns the most when it is right and costs more when it is wrong."),
    ]

    /// The style nearest a margin, the way the box page picks one.
    public nonisolated static func style(k: Double) -> Style {
        styles.min { abs($0.k - k) < abs($1.k - k) } ?? styles[2]
    }

    /// What "Use the plan" asks for when the box has not said: the
    /// registry's first primary planner mode, never a name written here.
    public nonisolated static let planFallback = Contract.modes.first { $0.tier == "primary" && $0.key.hasPrefix("planner_") }?.key ?? Contract.modes[0].key

    /// The planner preferences as the box answered them.
    public struct Prefs: Equatable, Sendable, Codable {
        public var safetyK: Double
        /// "allowed", "not_allowed" or "unknown".
        public var batteryExport: String
        /// The planner mode the box maps these onto.
        public var mappedMode: String
    }

    public enum Ask: Equatable, Sendable {
        case mode(String)
        case style(Double)
        case export(Bool)
    }

    /// One change, followed: sent, received (`cmd.ack`), and what the box did.
    public struct Change: Equatable, Sendable {
        public enum Result: Equatable, Sendable {
            case applied
            /// Something else changed it first.
            case superseded
            /// Taken, never confirmed. Not a failure and not a success.
            case unconfirmed
            /// Refused, or never arrived. The reason is ready to show.
            case refused(String)
        }

        public let ask: Ask
        /// Held until the session streams, so nothing is sent into a gap.
        public var waiting = false
        public var acked = false
        public var result: Result?
        /// The box's last report when the result came: an applied change
        /// stands until the box reports again, so the screen does not flick
        /// back to the old value in between.
        var reportAtResult: Double?

        public var settled: Bool { result != nil }
    }

    /// How long a confirmed change keeps its receipt on screen.
    nonisolated static let doneShownMs: Double = 8_000

    public private(set) var change: Change?
    /// The planner preferences on screen: the box's answer, or what an
    /// earlier launch kept until the box answers. The same again changes
    /// nothing.
    public private(set) var prefsStamp: Stamped<Prefs>?
    public var prefs: Prefs? { prefsStamp?.value }
    /// When the prefs were last read, so an applied style or sale stands
    /// until the box has been asked again.
    @ObservationIgnored private var prefsReadAtMs: Double?

    /// Runs after the box applied a change, so the plan can be read again.
    @ObservationIgnored public var applied: (@MainActor () -> Void)?
    @ObservationIgnored private unowned let site: SiteModel
    @ObservationIgnored private var clearing: Cancellable?
    @ObservationIgnored private var ask: LiveAsk?
    @ObservationIgnored private var active = 0
    @ObservationIgnored private var want = 0

    public init(site: SiteModel) {
        self.site = site
        prefsStamp = site.kept?.prefs?.cached
        site.keep { [weak self] home in home.prefs = self?.prefsStamp }
    }

    public func activate() {
        active += 1
        if ask == nil {
            ask = LiveAsk(site: site, want: { [weak self] in
                guard let self, self.active > 0, self.site.hasPassthrough else { return nil }
                return "prefs \(self.want)"
            }, ask: { [weak self] in try await self?.loadPrefs() })
        }
        ask?.evaluate()
    }

    public func deactivate() {
        active = max(0, active - 1)
        ask?.evaluate()
    }

    func loadPrefs() async throws {
        let wire = try await site.callBox(.get, "/api/planner/prefs")
        let next = Stamped(Self.prefs(wire), asOfMs: site.scheduler.nowMs, origin: .relay)
        if let taken = Stamped.taking(next, over: prefsStamp) { prefsStamp = taken }
        prefsReadAtMs = site.scheduler.nowMs
    }

    static func prefs(_ wire: JSON?) -> Prefs {
        let k = wire?["safety_k"]?.number ?? wire?["mapped_k"]?.number ?? Self.styles[2].k
        let export = wire?["battery_export"]?.string.flatMap { ["allowed", "not_allowed", "unknown"].contains($0) ? $0 : nil } ?? "unknown"
        let mapped = wire?["mapped_mode"]?.string.flatMap { $0.hasPrefix("planner_") ? $0 : nil } ?? planFallback
        return Prefs(safetyK: min(2, max(0, k.isFinite ? k : 0.3)), batteryExport: export, mappedMode: mapped)
    }

    // MARK: What the screen shows

    /// Every mode the box offers, in its order. Hidden ones are valid over
    /// the API but never choices.
    public var modes: [ModeInfo] { site.session.modes.filter { $0.tier != "hidden" } }
    /// The manual fallbacks: every mode the planner does not drive.
    public var manualModes: [ModeInfo] { modes.filter { !ModeWords.isPlan($0.key) } }

    /// The mode the box reports, which is the only one that counts.
    public var actual: String? {
        guard let i = site.session.fields[Contract.FID.mode].map({ Int($0) }), i >= 0, i < site.session.modes.count else { return nil }
        return site.session.modes[i].key
    }

    /// The choice while it is on its way, else what the box reports.
    public var shown: String? {
        if let change, standing(change), case .mode(let m) = change.ask { return m }
        return actual
    }

    public var shownStyle: Style? {
        if let change, standing(change), case .style(let k) = change.ask { return Self.style(k: k) }
        return prefs.map { Self.style(k: $0.safetyK) }
    }

    public var shownExport: Bool? {
        if let change, standing(change), case .export(let on) = change.ask { return on }
        guard let e = prefs?.batteryExport, e != "unknown" else { return nil }
        return e == "allowed"
    }

    /// A choice stands while it is on its way, and once applied until the
    /// box reports again. Any other answer leaves what the box reports.
    private func standing(_ change: Change) -> Bool {
        switch change.result {
        case nil: return true
        case .applied?:
            if case .mode = change.ask { return site.lastFrameAtMs == change.reportAtResult }
            return prefsReadAtMs == change.reportAtResult
        default: return false
        }
    }

    /// The mode asked for while it is on its way, for the row that waits.
    public var pending: String? {
        guard let change, change.result == nil, case .mode(let m) = change.ask else { return nil }
        return m
    }

    /// A change the box took and never confirmed, while what it reports
    /// still differs: "Asked for Idle. Your box has not confirmed it."
    public var doubt: String? {
        guard let change, change.result == .unconfirmed else { return nil }
        let name: String
        switch change.ask {
        case .mode(let m):
            guard actual != m else { return nil }
            name = ModeWords.name(info(m))
        case .style(let k):
            let style = Self.style(k: k)
            guard shownStyle != style else { return nil }
            name = NodeWords.text(style.name)
        case .export(let on):
            guard shownExport != on else { return nil }
            name = NodeWords.text(on ? "selling to the grid" : "not selling to the grid")
        }
        return NodeWords.format("Asked for %@. Your box has not confirmed it.", name)
    }

    /// Whether a change can go now: commands travel only on a streaming
    /// session.
    public var connected: Bool {
        site.session.phase == .streaming && site.carrier != .cache
    }

    public func info(_ key: String?) -> ModeInfo? {
        key.flatMap { k in site.session.modes.first { $0.key == k } }
    }

    /// The label on Now: "Plan · Balanced", or a manual mode's name.
    public var label: String? {
        guard let key = shown else { return nil }
        if ModeWords.isPlan(key), let style = shownStyle {
            return "\(NodeWords.text("Plan")) · \(NodeWords.text(style.name))"
        }
        return ModeWords.name(info(key))
    }

    /// Both must hold: the box offers dispatch, and this phone's grant
    /// carries the scope the box checks. A control a viewer would be refused
    /// is not drawn at all. From caps kept at an earlier launch this draws
    /// the control in its place; `canControl` says whether it works yet.
    public var mayControl: Bool {
        site.session.caps.contains(Contract.capPlanDispatch) && site.session.scopes.contains(Contract.scopeModeWrite)
    }

    /// A control works only once the box has spoken in this session: caps
    /// kept from an earlier launch never send a command.
    public var canControl: Bool { site.heardFromBox && mayControl }

    public var sending: Bool { change.map { !$0.settled } ?? false }

    // MARK: Changing it

    /// Run a mode. The tap shows at once; the box decides.
    public func set(_ mode: String, cmdId: String? = nil) async {
        guard mode != shown else { return }
        await send(.mode(mode), op: Contract.opSetMode, args: [("mode", .text(mode))], cmdId: cmdId)
    }

    /// Back from a manual mode to the plan the household chose.
    public func usePlan() async {
        await set(prefs?.mappedMode ?? Self.planFallback)
    }

    public func setStyle(_ style: Style) async {
        guard style != shownStyle else { return }
        await send(.style(style.k), op: Contract.opPlannerPrefsSet, args: [("safety_k", .number(style.k))])
    }

    public func setExport(_ allowed: Bool) async {
        guard allowed != shownExport else { return }
        await send(.export(allowed), op: Contract.opPlannerPrefsSet, args: [("battery_export", .text(allowed ? "allowed" : "not_allowed"))])
    }

    /// How long a tap waits for the stream before it gives up.
    nonisolated static let streamWaitMs: Double = 3_000

    private func send(_ ask: Ask, op: String, args: [(String, CBOR)], cmdId: String? = nil) async {
        guard !sending else { return }
        clearing?.cancel()
        change = Change(ask: ask)
        if !connected {
            change?.waiting = true
            let up = await stream(within: Self.streamWaitMs)
            guard change?.ask == ask else { return }
            change?.waiting = false
            guard up else {
                change?.result = .refused(NodeWords.text("Not connected to your box right now. Try again when the connection is back."))
                return
            }
        }
        let result: Change.Result
        do {
            let r = try await site.core.command(op, args: args, onAck: { [weak self] in
                guard let self, self.change?.ask == ask else { return }
                self.change?.acked = true
            }, cmdId: cmdId)
            switch r.state {
            case .applied: result = .applied
            case .superseded: result = .superseded
            case .unconfirmed: result = .unconfirmed
            case .rejected, .expired: result = .refused(Self.refusal(r))
            }
            change?.acked = true
        } catch {
            result = .refused(Self.failure(error))
        }
        guard change?.ask == ask else { return }
        if case .mode = ask {
            change?.reportAtResult = site.lastFrameAtMs
        } else {
            change?.reportAtResult = prefsReadAtMs
        }
        change?.result = result
        // The prefs move the mode too, so both are read again, after any
        // answer the box gave: what it holds now is what shows.
        if case .mode = ask {} else { want += 1; self.ask?.evaluate() }
        guard result == .applied else { return }
        applied?()
        clearing = site.scheduler.after(Self.doneShownMs) { [weak self] in
            guard let self, self.change?.ask == ask, self.change?.result == .applied else { return }
            self.change = nil
        }
    }

    /// The receipt as the car view draws one: three marks and a sentence.
    public var outcome: EVText.Outcome? {
        guard let change else { return nil }
        switch change.result {
        case nil where change.waiting:
            return EVText.Outcome(sent: .active, received: .waiting, done: .waiting, text: NodeWords.text("Waiting for the connection…"), tone: .working)
        case nil:
            return EVText.Outcome(
                sent: .done, received: change.acked ? .done : .active, done: change.acked ? .active : .waiting,
                text: working(change),
                tone: .working
            )
        case .applied?:
            return EVText.Outcome(sent: .done, received: .done, done: .done, text: done(change.ask), tone: .done)
        case .superseded?:
            return EVText.Outcome(sent: .done, received: .done, done: .failed, text: NodeWords.text("Something else changed the mode first. Have a look and try again."), tone: .warning)
        case .unconfirmed? where doubt == nil:
            // The box shows what was asked after all.
            return EVText.Outcome(sent: .done, received: .done, done: .done, text: done(change.ask), tone: .done)
        case .unconfirmed?:
            return EVText.Outcome(sent: .done, received: .done, done: .waiting, text: NodeWords.text("Your box took it but has not confirmed it yet."), tone: .warning)
        case .refused(let why)?:
            return EVText.Outcome(sent: .done, received: change.acked ? .done : .failed, done: .failed, text: why, tone: .failed)
        }
    }

    private func working(_ change: Change) -> String {
        if case .mode(let key) = change.ask {
            let name = ModeWords.name(info(key))
            return change.acked ? NodeWords.format("Your box has it. Switching to %@…", name) : NodeWords.format("Sending %@ to your box…", name)
        }
        return change.acked ? NodeWords.text("Your box has it. Planning again…") : NodeWords.text("Sending to your box…")
    }

    private func done(_ ask: Ask) -> String {
        switch ask {
        case .mode(let key): return NodeWords.format("Your box now runs %@.", ModeWords.name(info(key)))
        case .style(let k): return NodeWords.format("The planning style is now %@.", NodeWords.text(Self.style(k: k).name))
        case .export(let on): return NodeWords.text(on ? "The battery may now sell when it pays." : "The battery no longer sells to the grid.")
        }
    }

    static func refusal(_ r: CmdResult) -> String {
        if r.state == .expired { return NodeWords.text("That took too long to reach your box. Try again.") }
        switch r.errorCode {
        case "E_PRECONDITION", "E_CONFLICT": return NodeWords.text("Something changed at home while this was sending. Try again.")
        case "E_SCOPE_DENIED", "E_GRANT_REVOKED": return NodeWords.text("Only the home's owner can change how it runs.")
        case "E_CMD_EXPIRED": return NodeWords.text("That took too long to reach your box. Try again.")
        case "E_BOOTING": return NodeWords.text("Your box is starting. Give it a minute.")
        case "E_UNKNOWN_OP": return NodeWords.text("Your box cannot do this yet. It may need an update.")
        default: return NodeWords.text("Your box did not change the mode. Nothing else changed.")
        }
    }

    static func failure(_ error: Error) -> String {
        if let e = error as? CommandError, e.code == "E_NO_ACK" { return NodeWords.text("That did not reach your box. Try again.") }
        if error is SessionError { return NodeWords.text("Not connected to your box right now. Try again when the connection is back.") }
        return NodeWords.text("That did not go through. Try again.")
    }
}

extension ModeModel {
    /// True once the session streams, false if it has not within `ms`.
    fileprivate func stream(within ms: Double) async -> Bool {
        if connected { return true }
        let wait = ModeStreamWait()
        let up = await withCheckedContinuation { cont in
            wait.continuation = cont
            wait.token = site.observe { [weak self, wait] in
                if self?.connected == true { wait.settle(true) }
            }
            wait.timer = site.scheduler.after(ms) { [wait] in wait.settle(false) }
        }
        if let token = wait.token { site.unobserve(token) }
        return up
    }
}

/// One wait for the stream, settled once.
@MainActor
private final class ModeStreamWait {
    var continuation: CheckedContinuation<Bool, Never>?
    var token: Int?
    var timer: Cancellable?

    func settle(_ up: Bool) {
        guard let cont = continuation else { return }
        continuation = nil
        timer?.cancel()
        cont.resume(returning: up)
    }
}
