import Foundation
import Testing
@testable import FTWShared

@Suite struct CacheTests {
    let files = AppGroupFiles(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ftw-cache-\(UUID().uuidString)"))

    func prices(_ total: Double = 42) -> PriceEntry {
        PriceEntry(fromMs: 0, prices: Prices(zone: "SE3", currency: "SEK", slots: [PriceSlot(startMs: 0, durationMs: 3_600_000, spotMinor: total, totalMinor: total)], stale: false))
    }

    @Test func aRecordReadsBackAsTheCacheNeverAsLive() throws {
        try files.write(CacheRecord(siteId: "home", carrier: .relay, srcState: .live, readAtMs: 1_000, value: prices()))
        let read = try #require(CacheReader(sources: [files]).read(PriceEntry.self, siteId: "home"))
        #expect(read.value == prices())
        #expect(read.record.carrier == .relay)
        #expect(read.carrier == .cache)
        #expect(read.srcState == .live)
        #expect(read.origin == .app)
        #expect(read.ageMs(nowMs: 61_000) == 60_000)
    }

    @Test func theFilesAreTheNamesTheAppAndWidgetsAgreeOn() throws {
        try files.write(CacheRecord(siteId: "home", carrier: .relay, srcState: .live, readAtMs: 1, value: prices()))
        try files.write(CacheRecord(siteId: "home", carrier: .relay, srcState: .live, readAtMs: 1, value: CarEntry(cars: [])))
        let names = try FileManager.default.contentsOfDirectory(atPath: files.directory.path).sorted()
        #expect(names == ["car-home", "prices-home"])
    }

    @Test func aRecordOfAnotherShapeOrHomeIsNotRead() throws {
        try files.write(CacheRecord(siteId: "home", carrier: .relay, srcState: .live, readAtMs: 1, value: prices()))
        #expect(files.read(PriceEntry.self, siteId: "other") == nil)
        #expect(files.read(CarEntry.self, siteId: "home") == nil)

        // A newer app wrote a version this one does not know.
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: files.url(PriceEntry.name, "home"))) as! [String: Any]
        json["version"] = PriceEntry.version + 1
        try JSONSerialization.data(withJSONObject: json).write(to: files.url(PriceEntry.name, "home"))
        #expect(files.read(PriceEntry.self, siteId: "home") == nil)
    }

    @Test func theNewestHomeIsTheOneTheAppHadOpen() throws {
        try files.write(CacheRecord(siteId: "cabin", carrier: .relay, srcState: .live, readAtMs: 1, value: prices()))
        let past = Date(timeIntervalSinceNow: -3_600)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: files.url(PriceEntry.name, "cabin").path)
        try files.write(CacheRecord(siteId: "home", carrier: .relay, srcState: .live, readAtMs: 2, value: prices()))
        #expect(CacheReader(sources: [files]).latestSiteID(PriceEntry.self) == "home")
        #expect(files.siteIDs(PriceEntry.self) == ["home", "cabin"])
        #expect(files.siteIDs(CarEntry.self).isEmpty)
    }

    /// A second source, such as a sealed copy from a cloud mirror, feeds the
    /// same records. The newest reading wins whichever source holds it.
    @Test func anotherSourceFeedsTheSameRecords() throws {
        struct Mirror: CacheSource {
            let record: CacheRecord<PriceEntry>
            var origin: CacheOrigin { .app }
            func read<Value: CacheValue>(_ type: Value.Type, siteId: String) -> CacheRecord<Value>? {
                record.siteId == siteId ? record as? CacheRecord<Value> : nil
            }
            func siteIDs<Value: CacheValue>(_ type: Value.Type) -> [String] { Value.self == PriceEntry.self ? [record.siteId] : [] }
        }
        try files.write(CacheRecord(siteId: "home", carrier: .relay, srcState: .live, readAtMs: 1_000, value: prices(10)))
        let newer = Mirror(record: CacheRecord(siteId: "home", carrier: .relay, srcState: .stale, readAtMs: 2_000, value: prices(20)))
        let older = Mirror(record: CacheRecord(siteId: "home", carrier: .relay, srcState: .live, readAtMs: 500, value: prices(30)))
        #expect(CacheReader(sources: [files, newer]).read(PriceEntry.self, siteId: "home")?.value == prices(20))
        #expect(CacheReader(sources: [files, older]).read(PriceEntry.self, siteId: "home")?.value == prices(10))
    }

    @Test func signingOutLeavesWidgetsNothing() throws {
        try files.write(CacheRecord(siteId: "home", carrier: .relay, srcState: .live, readAtMs: 1, value: prices()))
        files.removeAll()
        #expect(files.read(PriceEntry.self, siteId: "home") == nil)
        #expect(files.siteIDs(PriceEntry.self).isEmpty)
    }

    @Test func theSameCarAtAnotherMomentIsTheSameReading() {
        let car = CarEntry.Car(loadpointID: "garage", pluggedIn: true, socPct: 60, socSource: "inferred", socReadAtMs: 1, powerW: 7_200, targetSocPct: 80)
        var later = car
        later.socReadAtMs = 2
        #expect(CarEntry(cars: [car]).sameReading(CarEntry(cars: [later])))
        later.socPct = 61
        #expect(!CarEntry(cars: [car]).sameReading(CarEntry(cars: [later])))
    }

    /// No widget can open a file the app could not have written.
    @Test func theAppGroupComesFromTheBundleOrNotAtAll() {
        #expect(AppGroupFiles.shared(bundle: Bundle(for: BundleMarker.self)) == nil)
    }
}

private final class BundleMarker {}
