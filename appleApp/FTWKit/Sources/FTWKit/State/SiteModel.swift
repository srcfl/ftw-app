import Foundation
import FTWShared
import Observation
import os

private let log = Logger(subsystem: "energy.ftw.app", category: "widgets")

/// The bridge between the session and the screens.
///
/// The session owns protocol state; this exposes it, restores the cached
/// snapshot on start, keeps freshness honest and derives what the screens
/// ask for. Nothing above this touches a frame.
@Observable
@MainActor
public final class SiteModel {
    /// Fields the Now screen draws. Their sources drive the freshness band.
    static let nowFids = [Contract.FID.gridW, Contract.FID.pvW, Contract.FID.batteryW, Contract.FID.batterySoc, Contract.FID.loadW, Contract.FID.evW]
    /// A 1 Hz stream is always a moment behind and a dropped tick is normal
    /// on a phone; past a couple of beats the silence is real.
    static let streamQuietAfterMs: Double = 3_000
    /// How long a foreground stream gets to prove its socket still works.
    public static let foregroundFrameDeadlineMs: Double = 2_500
    static let recentWindowMs: Double = 130_000
    static let snapshotIntervalMs: Double = 15_000

    public private(set) var session = SessionState()
    /// Wall clock the cached view was captured. Nil when live.
    public private(set) var cachedAtMs: Double?
    public private(set) var lastFrameAtMs: Double?
    public private(set) var documentVisible = true
    /// The one clock screens depend on, so derived ages move on screen.
    public private(set) var nowMs: Double
    /// Import ceiling the optimiser defends, when known.
    public var ceilingW: Double?

    public let siteId: String?
    /// True for the demo: nothing is written, and the screens say so.
    public let isDemo: Bool

    @ObservationIgnored let core: Session
    @ObservationIgnored let scheduler: Scheduler
    @ObservationIgnored private let files: SealedFiles?
    /// What widgets read. Nil for the demo and in tests.
    @ObservationIgnored private let shared: AppGroupFiles?
    @ObservationIgnored private var lastCars: (entry: CarEntry, atMs: Double)?
    /// The prices last left for the widgets, so the same prices again are
    /// neither written nor reloaded.
    @ObservationIgnored private var lastPrices: PriceEntry?
    /// The latest write to `shared`. Each waits for the one before, so they
    /// land in the order they were asked for.
    @ObservationIgnored private var writing: Task<Void, Never>?
    /// Called after every write to `shared`, so the app can wake its widgets.
    @ObservationIgnored public var sharedWritten: (@MainActor () -> Void)?
    @ObservationIgnored private var attemptStartedAtMs: Double
    @ObservationIgnored private var ticker: Cancellable?
    @ObservationIgnored private var resumeTimer: Cancellable?
    @ObservationIgnored private var resumeWaiting = false
    @ObservationIgnored private var recent: [(t: Double, v: [Int: Double])] = []
    @ObservationIgnored private var lastSnapshotMs: Double = 0
    @ObservationIgnored private var snapshotTimer: Cancellable?
    @ObservationIgnored private var destroyed = false
    @ObservationIgnored private var listeners: [Int: @MainActor () -> Void] = [:]
    @ObservationIgnored private var nextListener = 0
    /// Runs the passkey ceremony a write needs. Injected by the shell.
    @ObservationIgnored public var stepUp: (@MainActor () async -> StepUpOutcome)?

    public init(siteId: String?, build: String, ua: String, scheduler: Scheduler, files: SealedFiles?, shared: AppGroupFiles? = nil, isDemo: Bool = false) {
        self.siteId = siteId
        self.scheduler = scheduler
        self.files = files
        self.shared = isDemo ? nil : shared
        self.isDemo = isDemo
        nowMs = scheduler.nowMs
        attemptStartedAtMs = scheduler.nowMs
        core = Session(build: build, ua: ua, scheduler: scheduler)
        core.onChange = { [weak self] s in self?.onSession(s) }
    }

    // MARK: Lifecycle

