import Foundation
import FTWShared

/// One charger as `/api/loadpoints` serves it, read tolerantly, and the
/// sentences that describe it. No sentence claims what the box has not
/// said: a charger that does not know the car's charge is described by what
/// it does know, never by an invented percentage.
public struct Loadpoint: Equatable, Sendable, Identifiable {
    public struct Schedule: Equatable, Sendable {
        public var socPct: Double
        /// The ready time as the box sends it: the UTC minute of day of that
        /// time on today's date.
        public var timeOfDayMinUTC: Int
        /// The ready time on the household clock, from a box that sends it.
        public var clockMin: Int?
        public var surplusUnlockPct: Double
        public var recurring: Bool
        /// 7-bit weekday mask, bit 0 = Monday. Zero means every day.
        public var days: Int
        /// The goal is the car's own limit rather than a percentage.
        public var finishAtVehicleLimit: Bool

        public init(socPct: Double, timeOfDayMinUTC: Int, clockMin: Int?, surplusUnlockPct: Double, recurring: Bool, days: Int, finishAtVehicleLimit: Bool) {
            self.socPct = socPct
            self.timeOfDayMinUTC = timeOfDayMinUTC
            self.clockMin = clockMin
            self.surplusUnlockPct = surplusUnlockPct
            self.recurring = recurring
            self.days = days
            self.finishAtVehicleLimit = finishAtVehicleLimit
        }
    }

    public struct Manual: Equatable, Sendable {
        public var state: String?
        public var requestedA: Double?
        public var requestedW: Double?
        public var commandedA: Double?
        public var chargerReason: String?
        public var limitReason: String?
        public var chargerUpdatedAtMs: Double?
    }

    public struct Charger: Equatable, Sendable {
        public var known: Bool
        public var available: Bool?
        public var updatedAtMs: Double?
        public var reason: String?
    }

    public struct Window: Equatable, Sendable, Identifiable {
        public var fromMs: Double
        public var toMs: Double
        public var peakW: Double?
        public var energyWh: Double?
        public var id: Double { fromMs }
    }

    public var id: String
    public var pluggedIn: Bool
    public var powerW: Double
    public var socPct: Double?
    public var socSource: String
    /// How old the car's own report of its level was when the box answered.
    public var vehicleSocAgeS: Double?
    /// The car's own report, kept apart from the box's estimate.
    public var vehicleSocPct: Double?
    public var vehicleDriver: String
    public var vehicleStale: Bool
    public var vehicleCapacityWh: Double?
    public var capacitySource: String
    public var socRetention: String
    public var chargingDeclined: Bool
    public var targetSocPct: Double?
    /// The deadline the box plans for, on the phone's clock.
    public var targetTimeMs: Double?
    public var goalComplete: Bool
    public var sessionWh: Double
    public var minChargeW: Double?
    public var maxChargeW: Double?
    public var phases: Double?
    public var voltageV: Double?
    public var manualSaveError: Bool
    public var manualRestoreUnconfirmed: Bool
    public var manualActive: Bool
    public var manual: Manual?
    public var charger: Charger?
    public var commandedW: Double?
    public var commandedReason: String
    public var commandedKnown: Bool
    public var updatedAtMs: Double?
    public var gridDeferred: Bool
    public var planStartMs: Double?
    public var planEndMs: Double?
    public var planTotalWh: Double?
    public var planPending: Bool
    public var planOutdated: Bool
    /// Whether this box reports its plan with the charger, in one read.
    public var inlinePlan: Bool
    public var planWindows: [Window]
    public var manualChargeW: Double?
    public var surplusOnly: Bool
    public var boostActive: Bool
    public var boostExpiresAtMs: Double?
    public var boostReservePct: Double?
    public var boostStopReason: String?
    public var schedule: Schedule?

    /// When the level was read, on the phone's clock. A level from the car
    /// is as old as the car's last report; any other level is the box's
    /// account as of its answer. The box's own wall clock is never used: a
    /// box without a clock source reads 1970.
    public func socReadAtMs(answeredAtMs: Double) -> Double? {
        guard socPct != nil else { return nil }
        if socSource == "vehicle", let age = vehicleSocAgeS, age.isFinite, age >= 0 {
            return answeredAtMs - age * 1000
        }
        return answeredAtMs
    }

    /// A state of charge off the wire, whole percent. The box stores
    /// fractions and still reads a legacy percent; zero means unset.
    static func pct(_ v: JSON?) -> Double? {
        guard let f = v?.number, f > 0 else { return nil }
        return (f > 1 ? f : f * 100).rounded()
    }

