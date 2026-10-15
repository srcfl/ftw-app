import Foundation

// The bulk-lane answers history and the plan arrive in: `hist.query`,
// `hist.chunk` and `hist.end`, and `plan.get` with its `plan`. Shapes from
// ftw-webapp docs/protocol.md and the box's go/protocol/messages.go.
//
// Every decoder ignores keys it does not know and defaults what an older box
// leaves out.

// MARK: - History

/// The stores the box keeps, named as the registry's `resolutions` names them.
public enum Resolution: String, Sendable, CaseIterable {
    case fiveMinutes = "5m"
    case hour = "1h"
}

/// A hole on the wire. Distinct from zero, which is a real reading.
public let missingSample = Int32.min

public struct HistQuery: Sendable {
    /// Registry field names, such as `pv_w`.
    public var series: [String]
    public var res: Resolution
    /// Wall clock: these are hours a person reads.
    public var fromMs: Double
    public var toMs: Double
    /// Tiles already held, so the box sends only what changed.
    public var have: [(tileId: String, etag: String)]
    public var maxPoints: Int?

    public init(series: [String], res: Resolution, fromMs: Double, toMs: Double, have: [(tileId: String, etag: String)] = [], maxPoints: Int? = nil) {
        self.series = series
        self.res = res
        self.fromMs = fromMs
        self.toMs = toMs
        self.have = have
        self.maxPoints = maxPoints
    }

    var cbor: CBOR {
        var pairs: [(String, CBOR)] = [
            ("series", .array(series.map { .text($0) })),
            ("res", .text(res.rawValue)),
            // Whole milliseconds: the box reads these into int64 and drops a
            // query whose times carry a fraction.
            ("fromMs", .ms(fromMs)),
            ("toMs", .ms(toMs)),
        ]
        if !have.isEmpty {
            pairs.append(("have", .array(have.map { .map([("tileId", .text($0.tileId)), ("etag", .text($0.etag))]) })))
        }
        if let maxPoints { pairs.append(("maxPoints", .int(maxPoints))) }
        return .map(pairs)
    }
}

/// One tile: evenly spaced samples from `startMs`, one int32 column per
/// series. Mean watts over each step, site-signed.
public struct HistChunk: Sendable, Equatable {
    public var tileId: String
    public var etag: String
    public var res: Resolution
    public var startMs: Double
    public var stepMs: Double
    public var series: [String]
    /// Column-packed int32 little-endian, one block per series.
    public var data: Bytes
    /// The trailing tile is still filling; never kept.
    public var partial: Bool

    public init(tileId: String, etag: String, res: Resolution, startMs: Double, stepMs: Double, series: [String], data: Bytes, partial: Bool) {
        self.tileId = tileId
        self.etag = etag
        self.res = res
        self.startMs = startMs
        self.stepMs = stepMs
        self.series = series
        self.data = data
        self.partial = partial
    }

    init?(_ c: CBOR) {
        guard let tileId = c["tileId"]?.string else { return nil }
        self.tileId = tileId
        etag = c["etag"]?.string ?? ""
        res = c["res"]?.string.flatMap(Resolution.init(rawValue:)) ?? .fiveMinutes
        startMs = c["startMs"]?.double ?? 0
        stepMs = c["stepMs"]?.double ?? 300_000
        series = c["series"]?.stringArray ?? []
        data = c["data"]?.byteString ?? []
        partial = c["partial"]?.bool ?? false
    }

    var cbor: CBOR {
        .map([
            ("tileId", .text(tileId)), ("etag", .text(etag)), ("res", .text(res.rawValue)),
            ("startMs", .ms(startMs)), ("stepMs", .ms(stepMs)),
            ("series", .array(series.map { .text($0) })), ("data", .bytes(data)), ("partial", .bool(partial)),
        ])
    }
}

public struct HistGap: Equatable, Sendable {
    public var fromMs: Double
    public var toMs: Double
    public var reason: String
}

public struct HistEnd: Sendable, Equatable {
    /// What the box actually served, which may be coarser than asked for.
    public var resActual: Resolution
    public var gaps: [HistGap]

