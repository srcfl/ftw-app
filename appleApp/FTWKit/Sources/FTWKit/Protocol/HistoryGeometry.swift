import Foundation

/// History geometry: tiles, resolutions and the column packing. The same
/// numbers the box uses, so a tile asked for and a tile built are one tile.
///
/// Downsampling always happens on the box. When a window is too wide the box
/// clamps to a coarser store and reports `resActual`; when even that is too
/// wide it averages whole buckets and widens `stepMs`.
public enum HistoryGeometry {
    public struct Spec: Sendable {
        public let stepMs: Double
        public let tileSpanMs: Double
        public let retentionMs: Double
    }

    static let dayMs: Double = 86_400_000

    /// Mirrors `resolutions` in protocol/registry.yaml.
    public static func spec(_ res: Resolution) -> Spec {
        switch res {
        case .fiveMinutes: return Spec(stepMs: 300_000, tileSpanMs: 43_200_000, retentionMs: 30 * dayMs)
        case .hour: return Spec(stepMs: 3_600_000, tileSpanMs: 604_800_000, retentionMs: 730 * dayMs)
        }
    }

    /// Fine to coarse: the order the box clamps along.
    public static let order: [Resolution] = [.fiveMinutes, .hour]

    public static func pointsPerTile(_ res: Resolution) -> Int {
        let s = spec(res)
        return Int(s.tileSpanMs / s.stepMs)
    }

    /// Tiles are epoch-aligned, so two peers never disagree where one starts.
    public static func tileStart(_ res: Resolution, _ atMs: Double) -> Double {
        let span = spec(res).tileSpanMs
        return (atMs / span).rounded(.down) * span
    }

    public struct PlannedTile: Equatable, Sendable {
        public let tileId: String
        public let startMs: Double
        public let points: Int
    }

    public struct Plan: Equatable, Sendable {
        public let res: Resolution
        public let stride: Int
        public let stepMs: Double
        public let tiles: [PlannedTile]
    }

    /// Resolution, stride and tile list for a window, deterministically, so
    /// the client plans the same tiles the box will send.
    public static func plan(_ res: Resolution, fromMs: Double, toMs: Double, maxPoints: Int = 2000) -> Plan {
        let cap = max(1, maxPoints)
        // Transfer is whole tiles, so what must fit under the cap is the
        // tile-aligned span, not the requested one.
        func alignedSpan(_ r: Resolution) -> Double {
            let first = tileStart(r, fromMs)
            let last = tileStart(r, max(fromMs, toMs - 1))
            return last + spec(r).tileSpanMs - first
        }

        // Clamp to a coarser store before aggregating: coarser stored data is
        // real data, an aggregate of finer data is an average of it.
        var chosen = order.last!
        for candidate in order where order.firstIndex(of: candidate)! >= order.firstIndex(of: res)! {
            chosen = candidate
            if alignedSpan(candidate) / spec(candidate).stepMs <= Double(cap) { break }
        }

        let base = spec(chosen).stepMs
        let total = alignedSpan(chosen)
        let n = pointsPerTile(chosen)
        let options = (1...n).filter { n % $0 == 0 }
        let stride = options.first { total / (base * Double($0)) <= Double(cap) } ?? options.last!
        let span = spec(chosen).tileSpanMs
        let firstStart = tileStart(chosen, fromMs)
        let lastStart = tileStart(chosen, max(fromMs, toMs - 1))

        var tiles = [PlannedTile]()
        var start = firstStart
        while start <= lastStart {
            tiles.append(PlannedTile(tileId: tileID(chosen, stride: stride, startMs: start), startMs: start, points: n / stride))
            start += span
        }
        return Plan(res: chosen, stride: stride, stepMs: base * Double(stride), tiles: tiles)
    }

    /// The stride is part of a tile's identity: six buckets averaged hold
    /// different numbers from the same hours at full detail.
    public static func tileID(_ res: Resolution, stride: Int, startMs: Double) -> String {
        "\(res.rawValue)/\(stride)/\(Int64(startMs / spec(res).tileSpanMs))"
    }

