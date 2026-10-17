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

    /// The level and where it comes from, dated on the phone's clock from
    /// when the box answered. Nil when the box has none.
    public func level(answeredAtMs: Double) -> CarLevel? {
        guard let permille = socPermille else { return nil }
        let source = source ?? .assumed
        let at = source == .assumed ? nil : socAgeS.map { answeredAtMs - $0 * 1000 }
        return CarLevel(pct: (Double(permille) / 10).rounded(), source: source, estimate: socEstimate || source == .assumed, atMs: at, energySinceWh: energySinceWh)
    }

    /// The name to show: the owner's, else the maker's, else "Car".
    public var shownName: String {
        if !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        if !make.isEmpty { return make }
        return CarWords.text("Car")
    }

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

/// A car's level as the screen says it.
public struct CarLevel: Equatable, Sendable {
    public var pct: Double
    public var source: CarSocSource
    /// The box counts it as an estimate: energy has flowed since the
    /// reading, it was read before the car last left a charger, or it is
    /// assumed.
    public var estimate: Bool
    /// When the car reported it or someone set it. Nil when assumed.
    public var atMs: Double?
    public var energySinceWh: Double

    /// Whether it is a guess the screen draws faint: assumed, or an
    /// estimate with no reading under it.
    public var guessed: Bool { source == .assumed }
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
    init?(json w: JSON) {
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

// MARK: - Words

/// The car's sentences. Swedish lives in the table below, as AppWords does
/// it; a sentence without a translation falls back to the app's own.
public enum CarWords {
    public static func text(_ en: String) -> String {
        AppWords.language == .sv ? (sv[en] ?? NodeWords.text(en)) : en
    }

    /// `%@` in order, or `%1$@` by position.
    public static func format(_ en: String, _ args: String...) -> String {
        var out = text(en)
        for (i, a) in args.enumerated() { out = out.replacingOccurrences(of: "%\(i + 1)$@", with: a) }
        for a in args {
            guard let r = out.range(of: "%@") else { break }
            out.replaceSubrange(r, with: a)
        }
        return out
    }

    static let sv: [String: String] = [
        "Car": "Bil",
        "Cars": "Bilar",
        "Which car?": "Vilken bil?",
        "Which car is on %@?": "Vilken bil står på %@?",
        "None of these": "Ingen av dessa",
        "Tap the car so FTW plans for its level and goal.": "Tryck på bilen så planerar FTW efter dess nivå och mål.",
        "Until you choose, FTW charges it as a visitor's car, from spare solar.": "Tills du väljer laddar FTW den som en besökares bil, med överbliven sol.",
        "A visitor's car": "En besökares bil",
        "FTW does not know this car, so it shows no level.": "FTW känner inte bilen, så den visar ingen nivå.",
        "Sending your choice…": "Skickar ditt val…",
        "FTW received your choice.": "FTW har fått ditt val.",
        "FTW now plans for %@.": "FTW planerar nu för %@.",
        "FTW now charges it as a visitor's car.": "FTW laddar den nu som en besökares bil.",
        "Level unknown": "Nivån okänd",
        "from the car": "från bilen",
        "from the car %@ + %@": "från bilen %@ + %@",
        "set by hand": "satt för hand",
        "set by hand %@ + %@": "satt för hand %@ + %@",
        "assumed at plug-in": "antagen vid inkoppling",
        "yesterday %@": "i går %@",
        "Limit %@": "Laddgräns %@",
        "On %@ · %@ max": "På %@ · max %@",
        "On %@": "På %@",
        "Not plugged in": "Inte inkopplad",
        "Plugged in": "Inkopplad",
        "Charging": "Laddar",
        "FTW first took it for %@.": "FTW trodde först att det var %@.",
        "The car said it was plugged in here.": "Bilen sa själv att den kopplades in här.",
        "Only one car could be here.": "Bara en bil kunde stå här.",
        "The charger named the car.": "Laddaren angav bilen.",
        "Set the level": "Ange nivån",
        "Plug in the car, or let the car report, to update its level.": "Koppla in bilen, eller låt bilen rapportera, så uppdateras nivån.",
        "FTW no longer has this car.": "FTW har inte längre den här bilen.",
        "FTW no longer has that charger.": "FTW har inte längre den laddaren.",
        "That plug-in has ended.": "Den inkopplingen är slut.",
        "That car is on another charger.": "Den bilen står på en annan laddare.",
        "FTW could not take that.": "FTW kunde inte ta emot det.",
        "Your box does not keep cars yet. It may need an update.": "Din box håller inte bilar än. Den kan behöva uppdateras.",
        "Another car already has that VIN or tag.": "En annan bil har redan det VIN-numret eller den taggen.",
        "FTW keeps at most 32 cars.": "FTW håller högst 32 bilar.",
        "Name": "Namn",
        "Battery size": "Batteristorlek",
        "Level sources": "Nivåkällor",
        "No source reports this car's level yet.": "Ingen källa rapporterar bilens nivå än.",
        "Add a source": "Lägg till en källa",
        "Add a car": "Lägg till en bil",
        "Remove this car": "Ta bort bilen",
        "Remove %@?": "Ta bort %@?",
        "FTW forgets the car and its goal. A session on it becomes a visitor's.": "FTW glömmer bilen och dess mål. En pågående laddning blir en besökares.",
        "Saving…": "Sparar…",
        "Saved.": "Sparat.",
        "Removed.": "Borttagen.",
        "The cars FTW plans for. Each keeps its own level, goal and sources.": "Bilarna FTW planerar för. Var och en har egen nivå, eget mål och egna källor.",
        "Only the home's owner can change the cars.": "Bara hemmets ägare kan ändra bilarna.",
        "%@ kWh": "%@ kWh",
        "New car": "Ny bil",
        "Charges at most %@": "Laddar högst %@",
        "No car yet": "Ingen bil än",
        "Add your car in Settings so FTW can plan for it.": "Lägg till bilen under Inställningar så kan FTW planera för den.",
        "Cancel": "Avbryt",
        "Remove": "Ta bort",
        "Add": "Lägg till",
        "Done": "Klar",
    ]
}

/// The car's sentences, from what the box said and nothing more.
public enum CarText {
    /// "72 %", or "≈ 22 %" for an estimate.
    public static func percent(_ l: CarLevel) -> String {
        (l.estimate ? "≈\u{00A0}" : "") + AppWords.percent(l.pct)
    }

    /// Where the level comes from and how old it is: "from the car · 1 h
    /// ago", "from the car 16:31 + 6 kWh", "set by hand · 20 min ago",
    /// "assumed at plug-in". A reading is dated in minutes, never seconds;
    /// once energy has flowed it says how much since when.
    public static func origin(_ l: CarLevel, nowMs: Double, zone: TimeZone) -> String {
        switch l.source {
        case .assumed:
            return CarWords.text("assumed at plug-in")
        case .vehicle, .manual:
            let from = CarWords.text(l.source == .vehicle ? "from the car" : "set by hand")
            guard let at = l.atMs else { return from }
            if l.estimate, l.energySinceWh >= 50 {
                return CarWords.format(l.source == .vehicle ? "from the car %@ + %@" : "set by hand %@ + %@", when(at, nowMs: nowMs, zone: zone), AppWords.energy(l.energySinceWh))
            }
            let age = max(0, nowMs - at)
            return from + " · " + PowerFormat.age(age < 60_000 ? 0 : (age / 60_000).rounded(.down) * 60_000)
        }
    }

    /// "16:31" today, "yesterday 16:31", else "12 Oct 16:31".
    static func when(_ ms: Double, nowMs: Double, zone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date(timeIntervalSince1970: ms / 1000)), to: cal.startOfDay(for: Date(timeIntervalSince1970: nowMs / 1000))).day ?? 0
        let time = AppWords.clock(ms, zone: zone)
        switch days {
        case ...0: return time
        case 1: return CarWords.format("yesterday %@", time)
        default: return AppWords.day(ms, nowMs: nowMs, zone: zone)
        }
    }