    /// An RFC 3339 time from Go. Its zero time means none.
    static func ms(_ v: JSON?) -> Double? {
        guard let s = v?.string, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = f.date(from: s) ?? {
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: s)
        }()
        guard let date, date.timeIntervalSince1970 > 946_684_800 else { return nil }
        return date.timeIntervalSince1970 * 1000
    }

    public init(_ w: JSON) {
        let num: (String) -> Double? = { w[$0]?.number }
        id = w["id"]?.string ?? ""
        pluggedIn = w["plugged_in"]?.bool == true
        powerW = num("current_power_w") ?? 0
        let fraction = num("current_soc")
        if w["plugged_in"]?.bool == false {
            socPct = nil
        } else if let f = fraction, f >= 0, f <= 1 {
            socPct = (f * 100).rounded()
        } else {
            socPct = num("current_soc_pct")
        }
        socSource = w["soc_source"]?.string ?? ""
        vehicleSocAgeS = num("vehicle_soc_age_s")
        vehicleDriver = w["vehicle_driver"]?.string ?? ""
        vehicleStale = w["vehicle_stale"]?.bool == true
        if let v = num("vehicle_soc"), v >= 0, v <= 1, !vehicleDriver.isEmpty {
            vehicleSocPct = (v * 100).rounded()
        } else {
            vehicleSocPct = nil
        }
        vehicleCapacityWh = num("vehicle_capacity_wh")
        capacitySource = w["capacity_source"]?.string ?? ""
        socRetention = w["soc_retention"]?.string ?? ""
        chargingDeclined = w["charging_declined"]?.bool == true
        targetSocPct = Loadpoint.pct(w["target_soc"]) ?? num("target_soc_pct")
        targetTimeMs = Loadpoint.ms(w["target_time"])
        goalComplete = w["goal_complete"]?.bool == true
        sessionWh = max(0, (num("delivered_wh_session") ?? 0).rounded())
        minChargeW = num("min_charge_w")
        maxChargeW = num("max_charge_w")
        phases = num("phases")
        voltageV = num("voltage_v")
        manualActive = w["manual_active"]?.bool == true
        manualRestoreUnconfirmed = w["manual_restore_unconfirmed"]?.bool == true
        manualSaveError = w["manual_save_error"]?.bool == true
        if let m = w["manual"], m.object != nil {
            manual = Manual(
                state: m["state"]?.string,
                requestedA: m["requested_a"]?.number,
                requestedW: m["requested_w"]?.number,
                commandedA: m["commanded_a"]?.number,
                chargerReason: m["charger_reason"]?.string,
                limitReason: m["limit_reason"]?.string,
                chargerUpdatedAtMs: m["charger_updated_at_ms"]?.number
            )
        }
        if let c = w["charger"], c.object != nil {
            charger = Charger(known: c["known"]?.bool == true, available: c["available"]?.bool, updatedAtMs: c["updated_at_ms"]?.number, reason: c["reason"]?.string)
        }
        commandedW = num("commanded_w")
        commandedReason = w["commanded_reason"]?.string ?? ""
        commandedKnown = w["commanded_known"]?.bool == true
        updatedAtMs = num("updated_at_ms")
        gridDeferred = w["grid_deferred"]?.bool == true
        planStartMs = num("plan_next_start_ms")
        planEndMs = num("plan_next_end_ms")
        planTotalWh = num("plan_total_wh")
        planPending = w["plan_pending"]?.bool == true
        planOutdated = w["plan_outdated"]?.bool == true
        inlinePlan = (w["plan_pending"]?.bool != nil && w["plan_outdated"]?.bool != nil) || w["plan_windows"]?.array != nil
        if planPending || planOutdated {
            planWindows = []
        } else {
            planWindows = (w["plan_windows"]?.array ?? []).compactMap { x in
                guard let s = x["start_ms"]?.number, let e = x["end_ms"]?.number, e > s, let wh = x["wh"]?.number, wh >= 0 else { return nil }
                return Window(fromMs: s, toMs: e, peakW: nil, energyWh: wh)
            }
        }
        manualChargeW = manualActive ? num("manual_charge_w") : nil
        surplusOnly = w["surplus_only"]?.bool == true
        let boost = w["battery_boost"]
        boostActive = boost?["active"]?.bool == true
        boostExpiresAtMs = boostActive ? boost?["expires_at_ms"]?.number : nil
        boostReservePct = boostActive ? Loadpoint.pct(boost?["min_battery_soc"]) : nil
        if !boostActive, let reason = boost?["stop_reason"]?.string, !reason.isEmpty {
            boostStopReason = reason
        } else {
            boostStopReason = nil
        }
        if let s = w["schedule"], s.object != nil, let minute = s["time_of_day_min_utc"]?.number {
            let limit = s["finish_at_vehicle_limit"]?.bool == true
            let socPct = Loadpoint.pct(s["soc"]) ?? s["soc_pct"]?.number
            if limit || (socPct ?? 0) > 0 {
                let clock = s["time_of_day_min"]?.number.map { Int($0) }
                schedule = Schedule(
                    socPct: socPct ?? 100,
                    timeOfDayMinUTC: Int(minute),
                    clockMin: clock.flatMap { (0..<1440).contains($0) ? $0 : nil },
                    surplusUnlockPct: (s["surplus_unlock_bat_soc"]?.number ?? 0) * 100,
                    recurring: s["recurring"]?.bool == true,
                    days: Int(s["days"]?.number ?? 0) & 0x7f,
                    finishAtVehicleLimit: limit
                )
            }
        }
    }
}

// MARK: - Words

/// The app's own words in English or Swedish. The English sentence is the
/// key, so a missing translation shows English rather than a code.
///
/// FTWShared keeps its Swedish in a strings file; FTWKit has no resources,
/// so its Swedish lives in the table below. Tests pin a language with
/// `AppWords.$language.withValue(.sv) { … }`.
public enum AppWords {
    public enum Language: String, Sendable {
        case en, sv

        /// The phone's choice among the two the app speaks.
        public static var preferred: Language {
            Bundle.preferredLocalizations(from: ["en", "sv"]).first == "sv" ? .sv : .en
        }
    }

    @TaskLocal public static var language: Language = .preferred

    public static func text(_ en: String) -> String {
        language == .sv ? (sv[en] ?? en) : en
    }

    /// `%@` in order, or `%1$@` by position, replaced with ready text.
    public static func format(_ en: String, _ args: String...) -> String {
        var out = text(en)
        for (i, a) in args.enumerated() { out = out.replacingOccurrences(of: "%\(i + 1)$@", with: a) }
        for a in args {
            guard let r = out.range(of: "%@") else { break }
            out.replaceSubrange(r, with: a)
        }
        return out
    }

    /// A decimal in the language's own way: "7.2" or "7,2".
    public static func decimal(_ text: String) -> String {
        language == .sv ? text.replacingOccurrences(of: ".", with: ",") : text
    }

    /// "80 %", kept on one line.
    public static func percent(_ v: Double) -> String { "\(Int(v.rounded()))\u{00A0}%" }

    /// "7.2 kW" or "7,2 kW".
    public static func power(_ watts: Double) -> String {
        let p = PowerFormat.parts(watts)
        return "\(decimal(p.text))\u{00A0}\(p.unit)"
    }

    /// "14 kWh", one decimal below ten.
    public static func energy(_ wh: Double) -> String {
        let kwh = max(0, wh) / 1000
        return "\(decimal(kwh >= 10 ? String(Int(kwh.rounded())) : PowerFormat.fixed(kwh, 1)))\u{00A0}kWh"
    }

