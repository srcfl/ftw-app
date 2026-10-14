import Foundation
import FTWShared
import Observation

/// What the phone hands its Apple Watch, and how it runs what the watch
/// asks for. The watch reaches the box only through this phone: it can
/// open no relay and holds no key.
///
/// The records are the ones the widgets read, built from the same models
/// with the same dating: each says where it came from and when, so a watch
/// can show its age and never call it live. The demo builds them too, so
/// the watch shows the simulated home while the phone does.
@MainActor
public enum WatchShare {
    // MARK: What the watch shows

    public static func context(_ home: HomeModels?, isDemo: Bool, receipt: WatchReceipt? = nil, nowMs: Double) -> WatchContext {
        guard let home else { return .empty(sentAtMs: nowMs) }
        let key = homeKey(home)
        return WatchContext(
            home: key,
            isDemo: isDemo,
            prices: prices(home, key: key),
            cars: cars(home, key: key, nowMs: nowMs),
            plan: plan(home, key: key, nowMs: nowMs),
            now: now(home, key: key),
            modes: modes(home),
            receipt: receipt,
            sentAtMs: nowMs
        )
    }

    /// The models the watch's pages show, read as if a screen showing them
    /// had appeared: the prices, the chargers, the plan and the mode. Call
    /// the returned closure when the watch looks away.
    public static func looking(_ home: HomeModels) -> @MainActor () -> Void {
        let (prices, chargers, plan, mode) = (home.prices, home.loadpoints, home.nodes.plan, home.nodes.mode)
        prices.activate()
        chargers.activate()
        plan.activate()
        mode.activate()
        return {
            prices.deactivate()
            chargers.deactivate()
            plan.deactivate()
            mode.deactivate()
        }
    }

    /// The site, or the demo's own key, as a command from the watch names
    /// it.
    public static func homeKey(_ home: HomeModels) -> String { home.site.siteId ?? "demo" }

    static func carrier(_ origin: StampOrigin, site: SiteModel) -> CarrierKind {
        switch origin {
        case .cache: return .cache
        case .cloud: return .cloud
        case .relay: return site.carrier == .webrtc ? .webrtc : .relay
        }
    }

    static func prices(_ home: HomeModels, key: String) -> CacheRecord<PriceEntry>? {
        guard let w = home.prices.window else { return nil }
        return CacheRecord(siteId: key, carrier: carrier(w.origin, site: home.site), srcState: w.value.prices.stale ? .stale : .live, readAtMs: w.asOfMs, value: w.value)
    }

    static func cars(_ home: HomeModels, key: String, nowMs: Double) -> CacheRecord<CarEntry>? {
        let lps = home.loadpoints
        guard let stamp = lps.stamp else { return nil }
        let entry = CarEntry(cars: stamp.value.map { lp in
            CarEntry.Car(
                loadpointID: lp.id,
                pluggedIn: lp.pluggedIn,
                socPct: lps.level(lp)?.pct ?? lp.socPct,
                socSource: lp.socSource,
                socReadAtMs: lp.socReadAtMs(answeredAtMs: stamp.asOfMs),
                powerW: lp.powerW,
                targetSocPct: lp.targetSocPct,
                holding: LoadpointsModel.holding(lp)
            )
        })
        let answering = !lps.stale && stamp.value.allSatisfy { $0.charger?.available != false }
        return CacheRecord(siteId: key, carrier: carrier(stamp.origin, site: home.site), srcState: answering ? .live : .stale, readAtMs: stamp.asOfMs, value: entry)
    }

    static func plan(_ home: HomeModels, key: String, nowMs: Double) -> CacheRecord<PlanEntry>? {
        let model = home.nodes.plan
        guard let stamped = model.stamped else { return nil }
        let entry = home.nodes.planShare.entry.trimmed(nowMs: nowMs)
        let sent = stamped.fromCache ? stamped.asOfMs : (model.receivedAtMs ?? stamped.asOfMs)
        return CacheRecord(siteId: key, carrier: carrier(stamped.origin, site: home.site), srcState: entry.boxStale ? .stale : .live, readAtMs: sent, value: entry)
    }

    /// Now's figures as the phone holds them. Nil before anything was read.
    public static func now(_ home: HomeModels, key: String? = nil) -> CacheRecord<WatchNow>? {
        let site = home.site
        guard let at = site.readingAtMs ?? site.lastFrameAtMs ?? site.cachedAtMs else { return nil }
        let readings = NowFlow.readings(site: site, loadpoints: home.loadpoints).map(reading)
        let answer = InControl.answer(streaming: site.isLive, lastKnownMs: nil, dispatchBlockedBy: site.session.dispatchBlockedBy, sources: site.session.sources)
        let control: WatchNow.Control
        switch answer.tone {
        case .ok: control = .inControl
        case .warning: control = .notInControl
        case .neutral, .stale: control = .unknown
        }
        return CacheRecord(siteId: key ?? homeKey(home), carrier: site.carrier, srcState: site.isLive ? .live : .stale, readAtMs: at, value: WatchNow(readings: readings, control: control))
    }

