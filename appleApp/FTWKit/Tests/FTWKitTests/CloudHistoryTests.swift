import Foundation
import Testing
@testable import FTWKit
@testable import FTWDemo

/// The history while the box cannot answer: FTW Cloud's tiles, signed by the
/// box and dated, and the box's own answer the moment it comes back.
@MainActor
@Suite struct CloudHistoryTests {
    static let span: Int64 = 43_200_000
    static let step: Int64 = 300_000
    static let utc = TimeZone(identifier: "UTC")!

    /// A tile of the box's four series as the box signs it: points
    /// [first, first + count) of the tile that starts at `start`, each a
    /// value below `filled` and missing from there. Series s, point i holds
    /// `base` × (s + 1) + i.
    static func tile(_ w: CloudSite, start: Int64, first: Int = 0, count: Int = 144, filled: Int = 144,
                     closed: Bool = false, base: Int32 = 100, etag: String? = nil) throws -> CloudWire.Envelope {
        let data = HistoryGeometry.pack((0..<4).map { s in
            (first..<(first + count)).map { i in i < filled ? base * Int32(s + 1) + Int32(i) : missingSample }
        })
        let h = w.box.header(w.at)
        return try w.box.seal(CloudWire.msgTiles, h + [
            ("tileId", .text(HistoryGeometry.tileID(.fiveMinutes, stride: 1, startMs: Double(start)))),
            ("etag", .text(etag ?? HistoryGeometry.etag(data))), ("res", .text("5m")),
            ("startMs", .int(start + Int64(first) * step)), ("stepMs", .int(step)),
            ("series", .array(CloudWire.tileSeries.map { .text($0) })), ("data", .bytes(data)), ("partial", .bool(!closed)),
        ])
    }

    /// The box's own tile over Noise, for when it answers again.
    static func boxTile(start: Int64, filled: Int, closed: Bool, base: Int32) -> HistChunk {
        let data = HistoryGeometry.pack((0..<4).map { s in (0..<144).map { i in i < filled ? base * Int32(s + 1) + Int32(i) : missingSample } })
        return HistChunk(tileId: HistoryGeometry.tileID(.fiveMinutes, stride: 1, startMs: Double(start)), etag: HistoryGeometry.etag(data), res: .fiveMinutes,
                         startMs: Double(start), stepMs: Double(step), series: CloudWire.tileSeries, data: data, partial: !closed)
    }

    /// A home whose box is away: the phone knows its key from an earlier
    /// launch, and FTW Cloud holds yesterday's closed tile, today's tile
    /// whole up to 30 buckets and an append of six more.
    static func awayBox() throws -> (CloudSite, HistoryModel, Int64) {
        let w = try CloudSite()
        w.keepFromEarlierLaunch(gridW: nil)
        let start = w.at / span * span
        w.service.tiles = [
            try tile(w, start: start - span, closed: true),
            try tile(w, start: start, filled: 30),
            try tile(w, start: start, first: 30, count: 6),
        ]
        w.open()
        let history = HistoryModel(site: w.site)
        w.connectCloud()
        return (w, history, start)
    }

    @Test func aBoxAwayDrawsFTWCloudsTilesDated() async throws {
        let (w, history, start) = try Self.awayBox()
        await w.run(100)

        let asked = try #require(w.service.received.first { $0.t == CloudWire.msgTilesGet })
        #expect(try decodeCBOR(asked.b)["have"]?.entries?.isEmpty == true)
        #expect(history.fromCloud)
        #expect(w.relay.sent.isEmpty, "nothing went to a box that is not there")

        // Yesterday's tile and the six buckets appended to today's.
        let grid = history.samples(.grid, fromMs: Double(start - Self.span))
        #expect(grid.first?.watts == 100)
        let today = grid.filter { $0.startMs >= Double(start) }
        #expect(today[35].watts == 135)
        // FTW Cloud has answered: what it lacks is not on its way. Nor is
        // the time after the copy ends a hole the box confirmed: it is left
        // out, so the sum counts nothing as not recorded.
        #expect(!grid.contains { $0.fetching })
        #expect(today.count == 36)
        #expect(EnergyToday.sum(today, fromMs: Double(start)).missingMs == 0)

        // Dated where the copy ends, never as now.
        let upTo = Double(start + 36 * Self.step)
        #expect(history.cloudUpToMs == upTo)
        let note = try #require(history.cloudNote(nowMs: w.scheduler.nowMs, zone: Self.utc))
        #expect(note == "From FTW Cloud · up to \(AppWords.clock(upTo, zone: Self.utc))")
        #expect(!note.lowercased().contains("live"))
        #expect(!note.lowercased().contains("now"))

        // A closed tile from the copy is the box's bytes: it goes into the
        // same file the box's tiles do, and is offered as held next time.
        #expect(history.file?.tiles.contains { $0.tileId == HistoryGeometry.tileID(.fiveMinutes, stride: 1, startMs: Double(start - Self.span)) && !$0.partial } == true)

        // The box sends the next bucket as it closes; FTW Cloud forwards it.
        w.service.push(try Self.tile(w, start: start, first: 36, count: 1))
        await w.run(50)
        #expect(history.cloudUpToMs == Double(start + 37 * Self.step))
        #expect(history.samples(.grid, fromMs: Double(start))[36].watts == 136)
    }

