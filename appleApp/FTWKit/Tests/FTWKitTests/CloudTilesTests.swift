import Foundation
import Testing
@testable import FTWKit

/// srcfl/ftw `go/protocol/cloudwire/testdata/cloud-tile-vectors.json`,
/// copied unchanged: one tile of each shape signed by the vectors' box key,
/// a forged one, how pieces lay back together, and the bodies of
/// `tiles.get` and `tiles.end`.
struct CloudTileVectors: Decodable {
    struct Tile: Decodable {
        let name: String
        let tileId: String
        let etag: String
        let startMs: Int64
        let points: Int
        let partial: Bool
        let seq: UInt64
        let body: String
        let sig: String
        let envelope: String
        let frame: String
    }

    struct Laid: Decodable {
        let of: [String]
        let tileId: String
        let etag: String
        let startMs: Int64
        let partial: Bool
        let data: String
    }

    struct Exchange: Decodable {
        let body: String
        let envelope: String
    }

    let boxKey: CloudVectors.Key
    let series: [String]
    let tiles: [Tile]
    let forged: Tile
    let laid: [Laid]
    let tilesGet: Exchange
    let tilesEnd: Exchange
    let have: [String: [String]]

    static func load() throws -> CloudTileVectors {
        guard let url = Bundle.module.url(forResource: "cloud-tile-vectors", withExtension: "json", subdirectory: "Resources") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(CloudTileVectors.self, from: Data(contentsOf: url))
    }

    func envelope(_ t: Tile) throws -> CloudWire.Envelope { try CloudWire.Envelope.decode(Bytes(hex: t.envelope)) }

    func body(_ name: String) throws -> CloudWire.Tiles {
        let t = try #require(tiles.first { $0.name == name })
        return try CloudWire.Tiles(body: Bytes(hex: t.body))
    }
}

@Suite struct CloudTilesTests {
    @Test func everyShapeVerifiesDecodesAndChecks() throws {
        let v = try CloudTileVectors.load()
        let pk = Bytes(hex: v.boxKey.pk)
        let home = try #require(v.boxKey.home)
        #expect(CloudWire.homeID(pk: pk) == home)
        #expect(v.series == CloudWire.tileSeries)
        for t in v.tiles {
            let env = try v.envelope(t)
            #expect(try CloudWire.decodeFrame(Bytes(hex: t.frame)) == Bytes(hex: t.envelope), "\(t.name)")
            #expect(env.t == CloudWire.msgTiles)
            #expect(CloudWire.verify(boxKey: pk, home: home, envelope: env), "\(t.name)")
            let body = try CloudWire.Tiles(body: env.b)
            try body.check()
            #expect(body.tileId == t.tileId && body.etag == t.etag && body.startMs == t.startMs)
            #expect(body.points == t.points && body.partial == t.partial && body.header.seq == t.seq)
        }
    }

    @Test func aForgedTileDoesNotVerify() throws {
        let v = try CloudTileVectors.load()
        let env = try v.envelope(v.forged)
        #expect(!CloudWire.verify(boxKey: Bytes(hex: v.boxKey.pk), home: try #require(v.boxKey.home), envelope: env))
        // An unsigned copy of a real tile fails too.
        var bare = try v.envelope(v.tiles[0])
        bare.sig = []
        #expect(!CloudWire.verify(boxKey: Bytes(hex: v.boxKey.pk), home: try #require(v.boxKey.home), envelope: bare))
    }

    @Test func layMatchesGoForEveryCase() throws {
        let v = try CloudTileVectors.load()
        var cases: [[String]: [CloudTileVectors.Laid]] = [:]
        for l in v.laid { cases[l.of, default: []].append(l) }
        #expect(cases.count == 5)
        for (of, want) in cases {
            let got = CloudWire.lay(try of.map { try v.body($0) })
            #expect(got.count == want.count, "\(of)")
            for (g, w) in zip(got, want) {
                #expect(g.tileId == w.tileId && g.etag == w.etag && g.partial == w.partial && Int64(g.startMs) == w.startMs, "\(of)")
                #expect(g.data == Bytes(hex: w.data), "\(of) \(w.tileId)")
            }
        }
    }

    @Test func tilesGetAndTilesEndAreGosBytes() throws {
        let v = try CloudTileVectors.load()
        let closed = try v.body("closed")
        let env = CloudWire.encodeUnsigned(t: CloudWire.msgTilesGet, body: CloudWire.tilesGet(have: [closed.tileId: closed.etag]))
        #expect(env == Bytes(hex: v.tilesGet.envelope))
        let end = try CloudWire.Envelope.decode(Bytes(hex: v.tilesEnd.envelope))
        #expect(end.t == CloudWire.msgTilesEnd)
        #expect(try decodeCBOR(end.b)["n"]?.int == 3)
    }

    @Test func checkRefusesWhatIsNotATile() throws {
        let v = try CloudTileVectors.load()
        let good = try v.body("append 17:00")
        let cases: [String: (inout CloudWire.Tiles) -> Void] = [
            "etag": { $0.etag = "00000000" },
            "hourly": { $0.res = "1h" },
            "step": { $0.stepMs = 600_000 },
            "off the grid": { $0.startMs += 1 },
            "another tile's id": { $0.tileId = HistoryGeometry.tileID(.fiveMinutes, stride: 1, startMs: Double($0.tileStart - 43_200_000)) },
            "stride 2": { $0.tileId = HistoryGeometry.tileID(.fiveMinutes, stride: 2, startMs: Double($0.tileStart)) },
            "no series": { $0.series = [] },
            "twice a series": { $0.series = ["grid_w", "grid_w", "pv_w", "load_w"] },
            "closed but a piece": { $0.partial = false },
            "half a column": { t in
                t.data.removeLast(2)
                t.etag = HistoryGeometry.etag(t.data)
            },
            "past the tile": { t in
                t.startMs = t.tileStart + 143 * 300_000
                t.data += t.data
                t.etag = HistoryGeometry.etag(t.data)
            },
        ]
        for (name, mutate) in cases {
            var t = good
            mutate(&t)
            #expect(throws: CloudWire.WireError.self, "\(name)") { try t.check() }
        }
    }

    /// The store keeps what the box sent in its order: a body that came
    /// twice once, a whole piece over the pieces before it, a closed tile
    /// over every piece of it.
    @Test func theStoreKeepsTheBoxsOrder() throws {
        let v = try CloudTileVectors.load()
        let closed = try v.body("closed"), whole = try v.body("whole")
        let a1 = try v.body("append 17:00"), a2 = try v.body("append 17:05")
        let now = whole.tileStart + 6 * 3_600_000
        let want = CloudWire.lay([closed, whole, a1, a2])

        // A forwarded append that arrived before the answer, and the
        // answer, which carries it again.
        var s = CloudTileStore()
        for t in [a2, whole, a1, a2, closed] { s.take(t, nowMs: now) }
        #expect(s.laid == want)
        #expect(s.bodies.count == 4)

        // A whole piece sent later drops the pieces before it.
        var later = whole
        later.header.seq = 99
        later.header.wallMs = (a2.header.wallMs ?? 0) + 1
        s.take(later, nowMs: now)
        #expect(s.bodies.filter { $0.tileId == whole.tileId }.count == 1)

        // Two days on, both tiles have gone, and neither comes back.
        s.take(later, nowMs: whole.tileEnd + CloudWire.tileKeepMs)
        #expect(s.isEmpty)
    }
}
