import Foundation

/// FTW Cloud's tiles of one home as this phone holds them: each body as the
/// box signed it and the phone checked it, at most the last 48 hours, the
/// trailing tile's pieces in the order the box sent them.
struct CloudTileStore: Equatable, Sendable {
    private(set) var bodies: [CloudWire.Tiles] = []

    /// The order the box sent them: by its clock, then by `seq` within one
    /// send time. Tiles go only while the box's clock is synced, so every
    /// one carries `wallMs`.
    private static func sent(_ t: CloudWire.Tiles) -> (Int64, UInt64) { (t.header.wallMs ?? 0, t.header.seq) }

    /// Keeps one checked body. A closed tile replaces every piece of its
    /// tile, and a closed one the box sent before it, never one it sent
    /// after; a whole piece every piece the box sent before it. A body held
    /// already (a forwarded append that came again in an answer) changes
    /// nothing.
    mutating func take(_ t: CloudWire.Tiles, nowMs: Int64) {
        bodies.removeAll { $0.tileEnd <= nowMs - CloudWire.tileKeepMs }
        guard t.tileEnd > nowMs - CloudWire.tileKeepMs else { return }
        if bodies.contains(where: { $0.header.boot == t.header.boot && $0.header.seq == t.header.seq }) { return }
        if t.partial, bodies.contains(where: { $0.tileId == t.tileId && !$0.partial }) { return }
        if !t.partial {
            if let held = bodies.first(where: { $0.tileId == t.tileId && !$0.partial }), Self.sent(t) < Self.sent(held) { return }
            bodies.removeAll { $0.tileId == t.tileId }
        } else if t.whole {
            bodies.removeAll { $0.tileId == t.tileId && Self.sent($0) < Self.sent(t) }
        }
        bodies.append(t)
        bodies.sort { Self.sent($0) < Self.sent($1) }
        let pieces = bodies.filter { $0.tileId == t.tileId && $0.partial }
        if pieces.count > CloudWire.tilePiecesMax, let oldest = pieces.first {
            bodies.removeAll { $0 == oldest }
        }
    }

    /// The tiles laid back together, oldest first.
    var laid: [HistChunk] { CloudWire.lay(bodies) }

    var isEmpty: Bool { bodies.isEmpty }
}