    /// One contiguous int32 LE block per series.
    public static func pack(_ columns: [[Int32]]) -> Bytes {
        var out = Bytes()
        for column in columns {
            for v in column {
                let u = UInt32(bitPattern: v)
                out += [UInt8(u & 0xff), UInt8(u >> 8 & 0xff), UInt8(u >> 16 & 0xff), UInt8(u >> 24)]
            }
        }
        return out
    }

    public static func unpack(_ data: Bytes, seriesCount: Int) -> [[Int32]] {
        guard seriesCount > 0 else { return [] }
        let points = data.count / 4 / seriesCount
        guard points > 0 else { return Array(repeating: [], count: seriesCount) }
        return (0..<seriesCount).map { s in
            (0..<points).map { i in
                let at = (s * points + i) * 4
                return Int32(bitPattern: UInt32(data[at]) | UInt32(data[at + 1]) << 8 | UInt32(data[at + 2]) << 16 | UInt32(data[at + 3]) << 24)
            }
        }
    }

    /// Evenly spaced samples per series, ready to draw.
    public struct Frame: Equatable, Sendable {
        public var startMs: Double
        public var stepMs: Double
        public var points: Int
        public var names: [String]
        /// One per name. `missingSample` where there is a hole.
        public var columns: [[Int32]]

        public func value(_ name: String, at index: Int) -> Int32? {
            guard let c = names.firstIndex(of: name), index >= 0, index < columns[c].count else { return nil }
            let v = columns[c][index]
            return v == missingSample ? nil : v
        }

        public func time(at index: Int) -> Double { startMs + Double(index) * stepMs }
    }

    /// Lay tiles end to end. A missing tile stays missing rather than
    /// shifting what follows it: closing over a gap would show the wrong day.
    public static func assemble(_ plan: Plan, names: [String], tiles: [String: HistChunk]) -> Frame {
        let perTile = plan.tiles.first?.points ?? 0
        let points = perTile * plan.tiles.count
        var columns = names.map { _ in [Int32](repeating: missingSample, count: points) }
        for (index, planned) in plan.tiles.enumerated() {
            guard let tile = tiles[planned.tileId] else { continue }
            let unpacked = unpack(tile.data, seriesCount: tile.series.count)
            let offset = index * perTile
            for (target, name) in names.enumerated() {
                guard let s = tile.series.firstIndex(of: name), s < unpacked.count else { continue }
                let source = unpacked[s].prefix(perTile)
                for (i, v) in source.enumerated() { columns[target][offset + i] = v }
            }
        }
        return Frame(startMs: plan.tiles.first?.startMs ?? 0, stepMs: plan.stepMs, points: points, names: names, columns: columns)
    }

    /// Trim a tile-aligned frame to the window asked for.
    public static func clip(_ frame: Frame, fromMs: Double, toMs: Double) -> Frame {
        guard frame.points > 0 else { return frame }
        let first = max(0, Int(((fromMs - frame.startMs) / frame.stepMs).rounded(.down)))
        let last = min(frame.points, Int(((toMs - frame.startMs) / frame.stepMs).rounded(.up)))
        if first == 0 && last == frame.points { return frame }
        if last <= first { return Frame(startMs: frame.startMs, stepMs: frame.stepMs, points: 0, names: frame.names, columns: frame.names.map { _ in [] }) }
        return Frame(
            startMs: frame.startMs + Double(first) * frame.stepMs,
            stepMs: frame.stepMs,
            points: last - first,
            names: frame.names,
            columns: frame.columns.map { Array($0[first..<last]) }
        )
    }

    /// FNV-1a over the tile, the box's etag.
    public static func etag(_ data: Bytes) -> String {
        var h: UInt32 = 0x811c9dc5
        for b in data {
            h ^= UInt32(b)
            h = h &* 0x01000193
        }
        let s = String(h, radix: 16)
        return String(repeating: "0", count: 8 - s.count) + s
    }
}
