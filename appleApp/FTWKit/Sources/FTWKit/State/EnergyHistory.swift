import Foundation
import Observation

/// What the house used, made, bought and sold, day by day, from
/// GET /api/energy/daily. Integer watt-hours throughout, rounded once at the
/// door, so the total over the chart is the sum of the bars under it.
@Observable
@MainActor
public final class EnergyModel: Activatable {
    public enum Range: String, CaseIterable, Sendable, Identifiable {
        case today, week = "7d", month = "30d"
        public var id: String { rawValue }
        public var label: String { self == .today ? "Today" : self == .week ? "7 days" : "30 days" }
        public var title: String { self == .today ? "Today" : self == .week ? "Last 7 days" : "Last 30 days" }
        public var days: Int { self == .today ? 1 : self == .week ? 7 : 30 }
    }

    public struct Day: Equatable, Sendable, Identifiable {
        public let day: String
        public let loadWh: Double
        public let pvWh: Double
        public let importWh: Double
        public let exportWh: Double
        public let batChargedWh: Double
        public let batDischargedWh: Double
        public var id: String { day }
    }

    public struct Totals: Equatable, Sendable {
        public var loadWh: Double = 0
        public var pvWh: Double = 0
        public var importWh: Double = 0
        public var exportWh: Double = 0
        public var batChargedWh: Double = 0
        public var batDischargedWh: Double = 0
    }

    public private(set) var range: Range = .week
    /// Oldest first, today last.
    public private(set) var days: [Day] = []
    public private(set) var loading = false
    /// Whether the box has answered for this period. A period not yet read
    /// is not a period with nothing in it.
    public private(set) var loaded = false
    public private(set) var error: String?

    @ObservationIgnored private unowned let site: SiteModel
    @ObservationIgnored private var ask: LiveAsk?
    @ObservationIgnored private var active = 0
    @ObservationIgnored private var token = 0
    @ObservationIgnored private let calendar: Calendar

    public init(site: SiteModel, calendar: Calendar = .current) {
        self.site = site
        self.calendar = calendar
    }

    public var totals: Totals {
        days.reduce(into: Totals()) { t, d in
            t.loadWh += d.loadWh; t.pvWh += d.pvWh; t.importWh += d.importWh
            t.exportWh += d.exportWh; t.batChargedWh += d.batChargedWh; t.batDischargedWh += d.batDischargedWh
        }
    }

    /// "As much as", never "of": the sun and the kettle rarely coincide.
    public var solarSharePct: Int? {
        let t = totals
        guard t.loadWh > 0, t.pvWh > 0 else { return nil }
        return Int((t.pvWh / t.loadWh * 100).rounded())
    }

    public func activate() {
        active += 1
        if ask == nil {
            ask = LiveAsk(site: site, want: { [weak self] in
                guard let self, self.active > 0, self.site.documentVisible else { return nil }
                guard self.site.hasPassthrough else {
                    if !self.days.isEmpty { self.days = [] }
                    return nil
                }
                // Today's column fills all day, so the hour is in the name.
                let now = Date(timeIntervalSince1970: self.site.nowMs / 1000)
                return "energy \(self.range.rawValue) \(self.calendar.startOfDay(for: now).timeIntervalSince1970) \(self.calendar.component(.hour, from: now))"
            }, ask: { [weak self] in try await self?.load() })
        }
        ask?.evaluate()
    }

    public func deactivate() {
        active = max(0, active - 1)
        ask?.evaluate()
    }

    public func select(_ next: Range) {
        guard next != range else { return }
        token += 1
        range = next
        days = []
        loaded = false
        loading = false
        error = nil
        ask?.evaluate()
    }

    func load() async throws {
        token += 1
        let mine = token
        loading = true
        error = nil
        defer { if mine == token { loading = false } }
        do {
            let wire = try await site.callBox(.get, "/api/energy/daily", query: ["days": String(range.days)])
            guard mine == token else { return }
            days = (wire?["days"]?.array ?? []).map { row in
                Day(
                    day: row["day"]?.string ?? "",
                    loadWh: EnergyFormat.wholeWh(row["load_wh"]?.number),
                    pvWh: EnergyFormat.wholeWh(row["pv_wh"]?.number),
                    importWh: EnergyFormat.wholeWh(row["import_wh"]?.number),
                    exportWh: EnergyFormat.wholeWh(row["export_wh"]?.number),
                    batChargedWh: EnergyFormat.wholeWh(row["bat_charged_wh"]?.number),
                    batDischargedWh: EnergyFormat.wholeWh(row["bat_discharged_wh"]?.number)
                )
            }
            loaded = true
        } catch {
            guard mine == token else { return }
            if let e = error as? BoxAPIError, days.isEmpty {
                self.error = e.help
            } else {
                self.error = "Not up to date — your box is out of reach"
            }
            throw error
        }
    }
}

