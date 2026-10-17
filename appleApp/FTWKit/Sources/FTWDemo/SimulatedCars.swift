import Foundation
import FTWKit

/// A car the demo box keeps, as a Core with `der.car` keeps it
/// (docs/cars.md in srcfl/ftw). The car on the garage charger takes its
/// level and goal from the house, which charges it; a car that is away
/// keeps the level it had when it left.
public struct SimulatedCar: Sendable, Equatable {
    public var id: String
    public var name: String
    public var make: String
    public var capacityWh: Double
    public var socFraction: Double?
    /// vehicle, manual or assumed.
    public var socSource: String
    /// When the car reported the level or someone set it.
    public var readAtMs: Double?
    public var energySinceWh: Double
    public var chargeLimit: Double?
    public var goal: Car.Goal?
    public var surplusOnly: Bool
    public var sources: [String]

    public init(id: String, name: String, make: String = "", capacityWh: Double = 64_000, socFraction: Double? = nil, socSource: String = "", readAtMs: Double? = nil,
                energySinceWh: Double = 0, chargeLimit: Double? = nil, goal: Car.Goal? = nil, surplusOnly: Bool = false, sources: [String] = []) {
        self.id = id
        self.name = name
        self.make = make
        self.capacityWh = capacityWh
        self.socFraction = socFraction
        self.socSource = socSource
        self.readAtMs = readAtMs
        self.energySinceWh = energySinceWh
        self.chargeLimit = chargeLimit
        self.goal = goal
        self.surplusOnly = surplusOnly
        self.sources = sources
    }
}

/// The garage charger's plug-in, as a Core with cars keeps it.
public struct SimulatedSession: Sendable, Equatable {
    public var id: String
    /// Empty while the box does not know which car this is.
    public var carID: String
    /// One of the registry's `car_identified_by`.
    public var by: String
    public var choose: [String]
}

/// The car situations the demo opens in for a box that keeps cars, so each
/// screen of the car view can be shown without a box: `-FTWDemoCars two`.
public enum DemoCars: String, CaseIterable, Sendable {
    /// A box from before cars: the charger is the car.
    case old
    /// One car, on the charger. The demo's default.
    case one
    /// One car, away: its last level from the car an hour ago, as on
    /// Fredrik's box with the cable out.
    case away
    /// Two cars: one on the charger, which said so itself, one away.
    case two
    /// Two cars, and the charger asks which one is plugged in.
    case asking

    public static let modelY = "6f1d2a3b4c5d6e7f8091a2b3c4d5e6f7"
    public static let zoe = "0a1b2c3d4e5f60718293a4b5c6d7e8f9"

    @MainActor
    public func apply(to box: SimulatedBox, nowMs: Double) {
        let tesla = SimulatedCar(id: Self.modelY, name: "Model Y", make: "Tesla", capacityWh: 76_000, chargeLimit: 0.8,
                                 goal: Car.Goal(targetPermille: 800, readyByMin: 7 * 60, days: Car.Goal.everyDay, finishAtLimit: false), sources: ["tesla-ha"])
        let zoe = SimulatedCar(id: Self.zoe, name: "Zoe", make: "Renault", capacityWh: 52_000, socFraction: 0.45, socSource: "manual", readAtMs: nowMs - 3 * 3_600_000)
        switch self {
        case .old:
            box.cars = nil
        case .one:
            box.keepCars([tesla], on: Self.modelY, by: "only")
        case .away:
            var away = tesla
            away.socFraction = 0.72
            away.socSource = "vehicle"
            away.readAtMs = nowMs - 67 * 60_000
            box.house.unplug()
            box.keepCars([away], on: nil, by: "")
        case .two:
            box.keepCars([tesla, zoe], on: Self.modelY, by: "car")
        case .asking:
            box.keepCars([tesla, zoe], on: nil, by: "asking")
        }
    }
}

extension SimulatedBox {
    /// Keep cars as a Core with `der.car` does, with `on` plugged into the
    /// garage when the house's car is plugged in.
    public func keepCars(_ list: [SimulatedCar], on carID: String?, by: String) {
        cars = list
        garage = house.carPluggedIn ? SimulatedSession(id: newSessionID(), carID: carID ?? "", by: by, choose: by == "asking" ? Array(list.prefix(4).map(\.id)) : []) : nil
        if let car = list.first(where: { $0.id == carID }) { house.carCapacityWh = car.capacityWh }
    }

