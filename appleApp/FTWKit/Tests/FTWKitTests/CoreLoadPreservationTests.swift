import Foundation
import Testing
@testable import FTWKit

@MainActor
@Suite struct CoreLoadPreservationTests {
    typealias F = Contract.FID

    @Test func chargerDisplayKeepsTheCoreLoadUnchangedOrAbsent() {
        for load: Double? in [nil, 0, 25.75, 9_000, -20] {
            for wireEV: Double? in [nil, 0, 7_400] {
                var original = [F.gridW: 3_700.0, F.pvW: -1_200]
                original[F.loadW] = load
                original[F.evW] = wireEV
                let shown = Flow.withLoadpointEV(original, evW: 7_400)
                #expect(shown[F.loadW] == load)
                #expect(shown[F.evW] == 7_400)
                #expect(shown[F.gridW] == original[F.gridW])
                #expect(shown[F.pvW] == original[F.pvW])
            }
        }
    }

    @Test func bothInputFormatsKeepUnknownDistinctFromARecordedZero() throws {
        let missingStream: Double? = Flow.readings(fields: [:]).loadKw
        let missingStatus: Double? = Flow.readings(status: try JSON(parsing: Array("{}".utf8))).loadKw
        #expect(missingStream == nil)
        #expect(missingStatus == nil)
        let nullStatus: Double? = Flow.readings(status: try JSON(parsing: Array("{\"load_w\":null}".utf8))).loadKw
        #expect(nullStatus == nil)
        #expect(Flow.readings(fields: [F.loadW: 0]).loadKw == 0)
        #expect(Flow.readings(status: try JSON(parsing: Array("{\"load_w\":0}".utf8))).loadKw == 0)
        #expect(Flow.readings(fields: [F.loadW: 1_250]).loadKw == 1.25)
    }

    @Test func aHomeWithNoCoreLoadStillHasAnUnknownReading() throws {
        let readings = NowFlow.readings(fields: [F.gridW: 3_700], freshness: { _ in
            NodeFreshness(carrier: .relay, srcState: .never, ageMs: nil, sourceName: nil)
        })
        let home = try #require(readings.first { $0.node == .home })
        #expect(home.watts == nil)
        #expect(!home.flowing)
        let watch = WatchShare.reading(home)
        #expect(watch.watts == nil)
        #expect(watch.way == .noReading)
        #expect(!watch.live)
    }

    @Test func nowAndWatchKeepCoreZeroAndNeverSubtractTheCharger() throws {
        for load: Double? in [nil, 0, 1_600] {
            var fields = [F.gridW: 9_000.0]
            fields[F.loadW] = load
            fields = Flow.withLoadpointEV(fields, evW: 7_400)
            let readings = NowFlow.readings(fields: fields, freshness: { fid in
                NodeFreshness(carrier: .relay, srcState: fields[fid] == nil ? .never : .live, ageMs: 0, sourceName: nil)
            }, hasCar: true)
            let home = try #require(readings.first { $0.node == .home })
            #expect(home.watts == load)
            let watch = WatchShare.reading(home)
            #expect(watch.watts == load)
            #expect(watch.way == (load == nil ? .noReading : .using))
            #expect(watch.live == (load != nil))
        }
    }
}
