import Foundation
import FTWShared
import Observation

/// The last 48 hours of the home, from the box's history tiles: one query
/// at five minutes serves every node, so opening the battery after the sun
/// asks nothing new.
///
/// Closed tiles never change. They are sealed as `tiles-<site>` with the
/// tile still filling, so a node's history draws in frame one after a
/// kill, and the box is told which it already sent: only the tile still
/// filling crosses the wire again. That open tile stays on screen until
/// its replacement lands, so the right edge never pulls back.
///
/// The window is primed once after the first live frame, newest tile
/// first, and asked for again when the five minutes turn while a node's
/// view is open.
///
/// While the box cannot answer, FTW Cloud's copy can: it keeps the box's
/// signed tiles of the last 48 hours. They are asked for once per cloud
/// session and laid over what the phone holds, closed tiles being the same
/// bytes either way. They are dated, never live: `cloudUpToMs` says where
/// they end, and the box's own answer replaces them the moment it comes.
@Observable
@MainActor
public final class HistoryModel {
    /// The registry's names of what the tiles carry. The car is not among
    /// them: the box keeps no `ev_w` tiles (`CarEnergyModel` reads the car).
    public nonisolated static let series = ["grid_w", "pv_w", "battery_w", "load_w"]
    public nonisolated static let spanMs: Double = 48 * 3_600_000
    nonisolated static let maxPoints = 1500
    nonisolated static let stepMs: Double = 300_000

    public private(set) var frame: HistoryGeometry.Frame?
    public private(set) var gaps: [HistGap] = []
    /// The box answered at least once for this home since launch.
    public private(set) var loaded = false
    public private(set) var loading = false
    /// A sentence about the wire, never about the home.
    public private(set) var problem: String?
    /// What is shown came partly from FTW Cloud's copy, since the box last
    /// answered.
    public private(set) var fromCloud = false
    /// Where FTW Cloud's copy ends: the end of the newest five minutes with
    /// a value. Nil unless what is shown came from it.
    public private(set) var cloudUpToMs: Double?

    @ObservationIgnored private unowned let site: SiteModel
    @ObservationIgnored private var ask: LiveAsk?
    @ObservationIgnored private var active = 0
    @ObservationIgnored private var token = 0
    /// Closed tiles, by id. Immutable once closed.
    @ObservationIgnored private var tiles: [String: HistChunk] = [:]
    /// The tile still filling, as last sent: drawn until its replacement
    /// lands, never offered to the box as held.
    @ObservationIgnored private var open: HistChunk?
    /// The window has been asked for once since launch.
    @ObservationIgnored private var primed = false
    /// Tiles that land within one display frame are drawn as one change.
    @ObservationIgnored private var drawing: Cancellable?
    /// The load on the wire. A second caller waits for it rather than
    /// asking again.
    @ObservationIgnored private var running: Task<Void, Error>?
    /// The FTW Cloud session last asked for tiles, by when it opened, and
    /// whether its answer is complete.
    @ObservationIgnored private var cloudAsked: Double?
    @ObservationIgnored private var cloudAsking = false
    @ObservationIgnored private var cloudAnswered = false
    @ObservationIgnored let calendar: Calendar

    public init(site: SiteModel, calendar: Calendar = .current) {
        self.site = site
        self.calendar = calendar
        if let kept = site.keptFile(TileFile.self, "tiles"), kept.version == TileFile.version {
            for tile in kept.tiles.map(\.chunk) {
                if tile.partial { open = tile } else { tiles[tile.tileId] = tile }
            }
            let (plan, from, to) = window()
            show(plan, from, to)
        }
        site.keepFile("tiles") { [weak self] in self?.file }
        ask = LiveAsk(site: site, want: { [weak self] in
            guard let self, self.site.documentVisible, self.available, self.active > 0 || !self.primed else { return nil }
            // The window ends now, so which five minutes "now" is belongs
            // in the name; otherwise the right edge says "now" all day.
            return "history \(Int(self.site.nowMs / Self.stepMs))"
        }, ask: { [weak self] in try await self?.load() })
        site.observeCloudTiles { [weak self] end in self?.cloudTiles(end: end) }
        site.observe { [weak self] in self?.askCloud() }
    }

