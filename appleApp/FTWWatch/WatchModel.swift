import Foundation
import FTWShared
import Observation
import os

/// The watch's side of FTW: the last truth it kept, Now as it streams while
/// the app is on screen, and the receipts of its commands.
///
/// It reads through a `ReadPath` and sends through a `CommandPath`; today
/// both are the iPhone. It opens on its own cache before any path speaks,
/// so a watch with no phone near still shows what it last knew, dated. A
/// reading glows only for a moment after a live frame arrived.
@Observable
@MainActor
final class WatchModel {
    nonisolated static let log = Logger(subsystem: "energy.ftw.app.watchkitapp", category: "watch")

    /// The last context: from a path, or kept from before. Nil before the
    /// watch ever had one.
    private(set) var context: WatchContext?
    /// Now: the latest live frame, or the context's copy.
    private(set) var now: CacheRecord<WatchNow>?
    /// Whether Now glows: on with each live frame, off once the stream's
    /// own pace has passed with none (`WatchGlance.Glow`).
    private(set) var lit = false
    /// Commands can leave now.
    private(set) var canSend = false
    /// The phone can be reached: which car needs it.
    private(set) var phoneReachable = false
    /// The receipt of the last command for each target: a charger's id.
    private(set) var receipts: [String: WatchReceipt] = [:]

    /// Now's live trace, fed by the frames the phone passes on.
    let trace = WatchTrace(node: WatchModel.heroNode)

    /// The node Now traces, as the wrist last chose it. The home's use by
    /// default: it moves whenever something in the house switches.
    static var heroNode: WatchNow.Node {
        UserDefaults.standard.string(forKey: "FTWWatchHero").flatMap(WatchNow.Node.init(rawValue:)) ?? .home
    }

    func follow(_ node: WatchNow.Node) {
        UserDefaults.standard.set(node.rawValue, forKey: "FTWWatchHero")
        trace.follow(node)
    }

    @ObservationIgnored private let read: any ReadPath
    @ObservationIgnored private let command: any CommandPath
    @ObservationIgnored private let cache: WatchCache?
    /// When the latest live frame reached this watch. Nil for a copy from
    /// a context or the cache, which never glows.
    @ObservationIgnored private var nowArrivedAtMs: Double?
    @ObservationIgnored private var glow = WatchGlance.Glow()
    @ObservationIgnored private var cooling: Task<Void, Never>?
    /// On screen, so the phone should be sending Now.
    @ObservationIgnored private var looking = false
    @ObservationIgnored private var askedAtMs: Double = 0

    private var nowMs: Double { Date.now.timeIntervalSince1970 * 1000 }

    var zone: TimeZone { WatchGlance.zone(context) }
    var hasHome: Bool { context?.hasHome == true }

    init(read: any ReadPath, command: any CommandPath, cache: WatchCache?) {
        self.read = read
        self.command = command
        self.cache = cache
    }

    /// The paths this build uses: the phone, and FTW Cloud when the phone
    /// does not answer.
    static func make() -> WatchModel {
        let paths = PathChooser()
        let model = WatchModel(read: paths, command: paths, cache: .shared())
        paths.kept = { [weak model] in model?.context }
        return model
    }

    /// Open on the last truth, then listen.
    func start() {
        if let kept = cache?.load().map(Self.forPictures) {
            if let recent = kept.recent { trace.backfill(recent) }
            take(kept, keep: false)
        }
        read.start { [weak self] in self?.handle($0) }
        // The watch's own key, made once, for the day it reaches the box
        // without the phone.
        Task.detached(priority: .utility) {
            if WatchIdentity.publicKey() == nil { WatchModel.log.notice("no watch key yet") }
        }
    }

    /// How often a steady look tells the phone it still looks, well inside
    /// the phone's own time in the background and its 2 minutes.
    static let renewMs: Double = 20_000

    func look() {
        looking = true
        askedAtMs = nowMs
        read.look()
    }

    /// A complication's refresh in the background: one read, kept before
    /// watchOS ends the wake.
    func refresh() async {
        await read.refresh()
        if let ctx = context, ctx.hasHome { await cache?.save(ctx) }
    }

    /// Off screen: keep the newest frame and the trace's last minutes as
    /// the last truth, dated, for the next open.
    func away() {
        looking = false
        glow.reset()
        read.away()
        guard var ctx = context, ctx.hasHome else { return }
        if let now, now.readAtMs > (ctx.now?.readAtMs ?? 0) { ctx.now = now }
        ctx.recent = trace.recent() ?? ctx.recent
        context = ctx
        keep(ctx)
    }

    private func handle(_ event: PathEvent) {
        #if DEBUG
        if Self.noReading {
            switch event {
            case .news(.now), .news(.recent): return
            case .context(let ctx): return take(Self.forPictures(ctx), keep: false)
            default: break
            }
        }
        #endif
        switch event {
        case .context(let ctx): take(ctx, keep: true)
        case .news(.now(let record)): frame(record)
        case .news(.receipt(let r)): receipt(r)
        case .news(.recent(let r)):
            guard let ctx = context, ctx.hasHome else { return }
            trace.backfill(r)
            // Kept at once, so an open after a kill has these minutes too.
            keep(ctx)
        case .canSend(let ok): canSend = ok
        case .phoneReachable(let ok): phoneReachable = ok
        case .notSent(let id):
            guard let hit = receipts.first(where: { $0.value.commandID == id }), hit.value.sent == .active else { return }
            receipts[hit.key] = .unreachable(WatchCommand(id: id, op: hit.value.op, home: context?.home ?? "", sentAtMs: nowMs))
        }
    }