    static func reading(_ r: NodeReading) -> WatchNow.Reading {
        let way: WatchNow.Way
        switch r.node {
        case _ where r.watts == nil: way = .noReading
        case .solar: way = r.flowing ? .making : .resting
        case .battery: way = !r.flowing ? .resting : (r.towardHome ? .giving : .charging)
        case .home: way = .using
        case .grid: way = !r.flowing ? .balanced : (r.towardHome ? .buying : .selling)
        case .car: way = r.flowing ? .charging : .resting
        }
        let node: WatchNow.Node
        switch r.node {
        case .solar: node = .solar
        case .battery: node = .battery
        case .home: node = .home
        case .grid: node = .grid
        case .car: node = .car
        }
        return WatchNow.Reading(node: node, watts: r.watts, way: way, levelPct: r.levelPct, levelAssumed: r.levelAssumed, live: r.freshness.live)
    }

    static func modes(_ home: HomeModels) -> WatchModes? {
        let mode = home.nodes.mode
        guard !mode.modes.isEmpty else { return nil }
        return WatchModes(
            modes: mode.modes.map { WatchModes.Mode(key: $0.key, name: ModeWords.name($0), isPlan: ModeWords.isPlan($0.key)) },
            shown: mode.actual,
            label: mode.label,
            mayControl: mode.mayControl
        )
    }

    // MARK: Commands

    /// How long a command from the watch waits for the session to stream.
    /// The app may have been woken for it with no session open.
    public static let streamWaitMs: Double = LoadpointsModel.remoteStreamWaitMs

    /// Run one command from the watch on `home`, telling `step` each time
    /// the box answers. Returns the last receipt. Every mark comes from the
    /// phone's own receipt for the command, so CONFIRMED means the box's
    /// `cmd.result` said applied.
    public static func run(_ c: WatchCommand, home: HomeModels, nowMs: Double, step: @escaping @MainActor (WatchReceipt) -> Void) async -> WatchReceipt {
        func refused(_ text: String) -> WatchReceipt {
            WatchReceipt(commandID: c.id, op: c.op, sent: .failed, accepted: .waiting, confirmed: .waiting, text: text, tone: .failed)
        }
        guard c.home == homeKey(home) else { return refused(WatchWord.otherHome.text) }
        guard WatchCommand.isID(c.id) else { return refused(AppWords.text("That did not go through. Try again.")) }
        guard nowMs <= c.notValidAfterMs else { return refused(WatchWord.tooLate.text) }

        let lps = home.loadpoints
        switch c.op {
        case .chargeNow(let id), .backToPlan(let id), .pause(let id):
            // The car's receipt may still show the last command; this one's
            // starts when the step changes.
            let since = Since(lps.holdStep[id])
            let follower = Follower(read: {
                guard let s = since.fresh(lps.holdStep[id]) else { return nil }
                return receipt(EVText.outcome(s, lps.points.first { $0.id == id }), c)
            }, step: step)
            defer { follower.stop() }
            let out: RemoteOutcome
            switch c.op {
            case .chargeNow: out = await lps.perform(.chargeNow, loadpointID: id, waitMs: streamWaitMs, cmdId: c.id)
            case .backToPlan: out = await lps.perform(.backToPlan(loadpointID: id, home: nil), loadpointID: id, waitMs: streamWaitMs, cmdId: c.id)
            default: out = await pause(id, lps, cmdId: c.id)
            }
            // The step on the car's receipt is this command's only if it
            // was sent; a refusal before sending has none.
            if let step = lps.holdStep[id], step.ask == ask(c.op), follower.saw {
                return receipt(EVText.outcome(step, lps.points.first { $0.id == id }), c)
            }
            return out.kind == .failed ? refused(out.text) : WatchReceipt(commandID: c.id, op: c.op, sent: .done, accepted: .done, confirmed: out.kind == .done ? .done : .waiting, text: out.text, tone: out.kind == .done ? .done : .warning)

        case .mode(let key):
            let mode = home.nodes.mode
            guard mode.mayControl else { return refused(WatchWord.cannotChangeMode.text) }
            guard await streaming(home.site, within: streamWaitMs) else {
                return refused(AppWords.text("Not connected to FTW right now. Try again when the connection is back."))
            }
            if mode.actual == key {
                // The box already reports it: its own word, not a command's.
                return WatchReceipt(commandID: c.id, op: c.op, sent: .waiting, accepted: .waiting, confirmed: .done, text: mode.label ?? ModeWords.name(mode.info(key)), tone: .done)
            }
            let since = Since(mode.change)
            let follower = Follower(read: {
                guard let change = since.fresh(mode.change), change.ask == .mode(key), let o = mode.outcome else { return nil }
                return receipt(o, c)
            }, step: step)
            defer { follower.stop() }
            await mode.set(key, cmdId: c.id)
            guard let o = mode.outcome, mode.change?.ask == .mode(key) else {
                return refused(AppWords.text("That did not go through. Try again."))
            }
            return receipt(o, c)
        }
    }

