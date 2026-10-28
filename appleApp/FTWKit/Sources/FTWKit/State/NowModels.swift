import Foundation
import FTWShared
import Observation

/// A screen that is on screen. Models only ask the box for what someone can
/// see; a hidden tab keeps its state and stops asking.
@MainActor
public protocol Activatable: AnyObject {
    func activate()
    func deactivate()
}

/// Repeats a read on a fixed period while `shouldRun` holds, and reports a
/// retained answer as out of date once it is older than `maxAgeMs`.
@MainActor
final class Poller {
    private let scheduler: Scheduler
    private let periodMs: Double
    private let shouldRun: @MainActor () -> Bool
    private let work: @MainActor () async -> Void
    private var timer: Cancellable?
    private var running = false
    private var busy = false
    private var again = false

    init(scheduler: Scheduler, periodMs: Double, shouldRun: @escaping @MainActor () -> Bool, work: @escaping @MainActor () async -> Void) {
        self.scheduler = scheduler
        self.periodMs = periodMs
        self.shouldRun = shouldRun
        self.work = work
    }

    func start() {
        guard !running else { return }
        running = true
        tick()
    }

    func stop() {
        running = false
        timer?.cancel()
    }

    /// Read now, rather than at the next period. A confirmed action should
    /// reach the screen before its next timer.
    func refresh() {
        if busy { again = true } else if running { tick() }
    }

    private func tick() {
        timer?.cancel()
        guard running else { return }
        busy = true
        again = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.shouldRun() { await self.work() }
            self.busy = false
            guard self.running else { return }
            self.timer = self.scheduler.after(self.again ? 0 : self.periodMs) { [weak self] in self?.tick() }
        }
    }
}

/// The dashboard's own live document, GET /api/status, every two seconds
/// while the Now screen is up. Per-driver nodes, energy today, the fuse.
@Observable
@MainActor
public final class StatusWatch: Activatable {
    public static let maxAgeMs: Double = 15_000

    public private(set) var status: JSON?
    public private(set) var receivedAtMs: Double?
    public private(set) var fresh = false

    @ObservationIgnored private unowned let site: SiteModel
    @ObservationIgnored private var poller: Poller!
    @ObservationIgnored private var expiry: Cancellable?
    @ObservationIgnored private var active = 0

    public init(site: SiteModel) {
        self.site = site
        poller = Poller(scheduler: site.scheduler, periodMs: 2_000, shouldRun: { [weak self] in
            guard let self else { return false }
            return self.site.documentVisible && self.site.session.phase == .streaming && self.site.hasPassthrough
        }, work: { [weak self] in await self?.read() })
    }

    public func activate() {
        active += 1
        if active == 1 { poller.start() }
    }

    public func deactivate() {
        active = max(0, active - 1)
        if active == 0 {
            poller.stop()
            fresh = false
        }
    }

    private func read() async {
        do {
            let started = site.scheduler.nowMs
            guard let json = try await site.callBox(.get, "/api/status"), json.object != nil else { throw BoxAPIError(code: "E_BAD_BODY", help: "", status: nil) }
            let took = site.scheduler.nowMs - started
            status = json
            receivedAtMs = site.scheduler.nowMs
            fresh = took < Self.maxAgeMs && site.session.phase == .streaming
            expiry?.cancel()
            expiry = site.scheduler.after(max(0, Self.maxAgeMs - took)) { [weak self] in self?.fresh = false }
        } catch {
            expiry?.cancel()
            fresh = false
        }
    }
}

/// The chargers, read every five seconds for the Now diagram and the car
/// notice. Hidden phones stop polling.
@Observable
@MainActor
public final class ChargingWatch: Activatable {
    public private(set) var points: [Loadpoint] = []
    public private(set) var fresh = false

    @ObservationIgnored private unowned let site: SiteModel
    @ObservationIgnored private var poller: Poller!
    @ObservationIgnored private var expiry: Cancellable?
    @ObservationIgnored private var active = 0

    public init(site: SiteModel) {
        self.site = site
        poller = Poller(scheduler: site.scheduler, periodMs: 5_000, shouldRun: { [weak self] in
            guard let self else { return false }
            if !(self.site.documentVisible && self.site.session.phase == .streaming && self.site.hasPassthrough) {
                self.fresh = false
                return false
            }
            return true
        }, work: { [weak self] in await self?.read() })
    }

    public func activate() {
        active += 1
        if active == 1 { poller.start() }
    }

    public func deactivate() {
        active = max(0, active - 1)
        if active == 0 {
            poller.stop()
            fresh = false
        }
    }