    // MARK: The context

    /// `-FTWWatchNoReading YES` (debug builds) keeps Now's readings away,
    /// for pictures of the shape Now shows before its first one.
    private static var noReading: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "FTWWatchNoReading")
        #else
        false
        #endif
    }

    private static func forPictures(_ ctx: WatchContext) -> WatchContext {
        guard noReading else { return ctx }
        var out = ctx
        out.now = nil
        out.recent = nil
        return out
    }

    /// A context from a path or the cache. Only a sign-out forgets; a
    /// record the phone did not send keeps the one the watch has.
    private func take(_ next: WatchContext, keep: Bool) {
        guard let ctx = WatchContext.merging(next, over: context) else { return }
        if let old = context, old.sameAs(ctx) { return }
        if !ctx.hasHome {
            trace.clear()
            now = nil
            nowArrivedAtMs = nil
        }
        context = ctx
        // A live frame newer than the context's copy keeps its place.
        if nowArrivedAtMs == nil || (ctx.now?.readAtMs ?? 0) > (now?.readAtMs ?? 0) {
            now = ctx.now
            nowArrivedAtMs = nil
            relight()
            // A kept reading joins the trace in ink: seen, but not live.
            if let record = ctx.now { trace.add(record, lit: false) }
        }
        if let r = ctx.receipt { receipt(r) }
        if keep { self.keep(ctx) }
    }

    /// Keep `ctx` with the trace as it stands, so an open after a kill
    /// still has its last minutes.
    private func keep(_ ctx: WatchContext) {
        guard let cache else { return }
        var ctx = ctx
        if ctx.hasHome { ctx.recent = trace.recent() ?? ctx.recent }
        Task { [ctx] in await cache.save(ctx) }
    }

    private func frame(_ record: CacheRecord<WatchNow>) {
        guard context == nil || record.siteId == context?.home else { return }
        // Two paths may bring Now: an older reading never replaces a newer.
        guard record.readAtMs >= (now?.readAtMs ?? 0) else { return }
        glow.frame(readAtMs: record.readAtMs, standsMs: record.value.standsMs)
        now = record
        nowArrivedAtMs = nowMs
        relight()
        trace.add(record, lit: lit)
        // A steady look renews itself with the frames, so the phone never
        // lets it go while the wrist is up.
        if looking, nowMs - askedAtMs > Self.renewMs { look() }
    }

    /// Glow while the last frame is fresh for the stream's pace, then cool
    /// once: one wake per frame, no ticking timer.
    private func relight() {
        let forMs = glow.forMs
        lit = WatchGlance.lit(now, arrivedAtMs: nowArrivedAtMs, forMs: forMs, nowMs: nowMs)
        cooling?.cancel()
        guard lit, let arrived = nowArrivedAtMs else {
            trace.settle()
            return
        }
        let left = max(0, arrived + forMs - nowMs)
        cooling = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(left) + 50))
            guard !Task.isCancelled else { return }
            self?.cooled()
        }
    }

    /// No frame came in the stream's own time: dark, and one more ask in
    /// case the phone let the look go.
    private func cooled() {
        relight()
        guard !lit else { return }
        glow.reset()
        if looking { look() }
    }

    // MARK: Commands

    static func target(_ op: WatchCommand.Op) -> String {
        switch op {
        case .chargeNow(let id), .pause(let id), .backToPlan(let id), .chooseCar(let id, _, _): return id
        // The watch sends no mode: it changes in Plan on the iPhone.
        case .mode: return "mode"
        }
    }

    func receipt(for target: String) -> WatchReceipt? { receipts[target] }

    /// A command is on its way for this target.
    func sending(_ target: String) -> Bool { receipts[target].map { !$0.settled } ?? false }

    /// Leaving the car page lets its settled receipts go, so the page shows
    /// the car's state on return. A command still under way keeps its receipt.
    func leaveCars() {
        receipts = receipts.filter { !$0.value.settled }
    }

    /// The receipt shows at once; every mark after "sending" is the box's
    /// answer as the path brings it back.
    func send(_ op: WatchCommand.Op) {
        let target = Self.target(op)
        guard let home = context?.home, !sending(target) else { return }
        let c = WatchCommand(op: op, home: home, sentAtMs: nowMs)
        receipts[target] = .tapped(c)
        command.send(c)
        // One wait for an answer, not a loop: past it, say so honestly.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(WatchReceipt.answerMs)))
            guard let self, let r = self.receipts[target], r.commandID == c.id else { return }
            self.receipts[target] = r.noAnswer()
        }
    }

    private func receipt(_ r: WatchReceipt) {
        let target = Self.target(r.op)
        guard let mine = receipts[target], let next = mine.taking(r) else { return }
        receipts[target] = next
    }
}