    /// "07:00" in a zone, the 24-hour clock both languages use for FTW.
    public static func clock(_ ms: Double, zone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let c = cal.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: ms / 1000))
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    public static func clock(minute: Int) -> String {
        String(format: "%02d:%02d", (minute / 60) % 24, minute % 60)
    }

    /// "today 07:00", "tomorrow 07:00", "Tue 07:00", else "12 Oct 07:00".
    public static func day(_ ms: Double, nowMs: Double, zone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let at = Date(timeIntervalSince1970: ms / 1000)
        let now = Date(timeIntervalSince1970: nowMs / 1000)
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: at)).day ?? 0
        let time = clock(ms, zone: zone)
        switch days {
        case 0: return format("today %@", time)
        case 1: return format("tomorrow %@", time)
        case 2..<7: return "\(text(EVText.dayLabels[(cal.component(.weekday, from: at) + 5) % 7])) \(time)"
        default:
            let c = cal.dateComponents([.day, .month], from: at)
            return "\(c.day ?? 1) \(text(monthLabels[((c.month ?? 1) + 11) % 12])) \(time)"
        }
    }

    static let monthLabels = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    static let sv: [String: String] = [
        // Connecting, and the device key (AppModel.connect, Vault)
        "This phone has no record of that home.": "Telefonen har inga uppgifter om det hemmet.",
        "This device has no key for that home.": "Den här enheten har ingen nyckel till det hemmet.",
        "This home was paired before this app could reach it privately.": "Hemmet parkopplades innan appen kunde nå det privat.",
        "Unlocking was cancelled. Try again to open your home.": "Upplåsningen avbröts. Försök igen för att öppna ditt hem.",
        "This device can no longer unlock its key. Open your box's local dashboard, then Settings → FTW app → Show pairing code, and scan a new QR.": "Enheten kan inte längre låsa upp sin nyckel. Öppna boxens lokala dashboard, välj Settings → FTW app → Show pairing code och skanna en ny QR-kod.",
        "This phone is already set up for a home. Sign out of it first.": "Telefonen är redan kopplad till ett hem. Logga ut från det först.",
        "That is the only passkey that can unlock this device. Add another one first.": "Det är den enda passkey som kan låsa upp enheten. Lägg till en till först.",
        "This passkey has not been given access yet. Unlock with the one you set up first.": "Den här passkeyn har inte fått åtkomst än. Lås upp med den du skapade först.",
        "Open your box's local dashboard, then Settings → FTW app → Show pairing code, and scan the QR.": "Öppna boxens lokala dashboard, välj Settings → FTW app → Show pairing code och skanna QR-koden.",
        // Clock and calendar
        "today %@": "i dag %@",
        "tomorrow %@": "i morgon %@",
        "Mon": "mån", "Tue": "tis", "Wed": "ons", "Thu": "tor", "Fri": "fre", "Sat": "lör", "Sun": "sön",
        "Jan": "jan", "Feb": "feb", "Mar": "mar", "Apr": "apr", "May": "maj", "Jun": "jun",
        "Jul": "jul", "Aug": "aug", "Sep": "sep", "Oct": "okt", "Nov": "nov", "Dec": "dec",
        "every day": "varje dag",
        "weekdays": "vardagar",
        "weekends": "helger",
        "once": "en gång",
        "on weekdays": "vardagar",
        "on weekends": "helger",
        "on %@": "%@",

        // The car view
        "Your car": "Bilen",
        "Car": "Bilen",
        "Plugged in": "Inkopplad",
        "Not plugged in": "Inte inkopplad",
        "How full is the car?": "Hur full är bilen?",
        "Correct the level": "Rätta nivån",
        "Plug in the car to tell FTW its level.": "Koppla in bilen för att ange nivån.",
        "FTW takes a level only while the car is plugged in.": "FTW tar emot nivån bara när bilen är inkopplad.",
        "Level unknown": "Nivån är okänd",
        "From the car": "Från bilen",
        "From the car, last reported %@": "Från bilen, senast rapporterad %@",
        "You set %1$@ at %2$@": "Du angav %1$@ kl. %2$@",
        "You set %1$@ at %2$@. FTW adds what has charged since.": "Du angav %1$@ kl. %2$@. FTW räknar in det som laddats sedan.",
        "FTW's estimate from energy delivered": "FTW:s uppskattning från laddad energi",
        "FTW assumes %@. Nobody has told it the real level.": "FTW antar %@. Ingen har angett den riktiga nivån.",
        "FTW assumes": "FTW antar",
        "Nobody has told FTW the car's level yet. Choose it below.": "Ingen har angett bilens nivå än. Välj den nedan.",
        "from the car": "från bilen",
        "reported %@": "rapporterad %@",
        "you set": "du angav",
        "estimated": "uppskattad",
        "not confirmed": "inte bekräftad",
        "The car stopped charging. Its level is not confirmed.": "Bilen slutade ladda. Nivån är inte bekräftad.",
        "Only correct it if the car shows something else.": "Rätta bara om bilen visar något annat.",

        "Goal": "Mål",
        "Ready by": "Klar till",
        "%1$@ by %2$@ %3$@": "%1$@ till %2$@ %3$@",
        "Charge to the car's limit by %1$@ %2$@": "Ladda till bilens gräns till %1$@ %2$@",
        "Next: %@": "Nästa gång: %@",
        "Next: %@, home time": "Nästa gång: %@, hemmatid",
        "No goal yet. Without one, FTW only charges from spare solar.": "Inget mål än. Utan mål laddar FTW bara med solöverskott.",
        "Use %@": "Använd %@",
        "Change": "Ändra",
        "Save": "Spara",
        "Cancel": "Avbryt",
        "Remove goal": "Ta bort målet",
        "Charge to": "Ladda till",
        "Repeat": "Upprepa",
        "Weekdays": "Vardagar",
        "Every day": "Varje dag",
        "Weekends": "Helger",
        "Once": "En gång",
        "This box has no charger.": "Boxen har ingen laddare.",
        "Set %@": "Ange %@",
        "Saving the goal…": "Sparar målet…",
        "Goal saved. FTW is updating the plan.": "Målet är sparat. FTW räknar om planen.",
        "Goal removed.": "Målet är borttaget.",
        "Choose at least one day.": "Välj minst en dag.",

        "Updating the plan…": "Planen räknas om…",
        "Charging times are unavailable. Your goal is saved.": "Laddtiderna saknas just nu. Målet är sparat.",
        "Waiting for tomorrow's prices. Spare solar can charge meanwhile.": "Väntar på morgondagens priser. Solöverskott kan ladda under tiden.",
        "Charging %1$@–%2$@, about %3$@.": "Laddar %1$@–%2$@, cirka %3$@.",
        "Charging %1$@–%2$@, about %3$@, and %4$@ more times.": "Laddar %1$@–%2$@, cirka %3$@, och %4$@ gånger till.",
        "No charging planned yet.": "Ingen laddning planerad än.",
        "On track: %1$@ by %2$@.": "Hinner bli klar: %1$@ till %2$@.",
        "Will not make it: about %1$@ by %2$@, not %3$@.": "Hinner inte: cirka %1$@ till %2$@, inte %3$@.",
        "Goal reached.": "Målet är nått.",
        "Counted from FTW's guess of %@.": "Räknat från FTW:s antagande, %@.",
        "Counted from the level you gave.": "Räknat från nivån du angav.",

        "Charge now": "Ladda nu",
        "Pause": "Pausa",
        "Back to the plan": "Tillbaka till planen",
        "Charge now runs until you go back to the plan or unplug.": "Ladda nu kör tills du går tillbaka till planen eller kopplar ur.",
        "Sent": "Skickat",
        "Received": "Mottaget",
        "Done": "Utfört",

        // What the charger does
        "Charger status is out of date.": "Laddarens status är inaktuell.",
        "Waiting for the charger's first report.": "Väntar på laddarens första rapport.",
        "Paused by you": "Pausad av dig",
        "Charging now at %@": "Laddar nu med %@",
        "Charging at %@": "Laddar med %@",
        "Charge now sent to the charger": "Ladda nu är skickat till laddaren",
        "The charger is starting…": "Laddaren startar…",
        "The car is not taking power. Check the car's charge limit.": "Bilen tar ingen ström. Kolla bilens laddgräns.",
        "The charger has not responded. Check the charger.": "Laddaren har inte svarat. Kolla laddaren.",
        "The main fuse limits charging right now.": "Huvudsäkringen begränsar laddningen just nu.",
        "The charger limits the current.": "Laddaren begränsar strömmen.",
        "Pause sent. Waiting for the charger to stop.": "Paus skickad. Väntar på att laddaren stannar.",
        "The car stopped asking for power.": "Bilen vill inte ta mer ström.",
        "Paused for safety: the electricity meter is not reporting.": "Pausad för säkerhets skull: elmätaren rapporterar inte.",
        "Paused by the main fuse. It resumes on its own.": "Pausad av huvudsäkringen. Den fortsätter av sig själv.",
        "Plugged in · charges at %@": "Inkopplad · laddar kl. %@",
        "Plugged in, not charging now": "Inkopplad, laddar inte nu",
        "%@ this session": "%@ den här laddningen",

        // A command's outcome
        "Sending %@ to FTW…": "Skickar %@ till FTW…",
        "FTW received %@.": "FTW har tagit emot %@.",
        "FTW now plans from %@.": "FTW planerar nu från %@.",
        "FTW kept %@. A newer level came first.": "FTW behöll %@. Ett nyare värde kom före.",
        "FTW received %@ but has not confirmed it yet.": "FTW har tagit emot %@ men inte bekräftat det än.",
        "Sending Charge now…": "Skickar Ladda nu…",
        "Sending Pause…": "Skickar Pausa…",
        "Sending Back to the plan…": "Skickar Tillbaka till planen…",
        "FTW received it.": "FTW har tagit emot det.",
        "FTW received it but has not confirmed the result yet.": "FTW har tagit emot det men inte bekräftat resultatet än.",
        "FTW started charging. Waiting for the car to draw power.": "FTW har startat laddningen. Väntar på att bilen tar ström.",
        "%@. The plan waits until you go back to it.": "%@. Planen väntar tills du går tillbaka till den.",
        "Paused. The car will not charge until you choose.": "Pausad. Bilen laddar inte förrän du väljer.",
        "Back to the plan. FTW decides when to charge.": "Tillbaka till planen. FTW bestämmer när bilen laddar.",
        "Something else changed charging first. Try again.": "Något annat ändrade laddningen först. Försök igen.",

        // Why not
        "Plug the car in first. FTW takes a level only while the car is plugged in.": "Koppla in bilen först. FTW tar emot nivån bara när bilen är inkopplad.",
        "FTW cannot reach the charger right now. Try again shortly.": "FTW når inte laddaren just nu. Försök igen om en stund.",
        "Something changed at home while this was sending. Try again.": "Något ändrades hemma medan det skickades. Försök igen.",
        "Only the home's owner can control charging.": "Bara hemmets ägare kan styra laddningen.",
        "That took too long to reach FTW. Try again.": "Det tog för lång tid att nå FTW. Försök igen.",
        "FTW is starting. Give it a minute.": "FTW startar. Vänta en minut.",
        "Your box cannot do this yet. It may need an update.": "Din box kan inte det här än. Den kan behöva uppdateras.",
        "That did not go through. Try again.": "Det gick inte igenom. Försök igen.",
        "Did not reach FTW. Try again.": "Nådde inte FTW. Försök igen.",
        "Not connected to FTW right now. Try again when the connection is back.": "Inte ansluten till FTW just nu. Försök igen när anslutningen är tillbaka.",
        "FTW received it but could not save it for a restart.": "FTW har tagit emot det men kunde inte spara det inför en omstart.",

        // The box's API, said for people
        "Your box doesn't have that yet — it may be running older software.": "Din box har inte det här än. Den kan köra äldre programvara.",
        "Your box is busy with something else. This will fill in shortly.": "Din box är upptagen med något annat. Det här fylls i snart.",
        "Your box can't answer that right now. Still trying.": "Din box kan inte svara just nu. Försöker igen.",
        "Only the owner of this home can change that.": "Bara hemmets ägare kan ändra det.",
        "Your access to this home was withdrawn by its owner.": "Ägaren har dragit tillbaka din åtkomst till hemmet.",
        "That has to be done from the controls on the home screen.": "Det görs med knapparna i appen.",
        "That one is only available on your box's own page, from home.": "Det går bara att göra på boxens egen sida, hemifrån.",
        "That's more than we can send over your connection — narrow the range.": "Det är mer än anslutningen klarar. Välj ett mindre intervall.",
        "Your box needs more proof than this phone can give. Do it on your box.": "Din box kräver mer bevis än telefonen kan ge. Gör det på boxen.",
        "That didn't work. Nothing on your box has changed.": "Det fungerade inte. Inget på boxen har ändrats.",
        "Someone has to own this home, so the last owner cannot be removed.": "Någon måste äga hemmet, så den sista ägaren kan inte tas bort.",
        "That's no longer on your box.": "Det finns inte längre på boxen.",
        "Your box refused that from this phone.": "Din box nekade det från den här telefonen.",
        "Something changed on your box first. Nothing here was applied.": "Något ändrades på boxen först. Inget härifrån har genomförts.",
        "Your box can't answer that yet. Still trying.": "Din box kan inte svara på det än. Försöker igen.",
        "Something went wrong on your box. Nothing has changed.": "Något gick fel på boxen. Inget har ändrats.",
        "Your box couldn't do that.": "Din box kunde inte göra det.",
        "Your box didn't answer. Still trying.": "Din box svarade inte. Försöker igen.",
        "Your box sent something this app couldn't read.": "Din box skickade något som appen inte kunde läsa.",
        "Choose a valid ready time.": "Välj en giltig klartid.",
        "Choose a charge target from 10 to 100 %.": "Välj ett laddmål mellan 10 och 100 %.",
        "Not up to date — your box is out of reach": "Inte aktuellt – boxen går inte att nå",

        // Is FTW in control?
        "Is FTW in control?": "Styr FTW?",
        "Yes, FTW is in control": "Ja, FTW styr",
        "Nothing blocks it, and every device reports.": "Inget stoppar FTW, och alla enheter rapporterar.",
        "%@ is not reporting": "%@ rapporterar inte",
        "%@ devices are not reporting": "%@ enheter rapporterar inte",
        "The meter": "Elmätaren",
        "The inverter": "Växelriktaren",
        "Read at %@": "Läst kl. %@",
        "Not live right now": "Inte live just nu",
        "Last known %@.": "Senast känt %@.",
        "Waiting for your box.": "Väntar på din box.",
        "FTW is not in control right now": "FTW styr inte just nu",
        "A meter stopped reporting. Your home runs on grid power as usual.": "En mätare har slutat rapportera. Hemmet går på nätet som vanligt.",
        "The battery": "Batteriet",
        "The charger": "Laddaren",
        "A device": "En enhet",

        // Now
        "Now": "Nu",
        "Market now": "Elpris nu",
        "Electricity price": "Elpris",
        "incl. fees and VAT": "inkl. avgifter och moms",
        "Cheapest 2 h": "Billigast 2 h",
        "No 2 h window published": "Inget 2 h-fönster publicerat",
        "No prices published ahead yet.": "Inga priser framåt är publicerade än.",
        "Dotted line: average ahead, %@": "Streckad linje: snitt framåt, %@",
        "Some hours are missing their price.": "Några timmar saknar pris.",
        "Tomorrow's rates aren't published yet.": "Morgondagens priser är inte publicerade än.",
        "Price to import": "Pris att köpa",
        "now": "nu",
        "HOME": "HEMMET",
        "%@ self-powered today": "%@ egen el i dag",
        "Home using %@": "Hemmet använder %@",
        "GRID": "ELNÄT", "SOLAR": "SOL", "BATTERY": "BATTERI", "EV CHARGER": "LADDARE",
        "balanced": "i balans", "importing": "köper", "exporting": "säljer", "no data": "ingen data",
        "idle": "vilar", "charging": "laddar", "discharging": "laddar ur", "observe only": "bara övervakning",
        "Device details are out of date.": "Enhetsdetaljerna är inaktuella.",
        "Device details are out of date. Showing live totals.": "Enhetsdetaljerna är inaktuella. Visar live-summor.",

        // The shell
        "Live demo · simulated home": "Livedemo · simulerat hem",
        "Starting the demo": "Startar demon",
        "Exit demo": "Avsluta demon",
        "Demo": "Demo",
        "Plug in the car": "Koppla in bilen",
        "Unplug the car": "Koppla ur bilen",
        "The demo plugs in a car FTW cannot read, so FTW assumes 20 %.": "Demon kopplar in en bil som FTW inte kan läsa av, så FTW antar 20 %.",
        "Your box is starting": "Din box startar",
        "This can take a few minutes after an update. Nothing is wrong. Your home appears here when it is ready.": "Det kan ta några minuter efter en uppdatering. Inget är fel. Hemmet visas här när boxen är klar.",
        "Access ended": "Åtkomsten är avslutad",
        "This session ended.": "Sessionen är avslutad.",
        "Your box won't let this phone in?": "Släpper boxen inte in telefonen?",
        "Nothing from your box yet": "Inget från din box än",
        "This phone is paired to it and keeps trying on its own. Your home appears here as soon as the box answers.": "Telefonen är parkopplad och försöker själv. Hemmet visas här så fort boxen svarar.",
        "Get this phone back in": "Släpp in telefonen igen",
        "This app is older than your box. Some things are hidden until it updates.": "Appen är äldre än din box. En del döljs tills appen uppdateras.",
    ]
}

