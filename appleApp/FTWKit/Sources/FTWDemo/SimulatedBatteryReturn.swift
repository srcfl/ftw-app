import Foundation
import FTWKit

/// The demo home's energy tax refund after battery storage, in the shape of
/// Core's `GET /api/energy/battery-return` and its `.csv`. Most returned in
/// winter, when the battery buys at night and sells at the evening peak; a
/// box update leaves a gap in March and in August. Two years back a second
/// battery stood beside the first, and each has its own account. The oldest
/// year the box's settings had a size for that battery but read nothing
/// from it, so that year has no figure and says why.
enum SimulatedBatteryReturn {
    struct Battery {
        var assetId: String
        var label: String
        var capacityWh: Double
        var efficiency: Double
        /// Its part of what went back.
        var share: Double
    }

    static let sungrow = Battery(assetId: "sungrow-sh10rt", label: "sungrow", capacityWh: 13_500, efficiency: 0.884, share: 1)
    static let pixii = Battery(assetId: "pixii-powershaper", label: "pixii", capacityWh: 10_000, efficiency: 0.902, share: 0.38)
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

    /// The batteries the box read in the year.
    static func batteries(_ year: Int, nowMs: Double) -> [Battery] {
        guard year == BatteryReturn.thisYear(nowMs: nowMs) - 2 else { return [sungrow] }
        var first = sungrow
        first.share = 1 - pixii.share
        return [first, pixii]
    }

    /// The drivers with a battery size that read no battery in the year.
    static func unread(_ year: Int, nowMs: Double) -> [String] {
        year == BatteryReturn.thisYear(nowMs: nowMs) - BatteryReturn.yearsToApply ? [pixii.label] : []
    }

    static func report(_ year: Int, nowMs: Double) -> JSON {
        let hours = Self.hours(year, nowMs: nowMs)
        // A year without a figure counts no hours as complete.
        let figure = unread(year, nowMs: nowMs).isEmpty
        var months: [JSON] = []
        var returned = 0.0, complete = 0
        for m in 1...12 {
            let inMonth = hours.filter { $0.month == m }
            let wh = figure ? inMonth.reduce(0) { $0 + $1.returnedWh } : 0
            let full = figure ? inMonth.filter(\.complete).count : 0
            returned += wh
            complete += full
            months.append(["month": .number(Double(m)), "returned_wh": .number(wh), "hours": .number(Double(inMonth.count)),
                           "complete_hours": .number(Double(full))])
        }
        let batteries: [JSON] = batteries(year, nowMs: nowMs).map { b in
            ["asset_id": .string(b.assetId), "label": .string(b.label), "sized": true, "returned_wh": .number(returned * b.share),
             "efficiency": .number(b.efficiency), "capacity_wh": .number(b.capacityWh)]
        }
        return [
            "year": .number(Double(year)), "zone": .string(BatteryReturn.zone.identifier),
            "returned_wh": .number(returned), "hours": .number(Double(hours.count)),
            "complete_hours": .number(Double(complete)),
            "batteries": .array(batteries), "unread": .array(unread(year, nowMs: nowMs).map { .string($0) }),
            "problem": .string(figure ? "" : "battery_unread"),
            "months": .array(months),
        ]
    }

    /// The hourly basis, in Core's columns: one row per battery and hour.
    static func csv(_ year: Int, nowMs: Double) -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = BatteryReturn.zone
        let batteries = batteries(year, nowMs: nowMs)
        let figure = unread(year, nowMs: nowMs).isEmpty
        var lines = ["hour_start,battery,grid_import_wh,grid_export_wh,battery_charge_wh,battery_discharge_wh,solar_wh,vehicle_discharge_wh,other_batteries_discharge_wh,grid_to_battery_wh,battery_to_grid_wh,returned_wh,grid_held_wh,other_held_wh,complete,efficiency,capacity_wh"]
        for h in hours(year, nowMs: nowMs) {
            let back = h.returnedWh
            let toBattery = back > 0 ? 0 : (h.complete ? 120.0 : 0)
            for b in batteries {
                let s = b.share
                let fields: [Double] = [800 + toBattery, back * 1.1, toBattery * s, back * 1.2 * s, 0, 0, back * 1.2 * (1 - s),
                                        toBattery * s, back * 1.1 * s, figure ? back * s : 0, 4_200 * s, 3_100 * s]
                lines.append(([iso.string(from: Date(timeIntervalSince1970: h.startMs / 1000)), b.assetId] + fields.map { String(format: "%.1f", $0) }
                    + [String(h.complete), String(format: "%.4f", b.efficiency), String(format: "%.1f", b.capacityWh)]).joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
