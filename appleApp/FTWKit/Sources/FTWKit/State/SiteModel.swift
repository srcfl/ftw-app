import Foundation
import FTWShared
import Observation
import os

private let log = Logger(subsystem: "energy.ftw.app", category: "widgets")
/// When each source first delivered, counted from `start`, so the three
/// layers of a cold start and the relay's path can be compared. Read with
/// `log show --predicate 'subsystem == "energy.ftw.app" AND category == "reading"'`.
private let readingLog = Logger(subsystem: "energy.ftw.app", category: "reading")
private let signposter = OSSignposter(subsystem: "energy.ftw.app", category: "reading")
/// How many requests each stay in front cost, logged when the app hides.
private let askLog = Logger(subsystem: "energy.ftw.app", category: "asks")

/// The bridge between the session and the screens.
///
/// The session owns protocol state; this exposes it, restores the cached
/// snapshot on start, keeps freshness honest and derives what the screens
/// ask for. Nothing above this touches a frame.
///
/// Readings come from one of two places. With FTW Cloud on, the cloud is the
/// first: its copy arrives from memory within a round trip and every change
/// follows on the same socket, each envelope signed by the box and checked
/// here. The box session over the relay stays open beside it for commands,
/// and its readings take over when the cloud fails, is out of reach, or has
/// nothing better. `session` is what the screens read either way.
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
    static let snapshotIntervalMs: Double = 15_000

    public private(set) var session = SessionState()
    /// Wall clock the cached view was captured. Nil when live.
    public private(set) var cachedAtMs: Double?
    /// The box's uptime when the cached view was captured. Its sources'
    /// ages count against this until the box streams: hello names the
    /// uptime now, which is not the clock those readings were taken on.
    @ObservationIgnored private var cachedUptimeMs: Double?
    public private(set) var lastFrameAtMs: Double?
    /// When the box took the newest reading on screen, by the phone clock.
    /// From the box's own stream: its uptime, placed by the smallest gap
    /// seen this connection between the phone's clock and the box's, so a
    /// frame a slow network held back lands where it was taken. Through
    /// FTW Cloud: the send time rule U gives. The live trace stamps by it.
    @ObservationIgnored public private(set) var readingStampMs: Double?
    /// How long the newest reading stands before a silence is a gap. The
    /// box streams at 1 Hz in front and 0.2 Hz hidden, and misses a beat
    /// now and then; FTW Cloud sends on change and a heartbeat at least
    /// every H.
    @ObservationIgnored public private(set) var readingGapMs: Double = LiveTrace.gapMs
    public private(set) var documentVisible = true
    /// The clock screens read for ages. It moves with every reading, and
    /// between readings only when something on screen would change: the
    /// minute, a stream going quiet, a grade lapsing, or a counter the band
    /// shows in seconds.
    public private(set) var nowMs: Double
    /// The current minute. Text that needs no finer clock reads this and
    /// redraws once a minute.
    public private(set) var minuteMs: Double
    /// When each value on screen was read, by the phone clock. A view can
    /// glide from one value to the next over the time between them.
    public private(set) var fieldAtMs: [Int: Double] = [:]
    /// When the newest reading on screen was read, by the phone clock.
    public private(set) var readingAtMs: Double?
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
    /// Today over the grid as last left, so the same figures again are not
    /// written.
    @ObservationIgnored private var lastGridToday: GridTodayEntry?
    /// The latest write to `shared`. Each waits for the one before, so they
    /// land in the order they were asked for.
    @ObservationIgnored private var writing: Task<Void, Never>?
    /// Called after every write to `shared`, so the app can wake its widgets.
    @ObservationIgnored public var sharedWritten: (@MainActor () -> Void)?
    @ObservationIgnored private var attemptStartedAtMs: Double
    @ObservationIgnored private var clock: Cancellable?
    @ObservationIgnored private var resumeTimer: Cancellable?
    @ObservationIgnored private var resumeWaiting = false
    @ObservationIgnored private var lastSnapshotMs: Double = 0
    @ObservationIgnored private var snapshotTimer: Cancellable?
    /// The last snapshot written, without its time, so the same home is not
    /// written twice.
    @ObservationIgnored private var lastSnapshot: CachedSnapshot?
    /// What the last launch kept of this home beside its readings, read
    /// once when the model is made, so every model of the home opens on it.
    public let kept: HomeCache?
    /// Each model's part of the home file, filled in at every write.
    @ObservationIgnored private var keepers: [@MainActor (inout HomeCache) -> Void] = []
    /// The home file as last read or written, so the same home is not
    /// written twice.
    @ObservationIgnored private var lastHome: HomeCache?
    /// The models' own sealed files beside the home file.
    @ObservationIgnored private var fileKeepers: [FileKeeper] = []
    /// FTW Cloud's price window and chargers as last accepted, for the
    /// models that show them. Each change comes with a `notify`.
    @ObservationIgnored public private(set) var cloudPrices: Stamped<PriceEntry>?
    @ObservationIgnored public private(set) var cloudCars: Stamped<[CarEntry.Car]>?
    @ObservationIgnored private var destroyed = false
    /// The box session's own state, as the last frame left it.
    @ObservationIgnored private var relay = SessionState()
    /// When the box session last delivered a reading. Waking after sleep
    /// waits for this one, whatever the cloud does meanwhile.
    @ObservationIgnored private var relayFrameAtMs: Double?
    /// The phone's clock minus the box's uptime, the smallest seen since
    /// this carrier's hello: where a frame's uptime sits on the phone clock.
    @ObservationIgnored private var relayOffsetMs: Double?
    @ObservationIgnored private var listeners: [Int: @MainActor () -> Void] = [:]
    /// A burst of messages within one display frame reaches the screens as
    /// one change: the first goes at once, the rest together after it.
    @ObservationIgnored private var publishTimer: Cancellable?
    @ObservationIgnored private var lastPublishMs: Double = -.infinity
    /// Whether a source delivered a reading since the last publish.
    @ObservationIgnored private var relayDelivered = false
    @ObservationIgnored private var cloudDelivered = false
    /// From a start or a return to the front until the screen is live, as a
    /// signpost interval.
    @ObservationIgnored private var liveSpan: (name: StaticString, state: OSSignpostIntervalState, fromMs: Double)?
    /// What the band and the cards derive from, taken in the same change as
    /// `session`, so they never disagree while a burst waits for its frame.
    private var shown = Shown()

    private struct Shown {
        var source: ReadingSource = .relay
        var relay = SessionState()
        var relayFrameAtMs: Double?
        var cloudOpen = false
        var cloudView: CloudView?
    }

    // FTW Cloud. All nil while the home has no grant or this build no
    // endpoint.
    @ObservationIgnored private var cloud: CloudCarrier?
    @ObservationIgnored private(set) var cloudView: CloudView?
    @ObservationIgnored private(set) var cloudIdentity: CloudIdentity?
    @ObservationIgnored private var cloudDevice: Primitives.KeyPair?
    @ObservationIgnored private var cloudSocket: WebSocketFactory?
    @ObservationIgnored private var cloudEndpoint: CloudEndpoint?
    /// Rule U's anchor as last learned, kept with the identity so a cold
    /// start can age the cloud's copy of a box without a clock.
    @ObservationIgnored private var ruleU: CloudCache.Offset?
    @ObservationIgnored private var cloudDirty = false
    /// When the newest cloud envelope arrived, for the time of a reading the
    /// anchor cannot place.
    @ObservationIgnored private var cloudArrivalMs: Double?
    /// What the notification extension was last given for this home.
    @ObservationIgnored private var sharedCloudHome: CloudHome?
    /// Whether FTW Cloud's session takes the phone's APNs token, and the
    /// token, sent again at every opening.
    @ObservationIgnored private var pushSinkOn = false
    @ObservationIgnored private var pushToken: PushTokens.Token?
    /// Where the token comes from: `PushTokens`, unless a test hands its own.
    @ObservationIgnored var pushTokens = PushTokenSource.app
    /// Where the readings on screen came from at the last change.
    @ObservationIgnored private(set) var source: ReadingSource = .relay
    @ObservationIgnored private var startedAtMs: Double = 0
    /// Which stay in front this is, and the session's request count when it
    /// began.
    @ObservationIgnored private var visit = (number: 1, fromRequests: 0)
    @ObservationIgnored private var firsts: Set<String> = []
    /// The cloud session, for the About screen. Nil while there is none.
    public private(set) var cloudStatus: CloudCarrier.Status?
    @ObservationIgnored private var nextListener = 0
    /// Runs the passkey ceremony a write needs. Injected by the shell.
    @ObservationIgnored public var stepUp: (@MainActor () async -> StepUpOutcome)?

    /// One display frame: what arrives within it is drawn together.
    static let coalesceMs: Double = 16

    /// `demoShares` lets a demo leave its records for the widgets. Only a
    /// Debug build asks for it, to photograph them; the demo otherwise
    /// writes nothing.
    public init(siteId: String?, build: String, ua: String, scheduler: Scheduler, files: SealedFiles?, shared: AppGroupFiles? = nil, isDemo: Bool = false, demoShares: Bool = false) {
        self.siteId = siteId
        self.scheduler = scheduler
        self.files = files
        self.shared = isDemo && !demoShares ? nil : shared
        self.isDemo = isDemo
        nowMs = scheduler.nowMs
        minuteMs = (scheduler.nowMs / 60_000).rounded(.down) * 60_000
        attemptStartedAtMs = scheduler.nowMs
        let home = siteId.flatMap { id in files?.readJSON(HomeCache.self, "home-\(id)") }
        kept = home.flatMap { $0.version == HomeCache.version && $0.siteId == siteId ? $0 : nil }
        lastHome = kept?.asRead
        core = Session(build: build, ua: ua, scheduler: scheduler)
        core.onChange = { [weak self] s in self?.onSession(s) }
    }

    // MARK: Lifecycle

    /// Paint from cache, then let the shell connect. The cache is a carrier,
    /// not a failure: it is how the first frame has something honest.
    public func start() {
        startedAtMs = scheduler.nowMs
        beginLiveSpan("cold start to live")
        let cached = siteId.flatMap { id in files?.readJSON(CachedSnapshot.self, "snapshot-\(id)") }.flatMap { $0.siteId == siteId ? $0 : nil }
        if let cached {
            cachedAtMs = cached.savedAtMs
            cachedUptimeMs = cached.uptimeMs
            lastSnapshot = cached.timeless
        }
        if cached != nil || kept?.hello != nil { core.restore(cached, hello: kept?.hello) }
        if let siteId, let kept = files?.readJSON(CloudCache.self, "cloud-\(siteId)") {
            adoptCloud(kept.identity, offset: kept.offset)
        }
        scheduleClock()
    }

    /// Attach a carrier. Refused once the model is gone, so a slow connect
    /// can never hand an old home's stream to a new one.
    ///
    /// A carrier made for this call is already dialling. Waking it would
    /// only report a reconnect that never happened, so it gets the deadline
    /// and nothing more.
    @discardableResult
    public func connect(_ carrier: Carrier) -> Bool {
        if destroyed {
            carrier.close(reason: "superseded connection")
            return false
        }
        core.connect(carrier)
        if documentVisible { beginResume(wake: false) }
        return true
    }

    public func destroy() {
        destroyed = true
        clock?.cancel()
        resumeTimer?.cancel()
        snapshotTimer?.cancel()
        publishTimer?.cancel()
        core.onChange = nil
        core.close()
        cloud?.close()
        cloud = nil
        listeners = [:]
    }

    /// The app went to the background. Close the session and write what is
    /// on screen, once: iOS freezes the app within seconds anyway, and an
    /// open socket holds one of the four streams the relay allows a home. The
    /// readings stay, and the band dates them until a new carrier streams
    /// again.
    public func suspend() {
        guard !destroyed else { return }
        core.close()
        closeCloud()
        // After the close, so no last change of rate goes out on the wire.
        hide()
        // Settle what the screens say before iOS freezes them.
        publishTimer?.cancel()
        publishTimer = nil
        source = readingSource()
        publishNow()
        persistNow(wait: true)
    }

    /// Match the stream's cadence to whether anyone can see it.
    public func setVisible(_ visible: Bool) {
        guard visible else {
            hide()
            persistNow()
            return
        }
        let was = documentVisible
        documentVisible = true
        core.setTelemetryHz(1)
        cloud?.setLooking(true)
        if !was {
            visit = (visit.number + 1, core.requestsSent)
            // A start passes through inactive on its way to the front; its
            // own interval keeps running.
            if liveSpan == nil { beginLiveSpan("foreground to live") }
            beginResume(wake: relay.phase != .streaming || relayFrameAtMs == nil)
        }
        scheduleClock()
    }

    private func hide() {
        if documentVisible {
            askLog.notice("visit \(self.visit.number, privacy: .public): \(self.requestsThisVisit, privacy: .public) requests")
        }
        documentVisible = false
        core.setTelemetryHz(0.2)
        cloud?.setLooking(false)
        cancelResume()
        scheduleClock()
    }

    /// Request frames sent since the app last came to the front.
    public var requestsThisVisit: Int { core.requestsSent - visit.fromRequests }

    /// A new network path should replace the old one without waiting.
    public func networkOnline() {
        guard documentVisible else { return }
        cloud?.wake()
        beginResume(wake: true)
    }

    /// Pull to refresh: ask for a fresh stream in place.
    public func refresh() {
        core.wake()
        cloud?.wake()
    }

    // MARK: Observation for feature models

    /// Called after every change the screens see, and when the clock moves.
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
        let previous = relay
        let now = scheduler.nowMs
        if previous.phase == .streaming, s.phase != .streaming {
            attemptStartedAtMs = now
        }
        // Only a streaming session is a reading arriving. Restoring the cache
        // and answering hello both move the clock and carry no reading.
        let reading = s.phase == .streaming && (previous.phase != .streaming || s.uptimeMs != previous.uptimeMs)
        // A new hello, or a box that restarted, starts the clock over.
        if s.phase == .handshaking, previous.phase != .handshaking { relayOffsetMs = nil }
        if reading {
            let offset = now - s.uptimeMs
            if let held = relayOffsetMs, s.uptimeMs >= previous.uptimeMs { relayOffsetMs = min(held, offset) } else { relayOffsetMs = offset }
            relayFrameAtMs = now
            relayDelivered = true
            finishResume()
        }
        relay = s
        if s.heardFromBox, !previous.heardFromBox || previous.cloud != s.cloud {
            cloudHello(s.cloud)
        }
        // Every box message over Noise that names its uptime is a chance to
        // learn rule U, once hello has named the boot it belongs to.
        if s.heardFromBox, let boot = s.cloud?.boot, s.carrier == .relay || s.carrier == .webrtc, s.uptimeMs != previous.uptimeMs || !previous.heardFromBox {
            learnRuleU(boot: boot, uptimeMs: s.uptimeMs, phoneMs: now)
        }
        if s.phase == .streaming { scheduleSnapshot() }
        if reading { first("relay reading") }
        publish()
        scheduleClock()
    }

    /// Logs once per home how long after `start` something first happened.
    func first(_ what: String) {
        guard startedAtMs > 0, firsts.insert(what).inserted else { return }
        let ms = Int((scheduler.nowMs - startedAtMs).rounded())
        readingLog.notice("\(what, privacy: .public) \(ms, privacy: .public) ms after start")
    }

    /// Picks where readings come from now, and draws the change: at once
    /// when the screens have been still for a frame, else together with
    /// whatever else arrives within it.
    private func publish() {
        source = readingSource()
        guard publishTimer == nil else { return }
        let since = scheduler.nowMs - lastPublishMs
        if since >= Self.coalesceMs {
            publishNow()
            return
        }
        publishTimer = scheduler.after(Self.coalesceMs - since) { [weak self] in
            guard let self, !self.destroyed else { return }
            self.publishTimer = nil
            self.source = self.readingSource()
            self.publishNow()
        }
    }

    /// What the screens read: the box session's state, with the cloud's
    /// readings in it while the cloud is where readings come from, each value
    /// with the time it was read. The clock moves in the same change, so a
    /// reading redraws a screen once.
    private func publishNow() {
        let now = scheduler.nowMs
        lastPublishMs = now
        let s = composed()
        let delivered = source == .cloud ? cloudDelivered : relayDelivered
        relayDelivered = false
        cloudDelivered = false
        let at = readingTime(source) ?? now
        var times = fieldAtMs
        for (fid, v) in s.fields where session.fields[fid] != v || times[fid] == nil {
            times[fid] = at
        }
        for fid in times.keys where s.fields[fid] == nil { times[fid] = nil }
        if delivered {
            lastFrameAtMs = now
            readingStampMs = readingStamp(source, state: s) ?? at
            readingGapMs = readingGap(source)
        }
        if times != fieldAtMs { fieldAtMs = times }
        if delivered || readingAtMs == nil || s.fields.isEmpty != session.fields.isEmpty { readingAtMs = s.fields.isEmpty ? nil : at }
        // A stream, or a reading from the cloud, retires the cache's claim.
        if relay.phase == .streaming || (source == .cloud && delivered), cachedAtMs != nil { cachedAtMs = nil }
        advanceClock()
        shown = Shown(source: source, relay: relay, relayFrameAtMs: relayFrameAtMs, cloudOpen: cloud?.status.isOpen == true, cloudView: cloudView)
        session = s
        endLiveSpanIfLive()
        notify()
    }

    /// The readings the source in use gives, aged to now.
    private func composed() -> SessionState {
        var s = relay
        if source == .cloud, let view = cloudView, let identity = cloudIdentity {
            compose(&s, view: view, identity: identity)
        }
        return s
    }

    /// When the newest reading from a source was read, by the phone clock.
    /// For the cloud that is the anchor's send time; nil when it cannot be
    /// placed.
    private func readingTime(_ from: ReadingSource) -> Double? {
        switch from {
        case .relay:
            return relayFrameAtMs ?? cachedAtMs
        case .cloud:
            guard let view = cloudView else { return nil }
            return view.anchorSentMs(nowMs: Int64(scheduler.nowMs)).map(Double.init) ?? cloudArrivalMs
        }
    }

    /// When the box took the newest reading from a source, by the phone
    /// clock.
    private func readingStamp(_ from: ReadingSource, state s: SessionState) -> Double? {
        switch from {
        case .relay: return relayOffsetMs.map { s.uptimeMs + $0 }
        case .cloud: return readingTime(.cloud)
        }
    }

    /// How long a reading from a source stands before a silence is a gap:
    /// three and a half of the box's beats, or twice FTW Cloud's heartbeat
    /// and a margin.
    private func readingGap(_ from: ReadingSource) -> Double {
        switch from {
        case .relay: return LiveTrace.gapMs * (documentVisible ? 1 : 5)
        case .cloud: return max(LiveTrace.gapMs, 2 * Double(cloudView?.heartbeatMs ?? 15_000) + 500)
        }
    }

    // MARK: The clock

    /// Arms the one timer the clock needs: the next moment something on
    /// screen would change with no reading arriving. While live that is the
    /// minute, the moment the stream would count as quiet, or a cloud grade
    /// lapsing. A counter in seconds runs only while the band shows one.
    private func scheduleClock() {
        clock?.cancel()
        clock = nil
        guard !destroyed else { return }
        let now = scheduler.nowMs
        var next = ((now / 60_000).rounded(.down) + 1) * 60_000
        if documentVisible {
            if relay.phase == .streaming, let at = relayFrameAtMs, at + Self.streamQuietAfterMs > now {
                next = min(next, at + Self.streamQuietAfterMs)
            }
            if source == .cloud, let at = cloudView?.nextGradeChange(nowMs: Int64(now)) {
                next = min(next, Double(at))
            }
            if bandCountsSeconds {
                next = min(next, now + 1_000)
            }
        }
        clock = scheduler.after(max(1, next - now)) { [weak self] in
            guard let self, !self.destroyed else { return }
            self.clock = nil
            self.advanceClock()
            self.notify()
            self.scheduleClock()
        }
    }

    /// The band shows seconds while it counts a wait or an age under a
    /// minute; the clock ticks each second only then.
    private var bandCountsSeconds: Bool {
        let band = freshness(noCarrier: false)
        if band.wait != nil { return true }
        if band.age != nil, let age = ageMs, age < 60_000 { return true }
        return false
    }

    private func advanceClock() {
        nowMs = scheduler.nowMs
        let minute = (nowMs / 60_000).rounded(.down) * 60_000
        if minute != minuteMs { minuteMs = minute }
    }

    // MARK: Snapshots

    private func scheduleSnapshot() {
        guard siteId != nil, files != nil, snapshotTimer == nil else { return }
        let due = max(0, lastSnapshotMs + Self.snapshotIntervalMs - scheduler.nowMs)
        snapshotTimer = scheduler.after(due) { [weak self] in
            guard let self else { return }
            self.snapshotTimer = nil
            self.persistNow()
        }
    }

    /// Write what is on screen, unless it is what was written last. The seal
    /// and the file write run off the main actor; `wait` keeps them on it,
    /// for the moment before iOS freezes the app.
    public func persistNow(wait: Bool = false) {
        guard let siteId, let files, !destroyed else { return }
        if cloudDirty, let identity = cloudIdentity {
            cloudDirty = false
            files.writeJSON("cloud-\(siteId)", CloudCache(identity: identity, offset: ruleU), wait: wait)
            shareCloudHome()
        }
        writeHome(siteId: siteId, files: files, wait: wait)
        for keeper in fileKeepers {
            guard let data = keeper.encode(), data != keeper.last else { continue }
            keeper.last = data
            let name = "\(keeper.prefix)-\(siteId)"
            if wait { files.write(name, data.byteArray) } else { files.writeLater(name, data.byteArray) }
        }
        guard session.phase == .streaming || !session.fields.isEmpty, cachedAtMs == nil else { return }
        // The cloud's ages move with the clock; take them as of now.
        let state = source == .cloud ? composed() : session
        let snapshot = CachedSnapshot(siteId: siteId, savedAtMs: scheduler.nowMs, state: state)
        guard snapshot.timeless != lastSnapshot else { return }
        lastSnapshot = snapshot.timeless
        lastSnapshotMs = scheduler.nowMs
        files.writeJSON("snapshot-\(siteId)", snapshot, wait: wait)
    }

    /// A model's part of the home file: `fill` adds it at every write.
    public func keep(_ fill: @escaping @MainActor (inout HomeCache) -> Void) {
        keepers.append(fill)
    }

    /// A model's own sealed file beside the home file, `<prefix>-<site>`,
    /// written on the same triggers when what `value` gives differs from
    /// what was written last. Nil writes nothing.
    public func keepFile<T: Encodable>(_ prefix: String, _ value: @escaping @MainActor () -> T?) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        fileKeepers.append(FileKeeper(prefix: prefix) { value().flatMap { try? encoder.encode($0) } })
    }

    /// The file `keepFile` wrote for this home, as the last launch left it.
    public func keptFile<T: Decodable>(_ type: T.Type, _ prefix: String) -> T? {
        guard let siteId else { return nil }
        return files?.readJSON(T.self, "\(prefix)-\(siteId)")
    }

    /// Write the home file when it says something new. Hello is the box's
    /// own once it has spoken, else what the last launch kept.
    private func writeHome(siteId: String, files: SealedFiles, wait: Bool) {
        var home = HomeCache(siteId: siteId)
        home.hello = relay.heardFromBox ? HomeCache.Hello(relay) : kept?.hello
        for fill in keepers { fill(&home) }
        let read = home.asRead
        guard read != lastHome, read != HomeCache(siteId: siteId) else { return }
        lastHome = read
        files.writeJSON("home-\(siteId)", home, wait: wait)
    }

    // MARK: Time to live

    private func beginLiveSpan(_ name: StaticString) {
        if let span = liveSpan { signposter.endInterval(span.name, span.state) }
        liveSpan = (name, signposter.beginInterval(name), scheduler.nowMs)
    }

    /// Ends the interval the first time the screen is live after a start or
    /// a return, and logs the process's first live beside LaunchClock's
    /// first frame.
    private func endLiveSpanIfLive() {
        guard let span = liveSpan, isLive else { return }
        liveSpan = nil
        signposter.endInterval(span.name, span.state)
        let ms = Int((scheduler.nowMs - span.fromMs).rounded())
        readingLog.notice("\(span.name, privacy: .public) \(ms, privacy: .public) ms via \(self.carrier.rawValue, privacy: .public)")
        ProcessClock.markOnce("live")
    }

    // MARK: Waking after sleep

    /// Give a foreground stream a deadline to prove itself, and with `wake`
    /// ask the carrier to replace a path that may have slept stale.
    private func beginResume(wake: Bool) {
        guard !destroyed, documentVisible else { return }
        resumeTimer?.cancel()
        resumeWaiting = true
        if wake { core.wake() }
        let frameAtStart = relayFrameAtMs
        resumeTimer = scheduler.after(Self.foregroundFrameDeadlineMs) { [weak self] in
            guard let self, !self.destroyed, self.documentVisible, self.relayFrameAtMs == frameAtStart else { return }
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
        if shown.source == .cloud {
            if shown.cloudOpen { return .cloud }
            return cachedAtMs != nil ? .cache : .none
        }
        if shown.relay.phase == .streaming, shown.relayFrameAtMs != nil { return shown.relay.carrier }
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
            busy: busy,
            lastReading: (readingAtMs ?? cachedAtMs).map { AppWords.clock($0, zone: householdZone) }
        )
    }

    /// The household's time zone, as the box names it, else the phone's.
    var householdZone: TimeZone {
        session.box.flatMap { TimeZone(identifier: $0.tz) } ?? .current
    }

    /// The sources behind what the Now screen draws, named by the box.
    /// The box session's sources behind what Now draws. The cloud's are
    /// graded by `CloudView`, not by these.
    var nowSourceIDs: [String] { Self.nowSourceIDs(shown.relay) }

    static func nowSourceIDs(_ r: SessionState) -> [String] {
        var ids = [String]()
        for fid in nowFids where r.fields[fid] != nil {
            if let src = r.dict[fid]?.srcId, !ids.contains(src) { ids.append(src) }
        }
        return ids
    }

    public var srcState: SourceState {
        if session.fields.isEmpty { return .never }
        if shown.source == .cloud, let view = shown.cloudView { return Self.cloudState(view, nowMs: nowMs) }
        return Self.relayState(shown.relay, frameAtMs: shown.relayFrameAtMs, nowMs: nowMs)
    }

    /// The box session's grade for what Now draws, from the box's own
    /// source states and how long the stream has been quiet.
    static func relayState(_ r: SessionState, frameAtMs: Double?, nowMs: Double) -> SourceState {
        if r.fields.isEmpty { return .never }
        // Every source state was read off the disk: true when written.
        guard let frameAtMs else { return .stale }
        let ids = nowSourceIDs(r)
        let keys = ids.isEmpty ? Array(r.sources.keys) : ids
        let worst = keys.isEmpty ? .live : keys.map { r.sources[$0]?.state ?? .never }.max() ?? .live
        // A stream gone quiet is not live however healthy it looked.
        if worst == .live, nowMs - frameAtMs >= streamQuietAfterMs { return .lagging }
        return worst
    }

    /// The same grade from the newest state, for choosing a source.
    private var relaySrcState: SourceState {
        Self.relayState(relay, frameAtMs: relayFrameAtMs, nowMs: scheduler.nowMs)
    }

    public var sinceLastFrameMs: Double {
        guard let at = shown.relayFrameAtMs else { return 0 }
        let since = nowMs - at
        return since < Self.streamQuietAfterMs ? 0 : since
    }

    /// Age of the oldest reading on screen. Nil means unknown, which is the
    /// honest answer after a box restart.
    public var ageMs: Double? {
        if shown.source == .cloud, let view = shown.cloudView {
            guard let age = Self.cloudAge(view, nowMs: nowMs) else { return nil }
            if carrier == .cache, let at = cachedAtMs { return max(age, nowMs - at) }
            return age
        }
        let r = asCached(shown.relay)
        let ages = nowSourceIDs.compactMap { id -> Double? in
            guard let src = r.sources[id] else { return nil }
            let age = r.uptimeMs - src.lastOkMs
            return age < 0 ? nil : age
        }
        if carrier == .cache, let at = cachedAtMs {
            let shelf = nowMs - at
            return shelf + (ages.max() ?? 0)
        }
        guard let oldest = ages.max() else { return nil }
        return oldest + sinceLastFrameMs
    }

    /// The state with its clock as the cache left it, while what is on
    /// screen is the cache.
    func asCached(_ s: SessionState) -> SessionState {
        guard carrier == .cache, let cachedUptimeMs else { return s }
        var c = s
        c.uptimeMs = cachedUptimeMs
        return c
    }

    /// Live is three claims at once: streaming, not the cache, and every
    /// source answering.
    public var isLive: Bool {
        let streaming = shown.source == .cloud ? shown.cloudOpen : session.phase == .streaming
        return streaming && carrier != .cache && srcState == .live
    }

    public var explanation: Explanation.Result {
        Explanation.explain(fields: session.fields, dispatchBlockedBy: session.dispatchBlockedBy, ceilingW: ceilingW)
    }

    public var socPercent: Double? {
        session.fields[Contract.FID.batterySoc].map { ($0 / 10).rounded() }
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
    func sharePrices(_ prices: Prices, fromMs: Double, via: CarrierKind? = nil) -> Task<Void, Never>? {
        guard let siteId, let shared else { return nil }
        let entry = PriceEntry(fromMs: fromMs, prices: prices, timeZone: session.box?.tz)
        guard entry != lastPrices else { return nil }
        lastPrices = entry
        let record = CacheRecord(
            siteId: siteId,
            carrier: via ?? session.carrier,
            srcState: prices.stale ? .stale : .live,
            readAtMs: scheduler.nowMs,
            value: entry
        )
        return write(record, to: shared)
    }

    /// Leave the chargers for the widgets, as the box just described them.
    /// `fresh` says whether the box's own reading of the charger is current.
    func shareCars(_ points: [Loadpoint], fresh: Bool) {
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
        shareCarEntry(entry, answering: fresh && points.allSatisfy { $0.charger?.available != false })
    }

    /// One car record for the widgets; the same car again is skipped for a
    /// while.
    private func shareCarEntry(_ entry: CarEntry, answering: Bool, via: CarrierKind? = nil) {
        guard let siteId, let shared else { return }
        let now = scheduler.nowMs
        if let last = lastCars, last.entry.sameReading(entry), now - last.atMs < Self.carRewriteMs { return }
        lastCars = (entry, now)
        write(CacheRecord(siteId: siteId, carrier: via ?? session.carrier, srcState: answering ? .live : .stale, readAtMs: now, value: entry), to: shared)
    }

    /// Whether this home leaves records for the widgets.
    var sharesWidgets: Bool { siteId != nil && shared != nil }

    /// Leave today over the grid for the grid widget, dated when the box's
    /// totals arrived. `srcState` is the grid meter's as it was then.
    func shareGridToday(_ entry: GridTodayEntry, readAtMs: Double, srcState: SourceState) {
        guard let siteId, let shared, entry != lastGridToday else { return }
        lastGridToday = entry
        write(CacheRecord(siteId: siteId, carrier: session.carrier, srcState: srcState, readAtMs: readAtMs, value: entry), to: shared)
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
                if Value.self == GridTodayEntry.self { self?.lastGridToday = nil }
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

/// One model's sealed file, and what was written to it last.
@MainActor
private final class FileKeeper {
    let prefix: String
    let encode: @MainActor () -> Data?
    var last: Data?

    init(prefix: String, encode: @escaping @MainActor () -> Data?) {
        self.prefix = prefix
        self.encode = encode
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

// MARK: - FTW Cloud

/// Where a site model gets the phone's APNs token.
struct PushTokenSource: Sendable {
    var install: @Sendable (any PushTokenSink) async -> Void
    var uninstall: @Sendable () -> Void

    static let app = PushTokenSource(install: { await PushTokens.install($0) }, uninstall: { PushTokens.uninstall() })
}

/// The site model's end of `PushTokens`, which calls it off the main actor.
private struct CloudPushSink: PushTokenSink {
    let deliver: @MainActor @Sendable (PushTokens.Token) -> Void

    func register(apnsToken: Data, environment: PushEnvironment) async {
        await deliver(PushTokens.Token(data: apnsToken, environment: environment))
    }
}

/// Where the readings on screen come from.
enum ReadingSource: Sendable {
    case relay, cloud
}

/// What the app keeps of a home's FTW Cloud between launches: the box's word
/// on its key and names, and rule U's anchor. Both came from the box over
/// Noise; neither from the service.
struct CloudCache: Codable, Equatable, Sendable {
    /// The notification extension dates events with the same anchor.
    typealias Offset = CloudHome.Offset

    var identity: CloudIdentity
    var offset: Offset?
}

extension SiteModel {
    /// Read the home from FTW Cloud beside the box session, with the same
    /// device key. It starts once the box has said, now or at an earlier
    /// launch, that FTW Cloud is on and how to check what it forwards.
    public func connectCloud(deviceKey: Primitives.KeyPair, makeSocket: @escaping WebSocketFactory, endpoint: CloudEndpoint? = CloudEndpoint.current) {
        guard !destroyed, !isDemo else { return }
        cloudDevice = deviceKey
        cloudSocket = makeSocket
        cloudEndpoint = endpoint
        startCloud()
    }

    /// An owner pauses FTW Cloud for one of the home's phones, or lifts the
    /// pause. It only narrows what the box allows.
    @discardableResult
    public func suspendAtCloud(deviceID: String, _ on: Bool) -> Bool {
        cloud?.suspend(deviceID: deviceID, on) ?? false
    }

    /// Whether the box said FTW Cloud is on for this home.
    public var cloudOn: Bool { cloudIdentity != nil }

    private func startCloud() {
        guard cloud == nil, !destroyed, let endpoint = cloudEndpoint, let device = cloudDevice,
              let socket = cloudSocket, let identity = cloudIdentity else { return }
        let c = CloudCarrier(endpoint: endpoint, home: identity.home, deviceKey: device, looking: documentVisible, scheduler: scheduler, makeSocket: socket)
        c.setHandlers(
            onSnapshot: { [weak self] snap, at in self?.onCloudSnapshot(snap, at) },
            onEnvelope: { [weak self] env, at in self?.onCloudEnvelope(env, at) },
            onStatus: { [weak self] status in
                guard let self else { return }
                self.cloudStatus = status
                if status.isOpen { self.registerPush() }
                self.publish()
                self.scheduleClock()
            }
        )
        cloud = c
        cloudStatus = c.status
        installPushSink()
        c.start()
    }

    /// Close the session and keep what it delivered, which ages on screen.
    private func closeCloud() {
        cloud?.close()
        cloud = nil
        cloudStatus = nil
        publish()
    }

    private func adoptCloud(_ identity: CloudIdentity, offset: CloudCache.Offset?) {
        if !identity.sameHome(cloudIdentity) {
            closeCloud()
            cloudView = CloudView(home: identity.home, boxKey: identity.pk)
            ruleU = nil
        }
        cloudIdentity = identity
        if let offset, var view = cloudView {
            view.learnOffset(boot: offset.boot, phoneMs: offset.learnedAtMs, uptimeMs: offset.learnedAtMs - offset.offsetMs)
            cloudView = view
            ruleU = offset
        }
    }

    /// The box answered hello: FTW Cloud is on with this key, or off.
    private func cloudHello(_ identity: CloudIdentity?) {
        guard let identity else {
            // Off, or never on. What the cloud delivered goes with it, and
            // so do its pushes.
            closeCloud()
            if let home = cloudIdentity?.home ?? sharedCloudHome?.home { cloudKeys?.remove(home: home) }
            sharedCloudHome = nil
            uninstallPushSink()
            cloudView = nil
            cloudIdentity = nil
            ruleU = nil
            cloudDirty = false
            if let siteId { files?.remove("cloud-\(siteId)") }
            publish()
            return
        }
        adoptCloud(identity, offset: nil)
        shareCloudHome()
        cloudDirty = true
        persistNow()
        startCloud()
    }

    // MARK: Pushes

    /// The App Group files the notification extension reads. None in the
    /// demo, which has no App Group files.
    private var cloudKeys: CloudKeys? {
        shared.map { CloudKeys(directory: $0.directory) }
    }

    /// Give the notification extension what the box said over Noise: its
    /// key, its names, and rule U's anchor. Written only when it changed.
    private func shareCloudHome() {
        guard let siteId, let keys = cloudKeys, let identity = cloudIdentity else { return }
        let row = CloudHome(home: identity.home, siteId: siteId, boxKey: Data(identity.pk),
                            loadpoints: identity.loadpoints, sources: identity.sources, offset: ruleU)
        guard row != sharedCloudHome else { return }
        if let old = sharedCloudHome, old.home != row.home { keys.remove(home: old.home) }
        do {
            try keys.write(row)
            sharedCloudHome = row
        } catch {
            log.error("cloud keys not written: \(String(describing: error), privacy: .public)")
        }
    }

    /// While FTW Cloud is on, its session takes the phone's APNs token: it
    /// is how the service learns where Apple can reach this phone. The first
    /// install asks the person to allow notifications.
    private func installPushSink() {
        guard !pushSinkOn else { return }
        pushSinkOn = true
        let sink = CloudPushSink { [weak self] token in
            self?.pushToken = token
            self?.registerPush()
        }
        let source = pushTokens
        Task { await source.install(sink) }
    }

    private func uninstallPushSink() {
        guard pushSinkOn else { return }
        pushSinkOn = false
        pushToken = nil
        pushTokens.uninstall()
    }

    /// At every opening of the session, and when Apple gives a new token.
    private func registerPush() {
        guard let pushToken, let cloud, cloud.status.isOpen else { return }
        cloud.pushRegister(apnsToken: pushToken.data, environment: pushToken.environment)
    }

    /// Rule U: phone time minus box uptime, the smallest seen per boot.
    private func learnRuleU(boot: Bytes, uptimeMs: Double, phoneMs: Double) {
        guard var view = cloudView, uptimeMs > 0 else { return }
        let up = Int64(uptimeMs), now = Int64(phoneMs)
        view.learnOffset(boot: boot, phoneMs: now, uptimeMs: up)
        cloudView = view
        let offset = now - up
        if let held = ruleU, held.boot == boot, held.offsetMs <= offset {
            // Not smaller: only the time it was confirmed moves, which the
            // drift margin counts from. Kept in memory; written with the
            // next snapshot.
            ruleU = CloudCache.Offset(boot: boot, offsetMs: held.offsetMs, learnedAtMs: now)
        } else {
            ruleU = CloudCache.Offset(boot: boot, offsetMs: offset, learnedAtMs: now)
        }
        cloudDirty = true
    }

    private func onCloudSnapshot(_ snapshot: CloudWire.Snapshot, _ at: Double) {
        var any = false
        for env in snapshot.envelopes where acceptCloud(env, at) { any = true }
        first("cloud snapshot")
        if any { cloudRead(at) } else { publish() }
        scheduleClock()
    }

    private func onCloudEnvelope(_ env: CloudWire.Envelope, _ at: Double) {
        guard acceptCloud(env, at) else { return }
        if env.t == CloudWire.msgLive { first("cloud live") }
        cloudRead(at)
    }

    /// Check one envelope against the box's key and the freshness rules.
    /// The service cannot sign, so whatever fails here never reaches a screen.
    private func acceptCloud(_ env: CloudWire.Envelope, _ at: Double) -> Bool {
        guard var view = cloudView, (try? view.accept(env, arrivalMs: Int64(at))) != nil else { return false }
        cloudView = view
        switch env.t {
        case CloudWire.msgLP: takeCloudCars(at)
        case CloudWire.msgPrices: takeCloudPrices(at)
        default: break
        }
        return true
    }

    private func cloudRead(_ at: Double) {
        cloudArrivalMs = at
        if readingSource() == .cloud {
            cloudDelivered = true
            scheduleSnapshot()
        }
        publish()
        scheduleClock()
    }

    /// The box's own stream is where live readings come from: straight from
    /// the box, at its own rate. FTW Cloud gives the first frame before that
    /// stream is up, and stands in when it falls silent. Numbers never step
    /// back in time: a copy that is not live takes over only when it is at
    /// least as new as what is on screen. With neither live, the newer copy
    /// stays.
    private func readingSource() -> ReadingSource {
        guard let view = cloudView, view.live != nil else { return .relay }
        let now = scheduler.nowMs
        let relayStreaming = relay.phase == .streaming && relayFrameAtMs != nil
        if relayStreaming, relaySrcState == .live { return .relay }
        let cloudLive = Self.cloudState(view, nowMs: now) == .live
        if cloud?.status.isOpen == true, cloudLive { return .cloud }
        let cloudAt = view.anchorSentMs(nowMs: Int64(now)).map(Double.init)
        guard let relayAt = relayFrameAtMs ?? cachedAtMs else { return .cloud }
        return (cloudAt ?? -.infinity) >= relayAt ? .cloud : .relay
    }

    /// The cloud's readings in the shape the box session gives them, under
    /// the names the box session uses, aged to now.
    private func compose(_ s: inout SessionState, view: CloudView, identity: CloudIdentity) {
        guard let live = view.live else { return }
        let now = scheduler.nowMs
        let g = view.grade(nowMs: Int64(now))
        let name = { (id: String) in identity.sources[id] ?? id }
        var fields = [Int: Double]()
        for (k, v) in live.fields {
            if let fid = Int(k) { fields[fid] = Double(v) }
        }
        var dict = [Int: FieldDef]()
        for fid in fields.keys {
            let known = relay.dict[fid]
            dict[fid] = FieldDef(name: known?.name ?? "", unit: known?.unit, srcId: view.fieldSources[String(fid)]?.first.map(name))
        }
        let anchor = view.anchorReadings
        let t = Double(g.ageMs ?? 0)
        let upNow = Double(anchor?.uptimeMs ?? live.header.uptimeMs) + t
        var sources = [String: Source]()
        for (id, src) in view.sources {
            let n = name(id)
            let age = anchor?.ages[id].map { Double($0) + t } ?? (upNow - Double(src.lastOkMs))
            sources[n] = Source(kind: src.kind, name: relay.sources[n]?.name ?? n, lastOkMs: upNow - age,
                                staleAfterMs: Double(src.staleAfterMs), state: g.sources[id] ?? .never)
        }
        s.fields = fields
        s.dict = dict
        s.sources = sources
        s.dispatchBlockedBy = live.dispatchBlockedBy.map(name)
        s.uptimeMs = upNow
        s.carrier = cloud?.status.isOpen == true ? .cloud : .none
    }

    /// The worst grade among the fields Now draws. Never live without an
    /// anchor: a copy whose age cannot be checked is at best stale.
    static func cloudState(_ view: CloudView, nowMs: Double) -> SourceState {
        let g = view.grade(nowMs: Int64(nowMs))
        let graded = nowFids.compactMap { g.fields[String($0)] }
        var worst = graded.max() ?? g.sources.values.max() ?? .live
        if !g.anchored { worst = max(worst, .stale) }
        return worst
    }

    /// The cloud's grade for one field, never live without an anchor. Nil
    /// when Now is not reading through FTW Cloud.
    func cloudGrade(fid: Int) -> SourceState? {
        guard shown.source == .cloud, let view = shown.cloudView else { return nil }
        let g = view.grade(nowMs: Int64(nowMs))
        var grade = g.fields[String(fid)] ?? g.sources.values.max() ?? .live
        if !g.anchored { grade = max(grade, .stale) }
        return grade
    }

    /// The age of the oldest reading Now draws, by the anchor. Nil when the
    /// copy cannot be anchored: unverified, shown as "—".
    static func cloudAge(_ view: CloudView, nowMs: Double) -> Double? {
        let g = view.grade(nowMs: Int64(nowMs))
        guard g.anchored, let t = g.ageMs, let anchor = view.anchorReadings else { return nil }
        let ids = Set(nowFids.flatMap { view.fieldSources[String($0)] ?? [] })
        let ages = ids.compactMap { id -> Int64? in
            if let a = anchor.ages[id] { return a }
            return view.sources[id].map { anchor.uptimeMs - $0.lastOkMs }
        }
        guard let oldest = ages.max() else { return Double(t) }
        return Double(max(0, oldest) + t)
    }

    /// The cars as the cloud's lp has them, for the car's models and the
    /// widgets, dated when the box sent them.
    private func takeCloudCars(_ at: Double) {
        guard let view = cloudView, let lp = view.lp, let identity = cloudIdentity else { return }
        let now = scheduler.nowMs
        let g = view.grade(nowMs: Int64(now))
        let cars = lp.loadpoints.map { l in
            CarEntry.Car(
                loadpointID: identity.loadpoints[l.id] ?? l.id,
                pluggedIn: l.plugged,
                socPct: l.socPermille.map { (Double($0) / 10).rounded() },
                socSource: l.socSource,
                socReadAtMs: l.socAgeS.map { now - Double($0) * 1000 },
                powerW: Double(l.powerW),
                targetSocPct: l.targetPermille.map { (Double($0) / 10).rounded() }
            )
        }
        cloudCars = Stamped(cars, asOfMs: view.sentMs(lp.header, arrivalMs: Int64(at)).map(Double.init) ?? at, origin: .cloud)
        shareCarEntry(CarEntry(cars: cars), answering: lp.loadpoints.allSatisfy { g.loadpoints[$0.id] == .live }, via: .cloud)
    }

    /// The cloud's price window in the box session's shape, for the price
    /// model and the widgets.
    private func takeCloudPrices(_ at: Double) {
        guard let view = cloudView, let p = view.prices, p.slotMs > 0 else { return }
        var slots = [PriceSlot]()
        for i in p.spotMinor.indices {
            guard let spot = p.spotMinor[i], i < p.totalMinor.count, let total = p.totalMinor[i] else { continue }
            slots.append(PriceSlot(startMs: Double(p.t0Ms + Int64(i) * p.slotMs), durationMs: Double(p.slotMs),
                                   spotMinor: Double(spot), totalMinor: Double(total)))
        }
        guard !slots.isEmpty else { return }
        let prices = Prices(zone: p.zone, currency: p.currency, slots: slots, stale: false)
        cloudPrices = Stamped(PriceEntry(fromMs: Double(p.t0Ms), prices: prices, timeZone: session.box?.tz),
                              asOfMs: view.sentMs(p.header, arrivalMs: Int64(at)).map(Double.init) ?? at, origin: .cloud)
        sharePrices(prices, fromMs: Double(p.t0Ms), via: .cloud)
    }
}

extension CachedSnapshot {
    /// The same snapshot without the time it was written, to tell whether a
    /// new one says anything new.
    var timeless: CachedSnapshot {
        var c = self
        c.savedAtMs = 0
        return c
    }
}
