import Foundation

/// One charger as `/api/loadpoints` serves it, read tolerantly, and the
/// sentences that describe it. No sentence claims what the box has not
/// said: a charger that does not know the car's charge is described by what
/// it does know, never by an invented percentage.
public struct Loadpoint: Equatable, Sendable, Identifiable {
    public struct Schedule: Equatable, Sendable {
        public var socPct: Double
        public var timeOfDayMinUTC: Int
        public var surplusUnlockPct: Double
        public var recurring: Bool
        /// 7-bit weekday mask, bit 0 = Monday. Zero means every day.
        public var days: Int
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
    public var vehicleCapacityWh: Double?
    public var capacitySource: String
    public var socRetention: String
    public var chargingDeclined: Bool
    public var targetSocPct: Double?
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

    /// A state of charge off the wire, whole percent. The box stores
    /// fractions and still reads a legacy percent; zero means unset.
    static func pct(_ v: JSON?) -> Double? {
        guard let f = v?.number, f > 0 else { return nil }
        return (f > 1 ? f : f * 100).rounded()
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
        vehicleCapacityWh = num("vehicle_capacity_wh")
        capacitySource = w["capacity_source"]?.string ?? ""
        socRetention = w["soc_retention"]?.string ?? ""
        chargingDeclined = w["charging_declined"]?.bool == true
        targetSocPct = Loadpoint.pct(w["target_soc"]) ?? num("target_soc_pct")
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
        if let s = w["schedule"], s.object != nil, let minute = s["time_of_day_min_utc"]?.number,
           let socPct = Loadpoint.pct(s["soc"]) ?? s["soc_pct"]?.number, socPct > 0 {
            schedule = Schedule(
                socPct: socPct,
                timeOfDayMinUTC: Int(minute),
                surplusUnlockPct: (s["surplus_unlock_bat_soc"]?.number ?? 0) * 100,
                recurring: s["recurring"]?.bool == true,
                days: Int(s["days"]?.number ?? 0) & 0x7f
            )
        }
    }
}

public enum EVText {
    public static let dayLabels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    public static let manualSaveErrorText = "This choice is active now, but could not be saved for restart. FTW is retrying."

    /// The weekday mask as a person says it.
    public static func days(_ mask: Int) -> String {
        let m = mask & 0x7f
        if m == 0 || m == 0x7f { return "every day" }
        if m == 0b0011111 { return "weekdays" }
        if m == 0b1100000 { return "weekends" }
        return dayLabels.enumerated().filter { m & (1 << $0.offset) != 0 }.map(\.element).joined(separator: ", ")
    }

    // MARK: Clock conversions

    /// UTC minutes of the day on the local clock, today.
    public static func localTime(minuteUTC: Int, at: Date = Date(), calendar: Calendar = .current) -> (hour: Int, minute: Int) {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        var comps = utc.dateComponents([.year, .month, .day], from: at)
        comps.hour = minuteUTC / 60
        comps.minute = minuteUTC % 60
        let date = utc.date(from: comps) ?? at
        let local = calendar.dateComponents([.hour, .minute], from: date)
        return (local.hour ?? 0, local.minute ?? 0)
    }

    /// A local hour and minute back to UTC minutes of the day, exact for
    /// today's offset: the box's own page does the same.
    public static func minuteUTC(hour: Int, minute: Int, at: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        var comps = calendar.dateComponents([.year, .month, .day], from: at)
        comps.hour = hour
        comps.minute = minute
        guard let date = calendar.date(from: comps) else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let u = utc.dateComponents([.hour, .minute], from: date)
        return (u.hour ?? 0) * 60 + (u.minute ?? 0)
    }

    public static func clock(_ ms: Double, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: ms / 1000))
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    // MARK: Sentences

