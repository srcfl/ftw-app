import Foundation
import FTWShared

// Cars (docs/cars.md in srcfl/ftw). A car belongs to its owner, not to the
// home, and visits chargers. A box that lists `der.car` keeps each car's
// level, goal and sources apart from the charger, and each charger names
// the car on it. A box without it treats each charger as its car, and the
// app draws the charger as before.

/// A car's names on the wire, from the registry's `car_fields`. A name with
/// a dot is a field of the object before the dot. `ContractTests` holds this
/// list to the registry's.
public enum CarField: String, CaseIterable, Sendable {
    case id, boxMinted, ownerId, name, make, vin, capacityWh, maxW, phases
    case socPermille, socSource, socAgeS, energySinceWh, socEstimate, chargeLimitPermille
    case goal
    case goalTargetPermille = "goal.targetPermille"
    case goalReadyByMin = "goal.readyByMin"
    case goalDays = "goal.days"
    case goalFinishAtLimit = "goal.finishAtLimit"
    case surplusOnly, identifiers, sources

    /// The name on the session: the part after the dot.
    public var wire: String { rawValue.split(separator: ".").last.map(String.init) ?? rawValue }
    /// The name on the box's HTTP routes, which spell every registry name
    /// in snake_case.
    public var http: String { snakeCase(wire) }
}

/// What a charger carries about the car on it, from the registry's
/// `charger_car_fields`.
public enum ChargerCarField: String, CaseIterable, Sendable {
    case session, carId, carIdentifiedBy, carCorrected, carCorrectedFrom, choose

    public var http: String { snakeCase(rawValue) }
}

/// Where a car's level comes from, from the registry's `car_soc_sources`.
public enum CarSocSource: String, CaseIterable, Sendable, Codable {
    /// A reading from the car itself.
    case vehicle
    /// A level someone set.
    case manual
    /// A known car's plug-in default. Always an estimate.
    case assumed
}

/// How the box knows which car is on a charger, from the registry's
/// `car_identified_by`.
public enum CarIdentifiedBy: String, CaseIterable, Sendable, Codable {
    case charger, car, only, tap
    /// The box raised `car.which` and waits for a tap.
    case asking
    /// A visitor: a car the box cannot name.
    case none
}

/// "socPermille" → "soc_permille", as the box spells a registry name on its
/// HTTP routes.
func snakeCase(_ camel: String) -> String {
    var out = ""
    for c in camel {
        if c.isUppercase {
            out += "_" + c.lowercased()
        } else {
            out.append(c)
        }
    }
    return out
}

/// One car as the box keeps it, read tolerantly from `GET /api/cars` or
/// from a `cmd.result`. A field the box leaves out (a viewer sees no VIN)
/// reads as empty.
public struct Car: Equatable, Sendable, Identifiable, Codable {
    /// What the car should reach and when. One goal per car, used wherever
    /// it is plugged in.
    public struct Goal: Equatable, Sendable, Codable {
        public var targetPermille: Int
        /// Minutes after midnight in the box's time zone.
        public var readyByMin: Int
        /// ISO weekday mask, Monday in bit 0. 0 is once, 127 every day.
        public var days: Int
        /// Charge on to the car's own limit rather than to the target.
        public var finishAtLimit: Bool

        public init(targetPermille: Int, readyByMin: Int, days: Int, finishAtLimit: Bool) {
            self.targetPermille = targetPermille
            self.readyByMin = readyByMin
            self.days = days
            self.finishAtLimit = finishAtLimit
        }

        /// Every day, as a goal's days say it.
        public static let everyDay = 0x7F
    }

