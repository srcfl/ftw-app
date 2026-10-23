import Foundation
import FTWShared

/// What a watch shows from one read of FTW Cloud, as the records its pages
/// and complications read.
///
/// Every envelope is checked against the box's key the phone handed over
/// (never one from the service) and dated by the freshness rules
/// (`CloudView`), so a record is never newer or more live than the box
/// graded it. A class the read did not bring, or one no rule anchors, is
/// left out, and the watch keeps what it had. The plan is the phone's: the
/// box does not send it to FTW Cloud.
public enum WatchCloud {
    /// The records one read gives, and how long Now stays live after
    /// `nowMs` by the box's own grades. Nil when Now is not live.
    public struct Read: Equatable, Sendable {
        public var context: WatchContext
        public var liveForMs: Double?
    }

    public static func read(_ snapshot: CloudWire.Snapshot, link: WatchLink, kept: WatchContext?, arrivalMs: Double) -> Read? {
        guard let boxKey = link.cloudKey else { return nil }
        var view = CloudView(home: link.cloudHome, boxKey: Bytes(boxKey))
        let at = Int64(arrivalMs)
        for env in snapshot.envelopes {
            try? view.accept(env, arrivalMs: at)
        }
        let g = view.grade(nowMs: at)
        var ctx = WatchContext(home: link.site, isDemo: false, sentAtMs: arrivalMs)
        ctx.modes = kept?.modes
        ctx.link = link

        var liveForMs: Double?
        if let now = now(view, grades: g, nowMs: at) {
            ctx.now = CacheRecord(siteId: link.site, carrier: .cloud, srcState: now.state, readAtMs: now.readAtMs, value: now.value)
            if now.state == .live, let next = view.nextGradeChange(nowMs: at) {
                liveForMs = Double(max(0, next - at))
                ctx.now?.value.standsMs = liveForMs
            }
        }
        if let lp = view.lp, let sent = view.sentMs(lp.header, arrivalMs: at) {
            let keptCars = kept?.cars?.value
            let cars = lp.loadpoints.map(view.joined).map { l -> CarEntry.Car in
                let id = link.loadpoints[l.id] ?? l.id
                let before = keptCars?.cars.first { $0.loadpointID == id }
                return CarEntry.Car(
                    loadpointID: id,
                    pluggedIn: l.plugged,
                    socPct: l.socPermille.map { (Double($0) / 10).rounded() },
                    socSource: l.socSource,
                    socReadAtMs: view.socReadAtMs(l).map(Double.init),
                    powerW: Double(l.powerW),
                    targetSocPct: l.targetPermille.map { (Double($0) / 10).rounded() },
                    carID: l.plugged ? before?.carID : nil,
                    carName: l.plugged ? before?.carName : nil
                )
            }
            let answering = lp.loadpoints.allSatisfy { g.loadpoints[$0.id] == .live }
            ctx.cars = CacheRecord(siteId: link.site, carrier: .cloud, srcState: answering ? .live : .stale, readAtMs: Double(sent),
                                   value: CarEntry(cars: cars, owned: keptCars?.owned, asking: keptCars?.asking))
        }
        if let p = view.prices, p.slotMs > 0, let sent = view.sentMs(p.header, arrivalMs: at) {
            var slots = [PriceSlot]()
            for i in p.spotMinor.indices {
                guard let spot = p.spotMinor[i], i < p.totalMinor.count, let total = p.totalMinor[i] else { continue }
                slots.append(PriceSlot(startMs: Double(p.t0Ms + Int64(i) * p.slotMs), durationMs: Double(p.slotMs),
                                       spotMinor: Double(spot), totalMinor: Double(total)))
            }
            if !slots.isEmpty {
                ctx.prices = CacheRecord(siteId: link.site, carrier: .cloud, srcState: .live, readAtMs: Double(sent),
                                         value: PriceEntry(fromMs: Double(p.t0Ms), prices: Prices(zone: p.zone, currency: p.currency, slots: slots, stale: false), timeZone: link.timeZone))
            }
        }
        return Read(context: ctx, liveForMs: liveForMs)
    }

    /// Now from the newest `live`: one reading per node, as the phone words
    /// them, each live only while the box's grade for its field is.
    static func now(_ view: CloudView, grades g: CloudView.Grades, nowMs: Int64) -> (value: WatchNow, state: SourceState, readAtMs: Double)? {
        guard let live = view.live, g.anchored, let sent = view.anchorSentMs(nowMs: nowMs) else { return nil }
        var fields = [Int: Double]()
        for (k, v) in live.fields {
            if let fid = Int(k) { fields[fid] = Double(v) }
        }
        let carLevel = view.lp?.loadpoints.map(view.joined).first { $0.plugged }?.socPermille.map { (Double($0) / 10).rounded() }
        let hasCar = !(view.lp?.loadpoints.isEmpty ?? true)
        func grade(_ fid: Int) -> SourceState { g.fields[String(fid)] ?? .stale }

        var readings = [WatchNow.Reading]()
        for node in WatchNow.Node.allCases {
            let fid = Self.fid(node)
            guard node == .grid || node == .home || fields[fid] != nil || (node == .car && hasCar) else { continue }
            let raw = fields[fid]
            let w = raw ?? 0
            let idle = abs(w) <= idleW
            let way: WatchNow.Way
            var level: Double?
            switch node {
            case _ where raw == nil: way = .noReading
            case .solar: way = idle ? .resting : .making
            case .battery:
                way = idle ? .resting : (w > 0 ? .charging : .giving)
                level = fields[Contract.FID.batterySoc].map { ($0 / 10).rounded() }
            case .home: way = .using
            case .grid: way = idle ? .balanced : (w > 0 ? .buying : .selling)
            case .car:
                way = idle ? .resting : .charging
                level = carLevel
            }
            readings.append(WatchNow.Reading(node: node, watts: raw.map(abs), way: way, levelPct: level, live: raw != nil && grade(fid) == .live))
        }

        let shown = readings.filter { $0.watts != nil }.map { grade(Self.fid($0.node)) }
        let state = shown.max() ?? .stale
        let control: WatchNow.Control
        if state != .live {
            control = .unknown
        } else if !live.dispatchBlockedBy.isEmpty || g.sources.values.contains(where: { $0 == .stale || $0 == .down }) {
            control = .notInControl
        } else {
            control = .inControl
        }
        return (WatchNow(readings: readings, control: control), state, Double(sent))
    }

    /// The phone's idle line: at or under this a flow rests.
    static let idleW: Double = 42

    static func fid(_ node: WatchNow.Node) -> Int {
        switch node {
        case .solar: return Contract.FID.pvW
        case .battery: return Contract.FID.batteryW
        case .home: return Contract.FID.loadW
        case .grid: return Contract.FID.gridW
        case .car: return Contract.FID.evW
        }
    }
}

extension WatchCloud {
    /// How long the watch waits to read again after FTW Cloud refused
    /// `refusals` reads in a row. The first may be a read that beat the
    /// roster to the service just after the phone added this watch, so it
    /// waits half a minute; after that a wrist raised again and again does
    /// not ask again and again.
    public static func readWaitMs(refusals: Int) -> Double {
        refusals <= 1 ? 30_000 : 15 * 60_000
    }
}