    /// What the charger is doing now. Power leads when there is any.
    public static func status(_ lp: Loadpoint, canControl: Bool = true) -> String {
        if lp.manualRestoreUnconfirmed {
            return (canControl ? "Confirm how to continue charging." : "An owner needs to confirm how charging should continue.") + " FTW could not confirm the charger or connection."
        }
        if let c = lp.charger, c.available != true {
            return c.known ? "Charger status is out of date. FTW cannot confirm whether the car is charging." : "Waiting for the charger’s first status report."
        }
        if !lp.pluggedIn { return "Not plugged in" }
        if lp.manualActive { return manualStatus(lp) }
        if lp.powerW >= 100 { return "Charging at \(PowerFormat.text(lp.powerW))" }
        if lp.chargingDeclined { return "The car stopped asking for charge. Check its charge limit or schedule. This does not confirm the battery is full." }
        if lp.commandedKnown, lp.commandedReason == "site_meter_stale" { return "Paused for safety: house power readings are out of date. Charging resumes when readings return." }
        if lp.commandedKnown, lp.commandedW == 0, ["fuse_cooldown", "fuse_limit"].contains(lp.commandedReason) { return "Paused: main-fuse protection. Charging resumes on its own." }
        if lp.commandedKnown, let w = lp.commandedW, w > 0 {
            return "FTW requests \(PowerFormat.text(w)). Waiting for the car to draw power." + (lp.charger?.reason.map { " Charger reports: \($0)." } ?? "")
        }
        return "Plugged in — not charging right now"
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
        let m = lp.manual
        let request = m?.requestedA.map { "\(Int($0.rounded())) A" } ?? "your charge request"
        let limit = m?.commandedA.map { "\(Int($0.rounded())) A" } ?? "the requested current"
        let reason = m?.chargerReason.flatMap { $0.isEmpty ? nil : " Charger reports: \($0)." } ?? ""
        let flowing = lp.powerW >= 100 ? PowerFormat.text(lp.powerW) : nil
        switch m?.state {
        case "unavailable": return "Charger status is out of date. FTW cannot confirm whether the car is charging."
        case "pausing": return "Pause requested. " + (flowing.map { "\($0) is still flowing. " } ?? "") + "Waiting for the charger to stop."
        case "paused": return "Paused by you. Charging stays off until you resume the plan, choose Charge now, or unplug."
        case "charging": return lp.powerW > 0 ? "Charging at \(PowerFormat.text(lp.powerW)). \(request) requested." : "The charger reports charging. Waiting for a power reading."
        case "sent": return "FTW received \(request). Waiting for the charger to confirm the new limit." + (flowing.map { " Still charging at \($0)." } ?? "")
        case "accepted": return "Charger reports a \(limit) limit. Waiting for the car to start drawing…\(reason)"
        case "not_drawing": return "Charger offers \(limit) but the car is not drawing.\(reason.isEmpty ? " Check the car’s charge limit or schedule." : reason)"
        case "stalled":
            if isPaused(lp) { return "The charger has not stopped after your pause request. Check the charger’s app." }
            return "The charger has not acted on \(request)." + (flowing.map { " Still charging at \($0)." } ?? "") + (reason.isEmpty ? " Check the charger and the car’s charge limit or schedule." : reason)
        case "limited":
            switch m?.limitReason {
            case "charger_limit": return "The charger limits this request to \(limit) (\(request) requested)."
            case "site_meter_stale": return "Paused for safety: house power readings are out of date. Charging resumes when readings return."
            case "fuse_cooldown": return "Paused: main-fuse protection. Charging resumes on its own."
            default: return "Main fuse limits this charge to \(limit) right now (\(request) requested)."
            }
        default:
            if lp.powerW >= 100 { return "Charging at \(PowerFormat.text(lp.powerW))" }
            return "Manual charge requested. Waiting for charger status."
        }
    }

    public static func plan(_ lp: Loadpoint, nowMs: Double, canControl: Bool = true, calendar: Calendar = .current) -> String? {
        if lp.planPending { return "Updating the charging plan…" }
        if lp.planOutdated { return "Charging times are unavailable. Your settings are saved." }
        if !lp.pluggedIn || lp.manualActive || lp.manualRestoreUnconfirmed || lp.chargingDeclined { return nil }
        if let c = lp.charger, c.available != true { return nil }
        if lp.gridDeferred, lp.schedule != nil { return "Waiting for tomorrow’s electricity prices. Solar surplus can charge the car meanwhile." }
        if let s = lp.planStartMs, let e = lp.planEndMs, s > 0, e > nowMs {
            return "Charging planned \(clock(s, calendar: calendar))–\(clock(e, calendar: calendar))."
        }
        if lp.surplusOnly { return "Solar only: charging waits for spare solar power." }
        if lp.schedule == nil, lp.powerW < 100 {
            return canControl ? "No charging plan yet. Set a ready time, or choose Charge now." : "No charging plan yet. Ask an owner to set a ready time or start charging."
        }
        if lp.schedule != nil, lp.powerW < 100 {
            return canControl ? "No charge window yet for this goal. Choose Charge now if you need to charge immediately." : "No charge window yet for this goal. An owner can start charging now."
        }
        return nil
    }

