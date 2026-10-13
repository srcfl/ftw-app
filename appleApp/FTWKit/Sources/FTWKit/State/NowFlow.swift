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
    /// One reading per node the home has. The grid is always there, because
    /// a home that cannot see its own meter should see that gap; any other
    /// node the box sends no field for is left out rather than drawn at zero.
    public static func readings(
        fields: [Int: Double],
        freshness: (Int) -> NodeFreshness,
        carLevel: (pct: Double, assumed: Bool)? = nil,
        hasCar: Bool = false
    ) -> [NodeReading] {
        var out = [NodeReading]()
        for node in EnergyNode.allCases {
            let raw = fields[node.fid]
            if raw == nil, node != .grid, !(node == .car && hasCar) { continue }
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
                word: word,
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
