import FTWKit
import FTWShared
import Observation
import os
import UIKit
import WatchConnectivity

/// The iPhone's side of the Apple Watch.
///
/// watchOS gives an ordinary app no WebSocket and no Network connection
/// (TN3135), so the watch can neither reach the relay nor hold a key. This
/// phone does both for it:
///
/// - After each write of the widgets' cache it hands the watch the same
///   records (`updateApplicationContext`). When tomorrow's prices arrive it
///   also wakes the watch's complication (`transferCurrentComplicationUserInfo`).
/// - While the watch app is on screen, it opens its own session and sends
///   Now's readings as they arrive, and stops when the watch looks away.
/// - A command from the watch (`sendMessageData`) runs here, over this
///   phone's session, exactly as the car view would send it. Each answer
///   from the box goes back as a receipt. FTW Cloud never controls.
///
/// A watch unlocked on the wrist counts as unlocked for its commands
/// (Fredrik, 14 Oct 2026). The device key opens after the first unlock, so
/// a locked phone in a pocket can still carry them.
///
/// The watch also offers its own public key. Once an owner adds it to the
/// box (`WatchAccess`), the context carries the watch's link, and the watch
/// reaches the box through FTW Cloud when this phone is away.
@MainActor
final class WatchBridge: NSObject {
    static let shared = WatchBridge()
    nonisolated static let log = Logger(subsystem: "energy.ftw.app", category: "watch")

    private var app: AppModel?
    private var runner: IntentRunner?
    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    /// The context last handed over, so the same records are not sent twice.
    private var lastSent: WatchContext?
    /// The last command's end, kept in the context for a watch that slept.
    private var lastReceipt: WatchReceipt?
    /// Writes come in bursts (prices, plan, car): one send after the last.
    private var pending: Task<Void, Never>?
    /// The demo writes no cache. While it runs, its records are watched
    /// instead, and sent at most this often.
    private static let demoEveryMs: Double = 60_000
    private var demoSentAtMs: Double = 0
    /// While the watch app is on screen: the session held open and Now's
    /// readings followed.
    private var look: Task<Void, Never>?
    private var lookTimer: Task<Void, Never>?
    /// The time iOS gives this app in the background for a look, taken anew
    /// with each word from the watch.
    private var lookTime: BackgroundTime?
    /// The watch says it still looks each time it comes to the front, and
    /// every 20 s while it stays there. Past this without word, the session
    /// is let go.
    private static let lookMs: Double = 120_000
    /// When Now last went to the watch.
    private var forwardedAtMs: Double = 0
    /// A look asked again after this long without Now gets the last three
    /// minutes again: the watch missed them.
    private static let missedMs: Double = 10_000

    private var nowMs: Double { Date.now.timeIntervalSince1970 * 1000 }

    /// Once, at launch, after the intents' runner.
    func install(_ app: AppModel, runner: IntentRunner) {
        self.app = app
        self.runner = runner
        guard let session else { return }
        session.delegate = self
        session.activate()
        followHome()
    }

    /// After every write to the App Group: the watch's copy follows.
    func cacheWritten() {
        schedule(after: .milliseconds(500))
    }