    /// Whether this box keeps history at all. Unknown until its hello.
    public var available: Bool {
        !site.heardFromBox || site.session.caps.contains(Contract.capHistory5m)
    }

    public func activate() {
        active += 1
        ask?.evaluate()
        askCloud()
    }

    public func deactivate() {
        active = max(0, active - 1)
        ask?.evaluate()
    }

    /// The 48 hours that end now, as tiles.
    private func window() -> (HistoryGeometry.TilePlan, Double, Double) {
        let to = site.nowMs
        let from = to - Self.spanMs
        return (HistoryGeometry.plan(.fiveMinutes, fromMs: from, toMs: to, maxPoints: Self.maxPoints), from, to)
    }

    /// Ask for the window, or wait for the ask already on the wire.
    func load() async throws {
        if let running { return try await running.value }
        let task = Task { @MainActor in try await self.fetchWindow() }
        running = task
        defer { running = nil }
        try await task.value
    }

    private func fetchWindow() async throws {
        token += 1
        let mine = token
        let (plan, from, to) = window()
        if frame == nil, !tiles.isEmpty || open != nil { show(plan, from, to) }
        loading = true
        defer { if mine == token { loading = false } }
        do {
            // With older tiles missing too, the tile still filling comes
            // first, so the right edge draws before the rest.
            if let newest = plan.tiles.last, plan.tiles.dropLast().contains(where: { tiles[$0.tileId] == nil }) {
                _ = try await fetch(HistQuery(series: Self.series, res: .fiveMinutes, fromMs: newest.startMs, toMs: to, maxPoints: Self.maxPoints), plan, from, to, mine)
                guard mine == token else { return }
            }
            let held = plan.tiles.compactMap { tiles[$0.tileId] }.map { ($0.tileId, $0.etag) }
            let end = try await fetch(HistQuery(series: Self.series, res: .fiveMinutes, fromMs: from, toMs: to, have: held, maxPoints: Self.maxPoints), plan, from, to, mine)
            guard mine == token else { return }
            drawing?.cancel()
            drawing = nil
            // Tiles that fell out of the window are not kept.
            tiles = tiles.filter { id, _ in plan.tiles.contains { $0.tileId == id } }
            if let o = open, !plan.tiles.contains(where: { $0.tileId == o.tileId }) { open = nil }
            show(plan, from, to)
            gaps = end.gaps
            loaded = true
            primed = true
            problem = nil
            // The box's own answer: FTW Cloud's copy has nothing to add.
            fromCloud = false
            cloudUpToMs = nil
        } catch {
            guard mine == token else { return }
            problem = Self.failure(error, hadSome: frame != nil)
            throw error
        }
    }

    private func fetch(_ query: HistQuery, _ plan: HistoryGeometry.TilePlan, _ from: Double, _ to: Double, _ mine: Int) async throws -> HistEnd {
        try await site.core.history(query) { [weak self] chunk in
            guard let self, mine == self.token else { return }
            if chunk.partial {
                self.open = chunk
            } else {
                self.tiles[chunk.tileId] = chunk
                if self.open?.tileId == chunk.tileId { self.open = nil }
            }
            // Drawn as the tiles arrive, a display frame at a time: a tile
            // still on its way is a bridge the next one grows into.
            guard self.drawing == nil else { return }
            self.drawing = self.site.scheduler.after(SiteModel.coalesceMs) { [weak self] in
                guard let self else { return }
                self.drawing = nil
                self.show(plan, from, to)
            }
        }
    }

    // MARK: FTW Cloud's copy

    /// The box streams: it answers for itself.
    private var boxAnswers: Bool { site.session.phase == .streaming }