// MARK: - Sentences

public enum EVText {
    public static let dayLabels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    public static let manualSaveErrorText = "This choice is active now, but could not be saved for restart. FTW is retrying."

    /// The weekday mask as a person says it.
    public static func days(_ mask: Int) -> String {
        let m = mask & 0x7f
        if m == 0 || m == 0x7f { return AppWords.text("every day") }
        if m == 0b0011111 { return AppWords.text("weekdays") }
        if m == 0b1100000 { return AppWords.text("weekends") }
        return dayLabels.enumerated().filter { m & (1 << $0.offset) != 0 }.map { AppWords.text($0.element) }.joined(separator: ", ")
    }

    /// The days after a time: "on weekdays", "every day", "once".
    static func dayPhrase(_ mask: Int, recurring: Bool) -> String {
        guard recurring else { return AppWords.text("once") }
        let m = mask & 0x7f
        if m == 0 || m == 0x7f { return AppWords.text("every day") }
        if m == 0b0011111 { return AppWords.text("on weekdays") }
        if m == 0b1100000 { return AppWords.text("on weekends") }
        return AppWords.format("on %@", days(m))
    }

    // MARK: The household clock

    /// The zone the box keeps its clock in, when it names one; else the
    /// phone's. "Local" is what a box without TZ sends, and UTC is what a
    /// container without a zone runs in: neither is anyone's home.
    public static func householdZone(boxTZ: String?, phone: TimeZone = .current) -> TimeZone {
        guard let id = boxTZ, !["", "Local", "UTC", "Etc/UTC", "GMT", "Etc/GMT"].contains(id), let zone = TimeZone(identifier: id) else {
            return phone
        }
        return zone
    }

