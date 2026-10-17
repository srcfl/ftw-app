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
    /// Power flows toward the home. Decides which way the light runs.
    public let towardHome: Bool
    /// The battery's charge, or the car's level, in percent.
    public let levelPct: Double?
    /// The car's level is FTW's assumption, not a reading.
    public let levelAssumed: Bool
    public let freshness: NodeFreshness

    public var id: EnergyNode { node }

    /// Above the idle line: worth a beam of light.
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
                // The car keeps its colour; the word and the beam say it
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
    /// The shape of Now before the box has ever answered: every corner and
    /// the home, with no figure and no word, so the first reading fills the
    /// drawing in place rather than building it.
    public static let skeleton: [NodeReading] = EnergyNode.allCases.map { node in
        NodeReading(
            node: node, watts: nil, word: "", tone: .muted, towardHome: true, levelPct: nil, levelAssumed: false,
            freshness: NodeFreshness(carrier: .none, srcState: .never, ageMs: nil, sourceName: nil)
        )
    }

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
        // On a box that keeps cars, a car with the cable out still has its
        // last level.
        let car = points.first.flatMap { loadpoints.level($0) }
            ?? loadpoints.cars.flatMap { cars in cars.keepsCars ? cars.ordered.first.flatMap { cars.level($0)?.asLevel(nowMs: site.nowMs) } : nil }
        return readings(
            fields: fields,
            freshness: { fid in fid == Contract.FID.evW && fromCharger ? loadpoints.freshness : site.freshness(fid: fid) },
            carLevel: car.map { ($0.pct, $0.origin == .assumed || $0.origin == .unconfirmed) },
            hasCar: !points.isEmpty,
            known: site.lastFrameAtMs == nil ? site.kept?.nodes ?? [] : []
        )
    }
}

/// Where the flow goes on Now, from the height there is: 45 % of the room
/// between the bar and the plan, never less than 232 pt and never more
/// than 340 pt, centred in that room so the ground above and below it
/// match. The price row of the plan's strip takes 15 % of the ground the
/// flow leaves, from 20 pt up to 56 pt, so its bars read as a chart. A
/// function of the screen and the home's shape alone, so nothing on the
/// page moves when data arrives.
public struct NowLayout: Equatable, Sendable {
    public static let minFlow: CGFloat = 232
    public static let maxFlow: CGFloat = 340
    public static let share: CGFloat = 0.45
    /// The least ground between the flow and the plan.
    public static let gap: CGFloat = 16
    public static let minPrice: CGFloat = 20
    public static let maxPrice: CGFloat = 56
    public static let priceShare: CGFloat = 0.15

    public let flow: CGFloat
    /// From the top of the room to the top of the flow.
    public let above: CGFloat
    /// The height of the strip's price row.
    public let price: CGFloat
    /// What the price row adds to the strip at its least.
    public var grow: CGFloat { price - Self.minPrice }

    /// - room: the height between the bar and the plan's strip at its
    ///   least, with a 20 pt price row.
    /// - least: the height the home's shape needs (`FlowPlan.least`): a
    ///   node on the middle axis needs more than the four corners do.
    public init(room: CGFloat, least: CGFloat = NowLayout.minFlow) {
        let free = max(0, room)
        flow = min(max(0, free - Self.gap), max(least, min(Self.maxFlow, max(Self.minFlow, free * Self.share))))
        let wanted = min(Self.maxPrice, max(Self.minPrice, (free - flow) * Self.priceShare))
        price = Self.minPrice + max(0, min(wanted - Self.minPrice, free - flow - Self.gap))
        let ground = free - flow - (price - Self.minPrice)
        above = max(0, min(ground / 2, ground - Self.gap))
    }
}

/// Where each part of the flow sits, by the box's own rules: the sun top
/// left, the battery top right, the grid bottom left, the car bottom right,
/// the home in the middle. A node whose partner across the middle is
/// missing moves onto the middle axis, so a home with no car is a Y and a
/// home with only the sun and the grid is a straight line.
public enum FlowPlan {
    public enum Spot: Equatable, Sendable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing, top, bottom, center

        /// Which way the node's text lines up: with the edge it sits on, or
        /// centred on the axis.
        public var leading: Bool { self == .topLeading || self == .bottomLeading }
        public var trailing: Bool { self == .topTrailing || self == .bottomTrailing }
        public var onTop: Bool { self == .topLeading || self == .topTrailing || self == .top }
    }

    /// A beam's two ends: at the node, and 8 pt outside the hub's ring.
    public struct Ends: Equatable, Sendable {
        public let node: CGPoint
        public let hub: CGPoint
        public var length: CGFloat { hypot(node.x - hub.x, node.y - hub.y) }
    }

    /// From a beam's end to the hub's ring.
    public static let hubGap: CGFloat = 8
    /// From a node's text to its beam.
    public static let nodeGap: CGFloat = 4
    /// A beam shorter than this is not drawn: there is no room for light.
    public static let shortest: CGFloat = 12

    public static func spot(_ node: EnergyNode, among nodes: [EnergyNode]) -> Spot {
        func has(_ n: EnergyNode) -> Bool { nodes.contains(n) }
        switch node {
        case .home: return .center
        case .solar: return has(.battery) ? .topLeading : .top
        case .battery: return has(.solar) ? .topTrailing : .top
        case .grid: return has(.car) ? .bottomLeading : .bottom
        case .car: return has(.grid) ? .bottomTrailing : .bottom
        }
    }

    /// The height a home's shape needs: the four corners fit the floor,
    /// while a node on the axis stacks over or under the hub with a beam
    /// between them.
    public static func least(_ nodes: [EnergyNode], node height: CGFloat = 72, hub: CGFloat = 92) -> CGFloat {
        let axis = nodes.contains { [.top, .bottom].contains(spot($0, among: nodes)) }
        guard axis else { return NowLayout.minFlow }
        return 2 * (height + nodeGap + 24 + hubGap + hub / 2)
    }

    /// Where a node's beam meets it: just past the text on the hub's side,
    /// a fifth of the way in from its inner edge, or under its middle on
    /// the axis. Fixed by the node's frame, never by its words, so a beam
    /// never moves when a figure changes.
    public static func anchor(_ frame: CGRect, at spot: Spot) -> CGPoint {
        let inset = frame.width * 0.2
        let y = spot.onTop ? frame.maxY + nodeGap : frame.minY - nodeGap
        if spot.leading { return CGPoint(x: frame.maxX - inset, y: y) }
        if spot.trailing { return CGPoint(x: frame.minX + inset, y: y) }
        return CGPoint(x: frame.midX, y: y)
    }

    /// The beam between a node and the hub, straight along the line to the
    /// hub's centre. Nil when the two sit too close for one.
    public static func beam(node frame: CGRect, at spot: Spot, hub: CGRect) -> Ends? {
        let a = anchor(frame, at: spot)
        let c = CGPoint(x: hub.midX, y: hub.midY)
        let d = hypot(a.x - c.x, a.y - c.y)
        let r = hub.width / 2 + hubGap
        guard d - r >= shortest else { return nil }
        let k = r / d
        return Ends(node: a, hub: CGPoint(x: c.x + (a.x - c.x) * k, y: c.y + (a.y - c.y) * k))
    }
}