    /// 128 bits as 32 lowercase hex digits.
    public var id: String
    /// The box made the car from its old settings.
    public var boxMinted: Bool
    public var name: String
    public var make: String
    public var vin: String
    public var capacityWh: Double
    /// The most the car's own charger takes; 0 when unknown.
    public var maxW: Double
    public var phases: Int
    /// The level. The car's own number, or the person's, while
    /// `socEstimate` is false. Nil when the box has none.
    public var socPermille: Int?
    /// One of `CarSocSource`, as the box said it.
    public var socSource: String
    /// Seconds since the car reported the level or someone set it, counted
    /// when the box answered.
    public var socAgeS: Double?
    /// Energy delivered to the car since that reading.
    public var energySinceWh: Double
    public var socEstimate: Bool
    /// The charge limit the car reported with its level.
    public var chargeLimitPermille: Int?
    public var goal: Goal?
    public var surplusOnly: Bool
    public var identifiers: [String]
    /// The vehicle drivers on this box that report the car's level.
    public var sources: [String]

    public init(id: String, name: String, boxMinted: Bool = false, make: String = "", vin: String = "", capacityWh: Double = 0, maxW: Double = 0, phases: Int = 0,
                socPermille: Int? = nil, socSource: String = "", socAgeS: Double? = nil, energySinceWh: Double = 0, socEstimate: Bool = false,
                chargeLimitPermille: Int? = nil, goal: Goal? = nil, surplusOnly: Bool = false, identifiers: [String] = [], sources: [String] = []) {
        self.id = id
        self.boxMinted = boxMinted
        self.name = name
        self.make = make
        self.vin = vin
        self.capacityWh = capacityWh
        self.maxW = maxW
        self.phases = phases
        self.socPermille = socPermille
        self.socSource = socSource
        self.socAgeS = socAgeS
        self.energySinceWh = energySinceWh
        self.socEstimate = socEstimate
        self.chargeLimitPermille = chargeLimitPermille
        self.goal = goal
        self.surplusOnly = surplusOnly
        self.identifiers = identifiers
        self.sources = sources
    }

    /// From the box's HTTP route, in snake_case.
    public init?(_ w: JSON) {
        self.init(read: CarRead(
            num: { f in w[f.http]?.number },
            text: { f in w[f.http]?.string },
            flag: { f in w[f.http]?.bool },
            list: { f in w[f.http]?.array?.compactMap(\.string) },
            goal: { w[CarField.goal.http].flatMap { g in g.object == nil ? nil : CarRead(
                num: { f in g[f.http]?.number }, text: { _ in nil }, flag: { f in g[f.http]?.bool }, list: { _ in nil }, goal: { nil }) } }
        ))
    }

    /// From the session, in the registry's own spelling: a `cmd.result`.
    public init?(cbor c: CBOR) {
        guard c.entries != nil else { return nil }
        self.init(read: CarRead(
            num: { f in c[f.wire]?.double },
            text: { f in c[f.wire]?.string },
            flag: { f in c[f.wire]?.bool },
            list: { f in c[f.wire]?.array?.compactMap(\.string) },
            goal: { c[CarField.goal.wire].flatMap { g in g.entries == nil ? nil : CarRead(
                num: { f in g[f.wire]?.double }, text: { _ in nil }, flag: { f in g[f.wire]?.bool }, list: { _ in nil }, goal: { nil }) } }
        ))
    }

    private init?(read r: CarRead) {
        guard let id = r.text(.id), !id.isEmpty else { return nil }
        self.id = id
        boxMinted = r.flag(.boxMinted) ?? false
        name = r.text(.name) ?? ""
        make = r.text(.make) ?? ""
        vin = r.text(.vin) ?? ""
        capacityWh = max(0, r.num(.capacityWh) ?? 0)
        maxW = max(0, r.num(.maxW) ?? 0)
        phases = whole(r.num(.phases)) ?? 0
        socPermille = r.num(.socPermille).flatMap { (0...1000).contains($0) ? Int($0.rounded()) : nil }
        socSource = r.text(.socSource) ?? ""
        socAgeS = r.num(.socAgeS).flatMap { $0 >= 0 ? $0 : nil }
        energySinceWh = r.num(.energySinceWh) ?? 0
        socEstimate = r.flag(.socEstimate) ?? false
        chargeLimitPermille = r.num(.chargeLimitPermille).flatMap { (1...1000).contains($0) ? Int($0.rounded()) : nil }
        if let g = r.goal(), let target = whole(g.num(.goalTargetPermille)), let ready = whole(g.num(.goalReadyByMin)) {
            goal = Goal(targetPermille: target, readyByMin: ready, days: (whole(g.num(.goalDays)) ?? 0) & 0x7F,
                        finishAtLimit: g.flag(.goalFinishAtLimit) ?? false)
        } else {
            goal = nil
        }
        surplusOnly = r.flag(.surplusOnly) ?? false
        identifiers = r.list(.identifiers) ?? []
        sources = r.list(.sources) ?? []
    }