    /// FTW Cloud's session information as hello carries it: the box's key,
    /// its boot, and each car under an opaque id. The key is a fixed point,
    /// which the demo never signs with.
    func cloudSession() -> CBOR {
        let pk: Bytes = [0x04] + Bytes(repeating: 0x2a, count: 64)
        let table = (cars ?? []).map { (Self.opaque($0.id), CBOR.text($0.id)) }
        return .map([("pk", .bytes(pk)), ("boot", .bytes(Bytes(repeating: 0x0b, count: 16))), ("sources", .map([(String, CBOR)]())),
                     ("loadpoints", .map([("o-garage", .text("garage"))])), ("cars", .map(table))])
    }

    /// The demo's stand-in for HMAC(grantKey, "car\0" ‖ id).
    public static func opaque(_ id: String) -> String { "o-" + id.prefix(8) }

    func newSessionID() -> String {
        sessions += 1
        return "s\(sessions)"
    }

    /// The car on the garage charger, when the box knows which.
    var pluggedCarID: String? {
        guard house.carPluggedIn, let id = garage?.carID, !id.isEmpty else { return nil }
        return id
    }

    /// A car as the box holds it now: the plugged-in car from the house.
    func car(_ c: SimulatedCar) -> Car {
        var out = Car(id: c.id, name: c.name, make: c.make, capacityWh: c.capacityWh, chargeLimitPermille: c.chargeLimit.map { Int(($0 * 1000).rounded()) },
                      goal: c.goal, surplusOnly: c.surplusOnly, sources: c.sources)
        let now = scheduler.nowMs
        if c.id == pluggedCarID {
            let h = house
            out.socPermille = Int((h.carSocFraction * 1000).rounded())
            switch h.carSocSource {
            case "vehicle":
                out.socSource = CarSocSource.vehicle.rawValue
                out.socAgeS = h.carReportedAtMs.map { max(0, (now - $0) / 1000).rounded() }
            case "assumed":
                out.socSource = CarSocSource.assumed.rawValue
                out.socEstimate = true
            default:
                out.socSource = CarSocSource.manual.rawValue
                out.socAgeS = levelSetAtMs.map { max(0, (now - $0) / 1000).rounded() }
                out.energySinceWh = max(0, h.sessionWh - levelMarkWh).rounded()
                out.socEstimate = out.energySinceWh > 1_000
            }
            out.goal = h.schedule.map { s in
                Car.Goal(targetPermille: Int((s.socFraction * 1000).rounded()), readyByMin: s.clockMin, days: s.recurring ? (s.days & 0x7F == 0 ? Car.Goal.everyDay : s.days) : 0,
                         finishAtLimit: c.goal?.finishAtLimit ?? false)
            }
            out.surplusOnly = h.surplusOnly
            out.capacityWh = h.carCapacityWh
        } else if let f = c.socFraction {
            out.socPermille = Int((f * 1000).rounded())
            out.socSource = c.socSource
            out.socAgeS = c.readAtMs.map { max(0, (now - $0) / 1000).rounded() }
            out.energySinceWh = c.energySinceWh
            out.socEstimate = c.socSource == "assumed" || c.energySinceWh > 1_000
        }
        return out
    }

    func carsJSON() -> JSON {
        ["cars": .array((cars ?? []).map { Self.json(car($0)) }), "removed": .array(removed.map { ["id": .string($0)] })]
    }

    /// A car in the box's HTTP spelling.
    static func json(_ c: Car) -> JSON {
        var w: JSON = [
            CarField.id.http: .string(c.id), CarField.name.http: .string(c.name), CarField.capacityWh.http: .number(c.capacityWh),
            CarField.energySinceWh.http: .number(c.energySinceWh), CarField.socEstimate.http: .bool(c.socEstimate), CarField.surplusOnly.http: .bool(c.surplusOnly),
        ]
        if !c.make.isEmpty { w = w.setting(CarField.make.http, .string(c.make)) }
        if let p = c.socPermille { w = w.setting(CarField.socPermille.http, .number(Double(p))) }
        if !c.socSource.isEmpty { w = w.setting(CarField.socSource.http, .string(c.socSource)) }
        if let a = c.socAgeS { w = w.setting(CarField.socAgeS.http, .number(a)) }
        if let l = c.chargeLimitPermille { w = w.setting(CarField.chargeLimitPermille.http, .number(Double(l))) }
        if let g = c.goal {
            w = w.setting(CarField.goal.http, [
                CarField.goalTargetPermille.http: .number(Double(g.targetPermille)), CarField.goalReadyByMin.http: .number(Double(g.readyByMin)),
                CarField.goalDays.http: .number(Double(g.days)), CarField.goalFinishAtLimit.http: .bool(g.finishAtLimit),
            ])
        }
        if !c.sources.isEmpty { w = w.setting(CarField.sources.http, .array(c.sources.map { .string($0) })) }
        return w
    }