    public func refresh() { poller.refresh() }

    /// Charger watts for the diagram, zero unless fresh.
    public var chargeW: Double { fresh ? Flow.loadpointChargeW(points) : 0 }

    private func read() async {
        do {
            guard let list = try await site.callBox(.get, "/api/loadpoints")?["loadpoints"]?.array else {
                throw BoxAPIError(code: "E_BAD_BODY", help: "", status: nil)
            }
            let next = list.map(Loadpoint.init).map { lp -> Loadpoint in
                // A charger that went out of touch keeps its last known cable.
                var lp = lp
                if lp.charger?.available == false, points.first(where: { $0.id == lp.id })?.pluggedIn == true { lp.pluggedIn = true }
                return lp
            }
            points = next
            fresh = site.documentVisible && site.session.phase == .streaming
            site.shareCars(next, fresh: fresh)
            expiry?.cancel()
            expiry = site.scheduler.after(15_000) { [weak self] in self?.fresh = false }
        } catch {
            fresh = false
        }
    }
}

/// Prices across today and tomorrow, from local midnight, asked for again
/// when the day turns and when tomorrow's rates publish.
///
/// It opens on the last window this phone had, from the sealed home file or
/// the widgets' record, and keeps it over midnight: yesterday's tomorrow is
/// today. The box's answer, or FTW Cloud's copy, replaces it only when it
/// differs.
///
/// The days behind today are a second window and a second read, asked for
/// once a day by the screens that draw them. Both in one request would not
/// fit: two days of quarter hours is 192 slots and about 11 kB, and the box
/// drops the far end of anything past the bulk frame it has
/// (`appproto/price.go` in srcfl/ftw). Keeping them apart also leaves the
/// widgets' record exactly what it was — today forward, nothing behind.
@Observable
@MainActor
public final class PriceModel: Activatable {
    static let horizonMs: Double = 48 * 3_600_000
    /// How far behind today the box is asked for: the two days the node
    /// timelines reach back.
    static let pastMs: Double = 48 * 3_600_000
    static let publishHour = 14

    /// The window on screen, with when and where it came from.
    public private(set) var window: Stamped<PriceEntry>?
    /// The days behind today, as the box last had them. Its `fromMs` is
    /// the midnight the window starts at, two days before today's.
    public private(set) var past: Stamped<PriceEntry>?
    /// Why there are no days behind: a sentence about the wire, never
    /// about the home.
    public private(set) var pastProblem: String?

    @ObservationIgnored private unowned let site: SiteModel
    @ObservationIgnored private var ask: LiveAsk?
    @ObservationIgnored private var pastAsk: LiveAsk?
    @ObservationIgnored private var active = 0
    @ObservationIgnored private var pastActive = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pastGeneration = 0
    @ObservationIgnored private let calendar: Calendar
    /// FTW Cloud's window as last taken, so it is taken once.
    @ObservationIgnored private var cloudTaken: Stamped<PriceEntry>?
    /// The name asked under after the publish hour. It stays once
    /// tomorrow's rates are here, so their arrival is no reason to ask
    /// again.
    @ObservationIgnored private var publishedName: String?

    /// `cache` is what the app left for its widgets: the window a launch
    /// opens on when the sealed home file has none.
    public init(site: SiteModel, calendar: Calendar = .current, cache: CacheReader? = nil) {
        self.site = site
        self.calendar = calendar
        let shared = site.siteId.flatMap { cache?.read(PriceEntry.self, siteId: $0) }.map { Stamped($0.value, asOfMs: $0.record.readAtMs, origin: .cache) }
        window = [site.kept?.prices?.cached, shared].compactMap { $0 }.max { $0.asOfMs < $1.asOfMs }
        if let kept = site.keptFile(PastPriceFile.self, "prices-past"), kept.version == PastPriceFile.version {
            past = Stamped(PriceEntry(fromMs: kept.fromMs, prices: kept.prices, timeZone: kept.timeZone), asOfMs: kept.asOfMs, origin: .cache)
        }
        site.keep { [weak self] home in home.prices = self?.window }
        site.keepFile("prices-past") { [weak self] in
            self?.past.map { PastPriceFile(fromMs: $0.value.fromMs, asOfMs: $0.asOfMs, prices: $0.value.prices, timeZone: $0.value.timeZone) }
        }
        site.observe { [weak self] in self?.takeCloud() }
    }

    public var prices: Prices? { window?.value.prices }
    public var fromMs: Double { window?.value.fromMs ?? 0 }