    public var source: CarSocSource? { CarSocSource(rawValue: socSource) }

    /// A new car's id, minted on the phone: 128 random bits as 32 lowercase
    /// hex digits, the same on every box its owner has.
    public static func mintID() -> String {
        var g = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &g)) }.joined()
    }

    /// Whether an id is one a car can have.
    public static func isID(_ id: String) -> Bool {
        id.count == 32 && id.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

/// A whole number from the wire, or nil: a NaN or a huge value never
/// reaches `Int`, which would trap.
private func whole(_ v: Double?) -> Int? {
    guard let v, v.isFinite, abs(v) < 1e9 else { return nil }
    return Int(v.rounded())
}

/// Reads a car's fields by their registry names, from JSON or CBOR.
private struct CarRead {
    let num: (CarField) -> Double?
    let text: (CarField) -> String?
    let flag: (CarField) -> Bool?
    let list: (CarField) -> [String]?
    let goal: () -> CarRead?
}

/// What a charger says about the car on it. Empty while nothing is plugged
/// in, and from a box that keeps no cars.
public struct ChargerCar: Equatable, Sendable, Codable {
    /// This plug-in's id. A tap names it, and the box refuses a tap for a
    /// plug-in that has ended.
    public var session: String
    /// The session's car; empty while the box does not know which.
    public var carID: String
    /// One of `CarIdentifiedBy`, as the box said it.
    public var identifiedBy: String
    /// A better rule replaced the car the box named first, which was
    /// `correctedFrom`.
    public var corrected: Bool
    public var correctedFrom: String
    /// While the box asks: the cars a tap may pick, at most four.
    public var choose: [String]

    public init(session: String = "", carID: String = "", identifiedBy: String = "", corrected: Bool = false, correctedFrom: String = "", choose: [String] = []) {
        self.session = session
        self.carID = carID
        self.identifiedBy = identifiedBy
        self.corrected = corrected
        self.correctedFrom = correctedFrom
        self.choose = choose
    }

    /// From `GET /api/loadpoints`; nil when the charger carries none.
    package init?(json w: JSON) {
        let f = { (k: ChargerCarField) in w[k.http] }
        let session = f(.session)?.string ?? ""
        let car = f(.carId)?.string ?? ""
        let by = f(.carIdentifiedBy)?.string ?? ""
        guard !session.isEmpty || !car.isEmpty || !by.isEmpty else { return nil }
        self.init(session: session, carID: car, identifiedBy: by, corrected: f(.carCorrected)?.bool ?? false,
                  correctedFrom: f(.carCorrectedFrom)?.string ?? "", choose: f(.choose)?.array?.compactMap(\.string) ?? [])
    }

    /// From a `cmd.result` after `session.car.set`.
    init?(cbor c: CBOR) {
        guard c.entries != nil else { return nil }
        let f = { (k: ChargerCarField) in c[k.rawValue] }
        self.init(session: f(.session)?.string ?? "", carID: f(.carId)?.string ?? "", identifiedBy: f(.carIdentifiedBy)?.string ?? "",
                  corrected: f(.carCorrected)?.bool ?? false, correctedFrom: f(.carCorrectedFrom)?.string ?? "",
                  choose: f(.choose)?.array?.compactMap(\.string) ?? [])
    }

    public var by: CarIdentifiedBy? { CarIdentifiedBy(rawValue: identifiedBy) }
    /// The box waits for someone to say which car this is.
    public var asking: Bool { by == .asking }
}
