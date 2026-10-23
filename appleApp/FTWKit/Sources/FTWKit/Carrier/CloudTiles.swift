import Foundation

/// FTW Cloud's tiles: the last 48 hours of the box's five-minute history, so
/// a phone can draw it while the box cannot answer (srcfl/ftw
/// `docs/protocol-cloud.md`, tiles). A port of Go's `cloudwire/tiles.go`;
/// `CloudTilesTests` replays its vectors.
///
/// A tiles body is the box's `hist.chunk` with the common header, signed by
/// the box. It comes in three shapes, all at five minutes and stride 1:
/// closed (every point, the same bytes the box serves over Noise), whole (a
/// trailing tile with every point, missing where a bucket has not closed),
/// and an append (only the buckets that closed since the last piece).
extension CloudWire {
    /// Phone to service, `{have}`: the closed tiles the phone holds, by id
    /// and etag. The service answers with the box's tiles the phone lacks.
    public static let msgTilesGet = "tiles.get"
    /// Service to phone, `{n}`: the answer to `tiles.get` is complete.
    public static let msgTilesEnd = "tiles.end"

    /// The columns the box sends, in this order: what the history asks the
    /// box for, so a closed tile is the same bytes either way.
    public static let tileSeries = ["grid_w", "pv_w", "battery_w", "load_w"]
    /// How far back the service keeps tiles, and the phone holds them.
    public static let tileKeepMs: Int64 = 48 * 3_600_000
    /// How many pieces of the trailing tile a holder keeps.
    static let tilePiecesMax = 16
    static let tileSeriesMax = 16
    static let tileStepMs: Int64 = 300_000
    static let tileSpanMs: Int64 = 43_200_000
    static let tilePoints = 144

    /// One tile, or one piece of the trailing tile.
    public struct Tiles: Equatable, Sendable {
        public var header: Header
        public var tileId: String
        public var etag: String
        public var res: String
        public var startMs: Int64
        public var stepMs: Int64
        public var series: [String]
        /// int32 LE, one block per series, `missingSample` for a hole.
        public var data: Bytes
        public var partial: Bool

        /// The start of the tile this body belongs to.
        public var tileStart: Int64 { startMs / CloudWire.tileSpanMs * CloudWire.tileSpanMs }
        public var tileEnd: Int64 { tileStart + CloudWire.tileSpanMs }
        /// Points per series.
        public var points: Int { series.isEmpty ? 0 : data.count / 4 / series.count }
        /// A closed tile, or a whole piece that replaces every piece of its
        /// tile before it.
        public var whole: Bool { startMs == tileStart }

        /// Whether this is one of the three shapes. Nothing else is held or
        /// laid.
        public func check() throws {
            func bad(_ why: String) -> WireError { WireError(code: "E_CLOUD_TILE", message: why) }
            guard res == Resolution.fiveMinutes.rawValue, stepMs == CloudWire.tileStepMs else { throw bad("not 5-minute steps") }
            guard startMs >= 0, startMs % stepMs == 0 else { throw bad("start off the 5-minute grid") }
            guard tileId == HistoryGeometry.tileID(.fiveMinutes, stride: 1, startMs: Double(tileStart)) else {
                throw bad("tile id does not name the tile its start is in")
            }
            guard !series.isEmpty, series.count <= CloudWire.tileSeriesMax else { throw bad("series count") }
            guard Set(series).count == series.count, series.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 }) else { throw bad("series names") }
            let n = points
            guard n >= 1, data.count == n * 4 * series.count else { throw bad("data is not whole columns") }
            guard Int((startMs - tileStart) / stepMs) + n <= CloudWire.tilePoints else { throw bad("data runs past the tile") }
            guard partial || (whole && n == CloudWire.tilePoints) else { throw bad("a closed tile that is not the whole tile") }
            guard etag == HistoryGeometry.etag(data) else { throw bad("etag") }
        }

        /// The tile as the box session carries it.
        public var chunk: HistChunk {
            HistChunk(tileId: tileId, etag: etag, res: .fiveMinutes, startMs: Double(startMs), stepMs: Double(stepMs), series: series, data: data, partial: partial)
        }
    }

    /// `tiles.get`'s body.
    static func tilesGet(have: [String: String]) -> CBOR {
        .map([("have", .map(have.sorted { $0.key < $1.key }.map { ($0.key, CBOR.text($0.value)) }))])
    }

    /// Puts tiles back together in the order the box sent them: a closed tile
    /// as it is; the trailing tile from its newest whole piece, with each
    /// later append laid over it. A piece of a tile already closed changes
    /// nothing, and neither does a body that fails `check`. One chunk per
    /// tile, oldest first; a trailing tile stays partial, its etag that of
    /// the data as laid, never one to offer as held.
    public static func lay(_ bodies: [Tiles]) -> [HistChunk] {
        var byID = [String: HistChunk]()
        for t in bodies {
            guard (try? t.check()) != nil else { continue }
            var held = byID[t.tileId]
            if let h = held, !h.partial { continue }
            guard t.partial else {
                byID[t.tileId] = t.chunk
                continue
            }
            let per = tilePoints
            if held == nil || t.whole || held?.series != t.series {
                held = HistChunk(tileId: t.tileId, etag: "", res: .fiveMinutes, startMs: Double(t.tileStart), stepMs: Double(t.stepMs),
                                 series: t.series, data: missing(t.series.count * per), partial: true)
            }
            guard var c = held else { continue }
            let n = t.points
            let at = Int((t.startMs - t.tileStart) / t.stepMs)
            for s in t.series.indices {
                c.data.replaceSubrange((s * per + at) * 4..<(s * per + at + n) * 4, with: t.data[(s * n * 4)..<((s + 1) * n * 4)])
            }
            byID[t.tileId] = c
        }
        return byID.values.map { c -> HistChunk in
            var c = c
            if c.partial { c.etag = HistoryGeometry.etag(c.data) }
            return c
        }.sorted { $0.startMs < $1.startMs }
    }

    /// `n` samples of `missingSample`.
    private static func missing(_ n: Int) -> Bytes {
        let u = UInt32(bitPattern: missingSample)
        return Bytes((0..<n).flatMap { _ in [UInt8(u & 0xff), UInt8(u >> 8 & 0xff), UInt8(u >> 16 & 0xff), UInt8(u >> 24)] })
    }
}

extension CloudWire.Tiles {
    public init(body: Bytes) throws {
        let f = try CloudWire.Fields(body: body)
        self.init(
            header: try CloudWire.Header(f),
            tileId: try f.text("tileId"),
            etag: try f.text("etag"),
            res: try f.text("res"),
            startMs: try f.int("startMs"),
            stepMs: try f.int("stepMs"),
            series: try CloudWire.texts(f["series"], "series"),
            data: try f.bytes("data"),
            partial: try f.bool("partial")
        )
    }
}

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
    /// tile; a whole piece every piece the box sent before it. A body held
    /// already (a forwarded append that came again in an answer) changes
    /// nothing.
    mutating func take(_ t: CloudWire.Tiles, nowMs: Int64) {
        bodies.removeAll { $0.tileEnd <= nowMs - CloudWire.tileKeepMs }
        guard t.tileEnd > nowMs - CloudWire.tileKeepMs else { return }
        if bodies.contains(where: { $0.header.boot == t.header.boot && $0.header.seq == t.header.seq }) { return }
        if bodies.contains(where: { $0.tileId == t.tileId && !$0.partial }) { return }
        if !t.partial {
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