    @Test func theBoxsAnswerReplacesTheCopy() async throws {
        let (w, history, start) = try Self.awayBox()
        await w.run(100)
        #expect(history.fromCloud)

        // The box comes back and answers for itself.
        w.relay.history = [Self.boxTile(start: start - Self.span, filled: 144, closed: true, base: 500),
                           Self.boxTile(start: start, filled: 37, closed: false, base: 500)]
        w.site.connect(w.relay)
        w.relay.open(w.scheduler.nowMs)
        w.relay.helloOk(uptimeMs: w.uptime, cloud: w.identity, caps: [Contract.capCloudLink, Contract.capAPIPassthrough, Contract.capHistory5m])
        w.relay.snap(uptimeMs: w.uptime, gridW: 900)
        await w.run(200)
        #expect(w.relay.sent.contains("hist.query"))
        #expect(!history.fromCloud)
        #expect(history.cloudUpToMs == nil)
        #expect(history.cloudNote(nowMs: w.scheduler.nowMs) == nil)
        #expect(history.samples(.grid, fromMs: Double(start))[36].watts == 536)

        // While the box streams and has answered, the copy adds nothing.
        let before = history.frame
        w.service.push(try Self.tile(w, start: start, first: 37, count: 1, base: 900))
        await w.run(50)
        #expect(history.frame == before)
    }

    @Test func aForgedOrUnsignedTileIsNeverLaid() async throws {
        let w = try CloudSite()
        w.keepFromEarlierLaunch(gridW: nil)
        let start = w.at / Self.span * Self.span
        let real = try Self.tile(w, start: start, filled: 30)
        let other = try Self.tile(w, start: start, filled: 30, base: 999)
        w.service.tiles = [
            // Another tile's body under this tile's signature.
            CloudWire.Envelope(t: CloudWire.msgTiles, b: other.b, sig: real.sig),
            // No signature at all.
            CloudWire.Envelope(t: CloudWire.msgTiles, b: real.b, sig: []),
            // Signed, but not a tile: the etag does not match its data.
            try Self.tile(w, start: start - Self.span, closed: true, etag: "00000000"),
        ]
        w.open()
        let history = HistoryModel(site: w.site)
        w.connectCloud()
        await w.run(100)
        #expect(w.service.received.contains { $0.t == CloudWire.msgTilesGet })
        #expect(w.site.cloudTiles.isEmpty)
        #expect(!history.fromCloud)
        #expect(history.samples(.grid, fromMs: Double(start - Self.span)).allSatisfy { $0.watts == nil })
    }

    @Test func withTheCopyOffNothingIsAsked() async throws {
        let w = try CloudSite()
        // The box linked for its tunnel, the readable copy off: no tables.
        w.files.writeJSON("cloud-s1", CloudCache(identity: CloudIdentity(pk: w.box.pk, boot: w.box.boot), offset: nil))
        w.open()
        let history = HistoryModel(site: w.site)
        w.connectCloud()
        await w.run(100)
        #expect(!w.service.received.contains { $0.t == CloudWire.msgTilesGet })
        #expect(!history.fromCloud)
    }

    /// The demo's picture of a box that goes away (`-FTWDemoBoxAway`) runs
    /// the same path: the box names its key in hello and goes, and FTW
    /// Cloud's signed tiles draw, dated.
    @Test func theDemosAwayBoxDrawsFromTheCopy() async throws {
        final class Parts {
            var cloud: SimulatedCloud?
            var carrier: LoopbackCarrier?
        }
        let parts = Parts()
        let scheduler = ManualScheduler(nowMs: GridTodayShareTests.evening)
        let app = AppModel(store: MemoryStore(), files: nil, shared: nil, passkeys: nil, scheduler: scheduler, build: "test", ua: "test", demo: { s in
            let box = SimulatedBox(scheduler: s)
            DemoCars.one.apply(to: box, nowMs: s.nowMs)
            let cloud = SimulatedCloud(box: box, scheduler: s)
            box.linkedToCloud = true
            box.cloudKey = cloud.pk
            box.answersHistory = false
            parts.cloud = cloud
            let carrier = LoopbackCarrier(box: box, scheduler: s)
            parts.carrier = carrier
            return carrier
        })
        app.startDemo()
        let cloud = try #require(parts.cloud)
        let site = try #require(app.site)
        site.connectDemoCloud(endpoint: cloud.endpoint, makeSocket: cloud.factory)
        let history = try #require(app.home?.nodes.history)
        await GridTodayShareTests().run(scheduler, 3_000)
        #expect(site.cloudCopyOpenSinceMs != nil)
        #expect(!history.fromCloud, "the box still streams")

        cloud.awayAtMs = scheduler.nowMs
        parts.carrier?.drop()
        await GridTodayShareTests().run(scheduler, 1_000)
        #expect(history.fromCloud)
        let upTo = try #require(history.cloudUpToMs)
        #expect(upTo <= cloud.awayAtMs! - 30_000 && upTo > cloud.awayAtMs! - 10 * 60_000)
        #expect(history.samples(.solar, fromMs: GridTodayShareTests.evening - 24 * 3_600_000).contains { $0.watts != nil })
    }

    /// A copy that ends on another day says which.
    @Test func anOlderCopyNamesItsDay() async throws {
        let (w, history, start) = try Self.awayBox()
        await w.run(100)
        let note = try #require(history.cloudNote(nowMs: Double(start) + 3 * 86_400_000, zone: Self.utc))
        #expect(note.hasPrefix("From FTW Cloud · up to "))
        #expect(!note.contains("today"))
        #expect(note.hasSuffix(AppWords.clock(Double(start + 36 * Self.step), zone: Self.utc)))
    }
}