    /// Whether this box serves prices at all. Unknown until its hello, so
    /// a screen holds the shape of a price row rather than hiding it.
    public var available: Bool {
        !site.heardFromBox || site.session.caps.contains(Contract.capPriceSpot)
    }

    /// Every slot the phone holds in a window, the days behind and the days
    /// ahead as one series, each start once and the newer read winning. The
    /// box is the record: where neither window has a slot there is a hole,
    /// never a zero.
    public func slots(fromMs: Double, toMs: Double) -> [PriceSlot] {
        var byStart: [Double: PriceSlot] = [:]
        for slot in (past?.value.prices.slots ?? []) + (prices?.slots ?? [])
        where slot.startMs < toMs && slot.startMs + slot.durationMs > fromMs {
            byStart[slot.startMs] = slot
        }
        return byStart.values.sorted { $0.startMs < $1.startMs }
    }

    /// One day as History's price row tells it, out of every slot the phone
    /// holds.
    public func day(fromMs: Double, toMs: Double, clock: ZoneClock = .of(.current)) -> PriceDay {
        PriceDay.make(slots(fromMs: fromMs, toMs: toMs), fromMs: fromMs, toMs: toMs, currency: currency, clock: clock)
    }

    private func take(_ next: Stamped<PriceEntry>) {
        if let taken = Stamped.taking(next, over: window) { window = taken }
    }

    private func takeCloud() {
        guard let cloud = site.cloudPrices, cloud != cloudTaken else { return }
        cloudTaken = cloud
        take(cloud)
    }

    public var currency: String { prices?.currency ?? "SEK" }
    public var hasHole: Bool { prices.map { PriceUnits.hasHole($0.slots, fromMs: fromMs) } ?? false }

    func midnight(_ ms: Double) -> Double {
        calendar.startOfDay(for: Date(timeIntervalSince1970: ms / 1000)).timeIntervalSince1970 * 1000
    }

    /// The window, named by what would make it out of date: a new day, the
    /// hour tomorrow's rates publish, and, while they are late, each
    /// quarter hour until they come.
    var wanted: String? {
        guard active > 0, site.session.caps.contains(Contract.capPriceSpot) else { return nil }
        let now = Date(timeIntervalSince1970: site.nowMs / 1000)
        let hour = calendar.component(.hour, from: now)
        let day = midnight(site.nowMs)
        guard hour >= Self.publishHour else { return "\(day)/pending" }
        let here = hasTomorrow(after: day)
        if here, let publishedName, publishedName.hasPrefix("\(day)/") { return publishedName }
        let name = here ? "\(day)/published" : "\(day)/late \(Int(site.nowMs / 900_000))"
        publishedName = name
        return name
    }

    /// Whether the window on screen holds tomorrow's rates.
    func hasTomorrow(after day: Double) -> Bool {
        let tomorrow = midnight(day + 36 * 3_600_000)
        return prices?.slots.contains { $0.startMs >= tomorrow } ?? false
    }

    public func activate() {
        active += 1
        if ask == nil {
            ask = LiveAsk(site: site, want: { [weak self] in
                guard let self else { return nil }
                // A box that says it no longer offers prices shows none. A
                // window from yesterday still holds today's prices, so it
                // stays until the new one lands.
                if self.site.heardFromBox, !self.site.session.caps.contains(Contract.capPriceSpot), self.window != nil { self.window = nil }
                return self.wanted
            }, ask: { [weak self] in try await self?.load() })
        }
        ask?.evaluate()
    }

    public func deactivate() {
        active = max(0, active - 1)
        ask?.evaluate()
    }

    /// A screen that draws days behind today asks for them too: History's
    /// price row, and the price screen once it is dragged back. One read a
    /// day, on its own window.
    public func activatePast() {
        pastActive += 1
        if pastAsk == nil {
            pastAsk = LiveAsk(site: site, want: { [weak self] in
                guard let self, self.pastActive > 0, self.available, self.site.heardFromBox else { return nil }
                // Named by the day alone: the days behind do not change
                // when tomorrow's rates publish.
                return "past prices \(Int(self.pastFromMs))"
            }, ask: { [weak self] in try await self?.loadPast() })
        }
        pastAsk?.evaluate()
    }

    public func deactivatePast() {
        pastActive = max(0, pastActive - 1)
        pastAsk?.evaluate()
    }

    /// The midnight the days behind start at.
    var pastFromMs: Double { midnight(site.nowMs) - Self.pastMs }