    static func calendar(_ zone: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal
    }

    /// The first instant on `day`'s date at which the clock shows `clock`
    /// minutes or later: Core's `wallClock`. A skipped time gives the end of
    /// the gap, a repeated one its first pass.
    static func wallClock(_ day: Date, clock: Int, zone: TimeZone) -> Date {
        let cal = calendar(zone)
        let start = cal.startOfDay(for: day)
        return cal.date(bySettingHour: clock / 60, minute: clock % 60, second: 0, of: start, matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward) ?? start
    }

    /// A UTC minute of day as the box reads it: the time on `at`'s date in
    /// `zone` that has that UTC minute. Core's `clockFromUTC`.
    public static func clockFromUTC(_ minuteUTC: Int, at: Date, zone: TimeZone) -> Int {
        let m = ((minuteUTC % 1440) + 1440) % 1440
        let start = wallClock(at, clock: 0, zone: zone)
        let utc = calendar(TimeZone(identifier: "UTC")!)
        var c = utc.dateComponents([.year, .month, .day], from: start)
        c.hour = m / 60
        c.minute = m % 60
        var t = utc.date(from: c) ?? start
        if t < start { t = t.addingTimeInterval(86_400) }
        let l = calendar(zone).dateComponents([.hour, .minute], from: t)
        return (l.hour ?? 0) * 60 + (l.minute ?? 0)
    }

    /// The household clock as the box's API carries it: the UTC minute of
    /// that time on `at`'s date. Core's `utcMinuteToday`.
    public static func minuteUTC(clock: Int, at: Date, zone: TimeZone) -> Int {
        let u = calendar(TimeZone(identifier: "UTC")!).dateComponents([.hour, .minute], from: wallClock(at, clock: clock, zone: zone))
        return (u.hour ?? 0) * 60 + (u.minute ?? 0)
    }

    /// The ready time the box uses, on the household clock.
    public static func goalClock(_ s: Loadpoint.Schedule, at: Date, zone: TimeZone) -> Int {
        s.clockMin ?? clockFromUTC(s.timeOfDayMinUTC, at: at, zone: zone)
    }

    /// The next time the household clock shows the ready time on an allowed
    /// day, strictly after now: Core's `NextDeadlineUTC`.
    public static func nextDeadlineMs(_ s: Loadpoint.Schedule, nowMs: Double, zone: TimeZone) -> Double {
        let now = Date(timeIntervalSince1970: nowMs / 1000)
        let clock = goalClock(s, at: now, zone: zone)
        let cal = calendar(zone)
        let today = cal.startOfDay(for: now)
        for i in 0..<15 {
            guard let day = cal.date(byAdding: .day, value: i, to: today) else { break }
            let iso = (cal.component(.weekday, from: day) + 5) % 7
            if s.days != 0, s.days & (1 << iso) == 0 { continue }
            let t = wallClock(day, clock: clock, zone: zone)
            if t > now { return t.timeIntervalSince1970 * 1000 }
        }
        return nowMs
    }

    /// "80 % by 07:00 on weekdays", on the household clock.
    public static func goal(_ s: Loadpoint.Schedule, at: Date, zone: TimeZone) -> String {
        let time = AppWords.clock(minute: goalClock(s, at: at, zone: zone))
        let when = dayPhrase(s.days, recurring: s.recurring)
        if s.finishAtVehicleLimit { return AppWords.format("Charge to the car's limit by %1$@ %2$@", time, when) }
        return AppWords.format("%1$@ by %2$@ %3$@", AppWords.percent(s.socPct), time, when)
    }

    /// The deadline the box plans for: its own, or worked out the way it
    /// works it out. Shown on the household clock, said so when the phone is
    /// somewhere else.
    public static func nextGoal(_ lp: Loadpoint, nowMs: Double, zone: TimeZone, phone: TimeZone = .current) -> String? {
        guard let s = lp.schedule else { return nil }
        let at = lp.targetTimeMs.flatMap { $0 > nowMs ? $0 : nil } ?? nextDeadlineMs(s, nowMs: nowMs, zone: zone)
        let day = AppWords.day(at, nowMs: nowMs, zone: zone)
        let away = zone.secondsFromGMT(for: Date(timeIntervalSince1970: nowMs / 1000)) != phone.secondsFromGMT(for: Date(timeIntervalSince1970: nowMs / 1000))
        return AppWords.format(away ? "Next: %@, home time" : "Next: %@", day)
    }