    /// Paint from cache, then let the shell connect. The cache is a carrier,
    /// not a failure: it is how the first frame has something honest.
    public func start() {
        if let siteId, let cached = files?.readJSON(CachedSnapshot.self, "snapshot-\(siteId)"), cached.siteId == siteId {
            core.restore(cached)
            cachedAtMs = cached.savedAtMs
        }
        startTicker()
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = scheduler.after(1_000) { [weak self] in
            guard let self, !self.destroyed else { return }
            self.nowMs = self.scheduler.nowMs
            self.notify()
            self.startTicker()
        }
    }

    /// Attach a carrier. Refused once the model is gone, so a slow connect
    /// can never hand an old home's stream to a new one.
    @discardableResult
    public func connect(_ carrier: Carrier) -> Bool {
        if destroyed {
            carrier.close(reason: "superseded connection")
            return false
        }
        core.connect(carrier)
        if documentVisible { beginResume(immediate: true) }
        return true
    }

    public func destroy() {
        destroyed = true
        ticker?.cancel()
        resumeTimer?.cancel()
        snapshotTimer?.cancel()
        core.onChange = nil
        core.close()
        listeners = [:]
    }

    /// The app went to the background. Write what is on screen and close the
    /// session: iOS freezes the app within seconds anyway, and an open socket
    /// holds one of the four streams the relay allows a home. The readings
    /// stay, and the band dates them until a new carrier streams again.
    public func suspend() {
        guard !destroyed else { return }
        persistNow()
        core.close()
        // After the close, so no last change of rate goes out on the wire.
        setVisible(false)
    }

    /// Match the stream's cadence to whether anyone can see it.
    public func setVisible(_ visible: Bool) {
        let was = documentVisible
        documentVisible = visible
        core.setTelemetryHz(visible ? 1 : 0.2)
        if !visible {
            cancelResume()
            persistNow()
            return
        }
        if !was { beginResume(immediate: false) }
    }

    /// A new network path should replace the old one without waiting.
    public func networkOnline() {
        guard documentVisible else { return }
        beginResume(immediate: true)
    }

    /// Pull to refresh: ask for a fresh stream in place.
    public func refresh() {
        core.wake()
    }

    // MARK: Observation for feature models

    /// Called after every session change and every clock tick.
    @discardableResult
    public func observe(_ f: @escaping @MainActor () -> Void) -> Int {
        nextListener += 1
        listeners[nextListener] = f
        return nextListener
    }

    public func unobserve(_ token: Int) {
        listeners[token] = nil
    }

    private func notify() {
        for f in listeners.values { f() }
    }

    // MARK: Session changes

    private func onSession(_ s: SessionState) {
        let previous = session
        if previous.phase == .streaming, s.phase != .streaming {
            attemptStartedAtMs = scheduler.nowMs
        }
        // Only a streaming session is a reading arriving. Restoring the cache
        // and answering hello both move the clock and carry no reading.
        if s.phase == .streaming, previous.phase != .streaming || s.uptimeMs != previous.uptimeMs {
            let now = scheduler.nowMs
            lastFrameAtMs = now
            finishResume()
            recordRecent(s.fields, now)
        }
        session = s
        if s.phase == .streaming {
            cachedAtMs = nil
            scheduleSnapshot()
        }
        notify()
    }

    private func scheduleSnapshot() {
        guard siteId != nil, files != nil, snapshotTimer == nil else { return }
        let due = max(0, lastSnapshotMs + Self.snapshotIntervalMs - scheduler.nowMs)
        snapshotTimer = scheduler.after(due) { [weak self] in
            guard let self else { return }
            self.snapshotTimer = nil
            self.persistNow()
        }
    }

    /// Write the last streaming state now, before the app can be suspended.
    public func persistNow() {
        guard let siteId, let files, !destroyed, session.phase == .streaming || !session.fields.isEmpty, cachedAtMs == nil else { return }
        lastSnapshotMs = scheduler.nowMs
        files.writeJSON("snapshot-\(siteId)", CachedSnapshot(siteId: siteId, savedAtMs: scheduler.nowMs, state: session))
    }

    // MARK: Waking after sleep

