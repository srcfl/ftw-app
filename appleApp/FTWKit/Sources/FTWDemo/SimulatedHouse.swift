import Foundation

/// A made-up house for the demo and the tests: solar that follows the sun,
/// a household load with a morning and an evening, a battery run by the
/// chosen mode, and one car charger.
///
/// Power follows the site convention: positive into the site, PV never
/// positive, and `grid = load + battery + pv` where the load includes the car.
@MainActor
public final class SimulatedHouse {
    public let pvPeakW: Double = 6_500
    public let batteryCapacityWh: Double = 13_500
    public let batteryMaxW: Double = 5_000
    public let fuseAmps: Double = 25
    public let timeZone: TimeZone
    /// A clear midsummer's day whatever the date, for showing a day that
    /// sells more than it buys.
    public var sunny = false

    public private(set) var socFraction: Double = 0.62
    public private(set) var batteryW: Double = 0
    public private(set) var pvW: Double = 0
    public private(set) var baseLoadW: Double = 0
    public private(set) var gridW: Double = 0

    public var modeKey = "planner_passive_arbitrage" { didSet { planRev += 1 } }

    // The car. It arrives plugged in and unread, so the box assumes 20 %,
    // which is the moment the car view is for.
    public var carPluggedIn = true
    public var carSocFraction: Double = 0.2
    public var carSocSource = "assumed"
    public var carCapacityWh: Double = 64_000
    /// A car that reports its own level: when it last did. Nil for a car
    /// FTW cannot read.
    public var carReportedAtMs: Double?
    public private(set) var evW: Double = 0
    public var manualHoldW: Double? {
        didSet { if manualHoldW != oldValue { manualSinceMs = manualHoldW == nil ? nil : lastStepMs } }
    }
    /// When the current hold began. The demo charger takes a few seconds to
    /// act on it, as a real one does.
    public private(set) var manualSinceMs: Double?
    public var chargerRampMs: Double = 0
    public var surplusOnly = false
    public var boostUntilMs: Double?
    public var boostReserve: Double = 0.3
    public var lastBoostStop: String?
    /// The goal on the household clock, as Core keeps it.
    public var schedule: (socFraction: Double, clockMin: Int, recurring: Bool, days: Int, surplusUnlock: Double)? = (0.8, 7 * 60, true, 0b0011111, 0)
    public private(set) var sessionWh: Double = 0
    private var lastStepMs: Double = 0

    /// What the house did before the demo began, five minutes at a time,
    /// made up once from the same model, and what it has done since, as it
    /// ran. Keyed by the bucket's start.
    var pastBuckets: [Double: Bucket] = [:]
    var liveBuckets: [Double: (sum: Bucket, ms: Double)] = [:]
    /// When the house started running live. Earlier buckets are made up.
    var liveSinceMs: Double?
    /// The household's planner preferences, as Core keeps them.
    public var safetyK: Double = 0.3 { didSet { planRev += 1 } }
    public var batteryExport = "not_allowed" { didSet { planRev += 1 } }
    /// Moves when anything the plan depends on changes.
    public internal(set) var planRev: UInt64 = 1

    /// The cable goes in: a new session, nothing known about the car.
    public func plugIn() {
        carPluggedIn = true
        carSocFraction = 0.2
        carSocSource = carReportedAtMs == nil ? "assumed" : "vehicle"
        sessionWh = 0
        manualHoldW = nil
    }

    /// The cable comes out. An unplug releases a hold, as in Core.
    public func unplug() {
        carPluggedIn = false
        manualHoldW = nil
        boostUntilMs = nil
        evW = 0
    }

    /// Whether the charger has acted on the hold yet.
    public var holdActing: Bool {
        guard let since = manualSinceMs else { return false }
        return lastStepMs - since >= chargerRampMs
    }

    /// The next time the goal's clock comes round on an allowed day.
    public func deadlineMs(_ nowMs: Double) -> Double? {
        guard let s = schedule else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let now = Date(timeIntervalSince1970: nowMs / 1000)
        let today = cal.startOfDay(for: now)
        for i in 0..<15 {
            guard let day = cal.date(byAdding: .day, value: i, to: today),
                  let t = cal.date(bySettingHour: s.clockMin / 60, minute: s.clockMin % 60, second: 0, of: day) else { continue }
            let iso = (cal.component(.weekday, from: day) + 5) % 7
            if s.days != 0, s.days & (1 << iso) == 0 { continue }
            if t > now { return t.timeIntervalSince1970 * 1000 }
        }
        return nil
    }

