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
    /// The nodes Now draws, in its order. Grid and home stay visible so
    /// a missing meter or qualified load reads as unknown. Any other node
    /// the box sends no field for is left out rather than drawn at zero,
    /// unless the home is `known` to have it.
    public static func nodes(fields: [Int: Double], hasCar: Bool, known: [EnergyNode] = []) -> [EnergyNode] {
        EnergyNode.allCases.filter { node in
            node == .grid || node == .home || fields[node.fid] != nil || (node == .car && hasCar) || known.contains(node)
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
        // The charger can supply its own display reading when fresh, or
        // alongside a cached stream. It never changes Core's house load.
        if !loadpoints.stale || site.lastFrameAtMs == nil {
            fields = Flow.withLoadpointEV(fields, evW: chargeW)
        }
        if fields[Contract.FID.evW] == nil, !points.isEmpty { fields[Contract.FID.evW] = chargeW }
        let fromCharger = fields[Contract.FID.evW] != wire
        let car = loadpoints.carLevel
        return readings(
            fields: fields,
            freshness: { fid in fid == Contract.FID.evW && fromCharger ? loadpoints.freshness : site.freshness(fid: fid) },
            carLevel: car.map { ($0.pct, $0.origin == .assumed || $0.origin == .unconfirmed) },
            hasCar: !points.isEmpty,
            known: site.lastFrameAtMs == nil ? site.kept?.nodes ?? [] : []
        )
    }
}

/// Where the flow goes on Now, from the height there is: 72 % of the room
/// between the bar and the plan, never less than 232 pt and never more
/// than 420 pt, centred in that room so the ground above and below it
/// match. The price row of the plan's strip takes 15 % of the ground the
/// flow leaves, from 20 pt up to 56 pt, so its bars read as a chart. A
/// function of the screen and the home's shape alone, so nothing on the
/// page moves when data arrives.
public struct NowLayout: Equatable, Sendable {
    public static let minFlow: CGFloat = 232
    /// The ring and the four corners around it need the height of the ring
    /// plus a label above and below it (Ring / Quiet, 24 October 2026).
    public static let maxFlow: CGFloat = 420
    public static let share: CGFloat = 0.72
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

/// The ring's size and place in the flow's frame: the largest ring, up to
/// 62 % of the width, whose four corner labels clear it by 10 pt, with the
/// labels in the corners of a box (`box`) just tall enough for that. A label
/// on the axis above or below needs the most room; a corner label beside
/// the ring needs less, since the circle leaves the corners free. Where
/// even the least ring leaves the labels too little height, on the
/// smallest phones at the largest text, the labels shrink (`labelScale`)
/// rather than touch it.
public struct RingGeometry: Equatable, Sendable {
    public let center: CGPoint
    /// Through the middle of the arcs.
    public let diameter: CGFloat
    public let thickness: CGFloat
    /// The hub's circle inside it.
    public let hub: CGFloat
    /// The height of the box whose corners hold the labels.
    public let box: CGFloat
    /// What the labels are drawn at, of their size: 1 unless they would
    /// touch the least ring.
    public let labelScale: CGFloat

    /// The least ring: below it the home's figure has no room.
    public static let least: CGFloat = 120
    /// The least the labels shrink to; past it they may come closer.
    public static let leastScale: CGFloat = 0.7

    public init(size: CGSize, label: CGFloat, labelWidth: CGFloat, axis: Bool) {
        // How far a label's inner edge sits from the middle, sideways: none
        // for one centred on the axis.
        let dx = axis ? 0 : max(0, size.width / 2 - labelWidth)
        func thick(_ d: CGFloat) -> CGFloat { max(7, (d * 0.042).rounded()) }
        func dy(_ d: CGFloat) -> CGFloat {
            let reach = d / 2 + thick(d) / 2 + 10
            return dx < reach ? (reach * reach - dx * dx).squareRoot() : 0
        }
        func box(_ d: CGFloat) -> CGFloat { 2 * (dy(d) + label) }
        var d = min(size.width * 0.62, 300)
        while d > Self.least, box(d) > size.height { d = max(Self.least, d - 2) }
        diameter = d
        thickness = thick(d)
        hub = d * 0.62
        // The labels take what height the least ring leaves them.
        let room = size.height / 2 - dy(d)
        labelScale = box(d) > size.height && label > 0 ? min(1, max(Self.leastScale, room / label)) : 1
        self.box = min(size.height, 2 * (dy(d) + label * labelScale))
        center = CGPoint(x: size.width / 2, y: size.height / 2)
    }

    public var radius: CGFloat { diameter / 2 }

    /// A corner label's height for its three rows' type sizes, as
    /// `NodeLabel` lays them out: the name stops at 18 pt.
    public static func labelHeight(name: CGFloat, figure: CGFloat, word: CGFloat) -> CGFloat {
        min(name, 18) * 1.3 + figure * 1.2 + word * 1.3 + 2
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

    /// From the ring to a node on the axis, and from a node's text to the
    /// room it needs, in the axis's least height.
    public static let hubGap: CGFloat = 8
    public static let nodeGap: CGFloat = 4

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
    /// while a node on the axis stacks over or under the ring.
    public static func least(_ nodes: [EnergyNode], node height: CGFloat = 72, hub: CGFloat = 92) -> CGFloat {
        let axis = nodes.contains { [.top, .bottom].contains(spot($0, among: nodes)) }
        guard axis else { return NowLayout.minFlow }
        return 2 * (height + nodeGap + 24 + hubGap + hub / 2)
    }

    // MARK: The ring

    /// Degrees left open between two quarters of the ring.
    public static let ringGap: Double = 14

    /// The middle of a node's arc, in degrees clockwise from three o'clock
    /// (SwiftUI's angles, y down): the quarter facing the node's corner, or
    /// straight up or down for a node on the axis.
    public static func ringAngle(_ spot: Spot) -> Double {
        switch spot {
        case .topLeading: return 225
        case .topTrailing: return 315
        case .bottomTrailing: return 45
        case .bottomLeading: return 135
        case .top: return 270
        case .bottom: return 90
        case .center: return 0
        }
    }

    /// A node's arc: the whole quarter it may light (`track`), and the part
    /// it lights at `fill`, centred in it, so a stronger flow grows both
    /// ways and the quarter's middle always faces the node.
    public struct RingArc: Equatable, Sendable {
        public let track: ClosedRange<Double>
        public let lit: ClosedRange<Double>?
    }

    public static func ringArc(_ spot: Spot, fill: Double) -> RingArc {
        let mid = ringAngle(spot), half = (90 - ringGap) / 2
        let track = (mid - half)...(mid + half)
        let f = min(1, max(0, fill))
        guard f > 0.001 else { return RingArc(track: track, lit: nil) }
        return RingArc(track: track, lit: (mid - half * f)...(mid + half * f))
    }
}