    private func beginResume(immediate: Bool) {
        guard !destroyed, documentVisible else { return }
        resumeTimer?.cancel()
        resumeWaiting = true
        if immediate || session.phase != .streaming || lastFrameAtMs == nil {
            core.wake()
        }
        let frameAtStart = lastFrameAtMs
        resumeTimer = scheduler.after(Self.foregroundFrameDeadlineMs) { [weak self] in
            guard let self, !self.destroyed, self.documentVisible, self.lastFrameAtMs == frameAtStart else { return }
            self.core.wake()
        }
    }

    private func finishResume() {
        guard resumeWaiting else { return }
        resumeTimer?.cancel()
        resumeWaiting = false
    }

    private func cancelResume() {
        resumeTimer?.cancel()
        resumeWaiting = false
    }

    // MARK: What the screens read

    public var role: String { session.role }
    /// Whether to draw controls at all. Hiding is presentation; the box is
    /// what refuses.
    public var canConfigure: Bool { session.role == Contract.roleOwner }
    /// Before the box's hello, role and caps are this app's assumptions, and
    /// a sentence about the box built on them would be invented.
    public var heardFromBox: Bool { session.heardFromBox }
    public var paired: Bool { session.box != nil || !session.fields.isEmpty }
    public var hasPassthrough: Bool { session.caps.contains(Contract.capAPIPassthrough) }

    /// How the readings on screen reach us. A carrier is claimed only once it
    /// has delivered a reading: an open socket is evidence of nothing.
    public var carrier: CarrierKind {
        if session.phase == .streaming, lastFrameAtMs != nil { return session.carrier }
        return cachedAtMs != nil ? .cache : .none
    }

    public var connectionWaitMs: Double { max(0, nowMs - attemptStartedAtMs) }

    /// The relay turned this phone away: the home has as many phones
    /// watching as it serves. Said as such, never as a fault.
    public var busy: Bool { session.busy }

    /// The band for this home, read the way the web app's shell reads it.
    public func freshness(noCarrier: Bool) -> Freshness.Band {
        Freshness.band(
            carrier: carrier,
            transport: session.carrier,
            srcState: srcState,
            ageMs: ageMs,
            phase: session.phase,
            waitMs: connectionWaitMs,
            bootPct: session.boot?.pct,
            noCarrier: noCarrier,
            busy: busy
        )
    }

    /// The sources behind what the Now screen draws, named by the box.
    var nowSourceIDs: [String] {
        var ids = [String]()
        for fid in Self.nowFids where session.fields[fid] != nil {
            if let src = session.dict[fid]?.srcId, !ids.contains(src) { ids.append(src) }
        }
        return ids
    }

    public var srcState: SourceState {
        if session.fields.isEmpty { return .never }
        // Every source state was read off the disk: true when written.
        if lastFrameAtMs == nil { return .stale }
        let ids = nowSourceIDs
        let worst: SourceState
        if !ids.isEmpty {
            worst = core.worstSourceState(ids)
        } else if !session.sources.isEmpty {
            worst = core.worstSourceState(Array(session.sources.keys))
        } else {
            worst = .live
        }
        // A stream gone quiet is not live however healthy it looked.
        if worst == .live, sinceLastFrameMs > 0 { return .lagging }
        return worst
    }

    public var sinceLastFrameMs: Double {
        guard let at = lastFrameAtMs else { return 0 }
        let since = nowMs - at
        return since < Self.streamQuietAfterMs ? 0 : since
    }

    /// Age of the oldest reading on screen. Nil means unknown, which is the
    /// honest answer after a box restart.
    public var ageMs: Double? {
        let ages = nowSourceIDs.compactMap { core.ageOf($0) }
        if carrier == .cache, let at = cachedAtMs {
            let shelf = nowMs - at
            return shelf + (ages.max() ?? 0)
        }
        guard let oldest = ages.max() else { return nil }
        return oldest + sinceLastFrameMs
    }

    /// Live is three claims at once: streaming, not the cache, and every
    /// source answering.
    public var isLive: Bool {
        session.phase == .streaming && carrier != .cache && srcState == .live
    }