    func load() async throws {
        generation += 1
        let mine = generation
        let from = midnight(site.nowMs)
        do {
            let wire = try await site.prices(fromMs: from, toMs: from + Self.horizonMs)
            guard mine == generation else { return }
            take(Stamped(PriceEntry(fromMs: from, prices: wire, timeZone: site.session.box?.tz), asOfMs: site.nowMs, origin: .relay))
            site.sharePrices(wire, fromMs: from)
        } catch {
            // A window already drawn stays drawn; today's prices are still
            // today's. Rethrown so the ask heals.
            guard mine == generation else { return }
            throw error
        }
    }

    /// The days behind today. The answer is whatever the box has stored:
    /// its prices table is never pruned, so a box that has run for a week
    /// answers the whole window and a box installed yesterday answers part
    /// of it. What it does not have stays a hole.
    func loadPast() async throws {
        pastGeneration += 1
        let mine = pastGeneration
        let from = pastFromMs
        do {
            let wire = try await site.prices(fromMs: from, toMs: from + Self.pastMs)
            guard mine == pastGeneration else { return }
            let next = Stamped(PriceEntry(fromMs: from, prices: wire, timeZone: site.session.box?.tz), asOfMs: site.nowMs, origin: .relay)
            if let taken = Stamped.taking(next, over: past) { past = taken }
            pastProblem = nil
        } catch {
            guard mine == pastGeneration else { return }
            // A window already drawn stays drawn and says nothing; with
            // none, the screen says what happens now.
            if past == nil { pastProblem = Self.failure(error) }
            throw error
        }
    }

    /// Why the days behind are missing. A price window crosses the session,
    /// not the API, so the errors are the session's: no carrier, a timeout,
    /// or the box refusing. What happens now, never what broke inside.
    static func failure(_ error: Error) -> String {
        if let refusal = error as? BoxRefusal, refusal.detail.code == "E_UNAVAILABLE" {
            return NodeWords.text("Your box can't send its prices right now. Still trying.")
        }
        return NodeWords.text("No prices yet. Your box is out of reach.")
    }
}

/// The days behind today, kept on this phone so History's price row paints
/// in frame one. Its own file: the widgets' record stays today forward.
struct PastPriceFile: Codable, Equatable, Sendable {
    static let version = 1

    var version = PastPriceFile.version
    var fromMs: Double
    var asOfMs: Double
    var prices: Prices
    var timeZone: String?
}

/// "Is FTW in control?" in one calm line, from the stream alone: lane 0
/// carries the box's dispatch block and each source's state, so the line
/// needs no request and no timer. It is green only while frames arrive
/// and the box says nothing blocks it; from a cache it is grey and dated.
/// Core's per-device control feedback joins it when lane 0 carries it (M5).
public enum InControl {
    public enum Tone: Equatable, Sendable { case ok, warning, neutral, stale }

    public struct Answer: Equatable, Sendable {
        public let tone: Tone
        public let title: String
        public let detail: String?

        public init(tone: Tone, title: String, detail: String?) {
            self.tone = tone
            self.title = title
            self.detail = detail
        }
    }

    /// - streaming: frames are arriving now over a live carrier.
    /// - sources: the box's own account of each device it reads.
    public static func answer(streaming: Bool, lastKnownMs: Double?, dispatchBlockedBy: [String], sources: [String: Source], zone: TimeZone = .current) -> Answer {
        guard streaming else {
            return Answer(tone: .stale, title: AppWords.text("Not live right now"), detail: lastKnownMs.map { AppWords.format("Last known %@.", AppWords.clock($0, zone: zone)) } ?? AppWords.text("Waiting for your box."))
        }
        if !dispatchBlockedBy.isEmpty {
            return Answer(tone: .warning, title: AppWords.text("FTW is not in control right now"), detail: AppWords.text("A meter stopped reporting. Your home runs on grid power as usual."))
        }
        let quiet = sources.values.filter { $0.state == .stale || $0.state == .down }.sorted { $0.name < $1.name }
        if let first = quiet.first {
            let title = quiet.count == 1 ? AppWords.format("%@ is not reporting", noun(first.kind)) : AppWords.format("%@ devices are not reporting", String(quiet.count))
            return Answer(tone: .warning, title: title, detail: first.name.isEmpty ? nil : first.name)
        }
        return Answer(tone: .ok, title: AppWords.text("Yes, FTW is in control"), detail: AppWords.text("Nothing blocks it, and every device reports."))
    }

    static func noun(_ kind: String) -> String {
        switch kind {
        case "meter": return AppWords.text("The meter")
        case "inverter": return AppWords.text("The inverter")
        case "battery": return AppWords.text("The battery")
        case "charger", "ev": return AppWords.text("The charger")
        default: return AppWords.text("A device")
        }
    }
}
