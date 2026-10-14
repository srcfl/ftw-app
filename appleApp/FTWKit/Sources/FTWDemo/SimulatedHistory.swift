import Foundation
import FTWKit

/// The demo house's past and its plan: made up from the same sun, load and
/// prices it runs on now, so the history leads into the live reading and
/// the plan follows on from it. Deterministic, so two runs of a test agree.
extension SimulatedHouse {
    /// Mean watts over one five-minute bucket, site-signed.
    struct Bucket {
        var grid = 0.0, pv = 0.0, battery = 0.0, load = 0.0, ev = 0.0

        static func + (a: Bucket, b: Bucket) -> Bucket {
            Bucket(grid: a.grid + b.grid, pv: a.pv + b.pv, battery: a.battery + b.battery, load: a.load + b.load, ev: a.ev + b.ev)
        }

        func scaled(_ k: Double) -> Bucket {
            Bucket(grid: grid * k, pv: pv * k, battery: battery * k, load: load * k, ev: ev * k)
        }

        func value(_ series: String) -> Double? {
            switch series {
            case "grid_w": return grid
            case "pv_w": return pv
            case "battery_w": return battery
            case "load_w": return load
            default: return nil
            }
        }
    }

    static let bucketMs: Double = 300_000
    /// How far back the made-up past reaches: 48 hours and a tile's slack.
    static let pastMs: Double = 62 * 3_600_000
    static let minSoc = 0.1

    func recordLive(nowMs: Double, dtMs: Double) {
        if liveSinceMs == nil { liveSinceMs = nowMs }
        let start = (nowMs / Self.bucketMs).rounded(.down) * Self.bucketMs
        let b = Bucket(grid: gridW, pv: pvW, battery: batteryW, load: baseLoadW, ev: evW)
        let e = liveBuckets[start] ?? (Bucket(), 0)
        liveBuckets[start] = (e.sum + b.scaled(dtMs), e.ms + dtMs)
    }

    /// One bucket as the box's ledger would answer it: what the house did
    /// live when it was running, the made-up past before that, and nothing
    /// for a bucket that has not begun.
    func bucket(_ startMs: Double, nowMs: Double) -> Bucket? {
        guard startMs <= nowMs else { return nil }
        if let live = liveBuckets[startMs], live.ms > 0 {
            // The ledger's bucket is still filling: energy so far over the
            // whole bucket's length, as the box's mean power is.
            let full = startMs + Self.bucketMs <= nowMs
            return live.sum.scaled(1 / (full ? live.ms : Self.bucketMs))
        }
        ensurePast(nowMs: nowMs)
        return pastBuckets[startMs]
    }

    private func ensurePast(nowMs: Double) {
        guard pastBuckets.isEmpty else { return }
        let end = ((liveSinceMs ?? nowMs) / Self.bucketMs).rounded(.down) * Self.bucketMs
        var t = end - Self.pastMs
        var soc = 0.45
        while t < end {
            let mid = t + Self.bucketMs / 2
            // A bucket is a mean over five minutes, so the made-up past is
            // too.
            let pv = (0..<5).map { pvAt(t + Double($0) * 60_000 + 30_000) }.reduce(0, +) / 5
            let base = (0..<5).map { baseLoadAt(t + Double($0) * 60_000 + 30_000) }.reduce(0, +) / 5
            let ev = pastCarW(mid)
            let price = priceAt(mid)
            var b = decide(price: price, mean: 90, pv: pv, base: base, ev: ev, soc: soc, mode: "planner_passive_arbitrage")
            if b > 0, soc >= 0.98 { b = 0 }
            if b < 0, soc <= Self.minSoc { b = 0 }
            soc = max(0, min(1, soc + b * Self.bucketMs / 3_600_000 * (b > 0 ? 0.95 : 1 / 0.95) / batteryCapacityWh))
            pastBuckets[t] = Bucket(grid: (base + ev + b + pv).rounded(), pv: pv, battery: b.rounded(), load: base + ev, ev: ev)
            t += Self.bucketMs
        }
    }

    /// The car charged in the small hours of the last two nights.
    func pastCarW(_ ms: Double) -> Double {
        let h = hourOfDay(ms)
        let day = (ms / 86_400_000).rounded(.down)
        let hours = day.truncatingRemainder(dividingBy: 2) == 0 ? 3.0 : 1.5
        return h >= 1 && h < 1 + hours ? Self.chargerW : 0
    }