    public var explanation: Explanation.Result {
        Explanation.explain(fields: session.fields, dispatchBlockedBy: session.dispatchBlockedBy, ceilingW: ceilingW)
    }

    public var socPercent: Double? {
        session.fields[Contract.FID.batterySoc].map { ($0 / 10).rounded() }
    }

    private func recordRecent(_ fields: [Int: Double], _ now: Double) {
        var v = [Int: Double]()
        for fid in Self.nowFids { if let x = fields[fid] { v[fid] = x } }
        recent.append((now, v))
        let cutoff = now - Self.recentWindowMs
        recent.removeAll { $0.t < cutoff }
    }

    /// The last two minutes of one field, oldest first, so a live line opens
    /// already drawn.
    public func recentField(_ fid: Int) -> [(t: Double, v: Double)] {
        recent.compactMap { r in r.v[fid].map { (r.t, $0) } }
    }

    // MARK: Requests, through this layer

    public func prices(fromMs: Double, toMs: Double) async throws -> Prices {
        try await core.prices(fromMs: fromMs, toMs: toMs)
    }

    public func command(_ op: String, args: [(String, CBOR)], guards: [Guard] = []) async throws -> CmdResult {
        try await core.command(op, args: args, guards: guards)
    }

    public func api(_ req: APIRequest) async throws -> APIResponse {
        try await core.api(req)
    }

    // MARK: What widgets read

    /// A rewrite of the same car is skipped for this long. The charger is
    /// read every five seconds while the app is open; a widget does not need
    /// each of those.
    static let carRewriteMs: Double = 5 * 60_000

    /// Leave today's and tomorrow's prices for the widgets. The same prices
    /// again are skipped: the widgets' timeline already holds them, and a
    /// reload would only redraw it. Returns the write, for a caller that
    /// must not end before it lands.
    @discardableResult
    func sharePrices(_ prices: Prices, fromMs: Double) -> Task<Void, Never>? {
        guard let siteId, let shared else { return nil }
        let entry = PriceEntry(fromMs: fromMs, prices: prices)
        guard entry != lastPrices else { return nil }
        lastPrices = entry
        let record = CacheRecord(
            siteId: siteId,
            carrier: session.carrier,
            srcState: prices.stale ? .stale : .live,
            readAtMs: scheduler.nowMs,
            value: entry
        )
        return write(record, to: shared)
    }

    /// Leave the chargers for the widgets, as the box just described them.
    /// `fresh` says whether the box's own reading of the charger is current.
    func shareCars(_ points: [Loadpoint], fresh: Bool) {
        guard let siteId, let shared else { return }
        let now = scheduler.nowMs
        let entry = CarEntry(cars: points.map { lp in
            CarEntry.Car(
                loadpointID: lp.id,
                pluggedIn: lp.pluggedIn,
                socPct: lp.socPct,
                socSource: lp.socSource,
                socReadAtMs: lp.socReadAtMs(answeredAtMs: now),
                powerW: lp.powerW,
                targetSocPct: lp.targetSocPct,
                holding: LoadpointsModel.holding(lp)
            )
        })
        if let last = lastCars, last.entry.sameReading(entry), now - last.atMs < Self.carRewriteMs { return }
        lastCars = (entry, now)
        let answering = fresh && points.allSatisfy { $0.charger?.available != false }
        write(CacheRecord(siteId: siteId, carrier: session.carrier, srcState: answering ? .live : .stale, readAtMs: now, value: entry), to: shared)
    }

    /// Leave the plan for the plan widget. `sentAtMs` is when the box sent
    /// it, which is what the widget dates it by.
    func sharePlan(_ entry: PlanEntry, sentAtMs: Double) {
        guard let siteId, let shared else { return }
        write(CacheRecord(siteId: siteId, carrier: session.carrier, srcState: entry.boxStale ? .stale : .live, readAtMs: sentAtMs, value: entry), to: shared)
    }