    init(_ c: CBOR) {
        resActual = c["resActual"]?.string.flatMap(Resolution.init(rawValue:)) ?? .fiveMinutes
        gaps = (c["gaps"]?.array ?? []).compactMap { g in
            guard let from = g["fromMs"]?.double, let to = g["toMs"]?.double else { return nil }
            return HistGap(fromMs: from, toMs: to, reason: g["reason"]?.string ?? "no_data")
        }
    }
}

// MARK: - The plan

public struct PlanSlot: Equatable, Sendable, Identifiable, Codable {
    /// Wall clock: these are future times a person reads.
    public var startMs: Double
    public var durationMs: Double
    /// Signed watts at the battery, site convention: positive charges.
    public var batteryW: Double
    /// Expected import at the meter; negative means expected export.
    public var gridW: Double
    /// Import price in minor units per kWh, nil when unknown.
    public var priceMinor: Double?
    /// A stable code, never prose. The app owns every word.
    public var reason: String
    /// The battery's planned level at the end of the slot, in thousandths.
    /// Nil from a box that does not send it.
    public var socPermille: Double?
    public var id: Double { startMs }

    public init(startMs: Double, durationMs: Double, batteryW: Double, gridW: Double, priceMinor: Double?, reason: String, socPermille: Double? = nil) {
        self.startMs = startMs
        self.durationMs = durationMs
        self.batteryW = batteryW
        self.gridW = gridW
        self.priceMinor = priceMinor
        self.reason = reason
        self.socPermille = socPermille
    }

    public var endMs: Double { startMs + durationMs }
}

/// What the box means to do, slot by slot. Intent, not prophecy: the box
/// replans as the day turns out.
public struct Plan: Equatable, Sendable, Codable {
    public var rev: UInt64
    public var uptimeMs: Double
    public var slots: [PlanSlot]
    /// The planner could not run, or its plan is old, and the box fell back.
    /// "Nothing scheduled" and "we do not know what is scheduled" are
    /// different sentences.
    public var stale: Bool
    public var ceilingW: Double?
    /// Each charger's share of the plan. Nil from a box that sends none,
    /// which also pushes no plan when it replans.
    public var chargers: [PlanCharger]?

    public init(rev: UInt64, uptimeMs: Double, slots: [PlanSlot], stale: Bool, ceilingW: Double?, chargers: [PlanCharger]? = nil) {
        self.rev = rev
        self.uptimeMs = uptimeMs
        self.slots = slots
        self.stale = stale
        self.ceilingW = ceilingW
        self.chargers = chargers
    }

    init(_ c: CBOR) {
        rev = UInt64(max(0, c["rev"]?.int64 ?? 0))
        uptimeMs = c["uptimeMs"]?.double ?? 0
        slots = (c["slots"]?.array ?? []).compactMap { s in
            guard let start = s["startMs"]?.double else { return nil }
            return PlanSlot(
                startMs: start,
                durationMs: s["durationMs"]?.double ?? 900_000,
                batteryW: s["batteryW"]?.double ?? 0,
                gridW: s["gridW"]?.double ?? 0,
                priceMinor: s["priceMinor"]?.double,
                reason: s["reason"]?.string ?? "idle",
                socPermille: s["socPermille"]?.double
            )
        }
        stale = c["stale"]?.bool ?? false
        ceilingW = c["ceilingW"]?.double
        chargers = c["chargers"]?.array?.compactMap { PlanCharger($0) }
    }

    var cbor: CBOR {
        var pairs: [(String, CBOR)] = [
            ("rev", .unsigned(rev)), ("uptimeMs", .ms(uptimeMs)),
            ("slots", .array(slots.map { s in
                var slot: [(String, CBOR)] = [
                    ("startMs", .ms(s.startMs)), ("durationMs", .ms(s.durationMs)),
                    ("batteryW", .ms(s.batteryW)), ("gridW", .ms(s.gridW)), ("reason", .text(s.reason)),
                ]
                slot.append(("priceMinor", s.priceMinor.map { .ms($0) } ?? .null))
                if let soc = s.socPermille { slot.append(("socPermille", .ms(soc))) }
                return .map(slot)
            })),
            ("stale", .bool(stale)),
        ]
        pairs.append(("ceilingW", ceilingW.map { .ms($0) } ?? .null))
        if let chargers { pairs.append(("chargers", .array(chargers.map(\.cbor)))) }
        return .map(pairs)
    }
}