    /// While the box cannot answer, ask FTW Cloud once per session for the
    /// tiles this phone lacks: the closed tiles held go as `have`.
    private func askCloud() {
        guard !boxAnswers, available, site.documentVisible, let since = site.cloudCopyOpenSinceMs, cloudAsked != since else { return }
        cloudAsked = since
        cloudAnswered = false
        let (plan, _, _) = window()
        var have = [String: String]()
        for p in plan.tiles { if let t = tiles[p.tileId] { have[t.tileId] = t.etag } }
        cloudAsking = site.askCloudTiles(have: have)
        takeCloud()
    }

    private func cloudTiles(end: Bool) {
        if end, cloudAsking {
            cloudAsking = false
            cloudAnswered = true
        }
        takeCloud()
    }

    /// FTW Cloud's tiles onto what is shown, unless the box answered while
    /// it streams. A closed tile is the box's bytes and fills in; the tile
    /// still filling is taken only when it reaches further than the one
    /// shown.
    private func takeCloud() {
        guard !(boxAnswers && loaded) else { return }
        let (plan, from, to) = window()
        var took = false
        for c in site.cloudTiles.laid where plan.tiles.contains(where: { $0.tileId == c.tileId }) {
            if c.partial {
                guard tiles[c.tileId] == nil, Self.reach(c) > open.map(Self.reach) ?? -.infinity else { continue }
                open = c
            } else {
                guard tiles[c.tileId]?.etag != c.etag else { continue }
                tiles[c.tileId] = c
                if open?.tileId == c.tileId { open = nil }
            }
            took = true
        }
        // Nothing new, as after a launch with the box still away and the
        // copy's tiles already in the file: what is shown is FTW Cloud's
        // copy all the same until the box answers, and is dated as one.
        let confirms = !loaded && cloudAnswered && site.cloudTiles.laid.contains { c in plan.tiles.contains { $0.tileId == c.tileId } }
        if took || confirms { fromCloud = true }
        show(plan, from, to)
        cloudUpToMs = fromCloud ? frame.flatMap(Self.dataEndMs) : nil
    }

    /// Where a tile's values end: the end of its newest step with a value
    /// in any series, or its start.
    nonisolated static func reach(_ c: HistChunk) -> Double {
        let columns = HistoryGeometry.unpack(c.data, seriesCount: c.series.count)
        let last = columns.compactMap { $0.lastIndex { $0 != missingSample } }.max()
        return c.startMs + Double((last ?? -1) + 1) * c.stepMs
    }

    /// The end of a frame's newest step with a value, nil when it has none.
    nonisolated static func dataEndMs(_ frame: HistoryGeometry.Frame) -> Double? {
        let last = frame.columns.compactMap { $0.lastIndex { $0 != missingSample } }.max()
        return last.map { frame.time(at: $0) + frame.stepMs }
    }

    /// "From FTW Cloud · up to 17:15": where the shown history came from
    /// and where it ends, dated so it never reads as now. Nil unless it
    /// came from FTW Cloud's copy.
    public func cloudNote(nowMs: Double, zone: TimeZone = .current) -> String? {
        guard let at = cloudUpToMs else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let today = cal.isDate(Date(timeIntervalSince1970: at / 1000), inSameDayAs: Date(timeIntervalSince1970: nowMs / 1000))
        return NodeWords.format("From FTW Cloud · up to %@", today ? AppWords.clock(at, zone: zone) : AppWords.day(at, nowMs: nowMs, zone: zone))
    }

    /// The closed tiles and the open one, laid on the window. Past the open
    /// tile's newest value nothing is known yet: those steps have not
    /// arrived, so they read as on their way, not as a hole the box has.
    private func show(_ plan: HistoryGeometry.TilePlan, _ from: Double, _ to: Double) {
        var have = tiles.filter { id, _ in plan.tiles.contains { $0.tileId == id } }
        if let open, have[open.tileId] == nil, plan.tiles.contains(where: { $0.tileId == open.tileId }) { have[open.tileId] = open }
        var assembled = HistoryGeometry.assemble(plan, names: Self.series, tiles: have)
        if let open, have[open.tileId] == open, let index = plan.tiles.firstIndex(where: { $0.tileId == open.tileId }) {
            let perTile = plan.tiles.first?.points ?? 0
            let base = index * perTile
            let filled = assembled.columns.map { column in
                (base..<min(column.count, base + perTile)).last { column[$0] != missingSample } ?? (base - 1)
            }.max() ?? (base - 1)
            let end = min(assembled.arrived.count, base + perTile)
            if filled + 1 < end { for i in (filled + 1)..<end { assembled.arrived[i] = false } }
        }
        let next = HistoryGeometry.clip(assembled, fromMs: from, toMs: to)
        if next != frame { frame = next }
    }