    /// Encoding and the file write run off the main actor. A sign-out
    /// asked for meanwhile wins: the write is dropped rather than putting
    /// the home back (`AppGroupFiles.clearCount`).
    @discardableResult
    private func write<Value: CacheValue>(_ record: CacheRecord<Value>, to shared: AppGroupFiles) -> Task<Void, Never>? {
        guard !destroyed else { return nil }
        let asked = shared.clearCount
        let previous = writing
        let task = Task { [weak self] in
            await previous?.value
            do {
                guard try await shared.write(record, asked: asked) else { return }
                log.info("wrote \(Value.name, privacy: .public) for widgets, source \(record.srcState.rawValue, privacy: .public)")
                guard let self, !self.destroyed else { return }
                self.sharedWritten?()
            } catch {
                // A widget showing yesterday's record with its date is
                // better than no app; the next read tries again.
                log.error("could not write \(Value.name, privacy: .public) for widgets: \(error.localizedDescription, privacy: .public)")
                if Value.self == PriceEntry.self { self?.lastPrices = nil }
            }
        }
        writing = task
        return task
    }

    /// Wait for every write asked for so far to land, so whatever reads
    /// the App Group next (the Control) reads the newest record.
    public func flushShared() async {
        await writing?.value
    }

    /// Where the prices the widgets hold run out. Nil when they hold none.
    /// Read from what this process wrote, or off the main actor from disk
    /// after a cold launch.
    public func sharedPricesEndMs() async -> Double? {
        if let lastPrices { return Self.end(lastPrices) }
        guard let siteId, let shared else { return nil }
        return await Self.readEnd(shared, siteId: siteId)
    }

    @concurrent
    private nonisolated static func readEnd(_ shared: AppGroupFiles, siteId: String) async -> Double? {
        shared.read(PriceEntry.self, siteId: siteId).flatMap { end($0.value) }
    }

    private nonisolated static func end(_ entry: PriceEntry) -> Double? {
        entry.prices.slots.map { $0.startMs + $0.durationMs }.max()
    }

    /// The background refresh: wait for the stream, ask for today's and
    /// tomorrow's prices as the price card does, and leave them for the
    /// widgets. Returns what was written, or nil when nothing was: no
    /// stream within `waitMs`, a box without prices, or a failed ask.
    ///
    /// The caller builds the carrier and closes it after.
    @discardableResult
    public func refreshSharedPrices(calendar: Calendar = .current, waitMs: Double = 20_000) async -> Prices? {
        guard siteId != nil, shared != nil, !destroyed else { return nil }
        guard await streaming(within: waitMs) else {
            log.notice("background prices: no stream within \(Int(waitMs / 1000), privacy: .public) s")
            return nil
        }
        guard session.caps.contains(Contract.capPriceSpot) else {
            log.notice("background prices: this box offers no prices")
            return nil
        }
        let from = calendar.startOfDay(for: Date(timeIntervalSince1970: nowMs / 1000)).timeIntervalSince1970 * 1000
        do {
            let wire = try await prices(fromMs: from, toMs: from + PriceModel.horizonMs)
            sharePrices(wire, fromMs: from)
            // iOS may suspend the app once the task returns: land the write
            // first, or the one already on its way with these prices.
            await writing?.value
            return wire
        } catch {
            log.error("background prices: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// True once the session streams, false if it has not within `ms`.
    private func streaming(within ms: Double) async -> Bool {
        if session.phase == .streaming { return true }
        let wait = StreamWait()
        let ok = await withCheckedContinuation { cont in
            wait.continuation = cont
            wait.token = observe { [weak self, wait] in
                if self?.session.phase == .streaming { wait.settle(true) }
            }
            wait.timer = scheduler.after(ms) { [wait] in wait.settle(false) }
        }
        if let token = wait.token { unobserve(token) }
        return ok
    }
}

/// One wait for the stream, settled once. The timer settles it even if the
/// model is gone, so the background task always ends.
@MainActor
private final class StreamWait {
    var continuation: CheckedContinuation<Bool, Never>?
    var token: Int?
    var timer: Cancellable?

    func settle(_ ok: Bool) {
        guard let cont = continuation else { return }
        continuation = nil
        timer?.cancel()
        cont.resume(returning: ok)
    }
}