    /// A car in brief, as a `cmd.result` carries it.
    static func cbor(_ c: Car) -> CBOR {
        var pairs: [(String, CBOR)] = [(CarField.id.wire, .text(c.id)), (CarField.energySinceWh.wire, .number(c.energySinceWh)),
                                       (CarField.socEstimate.wire, .bool(c.socEstimate)), (CarField.surplusOnly.wire, .bool(c.surplusOnly))]
        if let p = c.socPermille { pairs.append((CarField.socPermille.wire, .int(p))) }
        if !c.socSource.isEmpty { pairs.append((CarField.socSource.wire, .text(c.socSource))) }
        if let a = c.socAgeS { pairs.append((CarField.socAgeS.wire, .number(a))) }
        if let l = c.chargeLimitPermille { pairs.append((CarField.chargeLimitPermille.wire, .int(l))) }
        if let g = c.goal {
            pairs.append((CarField.goal.wire, .map([("targetPermille", .int(g.targetPermille)), ("readyByMin", .int(g.readyByMin)), ("days", .int(g.days)), ("finishAtLimit", .bool(g.finishAtLimit))])))
        }
        return .map(pairs)
    }

    /// The garage's car fields on `GET /api/loadpoints`, and the level the
    /// one-release overlap shows there: a visitor's or an unnamed car's is
    /// unknown, with no number.
    func chargerCarJSON(_ lp: JSON) -> JSON {
        guard cars != nil, house.carPluggedIn, let g = garage else { return lp }
        var out = lp.setting(ChargerCarField.session.http, .string(g.id))
        if !g.carID.isEmpty { out = out.setting(ChargerCarField.carId.http, .string(g.carID)) }
        if !g.by.isEmpty { out = out.setting(ChargerCarField.carIdentifiedBy.http, .string(g.by)) }
        if !g.choose.isEmpty { out = out.setting(ChargerCarField.choose.http, .array(g.choose.map { .string($0) })) }
        if g.carID.isEmpty {
            out = out.setting("soc_source", "unknown").setting("current_soc", .null)
            out = out.setting("vehicle_soc", .null).setting("vehicle_driver", "")
        }
        return out
    }

    /// The charger brief a `session.car.set` result carries.
    func chargerCBOR() -> CBOR {
        let g = garage
        var pairs: [(String, CBOR)] = [(ChargerCarField.session.rawValue, .text(g?.id ?? ""))]
        if let id = g?.carID, !id.isEmpty { pairs.append((ChargerCarField.carId.rawValue, .text(id))) }
        if let by = g?.by, !by.isEmpty { pairs.append((ChargerCarField.carIdentifiedBy.rawValue, .text(by))) }
        return .map(pairs)
    }

    /// The cable moved on a box that keeps cars: the car that left keeps
    /// its level; a new plug-in is named by the only car, or asked about.
    func carCable(pluggedIn: Bool) {
        guard var list = cars else { return }
        if !pluggedIn {
            if let id = garage?.carID, let i = list.firstIndex(where: { $0.id == id }) {
                let held = car(list[i])
                list[i].socFraction = held.socPermille.map { Double($0) / 1000 }
                list[i].socSource = held.socSource
                list[i].readAtMs = held.socAgeS.map { scheduler.nowMs - $0 * 1000 } ?? scheduler.nowMs
                list[i].energySinceWh = held.energySinceWh
                list[i].goal = held.goal
            }
            cars = list
            garage = nil
            return
        }
        let only = list.count == 1 ? list[0].id : ""
        garage = SimulatedSession(id: newSessionID(), carID: only, by: list.count == 1 ? "only" : (list.isEmpty ? "none" : "asking"),
                                  choose: list.count > 1 ? Array(list.prefix(4).map(\.id)) : [])
        if let car = list.first(where: { $0.id == only }) { house.carCapacityWh = car.capacityWh }
        levelMarkWh = 0
        levelSetAtMs = nil
    }

