import Foundation
import FTWKit

/// The demo's day over the grid, from the same five-minute buckets its
/// history serves, so the grid widget's totals and its chart add up as they
/// do on a real box. Priced the way Core prices it: each quarter hour's
/// import at that quarter's price, less its export at the spot price.
extension SimulatedHouse {
    struct GridDay: Equatable {
        var importWh = 0.0
        var exportWh = 0.0
        var importCostOre = 0.0
        var exportRevenueOre = 0.0
        /// From local midnight to now.
        var expectedMs = 0.0
    }

    /// The spot price the demo pays for export: the share of the total
    /// price the plan's spot column carries (`mpcActions`).
    static let spotShare = 0.6

    /// Local midnight before `ms`, on the house's clock.
    func midnight(_ ms: Double) -> Double {
        ms - hourOfDay(ms) * 3_600_000
    }

    /// Today so far, bucket by bucket. A bucket still filling holds its
    /// energy so far, as the box's ledger does.
    func gridDay(nowMs: Double) -> GridDay {
        let from = midnight(nowMs)
        var day = GridDay(expectedMs: nowMs - from)
        var t = from
        while t < nowMs {
            if let b = bucket(t, nowMs: nowMs) {
                let kwh = b.grid * Self.bucketMs / 3_600_000 / 1000
                let quarter = (t / 900_000).rounded(.down) * 900_000
                let price = priceAt(quarter + 450_000)
                if kwh > 0 {
                    day.importWh += kwh * 1000
                    day.importCostOre += kwh * price
                } else {
                    day.exportWh -= kwh * 1000
                    day.exportRevenueOre -= kwh * price * Self.spotShare
                }
            }
            t += Self.bucketMs
        }
        return day
    }
}

extension SimulatedBox {
    /// One day of `GET /api/savings/daily`, in Core's fields. Today comes
    /// from the buckets; earlier days from the made-up ledger, priced at a
    /// flat day's average. The saving holds its share of the day so far,
    /// and the no-solar, no-battery cost is what was paid plus what was
    /// saved, as the box's own figures add up. The self-consumption
    /// baseline is there because a real box sends it; the app never reads
    /// it.
    func savingsRow(dayOffset: Int, nowMs: Double) -> JSON {
        let day = house.localDay(nowMs - Double(dayOffset) * 86_400_000)
        var g: SimulatedHouse.GridDay
        if dayOffset == 0 {
            g = house.gridDay(nowMs: nowMs)
        } else {
            let l = house.ledger(dayOffset: dayOffset, nowMs: nowMs)
            g = SimulatedHouse.GridDay(importWh: l.imp, exportWh: l.exp, importCostOre: l.imp / 1000 * 95, exportRevenueOre: l.exp / 1000 * 95 * SimulatedHouse.spotShare, expectedMs: 86_400_000)
        }
        let l = house.ledger(dayOffset: dayOffset, nowMs: nowMs)
        let expected = g.expectedMs.rounded()
        let actual = (g.importCostOre - g.exportRevenueOre).rounded()
        let saved = ((1_400 + 900 * house.wobble(Double(dayOffset) * 1e6, 5)) * min(1, g.expectedMs / 86_400_000)).rounded()
        return [
            "day": .string(day),
            "import_wh": .number(g.importWh.rounded()),
            "export_wh": .number(g.exportWh.rounded()),
            "load_wh": .number(l.load.rounded()),
            "pv_wh": .number(l.pv.rounded()),
            "ev_wh": 0,
            "import_cost_ore": .number(g.importCostOre.rounded()),
            "export_revenue_ore": .number(g.exportRevenueOre.rounded()),
            "actual_cost_ore": .number(actual),
            "baseline_cost_ore": .number(actual + saved),
            "saved_ore": .number(saved),
            "self_consumption_cost_ore": .number((actual + saved * 0.2).rounded()),
            "self_consumption_saved_ore": .number((saved * 0.2).rounded()),
            "expected_ms": .number(expected),
            "history_covered_ms": .number(expected),
            "priced_covered_ms": .number((expected * pricedShare).rounded()),
            "history_coverage_pct": 1,
            "priced_coverage_pct": .number(pricedShare),
            "resolution": "slot",
        ]
    }

    /// The whole answer for `days` days, today last, with the box's totals.
    func savingsAnswer(days: Int, nowMs: Double) -> JSON {
        let rows: [JSON] = (0..<days).reversed().map { savingsRow(dayOffset: $0, nowMs: nowMs) }
        func sum(_ key: String) -> JSON { .number(rows.reduce(0) { $0 + ($1[key]?.number ?? 0) }) }
        let expected = rows.reduce(0) { $0 + ($1["expected_ms"]?.number ?? 0) }
        let priced = rows.reduce(0) { $0 + ($1["priced_covered_ms"]?.number ?? 0) }
        let totals: JSON = [
            "import_wh": sum("import_wh"), "export_wh": sum("export_wh"), "load_wh": sum("load_wh"),
            "actual_cost_ore": sum("actual_cost_ore"), "baseline_cost_ore": sum("baseline_cost_ore"),
            "saved_ore": sum("saved_ore"),
            "self_consumption_cost_ore": sum("self_consumption_cost_ore"), "self_consumption_saved_ore": sum("self_consumption_saved_ore"),
            "expected_ms": .number(expected), "history_covered_ms": .number(expected), "priced_covered_ms": .number(priced),
            "history_coverage_pct": 1, "priced_coverage_pct": .number(expected > 0 ? priced / expected : 0),
        ]
        return [
            "days": .array(rows), "totals": totals,
            "tz": .string(house.timeZone.identifier), "value_scope": "site_total",
            "baseline": "no_pv_no_battery_vehicle_energy_at_daily_average",
            "baselines": ["no_pv_no_battery", "self_consumption"],
        ]
    }
}
