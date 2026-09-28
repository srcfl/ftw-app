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

    public private(set) var socFraction: Double = 0.62
    public private(set) var batteryW: Double = 0
    public private(set) var pvW: Double = 0
    public private(set) var baseLoadW: Double = 0
    public private(set) var gridW: Double = 0

    public var modeKey = "planner_passive_arbitrage"

    // The car.
    public var carPluggedIn = true
    public var carSocFraction: Double = 0.41
    public var carSocSource = "inferred"
    public var carCapacityWh: Double = 64_000
    public private(set) var evW: Double = 0
    public var manualHoldW: Double?
    public var surplusOnly = false
    public var boostUntilMs: Double?
    public var boostReserve: Double = 0.3
    public var lastBoostStop: String?
    public var schedule: (socFraction: Double, minuteUTC: Int, recurring: Bool, days: Int, surplusUnlock: Double)? = (0.8, 5 * 60, true, 0b0011111, 0)
    public private(set) var sessionWh: Double = 5_300

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

    /// Solar at a moment, as a PV reading (never positive).
    public func pvAt(_ ms: Double) -> Double {
        let h = hourOfDay(ms)
        guard h > 5.5, h < 20.5 else { return 0 }
        let sun = sin(Double.pi * (h - 5.5) / 15)
        let cloud = 0.85 + 0.15 * wobble(ms / 60_000, 3)
        return -(pvPeakW * max(0, sun) * max(0, sun) * cloud).rounded()
    }

    /// The house without the car.
    public func baseLoadAt(_ ms: Double) -> Double {
        let h = hourOfDay(ms)
        var w = 380.0
        if h >= 6.5 && h < 8.5 { w += 1_100 }
        if h >= 17 && h < 19.5 { w += 1_900 }
        if h >= 19.5 && h < 23 { w += 600 }
        return (w + 120 * wobble(ms / 5_000, 1)).rounded()
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
        if !carPluggedIn || carSocFraction >= 0.999 {
            evW = 0
        } else if let hold = manualHoldW {
            evW = hold
        } else if boostUntilMs != nil {
            evW = 7_400
        } else if surplusOnly {
            let spare = max(0, -pvW - baseLoadW - 200)
            evW = spare >= 1_400 ? min(spare, 11_000).rounded() : 0
        } else if let schedule, carSocFraction < schedule.socFraction, isChargeHour(nowMs) {
            evW = 11_000
        } else {
            evW = 0
        }
        if evW > 0 {
            let wh = evW * dtMs / 3_600_000
            sessionWh += wh
            carSocFraction = min(1, carSocFraction + wh * 0.92 / carCapacityWh)
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

        let h = dtMs / 3_600_000
        todayLoadWh += load * h
        todayPVWh += -pvW * h
        if gridW > 0 { todayImportWh += gridW * h } else { todayExportWh += -gridW * h }
        if batteryW > 0 { todayChargedWh += batteryW * h } else { todayDischargedWh += -batteryW * h }
    }

    /// The cheap night hours before the ready time.
    func isChargeHour(_ ms: Double) -> Bool {
        let h = hourOfDay(ms)
        return h >= 1 && h < 5
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
