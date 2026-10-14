import Foundation
import FTWShared
import Observation

/// A node's devices one by one, for a home with more than one: two
/// inverters, two batteries, two chargers. Lane 0 carries the home's totals
/// and each device's freshness, not each device's watts, so those are read
/// from the box's own status document.
///
/// Read when a node's view opens and again when that node's total moves
/// enough to change the split; never on a timer. Each row says when it was
/// read and whether its device is live, from the stream.
@Observable
@MainActor
public final class SourcesModel {
    public struct Device: Equatable, Sendable, Identifiable {
        /// The driver's name, as the box names it.
        public let name: String
        /// Watts as the node shows them, never signed.
        public let watts: Double
        /// What the reading means for this node, signed as the node shows it.
        public let shownW: Double
        public let levelPct: Double?
        public var id: String { name }
    }

    /// A total that moved this much since the last read asks again.
    static let moveW: Double = 150
    static let moveShare = 0.15
    /// Never more often than this, however much the total moves, and not
    /// again on opening another node's view within it.
    nonisolated static let minGapMs: Double = 30_000

    public private(set) var devices: [EnergyNode: [Device]] = [:]
    public private(set) var readAtMs: Double?

    @ObservationIgnored private unowned let site: SiteModel
    @ObservationIgnored private var watching: [EnergyNode: Int] = [:]
    @ObservationIgnored private var token: Int?
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var totalsAtRead: [EnergyNode: Double] = [:]
    @ObservationIgnored private var failedAtMs: Double?

    public init(site: SiteModel) {
        self.site = site
    }

    public func activate(_ node: EnergyNode) {
        watching[node, default: 0] += 1
        if token == nil { token = site.observe { [weak self] in self?.check() } }
        check(force: true)
    }

    public func deactivate(_ node: EnergyNode) {
        watching[node] = max(0, (watching[node] ?? 0) - 1)
        if watching.values.allSatisfy({ $0 == 0 }), let token {
            site.unobserve(token)
            self.token = nil
        }
    }

    /// Only a node with two devices or more has a split worth showing.
    public func split(_ node: EnergyNode) -> [Device]? {
        guard let list = devices[node], list.count >= 2 else { return nil }
        return list
    }

    private func check(force: Bool = false) {
        guard !inFlight, site.session.phase == .streaming, site.hasPassthrough, site.documentVisible else { return }
        let now = site.nowMs
        if let at = failedAtMs, now - at < LiveAsk.retryMs { return }
        // Never read yet (the view opened before the stream did): read now.
        if let at = readAtMs {
            guard now - at >= Self.minGapMs else { return }
        }
        if !force, readAtMs != nil {
            // A home with one device per node has no split to keep up.
            guard watching.contains(where: { node, n in n > 0 && (devices[node]?.count ?? 0) >= 2 }) else { return }
            let moved = watching.contains { node, n in
                guard n > 0, let w = site.session.fields[node.fid], let before = totalsAtRead[node] else { return false }
                return abs(w - before) > max(Self.moveW, abs(before) * Self.moveShare)
            }
            guard moved else { return }
        }
        // Claimed before the task runs, so two checks in one turn read once.
        inFlight = true
        Task { await read() }
    }

    private func read() async {
        defer { inFlight = false }
        let fields = site.session.fields
        do {
            let status = try await ReadOrder.$current.withValue(.status) { try await site.callBox(.get, "/api/status") }
            devices = Self.devices(status)
            readAtMs = site.nowMs
            failedAtMs = nil
            for node in EnergyNode.allCases { totalsAtRead[node] = fields[node.fid] }
        } catch {
            // The totals above are from the stream and stay true; the split
            // waits for the next read.
            failedAtMs = site.nowMs
        }
    }

    /// Per-driver readings from GET /api/status, by node. Drivers the box
    /// calls offline or disabled are not devices at work.
    nonisolated static func devices(_ status: JSON?) -> [EnergyNode: [Device]] {
        var out = [EnergyNode: [Device]]()
        for (name, d) in (status?["drivers"]?.object ?? []).sorted(by: { $0.0 < $1.0 }) {
            let st = d["status"]?.string ?? ""
            guard st != "offline", st != "disabled", d["not_running"]?.bool != true else { continue }
            if let p = d["pv_w"]?.number {
                out[.solar, default: []].append(Device(name: name, watts: abs(p), shownW: -p, levelPct: nil))
            }
            if let b = d["bat_w"]?.number {
                out[.battery, default: []].append(Device(name: name, watts: abs(b), shownW: b, levelPct: d["bat_soc"]?.number.map { ($0 * 100).rounded() }))
            }
            if let e = d["ev_w"]?.number {
                out[.car, default: []].append(Device(name: name, watts: abs(e), shownW: e, levelPct: nil))
            }
            if let m = d["meter_w"]?.number {
                out[.grid, default: []].append(Device(name: name, watts: abs(m), shownW: m, levelPct: nil))
            }
        }
        return out
    }
}

extension SiteModel {
    /// One device's freshness, from the stream's sources keyed by driver.
    public func deviceFreshness(_ name: String) -> NodeFreshness {
        let src = session.sources[name]
        var state = src?.state ?? .never
        var age = src.flatMap { s -> Double? in
            let a = session.uptimeMs - s.lastOkMs
            return a < 0 ? nil : a
        }
        if carrier == .cache, let at = cachedAtMs {
            if state == .live { state = .stale }
            age = (age ?? 0) + max(0, nowMs - at)
        } else if sinceLastFrameMs > 0, state == .live {
            state = .lagging
        }
        return NodeFreshness(carrier: carrier, srcState: state, ageMs: age, sourceName: src?.name ?? name)
    }
}
