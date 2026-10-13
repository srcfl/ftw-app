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
    /// flat day's average.
    func savingsRow(dayOffset: Int, nowMs: Double) -> JSON {
        let day = house.localDay(nowMs - Double(dayOffset) * 86_400_000)
        let saved = (1_400 + 900 * house.wobble(Double(dayOffset) * 1e6, 5)).rounded()
        var g: SimulatedHouse.GridDay
        if dayOffset == 0 {
            g = house.gridDay(nowMs: nowMs)
        } else {
            let l = house.ledger(dayOffset: dayOffset, nowMs: nowMs)
            g = SimulatedHouse.GridDay(importWh: l.imp, exportWh: l.exp, importCostOre: l.imp / 1000 * 95, exportRevenueOre: l.exp / 1000 * 95 * SimulatedHouse.spotShare, expectedMs: 86_400_000)
        }
        let expected = g.expectedMs.rounded()
        return [
            "day": .string(day),
            "import_wh": .number(g.importWh.rounded()),
            "export_wh": .number(g.exportWh.rounded()),
            "import_cost_ore": .number(g.importCostOre.rounded()),
            "export_revenue_ore": .number(g.exportRevenueOre.rounded()),
            "actual_cost_ore": .number((g.importCostOre - g.exportRevenueOre).rounded()),
            "saved_ore": .number(saved),
            "expected_ms": .number(expected),
            "history_covered_ms": .number(expected),
            "priced_covered_ms": .number((expected * pricedShare).rounded()),
            "history_coverage_pct": 1,
            "priced_coverage_pct": .number(pricedShare),
            "resolution": "slot",
        ]
    }
}
