import Foundation
import FTWKit

/// The demo home's energy tax refund after battery storage, in the shape of
/// Core's `GET /api/energy/battery-return` and its `.csv`. Most returned in
/// winter, when the battery buys at night and sells at the evening peak; a
/// box update leaves a gap in March and in August. The oldest year read two
/// batteries, so it has no figure and says why.
enum SimulatedBatteryReturn {
    static let capacityWh = 13_500.0
    static let efficiency = 0.884
    /// kWh back to the grid in a whole month, January first.
    static let monthKWh: [Double] = [96, 81, 64, 41, 22, 12, 9, 14, 33, 58, 79, 101]
    /// Hours with a meter missing, from the tenth of the month at noon.
    static let gaps = [0, 0, 6, 0, 0, 0, 0, 31, 0, 2, 0, 0]

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = BatteryReturn.zone
        return c
    }

    struct Hour {
        var startMs: Double
        var month: Int
        var complete: Bool
        var returnedWh: Double
    }

    /// Every hour of the year that has ended, as the box counts it.
    static func hours(_ year: Int, nowMs: Double) -> [Hour] {
        let cal = calendar
        guard let start = cal.date(from: DateComponents(year: year, month: 1, day: 1)),
              let end = cal.date(from: DateComponents(year: year + 1, month: 1, day: 1)) else { return [] }
        let until = min(end.timeIntervalSince1970 * 1000, (nowMs / 3_600_000).rounded(.down) * 3_600_000)
        var out: [Hour] = []
        var at = start.timeIntervalSince1970 * 1000
        while at < until {
            let date = Date(timeIntervalSince1970: at / 1000)
            let c = cal.dateComponents([.month, .day, .hour], from: date)
            let month = c.month ?? 1
            let day = c.day ?? 1, hour = c.hour ?? 0
            let days = Double(cal.range(of: .day, in: .month, for: date)?.count ?? 30)
            let gapHours = gaps[month - 1]
            let gap = day == 10 && hour >= 12 && hour < 12 + min(12, gapHours) || day == 11 && gapHours > 12 && hour < gapHours - 12
            // The battery sends back at the evening peak.
            let peak = (17..<21).contains(hour)
            out.append(Hour(startMs: at, month: month, complete: !gap, returnedWh: !gap && peak ? monthKWh[month - 1] * 1000 / (days * 4) : 0))
            at += 3_600_000
        }
        return out
    }

    static func report(_ year: Int, nowMs: Double) -> JSON {
        let hours = Self.hours(year, nowMs: nowMs)
        let oldest = year == BatteryReturn.thisYear(nowMs: nowMs) - BatteryReturn.yearsToApply
        var months: [JSON] = []
        var returned = 0.0
        for m in 1...12 {
            let inMonth = hours.filter { $0.month == m }
            let wh = oldest ? 0 : inMonth.reduce(0) { $0 + $1.returnedWh }
            returned += wh
            months.append(["month": .number(Double(m)), "returned_wh": .number(wh), "hours": .number(Double(inMonth.count)),
                           "complete_hours": .number(Double(inMonth.filter(\.complete).count))])
        }
        return [
            "year": .number(Double(year)), "zone": .string(BatteryReturn.zone.identifier),
            "returned_wh": .number(returned), "hours": .number(Double(hours.count)),
            "complete_hours": .number(Double(hours.filter(\.complete).count)),
            "efficiency": .number(efficiency), "capacity_wh": .number(capacityWh),
            "batteries": .number(oldest ? 2 : 1), "problem": .string(oldest ? "batteries" : ""),
            "months": .array(months),
        ]
    }

    /// The hourly basis, in Core's columns.
    static func csv(_ year: Int, nowMs: Double) -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = BatteryReturn.zone
        var lines = ["hour_start,grid_import_wh,grid_export_wh,battery_charge_wh,battery_discharge_wh,solar_wh,vehicle_discharge_wh,grid_to_battery_wh,battery_to_grid_wh,returned_wh,grid_held_wh,other_held_wh,complete,efficiency,capacity_wh"]
        for h in hours(year, nowMs: nowMs) {
            let back = h.returnedWh
            let toBattery = back > 0 ? 0 : (back == 0 && h.complete ? 120.0 : 0)
            let fields: [Double] = [800 + toBattery, back * 1.1, toBattery, back * 1.2, 0, 0, toBattery, back * 1.1, back, 4_200, 3_100]
            lines.append(([iso.string(from: Date(timeIntervalSince1970: h.startMs / 1000))] + fields.map { String(format: "%.1f", $0) }
                + [String(h.complete), String(format: "%.4f", efficiency), String(format: "%.1f", capacityWh)]).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
