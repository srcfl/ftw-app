import Foundation

// The plan as the box sends it: `plan.get` and its `plan`. Shapes from
// ftw-webapp docs/protocol.md and the box's go/protocol/messages.go. History
// is in FTWWire (`History.swift`).
//
// Every decoder ignores keys it does not know and defaults what an older box
// leaves out.

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

    package init(_ c: CBOR) {
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

    package var cbor: CBOR {
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
    /// A newer plan is being made: the windows are the plan the box goes on
    /// acting on until the new one lands. Outdated comes with it, and alone
    /// when the plan is not one the box acts on; then there are no windows.
    public var pending: Bool
    public var outdated: Bool
    /// Grid-funded charging waits for prices that reach the deadline.
    public var gridDeferred: Bool
    /// Moves when the charger's goal, ready time, schedule or solar-only
    /// choice changes, wherever that was done. Nil from a box without it.
    public var goalRev: UInt32?
    public var windows: [Loadpoint.Window]
    public var totalWh: Double
    /// How far short of the goal the plan leaves the car, in battery
    /// watt-hours. Nil when the plan has no goal for it.
    public var shortfallWh: Double?

    public init(id: String, carId: String? = nil, pluggedIn: Bool, pending: Bool = false, outdated: Bool = false, gridDeferred: Bool = false, goalRev: UInt32? = nil, windows: [Loadpoint.Window], totalWh: Double, shortfallWh: Double? = nil) {
        self.id = id
        self.carId = carId
        self.pluggedIn = pluggedIn
        self.pending = pending
        self.outdated = outdated
        self.gridDeferred = gridDeferred
        self.goalRev = goalRev
        self.windows = windows
        self.totalWh = totalWh
        self.shortfallWh = shortfallWh
    }

    package init?(_ c: CBOR) {
        guard let id = c["id"]?.string else { return nil }
        self.id = id
        carId = c["carId"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        pluggedIn = c["pluggedIn"]?.bool ?? false
        pending = c["pending"]?.bool ?? false
        outdated = c["outdated"]?.bool ?? false
        gridDeferred = c["gridDeferred"]?.bool ?? false
        goalRev = c["goalRev"]?.int64.flatMap { UInt32(exactly: $0) }
        windows = (c["windows"]?.array ?? []).compactMap { w in
            guard let s = w["startMs"]?.double, let e = w["endMs"]?.double, e > s, let wh = w["wh"]?.double, wh >= 0 else { return nil }
            return Loadpoint.Window(fromMs: s, toMs: e, peakW: nil, energyWh: wh)
        }
        totalWh = c["totalWh"]?.double ?? 0
        shortfallWh = c["shortfallWh"]?.double.map { max(0, $0) }
    }

    package var cbor: CBOR {
        var pairs: [(String, CBOR)] = [
            ("id", .text(id)), ("pluggedIn", .bool(pluggedIn)), ("pending", .bool(pending)), ("outdated", .bool(outdated)), ("gridDeferred", .bool(gridDeferred)),
            ("windows", .array(windows.map { .map([("startMs", .ms($0.fromMs)), ("endMs", .ms($0.toMs)), ("wh", .ms($0.energyWh ?? 0))]) })),
            ("totalWh", .ms(totalWh)),
        ]
        if let carId { pairs.append(("carId", .text(carId))) }
        if let goalRev { pairs.append(("goalRev", .unsigned(UInt64(goalRev)))) }
        if let shortfallWh { pairs.append(("shortfallWh", .ms(shortfallWh))) }
        return .map(pairs)
    }
}

extension Plan {
    /// The plan as it goes on the wire, for the simulated box.
    public var wire: CBOR { cbor }
}