    /// Pause, with the same checks Charge now gets on its way in: a stream,
    /// a box that takes commands, and a charger that exists.
    private static func pause(_ id: String, _ lps: LoadpointsModel, cmdId: String) async -> RemoteOutcome {
        guard await lps.refreshForAnswer(waitMs: streamWaitMs) else {
            return RemoteOutcome(.failed, AppWords.text("Not connected to FTW right now. Try again when the connection is back."))
        }
        guard let lp = lps.points.first(where: { $0.id == id }) else {
            return RemoteOutcome(.failed, LoadpointsModel.say("FTW has no charger to control."))
        }
        guard !lps.holdSending(lp) else {
            return RemoteOutcome(.failed, LoadpointsModel.say("FTW is still busy with your last command. Try again in a moment."))
        }
        await lps.pause(lp, cmdId: cmdId)
        return RemoteOutcome(.pending, "")
    }

    static func ask(_ op: WatchCommand.Op) -> EVText.Step.Ask? {
        switch op {
        case .chargeNow: return .chargeNow
        case .pause: return .pause
        case .backToPlan: return .resume
        case .mode: return nil
        }
    }

    /// The phone's receipt for a command, mark for mark.
    static func receipt(_ o: EVText.Outcome, _ c: WatchCommand) -> WatchReceipt {
        func mark(_ m: EVText.Outcome.Mark) -> WatchReceipt.Mark {
            switch m {
            case .done: return .done
            case .active: return .active
            case .waiting: return .waiting
            case .failed: return .failed
            }
        }
        let tone: WatchReceipt.Tone
        switch o.tone {
        case .working: tone = .working
        case .done: tone = .done
        case .warning: tone = .warning
        case .failed: tone = .failed
        }
        return WatchReceipt(commandID: c.id, op: c.op, sent: mark(o.sent), accepted: mark(o.received), confirmed: mark(o.done), text: o.text, tone: tone)
    }

    /// True once the session streams, false if it has not within `ms`.
    static func streaming(_ site: SiteModel, within ms: Double) async -> Bool {
        if site.session.phase == .streaming { return true }
        let wait = StreamWait()
        let ok = await withCheckedContinuation { cont in
            wait.continuation = cont
            wait.token = site.observe { [weak site, wait] in
                if site?.session.phase == .streaming { wait.settle(true) }
            }
            wait.timer = site.scheduler.after(ms) { [wait] in wait.settle(false) }
        }
        if let token = wait.token { site.unobserve(token) }
        return ok
    }
}

/// Passes each new receipt a model holds to `step`, from Observation,
/// until stopped. No timer: it runs when the model changes.
@MainActor
private final class Follower {
    private let read: @MainActor () -> WatchReceipt?
    private let step: @MainActor (WatchReceipt) -> Void
    private var last: WatchReceipt?
    private var stopped = false
    /// Whether it saw a receipt of this command at all.
    private(set) var saw = false

    init(read: @escaping @MainActor () -> WatchReceipt?, step: @escaping @MainActor (WatchReceipt) -> Void) {
        self.read = read
        self.step = step
        arm()
    }

    func stop() { stopped = true }

    private func arm() {
        guard !stopped else { return }
        let next = withObservationTracking { read() } onChange: { [weak self] in
            Task { @MainActor in self?.arm() }
        }
        guard let next, next != last else { return }
        last = next
        saw = true
        step(next)
    }
}

/// A value as it was when a command started. It counts as this command's
/// once it has changed, and from then on whatever it becomes.
@MainActor
private final class Since<Value: Equatable> {
    private let before: Value?
    private var moved = false

    init(_ before: Value?) {
        self.before = before
    }

    func fresh(_ now: Value?) -> Value? {
        if !moved {
            guard now != before else { return nil }
            moved = true
        }
        return now
    }
}

@MainActor
private final class StreamWait {
    var continuation: CheckedContinuation<Bool, Never>?
    var token: Int?
    var timer: Cancellable?

    func settle(_ ok: Bool) {
        timer?.cancel()
        continuation?.resume(returning: ok)
        continuation = nil
    }
}