    /// "85 % Ready by 07:00 · weekdays". Nil when the box has no schedule:
    /// an app that cannot read one cannot claim its absence.
    public static func schedule(_ lp: Loadpoint, at: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let s = lp.schedule else { return nil }
        let t = localTime(minuteUTC: s.timeOfDayMinUTC, at: at, calendar: calendar)
        let when = String(format: "%02d:%02d", t.hour, t.minute)
        return "\(Int(s.socPct.rounded())) % Ready by \(when) · \(s.recurring ? days(s.days) : "once")"
    }

    public static func session(_ lp: Loadpoint) -> String? {
        guard lp.pluggedIn, lp.sessionWh >= 50 else { return nil }
        let kwh = lp.sessionWh / 1000
        return "\(kwh >= 10 ? String(Int(kwh.rounded())) : PowerFormat.fixed(kwh, 1)) kWh this session"
    }

    // MARK: The car's level

    public static let socDefaultPct: Double = 50

    public static func socSource(_ lp: Loadpoint) -> String {
        let retention: String
        switch lp.socRetention {
        case "session": retention = " FTW keeps this level for the same charging session, including after a box restart."
        case "error": retention = " This level could not be saved for a box restart. Enter it again before relying on the plan after restarting."
        default: retention = " This level must be entered again after a box restart."
        }
        switch lp.socSource {
        case "assumed": return "Battery level needs confirmation. The plan currently assumes \(Int(lp.socPct ?? socDefaultPct)) %. Drag to match the car." + retention
        case "vehicle": return "Reported by the car. Drag only to correct drift."
        case "completed": return "The car stopped asking for charge. Its actual battery level is not confirmed. Drag to match the car."
        default: return "Estimated from energy delivered. Drag to the real value and the plan follows." + retention
        }
    }

    // MARK: Charge now, in amps

    public struct Current: Equatable, Sendable {
        public let minA: Int
        public let maxA: Int
        public let wattsPerAmp: Double
        public let phases: Int
    }

    /// The slider's range, with the box page's fallbacks: three phases at
    /// 230 V, 6 to 16 A when no floor or ceiling was reported.
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

    // MARK: Battery boost

    public static let boostReserveDefaultPct = 30
    public static let boostReserveMinPct = 5
    public static let boostDurations: [(seconds: Int, label: String)] = [(1800, "30 min"), (3600, "1 h"), (7200, "2 h"), (14400, "4 h")]
    public static let boostDurationDefault = 3600

    static let boostStop: [String: String] = [
        "cancelled": "it was stopped by hand",
        "expired": "its time ran out",
        "vehicle_unplugged": "the car was unplugged",
        "ev_target_reached": "the car reached its target",
        "departure_reached": "the departure time came",
        "operator_hold": "a manual charge took over",
        "surplus_only": "the charger went back to spare solar only",
        "site_safety_block": "the site meter went quiet",
        "loadpoint_driver_unavailable": "your box lost touch with the charger",
        "battery_unavailable": "your box lost touch with the house battery",
        "battery_reserve_reached": "the house battery reached its reserve",
        "battery_hold": "the house battery was held for something else",
        "core_mode": "the site mode does not allow it",
        "fuse_safety_block": "the fuse limit stepped in",
        "restart_lease_invalid": "your box restarted and would not resume it",
    ]

    public static func boostActive(_ lp: Loadpoint, calendar: Calendar = .current) -> String {
        let reserve = lp.boostReservePct.map { " down to \(Int($0)) %" } ?? ""
        let until = lp.boostExpiresAtMs.map { " until \(clock($0, calendar: calendar))" } ?? ""
        return "Battery boost is on — the house battery is helping the car\(reserve)\(until)."
    }

    public static func boostStopped(_ lp: Loadpoint) -> String? {
        guard !lp.boostActive, let reason = lp.boostStopReason else { return nil }
        return "The last boost ended because \(boostStop[reason] ?? "your box stopped it")."
    }
}