    /// The goal VISION names, offered when there is none.
    public static let suggestedGoal = (socPct: 80.0, clock: 7 * 60, days: 0b0011111)

    public static func suggestedGoalText() -> String {
        AppWords.format("%1$@ by %2$@ %3$@", AppWords.percent(suggestedGoal.socPct), AppWords.clock(minute: suggestedGoal.clock), dayPhrase(suggestedGoal.days, recurring: true))
    }

    // MARK: The car's level

    /// Where the level on screen comes from, said as such.
    public struct Level: Equatable, Sendable {
        public enum Origin: Equatable, Sendable {
            /// The car reported it within the last five minutes.
            case car
            /// The car reported it, longer ago than that.
            case carEarlier
            /// Someone set it in this app for this plug-in.
            case you
            /// The box's estimate from energy delivered.
            case estimated
            /// The box assumes it; nobody has said.
            case assumed
            /// The car stopped charging; the level is a guess pinned to the goal.
            case unconfirmed
        }

        public var pct: Double
        public var origin: Origin
        /// When the car reported it, or when it was set here.
        public var atMs: Double?
        /// What was set here, once the estimate has moved on from it.
        public var setPct: Double?
    }

    /// A level set in this app, kept for as long as the car stays plugged in.
    public struct LevelSet: Equatable, Sendable {
        public var pct: Double
        public var atMs: Double

        public init(pct: Double, atMs: Double) {
            self.pct = pct
            self.atMs = atMs
        }
    }

    /// Core plans from a car's report for five minutes (VehicleMaxAge).
    public static let carLevelMaxAgeMs: Double = 5 * 60_000

    /// What the box assumes at plug-in when nothing is known.
    public static let assumedPct: Double = 20

    /// The level and where it comes from. Nil when no car is plugged in:
    /// the box takes no level then, so none is offered.
    public static func level(_ lp: Loadpoint, answeredAtMs: Double, nowMs: Double, set: LevelSet? = nil) -> Level? {
        guard lp.pluggedIn else { return nil }
        var car: (pct: Double, atMs: Double)?
        if let pct = lp.vehicleSocPct {
            car = (pct, answeredAtMs - max(0, lp.vehicleSocAgeS ?? 0) * 1000)
        } else if lp.socSource == "vehicle", let pct = lp.socPct {
            car = (pct, lp.socReadAtMs(answeredAtMs: answeredAtMs) ?? answeredAtMs)
        }
        if let car, set.map({ $0.atMs <= car.atMs }) ?? true {
            let old = lp.vehicleStale || nowMs - car.atMs > carLevelMaxAgeMs
            return Level(pct: car.pct, origin: old ? .carEarlier : .car, atMs: car.atMs, setPct: nil)
        }
        switch lp.socSource {
        case "assumed":
            return Level(pct: lp.socPct ?? assumedPct, origin: .assumed, atMs: nil, setPct: nil)
        case "completed":
            guard let pct = lp.socPct else { return nil }
            return Level(pct: pct, origin: .unconfirmed, atMs: nil, setPct: nil)
        default:
            if let set {
                let pct = lp.socPct ?? set.pct
                return Level(pct: pct, origin: .you, atMs: set.atMs, setPct: abs(pct - set.pct) >= 1 ? set.pct : nil)
            }
            guard let pct = lp.socPct else { return nil }
            return Level(pct: pct, origin: .estimated, atMs: nil, setPct: nil)
        }
    }

    /// The sentence under the level: who said it, and when if it matters.
    public static func origin(_ l: Level, zone: TimeZone) -> String {
        switch l.origin {
        case .car: return AppWords.text("From the car")
        case .carEarlier: return AppWords.format("From the car, last reported %@", l.atMs.map { AppWords.clock($0, zone: zone) } ?? "—")
        case .you:
            let at = l.atMs.map { AppWords.clock($0, zone: zone) } ?? "—"
            if let set = l.setPct { return AppWords.format("You set %1$@ at %2$@. FTW adds what has charged since.", AppWords.percent(set), at) }
            return AppWords.format("You set %1$@ at %2$@", AppWords.percent(l.pct), at)
        case .estimated: return AppWords.text("FTW's estimate from energy delivered")
        case .assumed: return AppWords.format("FTW assumes %@. Nobody has told it the real level.", AppWords.percent(l.pct))
        case .unconfirmed: return AppWords.text("The car stopped charging. Its level is not confirmed.")
        }
    }

    /// Two or three words for a row: "FTW assumes", "from the car".
    public static func originShort(_ l: Level, zone: TimeZone) -> String {
        switch l.origin {
        case .car: return AppWords.text("from the car")
        case .carEarlier: return AppWords.format("reported %@", l.atMs.map { AppWords.clock($0, zone: zone) } ?? "—")
        case .you: return AppWords.text("you set")
        case .estimated: return AppWords.text("estimated")
        case .assumed: return AppWords.text("FTW assumes")
        case .unconfirmed: return AppWords.text("not confirmed")
        }
    }

    /// The chips, and a step of five from wherever the level stands.
    public static let levelPresets: [Double] = [20, 40, 60, 80]

    public static func stepped(_ pct: Double, up: Bool) -> Double {
        let next = up ? (pct / 5).rounded(.down) * 5 + 5 : (pct / 5).rounded(.up) * 5 - 5
        return min(100, max(0, next))
    }

    // MARK: What the charger does

    /// What the charger is doing, in a few words. Power leads when there is any.
    public static func status(_ lp: Loadpoint, zone: TimeZone = .current) -> String {
        if let c = lp.charger, c.available != true {
            return AppWords.text(c.known ? "Charger status is out of date." : "Waiting for the charger's first report.")
        }
        if !lp.pluggedIn { return AppWords.text("Not plugged in") }
        if lp.manualActive { return manualStatus(lp) }
        if lp.powerW >= 100 { return AppWords.format("Charging at %@", AppWords.power(lp.powerW)) }
        if lp.chargingDeclined { return AppWords.text("The car stopped asking for power.") }
        if lp.commandedKnown, lp.commandedReason == "site_meter_stale" { return AppWords.text("Paused for safety: the electricity meter is not reporting.") }
        if lp.commandedKnown, lp.commandedW == 0, ["fuse_cooldown", "fuse_limit"].contains(lp.commandedReason) { return AppWords.text("Paused by the main fuse. It resumes on its own.") }
        if !lp.planPending, !lp.planOutdated, let first = lp.planWindows.first ?? lp.planStartMs.map({ Loadpoint.Window(fromMs: $0, toMs: lp.planEndMs ?? $0, peakW: nil, energyWh: nil) }), first.fromMs > 0 {
            return AppWords.format("Plugged in · charges at %@", AppWords.clock(first.fromMs, zone: zone))
        }
        return AppWords.text("Plugged in, not charging now")
    }

