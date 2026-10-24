import Foundation
import FTWShared

// What the screen says about a car. The car itself, as the box keeps it,
// is FTWWire's (Protocol/Cars.swift).

extension Car {
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
        // The goal's level, inside the car's ring.
        "Goal %@": "Mål %@",
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