    /// The car ops, as Core answers them on a box that keeps cars.
    func actCar(_ cmdId: String, _ op: String, _ args: CBOR) {
        guard var list = cars else {
            result(cmdId, "rejected", error: ("E_UNKNOWN_OP", [("op", .text(op))]))
            return
        }
        let id = args["id"]?.string ?? ""
        func refuse(_ code: String, _ reason: String) {
            result(cmdId, "rejected", error: (code, [("op", .text(op)), ("reason", .text(reason))]))
        }
        switch op {
        case Contract.opSessionCarSet:
            guard id == "garage" else { return refuse("E_NOT_FOUND", "charger") }
            guard house.carPluggedIn, var g = garage, args["session"]?.string == g.id else { return refuse("E_PRECONDITION", "session") }
            let want = args["car_id"]?.string ?? ""
            guard want.isEmpty || list.contains(where: { $0.id == want }) else { return refuse("E_NOT_FOUND", "car") }
            g.carID = want
            g.by = want.isEmpty ? "none" : "tap"
            g.choose = []
            garage = g
            if let car = list.first(where: { $0.id == want }) {
                house.carCapacityWh = car.capacityWh
                if let goal = car.goal {
                    house.schedule = (Double(goal.targetPermille) / 1000, goal.readyByMin, goal.days != 0, goal.days == Car.Goal.everyDay ? 0 : goal.days, house.schedule?.surplusUnlock ?? 0)
                }
            }
            result(cmdId, "applied", extra: [("charger", chargerCBOR())])
            replan()
        case Contract.opCarSocSet:
            guard let i = list.firstIndex(where: { $0.id == id }) else { return refuse("E_NOT_FOUND", "car") }
            let soc = max(0, min(1, args["soc"]?.double ?? 0))
            if id == pluggedCarID {
                house.carSocFraction = soc
                house.carSocSource = "inferred"
                house.carReportedAtMs = house.carReportedAtMs.map { min($0, scheduler.nowMs - 1) }
                levelMarkWh = house.sessionWh
                levelSetAtMs = scheduler.nowMs
                replan()
            } else {
                list[i].socFraction = soc
                list[i].socSource = CarSocSource.manual.rawValue
                list[i].readAtMs = scheduler.nowMs
                list[i].energySinceWh = 0
                cars = list
            }
            result(cmdId, "applied", observed: soc, extra: [("car", Self.cbor(car(list[i])))])
        case Contract.opCarGoalSet:
            guard let i = list.firstIndex(where: { $0.id == id }) else { return refuse("E_NOT_FOUND", "car") }
            var goal = list[i].goal
            if args["clear"]?.bool == true { goal = nil }
            if let target = args["target"]?.double, let ready = args["ready_by_min"]?.int {
                goal = Car.Goal(targetPermille: Int((target * 1000).rounded()), readyByMin: ready, days: args["days"]?.int ?? 0, finishAtLimit: args["finish_at_limit"]?.bool ?? false)
            }
            if let surplus = args["surplus_only"]?.bool { list[i].surplusOnly = surplus }
            list[i].goal = goal
            cars = list
            if id == pluggedCarID {
                house.schedule = goal.map { (Double($0.targetPermille) / 1000, $0.readyByMin, $0.days != 0, $0.days == Car.Goal.everyDay ? 0 : $0.days, house.schedule?.surplusUnlock ?? 0) }
                if let surplus = args["surplus_only"]?.bool { house.surplusOnly = surplus }
                replan()
            }
            result(cmdId, "applied", extra: [("car", Self.cbor(car(list[i])))])
        case Contract.opCarAdd:
            guard Car.isID(id) else { return refuse("E_PRECONDITION", "invalid") }
            guard list.count < 32 else { return result(cmdId, "rejected", error: ("E_CAP_EXCEEDED", [("op", .text(op)), ("reason", .text("cars"))])) }
            let c = SimulatedCar(id: id, name: args["name"]?.string ?? "", capacityWh: args["capacity_wh"]?.double ?? 60_000)
            if let i = list.firstIndex(where: { $0.id == id }) { list[i].name = c.name } else { list.append(c) }
            removed.removeAll { $0 == id }
            cars = list
            result(cmdId, "applied", extra: [("car", Self.cbor(car(c)))])
        case Contract.opCarUpdate:
            guard let i = list.firstIndex(where: { $0.id == id }) else { return refuse("E_NOT_FOUND", "car") }
            if let name = args["name"]?.string { list[i].name = name }
            if let wh = args["capacity_wh"]?.double {
                list[i].capacityWh = wh
                if id == pluggedCarID { house.carCapacityWh = wh }
            }
            if let sources = args["sources"]?.array { list[i].sources = sources.compactMap(\.string) }
            cars = list
            result(cmdId, "applied", extra: [("car", Self.cbor(car(list[i])))])
        case Contract.opCarRemove:
            guard let i = list.firstIndex(where: { $0.id == id }) else { return refuse("E_NOT_FOUND", "car") }
            list.remove(at: i)
            removed.append(id)
            cars = list
            if garage?.carID == id { garage?.carID = ""; garage?.by = "none" }
            result(cmdId, "applied")
            replan()
        default:
            result(cmdId, "rejected", error: ("E_UNKNOWN_OP", []))
        }
    }
}