    /// What the battery does for one slot, in the plan's way: cheap hours
    /// fill it, spare sun goes in, dear hours cover the home. The margin the
    /// household chose keeps more in it.
    func decide(price: Double, mean: Double, pv: Double, base: Double, ev: Double, soc: Double, mode: String) -> Double {
        let net = base + ev + pv
        let keep = 0.2 + 0.25 * min(1, safetyK)
        switch mode {
        case "idle": return 0
        case "charge": return soc < 0.995 ? batteryMaxW : 0
        case "self_consumption": return max(-batteryMaxW, min(batteryMaxW, -net))
        case "peak_shaving": return net > 6_000 ? -(net - 6_000) : (pv < -500 ? min(batteryMaxW, -net) : 0)
        default:
            if net < -200 { return min(batteryMaxW, -net) }
            if price < mean * 0.7, soc < 0.9 { return 3_000 }
            if mode == "planner_arbitrage", price > mean * 1.35, soc > keep + 0.15 { return -batteryMaxW }
            if price > mean * 1.1, soc > keep { return -min(batteryMaxW, max(0, net)) }
            return 0
        }
    }

    /// One slot of the demo's plan.
    struct Step {
        var startMs: Double
        var durationMs: Double
        var batteryW: Double
        var gridW: Double
        var pvW: Double
        var loadW: Double
        var evW: Double
        var priceMinor: Double
        var soc: Double
        var reason: String
    }

    /// The next 24 hours in quarter hours, the one running now first and
    /// starting now.
    func plan(nowMs: Double, hours: Double = 24) -> [Step] {
        let slotMs: Double = 900_000
        var t = (nowMs / slotMs).rounded(.down) * slotMs
        let end = t + hours * 3_600_000
        var prices = [Double]()
        var probe = t
        while probe < end { prices.append(priceAt(probe + slotMs / 2)); probe += slotMs }
        let mean = prices.reduce(0, +) / Double(max(1, prices.count))
        let car = carPlan(nowMs)
        var soc = socFraction
        var out = [Step]()
        while t < end {
            let start = max(t, nowMs)
            let len = t + slotMs - start
            let mid = t + slotMs / 2
            let pv = pvAt(mid)
            let base = baseLoadAt(mid)
            let ev = car.map { mid >= $0.startMs && mid < $0.endMs ? Self.chargerW : 0 } ?? 0
            let price = priceAt(mid)
            var b = decide(price: price, mean: mean, pv: pv, base: base, ev: ev, soc: soc, mode: modeKey)
            if b > 0, soc >= 0.98 { b = 0 }
            if b < 0, soc <= Self.minSoc { b = 0 }
            b = b.rounded()
            soc = max(0, min(1, soc + b * len / 3_600_000 * (b > 0 ? 0.95 : 1 / 0.95) / batteryCapacityWh))
            let grid = (base + ev + b + pv).rounded()
            out.append(Step(startMs: start, durationMs: len, batteryW: b, gridW: grid, pvW: pv, loadW: base, evW: ev, priceMinor: price, soc: soc, reason: reason(b: b, grid: grid, pv: pv, price: price, mean: mean, soc: soc)))
            t += slotMs
        }
        return out
    }

    /// The box's reason codes, read off the numbers as Core reads them.
    private func reason(b: Double, grid: Double, pv: Double, price: Double, mean: Double, soc: Double) -> String {
        if abs(b) <= 100 { return soc <= Self.minSoc + 0.005 ? "reserve_held" : "idle" }
        if b > 0 { return grid > 100 && price < mean ? "cheap_import" : "solar_surplus" }
        if grid < -100 { return "export_paid" }
        return price > mean * 1.1 ? "expensive_import" : "idle"
    }
}