    /// What `tiles-<site>` keeps: the closed tiles in the window and the
    /// open one.
    var file: TileFile? {
        let kept = tiles.values.sorted { $0.startMs < $1.startMs } + (open.map { [$0] } ?? [])
        return kept.isEmpty ? nil : TileFile(tiles: kept.map(TileFile.Tile.init))
    }

    static func failure(_ error: Error, hadSome: Bool) -> String {
        if let refusal = error as? BoxRefusal, refusal.detail.code == "E_UNAVAILABLE" {
            return NodeWords.text("Your box can't send its history right now. Still trying.")
        }
        return hadSome ? NodeWords.text("Not up to date. Your box is out of reach.") : NodeWords.text("No history yet. Your box is out of reach.")
    }

    // MARK: What a node draws

    /// One node's samples from `fromMs`, as shown (solar as what it made),
    /// with a hole where the box recorded nothing.
    public func samples(_ node: EnergyNode, fromMs: Double) -> [HistorySample] {
        guard let frame else { return [] }
        return Self.samples(frame, node: node, fromMs: fromMs, untilMs: cloudUpToMs, fetching: pending)
    }

    /// A tile not here yet is on its way: while the box or FTW Cloud is
    /// asked, or before either has answered once and nothing has failed.
    var pending: Bool { loading || cloudAsking || (!loaded && problem == nil && !cloudAnswered) }

    /// `fetching`: a hole whose tile has not arrived is on its way, not
    /// known to be empty. `untilMs`: where FTW Cloud's copy ends. What
    /// follows is not in the copy, which says nothing about whether the box
    /// recorded it, so it is left out rather than counted as a hole.
    nonisolated static func samples(_ frame: HistoryGeometry.Frame, node: EnergyNode, fromMs: Double, untilMs: Double? = nil, fetching: Bool = false) -> [HistorySample] {
        guard frame.names.contains(node.series) else { return [] }
        var out = [HistorySample]()
        out.reserveCapacity(frame.points)
        for i in 0..<frame.points {
            let t = frame.time(at: i)
            guard t + frame.stepMs > fromMs, t < untilMs ?? .infinity else { continue }
            let watts = frame.value(node.series, at: i).map { node.shown(Double($0)) }
            out.append(HistorySample(startMs: t, stepMs: frame.stepMs, watts: watts, fetching: watts == nil && fetching && !frame.hasArrived(i)))
        }
        return out
    }

    /// Local midnight today, on the phone's clock.
    public var midnightMs: Double {
        calendar.startOfDay(for: Date(timeIntervalSince1970: site.nowMs / 1000)).timeIntervalSince1970 * 1000
    }

    /// Energy since midnight, from the same tiles the chart draws.
    public func today(_ node: EnergyNode) -> EnergyToday? {
        guard let frame, frame.names.contains(node.series) else { return nil }
        return EnergyToday.sum(Self.samples(frame, node: node, fromMs: midnightMs, untilMs: cloudUpToMs), fromMs: midnightMs)
    }
}

/// One step of a node's history: mean watts as shown, nil for a hole.
public struct HistorySample: Equatable, Sendable, Identifiable {
    public let startMs: Double
    public let stepMs: Double
    /// Signed as the node shows it: positive for solar making power, the
    /// battery charging, the home buying, the house using.
    public let watts: Double?
    /// A hole that is only not here yet: its tile is on its way. A hole
    /// that is not fetching is one the box has no record for.
    public var fetching = false
    public var id: Double { startMs }

