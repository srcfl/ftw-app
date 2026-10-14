import Foundation
import FTWShared

/// What Now draws for each node: the reading as a magnitude with a word for
/// its direction, its colour by role and direction, and whether it is live.
/// From lane 0 alone, so it moves with the stream and asks nothing.
public struct NodeReading: Equatable, Sendable, Identifiable {
    public let node: EnergyNode
    /// Watts as shown: never signed, the direction is in `word`. Nil when the
    /// box sends no such field.
    public let watts: Double?
    public let word: String
    public let tone: Flow.Tone
    /// Power flows toward the home. Decides which way the dots run.
    public let towardHome: Bool
    /// The battery's charge, or the car's level, in percent.
    public let levelPct: Double?
    /// The car's level is FTW's assumption, not a reading.
    public let levelAssumed: Bool
    public let freshness: NodeFreshness

    public var id: EnergyNode { node }

    /// Above the idle line: worth a moving line.
    public var flowing: Bool { (watts ?? 0) > Flow.idleW }
}

public enum NowFlow {
    /// The nodes Now draws, in its order. The grid is always there, because
    /// a home that cannot see its own meter should see that gap; any other
    /// node the box sends no field for is left out rather than drawn at zero,
    /// unless the home is `known` to have it.
    public static func nodes(fields: [Int: Double], hasCar: Bool, known: [EnergyNode] = []) -> [EnergyNode] {
        EnergyNode.allCases.filter { node in
            node == .grid || fields[node.fid] != nil || (node == .car && hasCar) || known.contains(node)
        }
    }

    /// One reading per node the home has. A node with no reading says so.
    public static func readings(
        fields: [Int: Double],
        freshness: (Int) -> NodeFreshness,
        carLevel: (pct: Double, assumed: Bool)? = nil,
        hasCar: Bool = false,
        known: [EnergyNode] = []
    ) -> [NodeReading] {
        var out = [NodeReading]()
        for node in nodes(fields: fields, hasCar: hasCar, known: known) {
            let raw = fields[node.fid]
            let w = raw ?? 0
            let shown = abs(node.shown(w))
            let idle = abs(w) <= Flow.idleW
            let word: String
            let tone: Flow.Tone
            var toward = true
            var level: Double?
            switch node {
            case .solar:
                word = idle ? NodeWords.text("resting") : NodeWords.text("making")
                tone = Flow.tone(.pv, w)
            case .battery:
                word = idle ? NodeWords.text("resting") : (w > 0 ? NodeWords.text("charging") : NodeWords.text("giving power"))
                tone = Flow.tone(.battery, w)
                toward = w < 0
                level = fields[Contract.FID.batterySoc].map { ($0 / 10).rounded() }
            case .home:
                word = NodeWords.text("using")
                tone = .house
                toward = false
            case .grid:
                word = raw == nil ? NodeWords.text("no reading") : (idle ? NodeWords.text("balanced") : (w > 0 ? NodeWords.text("buying") : NodeWords.text("selling")))
                tone = Flow.tone(.grid, raw)
                toward = w >= 0
            case .car:
                word = idle ? NodeWords.text("resting") : NodeWords.text("charging")
                // The car keeps its colour; the word and the dots say it
                // charges.
                tone = .ev
                toward = false
                level = carLevel?.pct
            }
            out.append(NodeReading(
                node: node,
                watts: raw == nil ? nil : shown,
                word: raw == nil ? NodeWords.text("no reading") : word,
                tone: tone,
                towardHome: toward,
                levelPct: level,
                levelAssumed: node == .car && (carLevel?.assumed ?? false),
                freshness: freshness(node.fid)
            ))
        }
        return out
    }
}

extension NowFlow {
    /// Now's nodes from the stream, with the car's charger watts where the
    /// stream leaves them out: the last the box said, dated by its read and
    /// never an invented 0 W. Before this run's first reading, the nodes the
    /// last launch drew keep their places.
    @MainActor
    public static func readings(site: SiteModel, loadpoints: LoadpointsModel) -> [NodeReading] {
        let points = loadpoints.points
        let chargeW = Flow.loadpointChargeW(points)
        var fields = site.session.fields
        let wire = fields[Contract.FID.evW]
        // The car comes off the house only when both are as old: a fresh
        // read beside the stream, or both from the cache. An old read never
        // changes a live figure.
        if !loadpoints.stale || site.lastFrameAtMs == nil {
            fields = Flow.withLoadpointEV(fields, evW: chargeW)
        }
        if fields[Contract.FID.evW] == nil, !points.isEmpty { fields[Contract.FID.evW] = chargeW }
        let fromCharger = fields[Contract.FID.evW] != wire
        let car = points.first.flatMap { loadpoints.level($0) }
        return readings(
            fields: fields,
            freshness: { fid in fid == Contract.FID.evW && fromCharger ? loadpoints.freshness : site.freshness(fid: fid) },
            carLevel: car.map { ($0.pct, $0.origin == .assumed || $0.origin == .unconfirmed) },
            hasCar: !points.isEmpty,
            known: site.lastFrameAtMs == nil ? site.kept?.nodes ?? [] : []
        )
    }
}