extension SimulatedBox {
    /// The tiles a query asks for, packed as the box packs them: the mean
    /// of the buckets under each point, a hole where there are none, and the
    /// tile still filling marked partial.
    func historyTiles(_ q: HistQuery) -> [HistChunk] {
        let now = scheduler.nowMs
        let plan = HistoryGeometry.plan(q.res, fromMs: q.fromMs, toMs: min(q.toMs, now), maxPoints: q.maxPoints ?? 2000)
        let stepMs = HistoryGeometry.spec(plan.res).stepMs
        let span = HistoryGeometry.spec(plan.res).tileSpanMs
        let held = Dictionary(q.have.map { ($0.tileId, $0.etag) }, uniquingKeysWith: { a, _ in a })
        var out = [HistChunk]()
        for tile in plan.tiles {
            var columns = [[Int32]]()
            for series in q.series {
                var column = [Int32]()
                for p in 0..<tile.points {
                    var sum = 0.0, n = 0.0
                    for k in 0..<plan.stride {
                        let at = tile.startMs + Double(p * plan.stride + k) * stepMs
                        guard q.res == .fiveMinutes else {
                            // The hourly store is the mean of its buckets.
                            var hs = 0.0, hn = 0.0
                            for m in 0..<12 {
                                if let v = house.bucket(at + Double(m) * SimulatedHouse.bucketMs, nowMs: now)?.value(series) { hs += v; hn += 1 }
                            }
                            if hn > 0 { sum += hs / hn; n += 1 }
                            continue
                        }
                        if let v = house.bucket(at, nowMs: now)?.value(series) { sum += v; n += 1 }
                    }
                    column.append(n > 0 ? Int32(max(Double(Int32.min) + 1, min(Double(Int32.max), (sum / n).rounded()))) : missingSample)
                }
                columns.append(column)
            }
            let data = HistoryGeometry.pack(columns)
            let etag = HistoryGeometry.etag(data)
            let partial = tile.startMs + span > now
            if !partial, held[tile.tileId] == etag { continue }
            out.append(HistChunk(tileId: tile.tileId, etag: etag, res: plan.res, startMs: tile.startMs, stepMs: plan.stepMs, series: q.series, data: data, partial: partial))
        }
        return out
    }

    /// The plan as `plan.get` answers it.
    /// The plan as Core sends it: made once a quarter, or when the mode
    /// or the preferences change, and the same plan until then.
    func sessionPlan() -> Plan {
        let quarter = (scheduler.nowMs / 900_000).rounded(.down)
        if let made = madePlan, made.quarter == quarter, made.rev == house.planRev { return made.plan }
        let steps = house.plan(nowMs: scheduler.nowMs)
        let plan = Plan(
            rev: house.planRev,
            uptimeMs: uptimeMs,
            slots: steps.map { PlanSlot(startMs: $0.startMs.rounded(), durationMs: $0.durationMs.rounded(), batteryW: $0.batteryW, gridW: $0.gridW, priceMinor: $0.priceMinor, reason: $0.reason, socPermille: ($0.soc * 1000).rounded()) },
            stale: false,
            ceilingW: nil
        )
        madePlan = (quarter, house.planRev, plan)
        return plan
    }

    /// The planner's own document's actions, as GET /api/mpc/plan carries
    /// them.
    func mpcActions() -> [JSON] {
        house.plan(nowMs: scheduler.nowMs).map { s in
            let slotStart = (s.startMs / 900_000).rounded(.down) * 900_000
            var a: JSON = [
                "execution_start_ms": .number(s.startMs.rounded()),
                "slot_start_ms": .number(slotStart),
                "slot_len_min": 15,
                "price_ore": .number(s.priceMinor),
                "spot_ore": .number((s.priceMinor * 0.6).rounded()),
                "pv_w": .number(s.pvW),
                "forecast_pv_w": .number(s.pvW),
                "forecast_load_w": .number(s.loadW),
                "load_w": .number(s.loadW),
                "battery_w": .number(s.batteryW),
                "grid_w": .number(s.gridW),
                "soc": .number(s.soc),
                "reason": .string(s.reason),
            ]
            if s.evW > 0 { a = a.setting("loadpoint_power_w", ["garage": .number(s.evW)]) }
            return a
        }
    }

    /// The ledger's rows for the car, an hour at a time.
    func carEnergyRows(sinceMs: Double, untilMs: Double) -> [JSON] {
        var rows = [JSON]()
        var t = (sinceMs / 3_600_000).rounded(.down) * 3_600_000
        let now = scheduler.nowMs
        while t < untilMs {
            var wh = 0.0
            for m in 0..<12 {
                if let b = house.bucket(t + Double(m) * SimulatedHouse.bucketMs, nowMs: now) { wh += b.ev * SimulatedHouse.bucketMs / 3_600_000 }
            }
            if wh > 0 {
                rows.append([
                    "schema_version": 1, "asset_id": "system", "flow": "vehicle_charge",
                    "bucket_start_ms": .number(t), "bucket_len_ms": 3_600_000, "energy_wh": .number(wh.rounded()),
                    "source": "meter", "quality": "measured", "provenance": "driver", "sample_count": 12,
                ])
            }
            t += 3_600_000
        }
        return rows
    }
}
