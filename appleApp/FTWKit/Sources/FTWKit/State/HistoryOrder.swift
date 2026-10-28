import Foundation

/// A row of History's day: one of the home's nodes, or what power cost.
/// Its key is the one word the phone keeps, so an order written by some
/// other version of the app reads as nothing rather than as a wrong row.
public enum HistoryRow: Hashable, Sendable, Identifiable {
    case node(EnergyNode)
    case price

    public var id: String { key }

    public var key: String {
        switch self {
        case .node(let node): return node.rawValue
        case .price: return "price"
        }
    }

    public init?(key: String) {
        if key == "price" {
            self = .price
        } else if let node = EnergyNode(rawValue: key) {
            self = .node(node)
        } else {
            return nil
        }
    }
}

/// Which row stands where in History, kept on this phone alone: the box is
/// the record of what the home did, not of the order someone cares to read
/// it in (Fredrik, 27 October 2026). The order is the rows' keys in one
/// string, so `-history.order grid,solar` stands in for it, for screenshots
/// and tests.
///
/// The rule holds three things a stored order cannot. A row this home has
/// not got is left out. A row that turns up later — a charger fitted today,
/// a box that starts serving prices — comes in beside the standard
/// neighbour it follows, wherever the rest has been moved to. A key from
/// another version is passed over, and an order with nothing left in it
/// falls back on the standard one.
public enum HistoryOrder {
    /// Where the order is kept, on this phone only.
    public static let key = "history.order"

    /// The order a day is told in until someone moves it: what the sun
    /// made, what the home used, what the battery stored and gave, what the
    /// grid sold and bought, what the car took, and what it all cost.
    public static let standard: [HistoryRow] = [
        .node(.solar), .node(.home), .node(.battery), .node(.grid), .node(.car), .price,
    ]

    /// What to keep after a move: the rows as the finger left them.
    public static func stored(_ rows: [HistoryRow]) -> String {
        rows.map(\.key).joined(separator: ",")
    }

    /// The rows to draw, in the order to draw them.
    public static func rows(stored: String, nodes: [EnergyNode], price: Bool) -> [HistoryRow] {
        var present = Set(nodes.map(HistoryRow.node))
        if price { present.insert(.price) }
        var out: [HistoryRow] = []
        for key in stored.split(separator: ",") {
            guard let row = HistoryRow(key: String(key)), present.contains(row), !out.contains(row) else { continue }
            out.append(row)
        }
        guard !out.isEmpty else { return standard.filter(present.contains) }
        for (i, row) in standard.enumerated() where present.contains(row) && !out.contains(row) {
            // The nearest standard neighbour before it that is already on
            // screen; with none, the row goes first.
            let after = standard[..<i].reversed().first { out.contains($0) }
            let at = after.flatMap { out.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            out.insert(row, at: at)
        }
        return out
    }

    /// One row put somewhere else: what a finger crossing its neighbour
    /// leaves behind, and what VoiceOver's "Move up" does. A place outside
    /// the list is the nearest end of it, and a row the list has not got
    /// changes nothing.
    public static func moved(_ rows: [HistoryRow], _ row: HistoryRow, to place: Int) -> [HistoryRow] {
        guard let from = rows.firstIndex(of: row) else { return rows }
        let to = min(max(0, place), rows.count - 1)
        guard to != from else { return rows }
        var out = rows
        out.remove(at: from)
        out.insert(row, at: to)
        return out
    }
}