/// Power over time: cache first, box second, then the difference only.
@Observable
@MainActor
public final class HistoryModel: Activatable {
    public enum Range: String, CaseIterable, Sendable, Identifiable {
        case day = "24h", week = "7d", month = "30d", year = "1y"
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .day: return "24 h"
            case .week: return "7 d"
            case .month: return "30 d"
            case .year: return "1 y"
            }
        }
        var spanMs: Double {
            switch self {
            case .day: return 86_400_000
            case .week: return 7 * 86_400_000
            case .month: return 30 * 86_400_000
            case .year: return 365 * 86_400_000
            }
        }
        var res: Resolution { self == .year ? .hour : .fiveMinutes }
    }

    /// Names from the registry, in the order they are drawn.
    public static let series = ["grid_w", "pv_w", "battery_w", "load_w"]
    static let maxPoints = 1500

    public private(set) var range: Range = .day
    public private(set) var frame: HistoryGeometry.Frame?
    public private(set) var resActual: Resolution?
    public private(set) var gaps: [HistGap] = []
    public private(set) var loading = false
    public private(set) var loaded = false
    public private(set) var error: String?
    /// The sample under the finger, as an index into `frame`.
    public var cursor: Int?

    @ObservationIgnored private unowned let site: SiteModel
    @ObservationIgnored private let tiles: TileCache
    @ObservationIgnored private var ask: LiveAsk?
    @ObservationIgnored private var active = 0
    @ObservationIgnored private var token = 0

    public init(site: SiteModel, tiles: TileCache) {
        self.site = site
        self.tiles = tiles
    }

    public func activate() {
        active += 1
        if ask == nil {
            ask = LiveAsk(site: site, want: { [weak self] in
                guard let self, self.active > 0, self.site.documentVisible else { return nil }
                // The window ends now, so which five minutes "now" is belongs
                // in the name; otherwise the right edge says "now" all day.
                return "\(self.range.rawValue) \(Int(self.site.nowMs / 300_000))"
            }, ask: { [weak self] in try await self?.load() })
        }
        ask?.evaluate()
    }

    public func deactivate() {
        active = max(0, active - 1)
        ask?.evaluate()
    }

    public func select(_ next: Range) {
        // The cursor is an index into this frame, and the same index in
        // another range is another moment.
        if next != range { cursor = nil }
        range = next
        ask?.evaluate()
    }

    /// The time under the cursor.
    public var cursorAtMs: Double? {
        guard let frame, let cursor else { return nil }
        return frame.time(at: cursor)
    }

    /// The value under the cursor, or the latest.
    public func value(_ name: String) -> Double? {
        guard let frame, frame.points > 0 else { return nil }
        return frame.value(name, at: cursor ?? frame.points - 1).map(Double.init)
    }

    public var missingMs: Double { gaps.reduce(0) { $0 + ($1.toMs - $1.fromMs) } }

    func load() async throws {
        token += 1
        let mine = token
        let names = Self.series
        let to = site.scheduler.nowMs
        let from = to - range.spanMs
        let plan = HistoryGeometry.plan(range.res, fromMs: from, toMs: to, maxPoints: Self.maxPoints)
        let cached = tiles.get(plan.tiles.map(\.tileId))
        var have = cached
        func show() { frame = HistoryGeometry.clip(HistoryGeometry.assemble(plan, names: names, tiles: have), fromMs: from, toMs: to) }
        // Whatever is on disk goes up now.
        if !cached.isEmpty { show() }

        loading = true
        error = nil
        defer { if mine == token { loading = false } }
        do {
            let end = try await site.history(
                HistQuery(series: names, res: range.res, fromMs: from, toMs: to, have: cached.values.map { ($0.tileId, $0.etag) }, maxPoints: Self.maxPoints)
            ) { [weak self] chunk in
                guard let self, mine == self.token else { return }
                have[chunk.tileId] = chunk
                self.tiles.put(chunk)
            }
            guard mine == token else { return }
            show()
            resActual = end.resActual
            gaps = end.gaps
            loaded = true
            tiles.flush(nowMs: to)
        } catch {
            guard mine == token else { return }
            if !have.isEmpty { show() }
            // Both sentences are about the wire, never about the house: an
            // answer that did not arrive says nothing about what was recorded.
            self.error = have.isEmpty ? "Nothing through yet — your box is out of reach" : "Not up to date — your box is out of reach"
            throw error
        }
    }

    /// "5 min trend · 5 min box readings" or "One point every hour".
    public var note: String {
        if let error { return error }
        if loading { return "Reading your box…" }
        guard let frame, resActual != nil else { return "" }
        let step = frame.stepMs
        var text: String
        if step < 3_600_000 {
            text = "One point every \(Int((step / 60_000).rounded())) minutes, from your box"
        } else {
            let hours = Int((step / 3_600_000).rounded())
            text = "One point every \(hours == 1 ? "hour" : hours == 24 ? "day" : "\(hours) hours"), from your box"
        }
        if missingMs > 0 {
            let m = missingMs
            text += " · \(m < 3_600_000 ? "\(max(1, Int((m / 60_000).rounded()))) min" : "\(Int((m / 3_600_000).rounded())) h") not recorded"
        }
        return text
    }
}