    /// A zero hold is a pause; older boxes omit their zero setpoint.
    public static func isPaused(_ lp: Loadpoint) -> Bool {
        guard !lp.manualRestoreUnconfirmed, lp.manualActive else { return false }
        if lp.manualChargeW == 0 { return true }
        if lp.manual?.state == "paused" || lp.manual?.state == "pausing" { return true }
        return lp.manualChargeW == nil && (lp.manual?.requestedW == 0 || lp.manual?.requestedA == 0)
    }

    /// The hold is intent; only a fresh charger reading proves charging.
    public static func manualStatus(_ lp: Loadpoint) -> String {
        if isPaused(lp) {
            if lp.manual?.state == "pausing" || (lp.manual?.state == "stalled" && lp.powerW >= 100) {
                return AppWords.text("Pause sent. Waiting for the charger to stop.")
            }
            return AppWords.text("Paused by you")
        }
        if lp.powerW >= 100 { return AppWords.format("Charging now at %@", AppWords.power(lp.powerW)) }
        switch lp.manual?.state {
        case "unavailable": return AppWords.text("Charger status is out of date.")
        case "accepted", "charging": return AppWords.text("The charger is starting…")
        case "not_drawing": return AppWords.text("The car is not taking power. Check the car's charge limit.")
        case "stalled": return AppWords.text("The charger has not responded. Check the charger.")
        case "limited":
            switch lp.manual?.limitReason {
            case "charger_limit": return AppWords.text("The charger limits the current.")
            case "site_meter_stale": return AppWords.text("Paused for safety: the electricity meter is not reporting.")
            case "fuse_cooldown": return AppWords.text("Paused by the main fuse. It resumes on its own.")
            default: return AppWords.text("The main fuse limits charging right now.")
            }
        default: return AppWords.text("Charge now sent to the charger")
        }
    }

    /// The plan for this car in one line, or why there is none.
    public static func plan(_ lp: Loadpoint, windows: [Loadpoint.Window], nowMs: Double, zone: TimeZone) -> String? {
        if lp.planPending { return AppWords.text("Updating the plan…") }
        if lp.planOutdated { return AppWords.text("Charging times are unavailable. Your goal is saved.") }
        guard lp.pluggedIn, !lp.manualActive, !lp.chargingDeclined, lp.charger?.available != false else { return nil }
        if lp.gridDeferred, lp.schedule != nil { return AppWords.text("Waiting for tomorrow's prices. Spare solar can charge meanwhile.") }
        let ahead = windows.filter { $0.toMs > nowMs }
        guard let first = ahead.first else {
            return lp.schedule == nil ? nil : AppWords.text("No charging planned yet.")
        }
        let wh = ahead.compactMap(\.energyWh).reduce(0, +)
        let from = AppWords.clock(max(first.fromMs, nowMs), zone: zone)
        let to = AppWords.clock(first.toMs, zone: zone)
        let total = AppWords.energy(wh > 0 ? wh : (lp.planTotalWh ?? 0))
        if ahead.count > 1 {
            return AppWords.format("Charging %1$@–%2$@, about %3$@, and %4$@ more times.", from, to, total, String(ahead.count - 1))
        }
        return AppWords.format("Charging %1$@–%2$@, about %3$@.", from, to, total)
    }

    public static func session(_ lp: Loadpoint) -> String? {
        guard lp.pluggedIn, lp.sessionWh >= 50 else { return nil }
        return AppWords.format("%@ this session", AppWords.energy(lp.sessionWh))
    }

    // MARK: Will the car be ready?

    public enum Readiness: Equatable, Sendable {
        case reached
        case onTrack(targetPct: Double, byMs: Double)
        case short(reachPct: Double, targetPct: Double, byMs: Double)
    }

    /// Within this much of the goal the plan counts as making it: a few
    /// hundred watt-hours is rounding inside the plan, not a missed morning.
    static func onTrackWh(_ capacityWh: Double) -> Double { max(300, capacityWh * 0.005) }

    /// Whether the car reaches its goal, from the plan's own shortfall for
    /// it. Nil when the box has not said: no goal, a charge-now hold that
    /// sets the plan aside, a plan being remade, or no shortfall read yet.
    public static func readiness(_ lp: Loadpoint, level: Level?, shortfallWh: Double?, nowMs: Double, zone: TimeZone) -> Readiness? {
        guard lp.pluggedIn, let s = lp.schedule, !lp.manualActive, !lp.planPending, !lp.planOutdated else { return nil }
        if lp.goalComplete { return .reached }
        guard let shortfallWh, shortfallWh.isFinite else { return nil }
        let target = s.finishAtVehicleLimit ? 100 : s.socPct
        let by = lp.targetTimeMs.flatMap { $0 > nowMs ? $0 : nil } ?? nextDeadlineMs(s, nowMs: nowMs, zone: zone)
        if let pct = level?.pct, pct >= target { return .reached }
        let capacity = (lp.vehicleCapacityWh ?? 0) > 0 ? lp.vehicleCapacityWh! : 60_000
        if shortfallWh <= onTrackWh(capacity) { return .onTrack(targetPct: target, byMs: by) }
        let reach = max(level?.pct ?? 0, (target - shortfallWh / capacity * 100).rounded(.down))
        return .short(reachPct: reach, targetPct: target, byMs: by)
    }

    public static func readiness(_ r: Readiness, level: Level?, nowMs: Double, zone: TimeZone) -> String {
        let main: String
        switch r {
        case .reached: return AppWords.text("Goal reached.")
        case .onTrack(let target, let by):
            main = AppWords.format("On track: %1$@ by %2$@.", AppWords.percent(target), AppWords.day(by, nowMs: nowMs, zone: zone))
        case .short(let reach, let target, let by):
            main = AppWords.format("Will not make it: about %1$@ by %2$@, not %3$@.", AppWords.percent(reach), AppWords.day(by, nowMs: nowMs, zone: zone), AppWords.percent(target))
        }
        switch level?.origin {
        case .assumed?, .unconfirmed?: return main + " " + AppWords.format("Counted from FTW's guess of %@.", AppWords.percent(level!.pct))
        default: return main
        }
    }

    // MARK: A command's outcome

    /// One command from the car view, followed from tap to outcome.
    public struct Step: Equatable, Sendable {
        public enum Ask: Equatable, Sendable {
            case level(Double)
            case chargeNow, pause, resume
        }

        public enum Result: Equatable, Sendable {
            /// The box did it, and read back what it now holds.
            case applied(observed: Double?)
            /// Something else changed it first; the box holds `observed`.
            case superseded(observed: Double?)
            /// Taken, not confirmed. Not a failure and not a success; the
            /// note says more when the box did.
            case unconfirmed(note: String?)
            /// Refused, or never arrived. The reason is ready to show.
            case refused(String)
        }

        public var ask: Ask
        /// The box said it has the intent (`cmd.ack`).
        public var acked: Bool
        /// What the box said happened (`cmd.result`), or why not.
        public var result: Result?

        public init(ask: Ask, acked: Bool = false, result: Result? = nil) {
            self.ask = ask
            self.acked = acked
            self.result = result
        }