    public static let chargerW: Double = 11_000
    public static let chargeEfficiency = 0.92

    /// The plan for the car: the night's cheap hours from 01:00, as many as
    /// the goal needs, never past the deadline. `shortfallWh` is what the
    /// battery still lacks at the deadline, the way Core's plan says it.
    public func carPlan(_ nowMs: Double) -> (startMs: Double, endMs: Double, wh: Double, shortfallWh: Double)? {
        guard carPluggedIn, manualHoldW == nil, !surplusOnly, let s = schedule, let deadline = deadlineMs(nowMs) else { return nil }
        let needWh = max(0, (s.socFraction - carSocFraction) * carCapacityWh)
        guard needWh > 1 else { return (nowMs, nowMs, 0, 0) }
        let night = deadline - (hourOfDay(deadline) - 1) * 3_600_000
        let start = max(nowMs, night < deadline ? night : nowMs)
        let hours = max(0, min((deadline - start) / 3_600_000, needWh / (Self.chargerW * Self.chargeEfficiency)))
        let gained = hours * Self.chargerW * Self.chargeEfficiency
        return (start, start + hours * 3_600_000, (hours * Self.chargerW).rounded(), max(0, needWh - gained).rounded())
    }

    // Energy since local midnight, integrated.
    public private(set) var todayImportWh: Double = 6_100
    public private(set) var todayExportWh: Double = 2_400
    public private(set) var todayPVWh: Double = 11_800
    public private(set) var todayLoadWh: Double = 15_500
    public private(set) var todayChargedWh: Double = 4_200
    public private(set) var todayDischargedWh: Double = 3_900
    private var dayKey = ""