    public init(startMs: Double, stepMs: Double, watts: Double?, fetching: Bool = false) {
        self.startMs = startMs
        self.stepMs = stepMs
        self.watts = watts
        self.fetching = fetching
    }
}

/// A node's history as the chart draws it: one point per step on a fixed
/// grid, so a point keeps its identity as data arrives; a break where the
/// box has no record; and over a stretch still being fetched, a straight
/// estimate between the measured points either side, never a value.
public enum HistoryPlot {
    public struct Point: Equatable, Sendable, Identifiable {
        public enum Kind: Equatable, Sendable { case measured, estimate }
        /// The middle of the step, or `fromMs` for a step cut by it.
        public let t: Double
        public let v: Double
        public let kind: Kind
        /// Measured points in the same run join; a hole the box confirms
        /// starts a new run. Estimates carry the run they bridge from.
        public let run: Int
        /// The step's start: the same for a point whether it is estimated
        /// or measured, so the one can grow into the other.
        public let id: Double

        public init(t: Double, v: Double, kind: Kind, run: Int, id: Double) {
            self.t = t
            self.v = v
            self.kind = kind
            self.run = run
            self.id = id
        }
    }

    public static func points(_ samples: [HistorySample], fromMs: Double) -> [Point] {
        var out = [Point]()
        out.reserveCapacity(samples.count)
        var run = 0
        var last: Point?
        var waiting = [HistorySample]()
        func t(_ s: HistorySample) -> Double { max(fromMs, s.startMs + s.stepMs / 2) }

        func settleWaiting(next: Point?) {
            defer { waiting.removeAll() }
            guard !waiting.isEmpty else { return }
            // A bridge needs a measured point on each side; without one the
            // stretch is simply not drawn yet.
            guard let a = last, a.kind == .measured, let b = next else {
                run += 1
                return
            }
            for s in waiting {
                let x = t(s)
                let f = b.t == a.t ? 0 : (x - a.t) / (b.t - a.t)
                out.append(Point(t: x, v: a.v + (b.v - a.v) * f, kind: .estimate, run: run, id: s.startMs))
            }
            // The measured line breaks under the bridge, so it never claims
            // a value there.
            run += 1
        }

        for s in samples {
            if let w = s.watts {
                let p = Point(t: t(s), v: w, kind: .measured, run: run, id: s.startMs)
                if !waiting.isEmpty { settleWaiting(next: Point(t: p.t, v: p.v, kind: .measured, run: run + 1, id: p.id)) }
                let point = Point(t: p.t, v: p.v, kind: .measured, run: run, id: p.id)
                out.append(point)
                last = point
            } else if s.fetching {
                waiting.append(s)
            } else {
                settleWaiting(next: nil)
                if last?.kind == .measured, last?.run == run { run += 1 }
                last = nil
            }
        }
        settleWaiting(next: nil)
        return out
    }
}

/// Energy one way and the other since a moment, in Wh. A mean power over a
/// step times the step is the energy the box's ledger recorded for it, so
/// these add up to what the box counted, less any hole.
public struct EnergyToday: Equatable, Sendable {
    /// Into the site: solar made, the battery charged, bought, used.
    public var inWh: Double
    /// Out of the site: the battery gave, the home sold.
    public var outWh: Double
    /// Time inside the window the box has no record for.
    public var missingMs: Double

    public static func sum(_ samples: [HistorySample], fromMs: Double) -> EnergyToday {
        var e = EnergyToday(inWh: 0, outWh: 0, missingMs: 0)
        for s in samples {
            // Only the part of the step since `fromMs`.
            let covered = max(0, s.startMs + s.stepMs - max(s.startMs, fromMs))
            guard covered > 0 else { continue }
            guard let w = s.watts else {
                // A step on its way is not missing yet.
                if !s.fetching { e.missingMs += covered }
                continue
            }
            let wh = abs(w) * covered / 3_600_000
            if w >= 0 { e.inWh += wh } else { e.outWh += wh }
        }
        return e
    }
}

