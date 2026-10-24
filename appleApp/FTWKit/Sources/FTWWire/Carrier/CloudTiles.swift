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

    /// The columns the box sends, in this order, and the only ones a tile
    /// may carry: what the history asks the box for, so a closed tile is the
    /// same bytes either way.
    public static let tileSeries = ["grid_w", "pv_w", "battery_w", "load_w"]
    /// How far back the service keeps tiles, and the phone holds them.
    public static let tileKeepMs: Int64 = 48 * 3_600_000
    /// How many pieces of the trailing tile a holder keeps.
    package static let tilePiecesMax = 16
    package static let tileStepMs: Int64 = 300_000
    package static let tileSpanMs: Int64 = 43_200_000
    package static let tilePoints = 144

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
            guard series == CloudWire.tileSeries else { throw bad("series are not tileSeries") }
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
    package static func tilesGet(have: [String: String]) -> CBOR {
        .map([("have", .map(have.sorted { $0.key < $1.key }.map { ($0.key, CBOR.text($0.value)) }))])
    }

    /// Puts tiles back together in the order the box sent them: a closed tile
    /// as it is; the trailing tile from its newest whole piece, with each
    /// later append laid over it; a later closed tile replaces an earlier
    /// one. A piece of a tile already closed changes nothing, and neither
    /// does a body that fails `check`. One chunk per
    /// tile, oldest first; a trailing tile stays partial, its etag that of
    /// the data as laid, never one to offer as held.
    public static func lay(_ bodies: [Tiles]) -> [HistChunk] {
        var byID = [String: HistChunk]()
        for t in bodies {
            guard (try? t.check()) != nil else { continue }
            var held = byID[t.tileId]
            // A piece of a tile already closed. A closed tile sent again,
            // after the box's ledger changed under it, replaces the first.
            if let h = held, !h.partial, t.partial { continue }
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