        public var settled: Bool { result != nil }
    }

    /// The receipt under a control: three marks and one sentence.
    public struct Outcome: Equatable, Sendable {
        public enum Mark: Equatable, Sendable { case done, active, waiting, failed }
        public enum Tone: Equatable, Sendable { case working, done, warning, failed }

        public var sent: Mark
        public var received: Mark
        public var done: Mark
        public var text: String
        public var tone: Tone
    }

    public static func outcome(_ step: Step, _ lp: Loadpoint?) -> Outcome {
        let received: Outcome.Mark
        let done: Outcome.Mark
        let tone: Outcome.Tone
        switch step.result {
        case nil:
            received = step.acked ? .done : .active
            done = step.acked ? .active : .waiting
            tone = .working
        case .applied?:
            received = .done
            done = .done
            tone = .done
        case .superseded?:
            received = .done
            done = .failed
            tone = .warning
        case .unconfirmed?:
            received = .done
            done = .waiting
            tone = .warning
        case .refused?:
            received = step.acked ? .done : .failed
            done = .failed
            tone = .failed
        }
        return Outcome(sent: .done, received: received, done: done, text: outcomeText(step, lp), tone: tone)
    }

    static func outcomeText(_ step: Step, _ lp: Loadpoint?) -> String {
        if case .refused(let why)? = step.result { return why }
        switch step.ask {
        case .level(let asked):
            let pct = AppWords.percent(asked)
            switch step.result {
            case nil: return AppWords.format(step.acked ? "FTW received %@." : "Sending %@ to FTW…", pct)
            case .applied(let seen)?: return AppWords.format("FTW now plans from %@.", AppWords.percent(seen.map { $0 * 100 } ?? asked))
            case .superseded(let seen)?: return AppWords.format("FTW kept %@. A newer level came first.", seen.map { AppWords.percent($0 * 100) } ?? "—")
            case .unconfirmed(let note)?: return note ?? AppWords.format("FTW received %@ but has not confirmed it yet.", pct)
            case .refused?: return ""
            }
        case .chargeNow, .pause, .resume:
            switch step.result {
            case nil:
                if step.acked { return AppWords.text("FTW received it.") }
                switch step.ask {
                case .pause: return AppWords.text("Sending Pause…")
                case .resume: return AppWords.text("Sending Back to the plan…")
                default: return AppWords.text("Sending Charge now…")
                }
            case .superseded?: return AppWords.text("Something else changed charging first. Try again.")
            case .unconfirmed(let note)?: return note ?? AppWords.text("FTW received it but has not confirmed the result yet.")
            case .applied?:
                switch step.ask {
                case .resume: return AppWords.text("Back to the plan. FTW decides when to charge.")
                case .pause:
                    if let lp, lp.manualActive, lp.powerW >= 100 { return AppWords.text("Pause sent. Waiting for the charger to stop.") }
                    return AppWords.text("Paused. The car will not charge until you choose.")
                default:
                    // The box holds the charge now; the charger's own account
                    // says whether the car takes it.
                    guard let lp, lp.manualActive, !isPaused(lp) else { return AppWords.text("FTW started charging. Waiting for the car to draw power.") }
                    if lp.powerW >= 100 { return AppWords.format("%@. The plan waits until you go back to it.", AppWords.format("Charging at %@", AppWords.power(lp.powerW))) }
                    switch lp.manual?.state {
                    case "not_drawing", "stalled", "limited", "unavailable": return manualStatus(lp)
                    default: return AppWords.text("FTW started charging. Waiting for the car to draw power.")
                    }
                }
            case .refused?: return ""
            }
        }
    }

    /// Why a command did not happen, from the box's stable code.
    public static func refusal(_ r: CmdResult) -> String {
        if r.state == .expired { return AppWords.text("That took too long to reach FTW. Try again.") }
        switch r.errorCode {
        case "E_UNAVAILABLE":
            switch r.errorArgs["reason"]?.string {
            case "unplugged": return AppWords.text("Plug the car in first. FTW takes a level only while the car is plugged in.")
            case "persistence_unconfirmed": return AppWords.text("FTW received it but could not save it for a restart.")
            default: return AppWords.text("FTW cannot reach the charger right now. Try again shortly.")
            }
        case "E_PRECONDITION", "E_CONFLICT": return AppWords.text("Something changed at home while this was sending. Try again.")
        case "E_SCOPE_DENIED", "E_GRANT_REVOKED": return AppWords.text("Only the home's owner can control charging.")
        case "E_CMD_EXPIRED": return AppWords.text("That took too long to reach FTW. Try again.")
        case "E_BOOTING": return AppWords.text("FTW is starting. Give it a minute.")
        case "E_UNKNOWN_OP": return AppWords.text("Your box cannot do this yet. It may need an update.")
        default: return AppWords.text("That did not go through. Try again.")
        }
    }

    /// Why a command never reached an answer.
    public static func failure(_ error: Error) -> String {
        if let e = error as? CommandError {
            return e.code == "E_NO_ACK" ? AppWords.text("Did not reach FTW. Try again.") : AppWords.text("That did not go through. Try again.")
        }
        if error is SessionError { return AppWords.text("Not connected to FTW right now. Try again when the connection is back.") }
        return AppWords.text("That did not go through. Try again.")
    }

    // MARK: Charge now, in amps

    public struct Current: Equatable, Sendable {
        public let minA: Int
        public let maxA: Int
        public let wattsPerAmp: Double
        public let phases: Int
    }

    /// The range, with the box page's fallbacks: three phases at 230 V, 6 to
    /// 16 A when no floor or ceiling was reported.
    public static func current(_ lp: Loadpoint) -> Current {
        let phases = (lp.phases ?? 0) > 0 ? lp.phases! : 3
        let volts = (lp.voltageV ?? 0) > 0 ? lp.voltageV! : 230
        let perAmp = phases * volts
        func toA(_ w: Double?) -> Int { guard let w, w > 0 else { return 0 }; return Int((w / perAmp).rounded()) }
        let minA = max(1, toA(lp.minChargeW) == 0 ? 6 : toA(lp.minChargeW))
        var maxA = toA(lp.maxChargeW) == 0 ? 16 : toA(lp.maxChargeW)
        if maxA <= minA { maxA = minA + 1 }
        return Current(minA: minA, maxA: maxA, wattsPerAmp: perAmp, phases: Int(phases))
    }

    /// Watts for a current, never above the ceiling the box declared.
    public static func watts(_ lp: Loadpoint, amps: Int) -> Double {
        let w = (Double(amps) * current(lp).wattsPerAmp).rounded()
        if let cap = lp.maxChargeW, cap > 0 { return min(w, cap) }
        return w
    }

    public static func amps(_ lp: Loadpoint, watts: Double) -> Int {
        Int((watts / current(lp).wattsPerAmp).rounded())
    }

    /// "16 A · 11.0 kW".
    public static func readout(_ lp: Loadpoint, amps: Int) -> String {
        "\(amps) A · \(PowerFormat.fixed(watts(lp, amps: amps) / 1000, 1)) kW"
    }
}