/// What the car drew, hour by hour, from the box's energy ledger. The tiles
/// carry no car, so this reads `GET /api/energy/history` once when the car's
/// view opens and when the hour turns while it is open.
@Observable
@MainActor
public final class CarEnergyModel {
    public struct Hour: Equatable, Sendable, Identifiable {
        public let startMs: Double
        public let lenMs: Double
        public let wh: Double
        public var id: Double { startMs }
    }

    /// The ledger's name for energy into a car.
    static let flow = "vehicle_charge"

    public private(set) var hours: [Hour] = []
    public private(set) var loaded = false
    public private(set) var problem: String?

    @ObservationIgnored private unowned let site: SiteModel
    @ObservationIgnored private var ask: LiveAsk?
    @ObservationIgnored private var active = 0

    public init(site: SiteModel) {
        self.site = site
    }

    public func activate() {
        active += 1
        if ask == nil {
            ask = LiveAsk(site: site, want: { [weak self] in
                guard let self, self.active > 0, self.site.documentVisible, self.site.hasPassthrough else { return nil }
                return "car energy \(Int(self.site.nowMs / 3_600_000))"
            }, ask: { [weak self] in try await self?.load() })
        }
        ask?.evaluate()
    }

    public func deactivate() {
        active = max(0, active - 1)
        ask?.evaluate()
    }

    func load() async throws {
        let to = site.nowMs.rounded(.down)
        let from = to - HistoryModel.spanMs
        do {
            let wire = try await site.callBox(.get, "/api/energy/history", query: [
                "since": String(Int64(from)), "until": String(Int64(to)), "bucket": "1h", "scope": "system",
            ])
            hours = Self.hours(wire?["points"]?.array ?? [])
            loaded = true
            problem = nil
        } catch let e as BoxAPIError {
            problem = e.help
            throw e
        }
    }

    /// The ledger's rows for the car, summed per hour. A row the box marks
    /// invalid is not the car's energy.
    static func hours(_ points: [JSON]) -> [Hour] {
        var byStart = [Double: (len: Double, wh: Double)]()
        for p in points where p["flow"]?.string == flow && p["quality"]?.string != "invalid" {
            guard let start = p["bucket_start_ms"]?.number, let len = p["bucket_len_ms"]?.number, let wh = p["energy_wh"]?.number, wh.isFinite else { continue }
            let e = byStart[start, default: (len, 0)]
            byStart[start] = (max(e.len, len), e.wh + max(0, wh))
        }
        return byStart.map { Hour(startMs: $0.key, lenMs: $0.value.len, wh: $0.value.wh) }.sorted { $0.startMs < $1.startMs }
    }

    /// Since a moment, in Wh.
    public func wh(sinceMs: Double) -> Double {
        hours.reduce(0) { sum, h in
            let covered = max(0, h.startMs + h.lenMs - max(h.startMs, sinceMs))
            return sum + h.wh * min(1, covered / max(1, h.lenMs))
        }
    }
}

/// The history tiles as `tiles-<site>` keeps them: about 11.5 KB of closed
/// tiles for 48 hours, and the tile still filling, marked partial.
struct TileFile: Codable, Equatable, Sendable {
    static let version = 1

    struct Tile: Codable, Equatable, Sendable {
        var tileId: String
        var etag: String
        var res: String
        var startMs: Double
        var stepMs: Double
        var series: [String]
        var data: Data
        var partial: Bool

        init(_ c: HistChunk) {
            tileId = c.tileId
            etag = c.etag
            res = c.res.rawValue
            startMs = c.startMs
            stepMs = c.stepMs
            series = c.series
            data = Data(c.data)
            partial = c.partial
        }

        var chunk: HistChunk {
            HistChunk(tileId: tileId, etag: etag, res: Resolution(rawValue: res) ?? .fiveMinutes, startMs: startMs, stepMs: stepMs, series: series, data: data.byteArray, partial: partial)
        }
    }

    var version = TileFile.version
    var tiles: [Tile]
}