    public init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    /// Hours since local midnight, as a fraction.
    func hourOfDay(_ ms: Double) -> Double {
        let seconds = ms / 1000 + Double(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: ms / 1000)))
        let day = seconds.truncatingRemainder(dividingBy: 86_400)
        return (day < 0 ? day + 86_400 : day) / 3_600
    }

    func localDay(_ ms: Double) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: ms / 1000))
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    /// Deterministic wobble in [-1, 1], so two runs of a test agree.
    func wobble(_ ms: Double, _ salt: Double) -> Double {
        let x = sin(ms / 7_919 + salt) * 43_758.5453
        return (x - x.rounded(.down)) * 2 - 1
    }

    /// How far the year is toward midsummer: 1 in June, 0 in December.
    func season(_ ms: Double) -> Double {
        if sunny { return 1 }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let day = Double(cal.ordinality(of: .day, in: .year, for: Date(timeIntervalSince1970: ms / 1000)) ?? 172)
        return 0.5 + 0.5 * cos(2 * Double.pi * (day - 172) / 365)
    }

    /// Solar at a moment, as a PV reading (never positive). A Swedish roof:
    /// long, strong days in June, short, weak ones in December.
    public func pvAt(_ ms: Double) -> Double {
        let h = hourOfDay(ms)
        let s = season(ms)
        let half = 3.5 + 4.5 * s
        guard h > 12.5 - half, h < 12.5 + half else { return 0 }
        let sun = sin(Double.pi * (h - 12.5 + half) / (2 * half))
        let cloud = sunny ? 1 : 0.85 + 0.15 * wobble(ms / 600_000, 3)
        return -(pvPeakW * (0.2 + 0.8 * s) * max(0, sun) * max(0, sun) * cloud).rounded()
    }

    /// The house without the car.
    public func baseLoadAt(_ ms: Double) -> Double {
        let h = hourOfDay(ms)
        var w = 380.0
        if h >= 6.5 && h < 8.5 { w += 1_100 }
        if h >= 17 && h < 19.5 { w += 1_900 }
        if h >= 19.5 && h < 23 { w += 600 }
        // Appliances coming and going, smoothly, and a little noise on top.
        let swing = 90 * sin(ms / 23_000) + 55 * sin(ms / 61_000 + 2)
        return (w + swing + 18 * wobble(ms / 1_000, 1)).rounded()
    }

    /// Import price in öre per kWh, total, for the plan and the price chart.
    public func priceAt(_ ms: Double) -> Double {
        let h = hourOfDay(ms)
        let base = 55 + 60 * max(0, sin(Double.pi * (h - 5) / 6)) + 80 * max(0, sin(Double.pi * (h - 15) / 6))
        let night = h < 5 ? -25.0 : 0
        return (base + night + 6 * wobble(ms / 3_600_000, 7)).rounded()
    }

    public var evWatts: Double { evW }

    /// Move the house forward.
    public func step(nowMs: Double, dtMs: Double) {
        let day = localDay(nowMs)
        if day != dayKey {
            if !dayKey.isEmpty {
                todayImportWh = 0; todayExportWh = 0; todayPVWh = 0
                todayLoadWh = 0; todayChargedWh = 0; todayDischargedWh = 0
            }
            dayKey = day
        }

        pvW = pvAt(nowMs)
        baseLoadW = baseLoadAt(nowMs)

        // The car.
        if let until = boostUntilMs, nowMs >= until {
            boostUntilMs = nil
            lastBoostStop = "expired"
        }
        lastStepMs = nowMs
        if !carPluggedIn || carSocFraction >= 0.999 {
            evW = 0
        } else if let hold = manualHoldW {
            evW = holdActing ? hold : 0
        } else if boostUntilMs != nil {
            evW = 7_400
        } else if surplusOnly {
            let spare = max(0, -pvW - baseLoadW - 200)
            evW = spare >= 1_400 ? min(spare, 11_000).rounded() : 0
        } else if let plan = carPlan(nowMs), nowMs >= plan.startMs, nowMs < plan.endMs {
            evW = Self.chargerW
        } else {
            evW = 0
        }
        if evW > 0 {
            let wh = evW * dtMs / 3_600_000
            sessionWh += wh
            carSocFraction = min(1, carSocFraction + wh * Self.chargeEfficiency / carCapacityWh)
            // A car that reports keeps reporting while it charges.
            if carReportedAtMs != nil, carSocSource == "vehicle" { carReportedAtMs = nowMs }
        }

        // The battery, by mode.
        let load = baseLoadW + evW
        let net = load + pvW
        var want: Double
        switch modeKey {
        case "idle": want = 0
        case "charge": want = batteryMaxW
        case "peak_shaving": want = net > 6_000 ? -(net - 6_000) : (pvW < -500 ? min(batteryMaxW, -net) : 0)
        case "planner_arbitrage":
            let p = priceAt(nowMs)
            want = p < 50 ? batteryMaxW : (p > 120 ? -batteryMaxW : -net)
        default:
            // Self-consumption: cover the house, soak up the surplus. The
            // boost lets the battery feed the car too, down to its reserve.
            want = -net
            if boostUntilMs == nil { want = -(baseLoadW + pvW) }
            if boostUntilMs != nil, socFraction <= boostReserve {
                boostUntilMs = nil
                lastBoostStop = "battery_reserve_reached"
            }
            if modeKey == "planner_passive_arbitrage", want < 0, priceAt(nowMs) < 45 { want = 0 }
        }
        want = max(-batteryMaxW, min(batteryMaxW, want))
        if socFraction >= 0.995, want > 0 { want = 0 }
        if socFraction <= 0.05, want < 0 { want = 0 }
        batteryW = want.rounded()
        let efficiency = batteryW > 0 ? 0.95 : 1 / 0.95
        socFraction = max(0, min(1, socFraction + batteryW * efficiency * dtMs / 3_600_000 / batteryCapacityWh))

        gridW = (load + batteryW + pvW).rounded()
        recordLive(nowMs: nowMs, dtMs: dtMs)

        let h = dtMs / 3_600_000
        // The house's own use, as Core counts it: the car is apart.
        todayLoadWh += baseLoadW * h
        todayPVWh += -pvW * h
        if gridW > 0 { todayImportWh += gridW * h } else { todayExportWh += -gridW * h }
        if batteryW > 0 { todayChargedWh += batteryW * h } else { todayDischargedWh += -batteryW * h }
    }

    /// A day of the energy ledger, made up from the same model, for days
    /// before today.
    public func ledger(dayOffset: Int, nowMs: Double) -> (load: Double, pv: Double, imp: Double, exp: Double, charged: Double, discharged: Double) {
        if dayOffset == 0 {
            return (todayLoadWh, todayPVWh, todayImportWh, todayExportWh, todayChargedWh, todayDischargedWh)
        }
        let seasonal = 0.8 + 0.3 * wobble(Double(dayOffset) * 86_400_000, 11)
        let pv = 26_000 * seasonal
        let load = 17_000 + 3_000 * wobble(Double(dayOffset) * 86_400_000, 12)
        let charged = min(12_000, pv * 0.35)
        let imp = max(1_000, load - pv * 0.55)
        return (load, pv, imp, max(0, pv - load * 0.45 - charged), charged, charged * 0.9)
    }
}