    private func schedule(after delay: Duration) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.send()
        }
    }

    /// Hand the watch what the phone holds now. Only to a paired watch with
    /// FTW installed; WatchConnectivity keeps the newest and delivers it
    /// when the watch next wakes.
    private func send() {
        guard let session, session.activationState == .activated, let app else { return }
        if app.isDemo { demoSentAtMs = nowMs }
        guard session.isPaired, session.isWatchAppInstalled else {
            Self.log.info("no watch to hand the context to: paired \(session.isPaired, privacy: .public), FTW on it \(session.isWatchAppInstalled, privacy: .public)")
            return
        }
        // No home and no paired site is a sign-out; no home with a site is
        // a phone still opening it, which the watch leaves be.
        let ctx = WatchShare.context(app.home, isDemo: app.isDemo, signedOut: app.home == nil && app.sites.current() == nil, receipt: lastReceipt, link: app.watchLink(), nowMs: nowMs)
        if let lastSent, lastSent.sameAs(ctx) { return }
        do {
            let data = try ctx.packed()
            try session.updateApplicationContext([WatchContext.key: data])
            if PriceEntry.bringsNewDay(old: lastSent?.prices?.value, new: ctx.prices?.value, nowMs: nowMs),
               session.isComplicationEnabled, session.remainingComplicationUserInfoTransfers > 0 {
                session.transferCurrentComplicationUserInfo([WatchContext.key: data])
                Self.log.info("tomorrow's prices to the complication, \(session.remainingComplicationUserInfoTransfers, privacy: .public) transfers left today")
            }
            lastSent = ctx
            Self.log.info("context to the watch: \(data.count, privacy: .public) bytes, home \(ctx.hasHome ? "yes" : "none", privacy: .public)")
        } catch {
            Self.log.error("context to the watch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The demo leaves no cache to follow: its records are watched
    /// directly. A paired home writes its cache, and that write sends.
    private func followHome() {
        guard let app else { return }
        withObservationTracking {
            _ = app.home
            // An owner added the watch: the link goes over at once.
            _ = app.watch.adding
            guard app.isDemo, let home = app.home else { return }
            _ = home.prices.window
            _ = home.loadpoints.stamp
            _ = home.nodes.plan.stamped
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.followHome()
                // The demo's own changes go at most once a minute; the last
                // of a burst waits for the minute to end.
                let wait = self.app?.isDemo == true ? max(500, Self.demoEveryMs - (self.nowMs - self.demoSentAtMs)) : 500
                self.schedule(after: .milliseconds(Int(wait)))
            }
        }
    }

    // MARK: The watch is looking

    private func startLooking() {
        send()
        // Each word from the watch takes the time in the background anew
        // before the last runs out, so a steady look with the phone locked
        // never gaps.
        let time = BackgroundTime("FTW watch looks") { [weak self] in self?.stopLooking() }
        lookTime?.end()
        lookTime = time
        // Asked again while it looks: keep the session, and only the clock
        // that lets it go starts over. A watch that went without Now
        // meanwhile gets the last three minutes again.
        if look != nil, nowMs - forwardedAtMs > Self.missedMs, let home = app?.home {
            send(news: .recent(WatchShare.recent(home, nowMs: nowMs)))
        }
        if look == nil, let runner {
            look = Task { [weak self] in
                _ = await runner.hold { home in
                    await self?.forwardNow(home)
                }
                self?.lookEnded()
            }
        }
        lookTimer?.cancel()
        lookTimer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.lookMs))
            guard !Task.isCancelled else { return }
            self?.stopLooking()
        }
    }

    private func stopLooking() {
        look?.cancel()
        look = nil
        lookTimer?.cancel()
        lookTimer = nil
    }

    /// The look's session is let go and suspended: the time in the
    /// background goes too, unless a new look has begun.
    private func lookEnded() {
        guard look == nil else { return }
        lookTime?.end()
        lookTime = nil
    }

    /// Now's readings to the watch as what it shows moves, and once a second
    /// otherwise, until the watch looks away, stops being reachable, or says
    /// nothing for `lookMs`.
    private func forwardNow(_ home: HomeModels) async {
        Self.log.info("watch looks: sending Now")
        let frames = FrameWatch(site: home.site)
        // The watch's pages count as screens that show these.
        let done = WatchShare.looking(home)
        defer {
            frames.stop()
            done()
        }
        // The reply to the look: the last three minutes first, so the trace
        // opens whole, then Now as it stands.
        send(news: .recent(WatchShare.recent(home, nowMs: nowMs)))
        var last = WatchShare.now(home)
        send(news: last.map(WatchNews.now))
        forwardedAtMs = nowMs
        // Ends when the look is let go; a watch out of reach meanwhile gets
        // nothing, and its reachability ends the look.
        for await _ in frames.stream {
            guard session?.isReachable == true else { continue }
            // At most a message a second unless what the wrist shows moved.
            guard let record = WatchShare.now(home), WatchShare.worthSending(record, after: last) else { continue }
            last = record
            send(news: .now(record))
            forwardedAtMs = nowMs
        }
        Self.log.info("watch looked away: Now no longer sent")
    }

    private func send(news: WatchNews?) {
        guard let news, let session, session.isReachable, let data = try? news.data() else { return }
        // WatchConnectivity calls back on its own queue, never the main one.
        session.sendMessageData(data, replyHandler: nil) { @Sendable error in
            WatchBridge.log.notice("news to the watch not delivered: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: A command from the watch

    private func run(_ command: WatchCommand) async {
        let time = BackgroundTime("FTW watch command")
        defer { time.end() }
        let started = ContinuousClock.now
        let end: WatchReceipt? = if let answer = WatchShare.answerAtOnce(command) {
            answer
        } else {
            await runner?.hold { [weak self] home in
                await WatchShare.run(command, home: home, nowMs: Date.now.timeIntervalSince1970 * 1000) { step in
                    self?.send(news: .receipt(step))
                }
            }
        }
        let receipt = end ?? WatchReceipt(commandID: command.id, op: command.op, sent: .failed, accepted: .waiting, confirmed: .waiting, text: ChargeNowActivity.openAndRetry, tone: .failed)
        Self.log.info("watch command \(String(describing: command.op), privacy: .public): \(receipt.tone.rawValue, privacy: .public) in \((ContinuousClock.now - started) / .milliseconds(1), format: .fixed(precision: 0), privacy: .public) ms")
        lastReceipt = receipt
        send(news: .receipt(receipt))
        // The car moved: the context carries the end and the
        // new state for a watch that looks later.
        await app?.site?.flushShared()
        send()
    }

    private func received(_ ask: WatchAsk) {
        switch ask {
        case .look: startLooking()
        case .away: stopLooking()
        case .command(let c): Task { await run(c) }
        }
    }
}

extension WatchBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error { WatchBridge.log.error("watch session: \(error.localizedDescription, privacy: .public)") }
        let key = session.receivedApplicationContext[WatchLink.watchKeyKey] as? Data
        Task { @MainActor in
            if let key { self.app?.watch.watchKey = key }
            self.send()
        }
    }

    /// The watch offered its key.
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let key = applicationContext[WatchLink.watchKeyKey] as? Data else { return }
        Task { @MainActor in
            guard self.app?.watch.watchKey != key else { return }
            self.app?.watch.watchKey = key
            self.lastSent = nil
            self.send()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// The person switched to another watch: the new one gets its own
    /// context.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
        Task { @MainActor in self.lastSent = nil }
    }

    /// FTW was installed on the watch, or a complication was added.
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.lastSent = nil
            self.send()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in if !reachable { self.stopLooking() } }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        guard let ask = WatchAsk.from(messageData) else { return }
        Task { @MainActor in self.received(ask) }
    }

    /// A command: the phone says at once that it has it, then the box's
    /// answers follow as news.
    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data, replyHandler: @escaping (Data) -> Void) {
        guard let ask = WatchAsk.from(messageData) else { return replyHandler(Data()) }
        if case .command(let c) = ask, let data = try? WatchNews.receipt(.phoneHasIt(c)).data() {
            replyHandler(data)
        } else {
            replyHandler(Data())
        }
        Task { @MainActor in self.received(ask) }
    }
}

/// Each change of the reading on screen, as a stream, for as long as it is
/// wanted. Observation drives it; nothing polls.
@MainActor
private final class FrameWatch {
    let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let site: SiteModel
    private var stopped = false

    init(site: SiteModel) {
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.site = site
        arm()
    }

    func stop() {
        stopped = true
        continuation.finish()
    }

    private func arm() {
        guard !stopped else { return }
        withObservationTracking {
            _ = site.readingAtMs
            _ = site.carrier
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.continuation.yield()
                self?.arm()
            }
        }
    }
}

/// A little time to finish in the background. The watch wakes this app
/// for a command or a look; without it iOS may freeze the app before the
/// box answers. UIKit is the only door to it.
@MainActor
private final class BackgroundTime {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(_ name: String, expired: @escaping @MainActor () -> Void = {}) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated {
                expired()
                self?.end()
            }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
