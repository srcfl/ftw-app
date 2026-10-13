import Foundation
import FTWShared
import Observation

/// The last 48 hours of the home, from the box's history tiles: one query
/// at five minutes serves every node, so opening the battery after the sun
/// asks nothing new.
///
/// Closed tiles never change, so they are kept for the session and the box
/// is told which it already sent; only the tile still filling crosses the
/// wire again. The window is asked for again when the five minutes turn,
/// and only while a node's view is open.
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
    /// The box answered at least once for this home.
    public private(set) var loaded = false
    public private(set) var loading = false
    /// A sentence about the wire, never about the home.
    public private(set) var problem: String?

    @ObservationIgnored private unowned let site: SiteModel
    @ObservationIgnored private var ask: LiveAsk?
    @ObservationIgnored private var active = 0
    @ObservationIgnored private var token = 0
    /// Closed tiles, by id. Immutable once closed.
    @ObservationIgnored private var tiles: [String: HistChunk] = [:]
    @ObservationIgnored let calendar: Calendar

    public init(site: SiteModel, calendar: Calendar = .current) {
        self.site = site
        self.calendar = calendar
    }

    /// Whether this box keeps history at all. Unknown until its hello.
    public var available: Bool {
        !site.heardFromBox || site.session.caps.contains(Contract.capHistory5m)
    }

    public func activate() {
        active += 1
        if ask == nil {
            ask = LiveAsk(site: site, want: { [weak self] in
                guard let self, self.active > 0, self.site.documentVisible, self.available else { return nil }
                // The window ends now, so which five minutes "now" is
                // belongs in the name; otherwise the right edge says "now"
                // all day.
                return "history \(Int(self.site.nowMs / Self.stepMs))"
            }, ask: { [weak self] in try await self?.load() })
        }
        ask?.evaluate()
    }

    public func deactivate() {
        active = max(0, active - 1)
        ask?.evaluate()
    }

    func load() async throws {
        token += 1
        let mine = token
        let to = site.nowMs
        let from = to - Self.spanMs
        let plan = HistoryGeometry.plan(.fiveMinutes, fromMs: from, toMs: to, maxPoints: Self.maxPoints)
        var have = tiles.filter { id, _ in plan.tiles.contains { $0.tileId == id } }
        if frame == nil, !have.isEmpty { show(plan, have, from, to) }
        loading = true
        defer { if mine == token { loading = false } }
        do {
            let query = HistQuery(series: Self.series, res: .fiveMinutes, fromMs: from, toMs: to, have: have.values.map { ($0.tileId, $0.etag) }, maxPoints: Self.maxPoints)
            let end = try await site.core.history(query) { [weak self] chunk in
                guard let self, mine == self.token else { return }
                have[chunk.tileId] = chunk
                if !chunk.partial { self.tiles[chunk.tileId] = chunk }
                // Drawn as the tiles arrive: a tile still on its way is a
                // bridge the next one grows into.
                self.show(plan, have, from, to)
            }
            guard mine == token else { return }
            show(plan, have, from, to)
            gaps = end.gaps
            loaded = true
            problem = nil
            // Tiles that fell out of the window are not asked for again.
            tiles = tiles.filter { id, _ in plan.tiles.contains { $0.tileId == id } }
        } catch {
            guard mine == token else { return }
            problem = Self.failure(error, hadSome: frame != nil)
            throw error
        }
    }

    private func show(_ plan: HistoryGeometry.TilePlan, _ have: [String: HistChunk], _ from: Double, _ to: Double) {
        frame = HistoryGeometry.clip(HistoryGeometry.assemble(plan, names: Self.series, tiles: have), fromMs: from, toMs: to)
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
        return Self.samples(frame, node: node, fromMs: fromMs, fetching: loading)
    }

    /// `fetching`: a hole whose tile has not arrived is on its way, not
    /// known to be empty.
    nonisolated static func samples(_ frame: HistoryGeometry.Frame, node: EnergyNode, fromMs: Double, fetching: Bool = false) -> [HistorySample] {
        guard frame.names.contains(node.series) else { return [] }
        var out = [HistorySample]()
        out.reserveCapacity(frame.points)
        for i in 0..<frame.points {
            let t = frame.time(at: i)
            guard t + frame.stepMs > fromMs else { continue }
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
        return EnergyToday.sum(Self.samples(frame, node: node, fromMs: midnightMs), fromMs: midnightMs)
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
                e.missingMs += covered
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