    /// "Limit 80 %": the charge limit the car reported.
    public static func limit(_ car: Car) -> String? {
        car.chargeLimitPermille.map { CarWords.format("Limit %@", AppWords.percent((Double($0) / 10).rounded())) }
    }

    /// A charger's name as the box gives it: its driver, capitalised.
    public static func chargerName(_ lp: Loadpoint) -> String {
        let raw = lp.driverName.flatMap { $0.isEmpty ? nil : $0 } ?? lp.id
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }

    /// "On Easee · 11 kW max": the charger the car is on, one line.
    public static func charger(_ lp: Loadpoint) -> String {
        guard let max = lp.maxChargeW, max > 0 else { return CarWords.format("On %@", chargerName(lp)) }
        return CarWords.format("On %@ · %@ max", chargerName(lp), AppWords.power(max))
    }

    /// How the box knew which car this is, when that is worth a line: a
    /// correction is shown, never silent.
    public static func identified(_ c: ChargerCar, name: (String) -> String?) -> String? {
        if c.corrected, !c.correctedFrom.isEmpty, let was = name(c.correctedFrom) {
            return CarWords.format("FTW first took it for %@.", was)
        }
        return nil
    }

    /// What a refused car op means for the person.
    public static func refusal(_ r: CmdResult) -> String {
        let reason = r.errorArgs["reason"]?.string
        switch r.errorCode {
        case "E_NOT_FOUND": return CarWords.text(reason == "charger" ? "FTW no longer has that charger." : "FTW no longer has this car.")
        case "E_PRECONDITION":
            switch reason {
            case "session": return CarWords.text("That plug-in has ended.")
            case "elsewhere": return CarWords.text("That car is on another charger.")
            default: return CarWords.text("FTW could not take that.")
            }
        case "E_UNAVAILABLE" where r.errorArgs["subsystem"]?.string == "cars":
            return CarWords.text("Your box does not keep cars yet. It may need an update.")
        case "E_DUPLICATE": return CarWords.text("Another car already has that VIN or tag.")
        case "E_CAP_EXCEEDED": return CarWords.text("FTW keeps at most 32 cars.")
        default: return EVText.refusal(r)
        }
    }
}

extension CarLevel {
    /// The level in the words a charger's level is said in, for the
    /// sentences and records written before cars: the car's own number is
    /// "from the car", a number someone set is theirs, anything after energy
    /// has flowed is FTW's estimate, and an assumption stays one.
    public func asLevel(nowMs: Double) -> EVText.Level {
        let origin: EVText.Level.Origin
        switch (source, estimate) {
        case (.assumed, _): origin = .assumed
        case (.vehicle, false): origin = atMs.map { nowMs - $0 > EVText.carLevelMaxAgeMs } == true ? .carEarlier : .car
        case (.manual, false): origin = .you
        case (_, true): origin = .estimated
        }
        return EVText.Level(pct: pct, origin: origin, atMs: origin == .estimated ? nil : atMs, setPct: nil)
    }

    /// The charger's word for the level's source, as `CarEntry` keeps it.
    public var legacySource: String {
        switch (source, estimate) {
        case (.assumed, _): return "assumed"
        case (.vehicle, false): return "vehicle"
        default: return "inferred"
        }
    }
}