/// One charger's share of the plan, as `GET /api/loadpoints` gives it, so
/// a plan the box pushes redraws the charger without a read. Keyed by the
/// charger: a car visits chargers.
public struct PlanCharger: Equatable, Sendable, Codable {
    /// The charger's loadpoint id.
    public var id: String
    /// The session's car, nil while the box does not know which, and from
    /// a box that keeps no cars.
    public var carId: String?
    public var pluggedIn: Bool
    /// A newer plan is being made, or the plan is not one the box acts on.
    /// The box sends no windows then.
    public var pending: Bool
    public var outdated: Bool
    public var windows: [Loadpoint.Window]
    public var totalWh: Double
    /// How far short of the goal the plan leaves the car, in battery
    /// watt-hours. Nil when the plan has no goal for it.
    public var shortfallWh: Double?

    public init(id: String, carId: String? = nil, pluggedIn: Bool, pending: Bool = false, outdated: Bool = false, windows: [Loadpoint.Window], totalWh: Double, shortfallWh: Double? = nil) {
        self.id = id
        self.carId = carId
        self.pluggedIn = pluggedIn
        self.pending = pending
        self.outdated = outdated
        self.windows = windows
        self.totalWh = totalWh
        self.shortfallWh = shortfallWh
    }

    init?(_ c: CBOR) {
        guard let id = c["id"]?.string else { return nil }
        self.id = id
        carId = c["carId"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        pluggedIn = c["pluggedIn"]?.bool ?? false
        pending = c["pending"]?.bool ?? false
        outdated = c["outdated"]?.bool ?? false
        windows = (c["windows"]?.array ?? []).compactMap { w in
            guard let s = w["startMs"]?.double, let e = w["endMs"]?.double, e > s, let wh = w["wh"]?.double, wh >= 0 else { return nil }
            return Loadpoint.Window(fromMs: s, toMs: e, peakW: nil, energyWh: wh)
        }
        totalWh = c["totalWh"]?.double ?? 0
        shortfallWh = c["shortfallWh"]?.double.map { max(0, $0) }
    }

    var cbor: CBOR {
        var pairs: [(String, CBOR)] = [
            ("id", .text(id)), ("pluggedIn", .bool(pluggedIn)), ("pending", .bool(pending)), ("outdated", .bool(outdated)),
            ("windows", .array(windows.map { .map([("startMs", .ms($0.fromMs)), ("endMs", .ms($0.toMs)), ("wh", .ms($0.energyWh ?? 0))]) })),
            ("totalWh", .ms(totalWh)),
        ]
        if let carId { pairs.append(("carId", .text(carId))) }
        if let shortfallWh { pairs.append(("shortfallWh", .ms(shortfallWh))) }
        return .map(pairs)
    }
}

extension HistQuery {
    /// The query as the box reads it, for the simulated box.
    public init?(cbor c: CBOR) {
        guard let res = c["res"]?.string.flatMap(Resolution.init(rawValue:)),
              let from = c["fromMs"]?.double, let to = c["toMs"]?.double else { return nil }
        self.init(
            series: c["series"]?.stringArray ?? [],
            res: res,
            fromMs: from,
            toMs: to,
            have: (c["have"]?.array ?? []).compactMap { h in
                guard let id = h["tileId"]?.string, let etag = h["etag"]?.string else { return nil }
                return (id, etag)
            },
            maxPoints: c["maxPoints"]?.int
        )
    }
}

extension HistChunk {
    /// The tile as it goes on the wire, for the simulated box.
    public var wire: CBOR { cbor }
}

extension Plan {
    /// The plan as it goes on the wire, for the simulated box.
    public var wire: CBOR { cbor }
}

extension HistEnd {
    public init(resActual: Resolution, gaps: [HistGap]) {
        self.resActual = resActual
        self.gaps = gaps
    }

    /// The end as it goes on the wire, for the simulated box.
    public var wire: CBOR {
        .map([
            ("resActual", .text(resActual.rawValue)),
            ("gaps", .array(gaps.map { .map([("fromMs", .ms($0.fromMs)), ("toMs", .ms($0.toMs)), ("reason", .text($0.reason))]) })),
        ])
    }
}
