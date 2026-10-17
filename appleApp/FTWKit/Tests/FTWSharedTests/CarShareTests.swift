import Foundation
import Testing
@testable import FTWShared

/// The car outside the app, on a box that keeps cars: the notification's
/// "Which car?" buttons, the watch's car page and the record both read.
@Suite struct CarShareTests {
    static let tesla = "6f1d2a3b4c5d6e7f8091a2b3c4d5e6f7"
    static let zoe = "0a1b2c3d4e5f60718293a4b5c6d7e8f9"
    static let cars = [CloudHome.Car(opaque: "oT", id: tesla, name: "Model Y"), CloudHome.Car(opaque: "oZ", id: zoe, name: "Zoe")]
    static let home = CloudHome(home: "h", siteId: "s1", boxKey: Data(), loadpoints: ["oL": "easee"], cars: cars)

    static func which(_ cars: [String], session: String = "s9") -> PushAlert {
        PushAlert(.event, home: "h", kind: PushKind.carWhich, args: ["session": session], lp: "oL", cars: cars, seq: 1, atMs: 1)
    }

    @Test func eachSetOfTheOwnersCarsHasItsButtons() {
        let sets = PushActions.carCategories(Self.cars)
        #expect(sets.map(\.id) == ["ftw.car.which.1", "ftw.car.which.2", "ftw.car.which.3"])
        #expect(sets[2].cars.map(\.name) == ["Model Y", "Zoe"])
        // More cars than the sets can cover: no buttons, the tap opens FTW.
        let many = (0..<7).map { CloudHome.Car(opaque: "o\($0)", id: String(repeating: "\($0)", count: 32), name: "Car \($0)") }
        #expect(PushActions.carCategories(many).isEmpty)
        // At most four buttons a set.
        let six = Array(many.prefix(6))
        #expect(PushActions.carCategories(six).allSatisfy { $0.cars.count <= 4 })
        #expect(PushActions.carCategories(six).count == 56)
    }

    @Test func aVerifiedCarWhichGetsTheSetItOffers() {
        let alert = Self.which(["oZ", "oT"])
        #expect(PushActions.carCategory(for: alert, home: Self.home) == "ftw.car.which.3")
        #expect(PushActions.carCategory(for: Self.which(["oZ"]), home: Self.home) == "ftw.car.which.2")
        // A car this phone does not know, or no table: no buttons.
        #expect(PushActions.carCategory(for: Self.which(["oX"]), home: Self.home) == nil)
        #expect(PushActions.carCategory(for: alert, home: CloudHome(home: "h", siteId: "s1", boxKey: Data())) == nil)
        // Only a verified event gets buttons.
        #expect(PushActions.carCategory(for: PushAlert(.generic, home: "h", kind: PushKind.carWhich, cars: ["oT"]), home: Self.home) == nil)

        let notice = PushNotice(alert, home: Self.home, language: .en)
        #expect(notice.category == "ftw.car.which.3")
        #expect(notice.verified["session"] == "s9")
        #expect(notice.verified["loadpointID"] == "easee")
        #expect(notice.title == "Which car is plugged in?")
    }

    @Test func aButtonNamesOneOfTheCarsTheEventOffered() {
        #expect(PushActions.carChoice(PushActions.carAction(Self.tesla)) == Self.tesla)
        #expect(PushActions.carChoice(PushActions.carAction(nil)) == "")
        #expect(PushActions.carChoice(PushActions.Action.level20.rawValue) == nil)
        #expect(PushActions.carChoice("ftw.car.NOTANID") == nil)
        let alert = Self.which(["oT"])
        #expect(PushActions.allowsCar(Self.tesla, for: alert, home: Self.home))
        #expect(PushActions.allowsCar("", for: alert, home: Self.home))
        // Zoe was not offered.
        #expect(!PushActions.allowsCar(Self.zoe, for: alert, home: Self.home))
        // A car's button never runs for another kind.
        let other = PushAlert(.event, home: "h", kind: PushKind.chargingConnected, lp: "oL", cars: ["oT"])
        #expect(!PushActions.allowsCar(Self.tesla, for: other, home: Self.home))
    }

    @Test func theWatchShowsTheCarWithTheCableOutAndHowOldItsLevelIs() {
        let t: Double = 1_791_799_200_000
        let entry = CarEntry(
            cars: [CarEntry.Car(loadpointID: "easee", pluggedIn: false, socPct: nil, socSource: "", socReadAtMs: nil, powerW: 0, targetSocPct: nil, holding: false)],
            owned: [CarEntry.Owned(id: Self.tesla, name: "Model Y", socPct: 72, source: "vehicle", socReadAtMs: t - 67 * 60_000, socEstimate: false, targetSocPct: 80, loadpointID: nil)],
            asking: []
        )
        let record = CacheRecord(siteId: "s1", carrier: .relay, srcState: .live, readAtMs: t, value: entry)
        let car = WatchGlance.cars(record, plan: nil, nowMs: t, zone: .current)[0]
        #expect(car.name == "Model Y")
        #expect(car.levelText == "72\u{00A0}%")
        #expect(car.origin == "from the car · 1 h ago")
        #expect(car.state == "Not plugged in")
        #expect(!car.pluggedIn)
        #expect(car.loadpointID.isEmpty)
        #expect(car.goal == "Goal 80\u{00A0}%")
        #expect(WatchGlance.asking(record).isEmpty)

        var asked = entry
        asked.asking = [CarEntry.Asking(loadpointID: "easee", session: "s9", choices: [.init(id: Self.tesla, name: "Model Y"), .init(id: Self.zoe, name: "Zoe")])]
        let ask = WatchGlance.asking(CacheRecord(siteId: "s1", carrier: .relay, srcState: .live, readAtMs: t, value: asked))
        #expect(ask.map(\.loadpointID) == ["easee"])
        #expect(ask.first?.choices.map(\.name) == ["Model Y", "Zoe"])
    }

    /// The car's own estimate stays the car's: an estimate from the car is
    /// "≈" and "from the car", never "set by hand".
    @Test func theWatchKeepsAnEstimateFromTheCarTheCars() {
        let t: Double = 1_791_799_200_000
        func glance(_ source: String, estimate: Bool) -> WatchGlance.Car {
            let entry = CarEntry(cars: [], owned: [CarEntry.Owned(id: Self.tesla, name: "Model Y", socPct: 75, source: source, socReadAtMs: t - 3_600_000, socEstimate: estimate, targetSocPct: nil, loadpointID: nil)], asking: [])
            return WatchGlance.cars(CacheRecord(siteId: "s1", carrier: .relay, srcState: .live, readAtMs: t, value: entry), plan: nil, nowMs: t, zone: .current)[0]
        }
        let estimate = glance("vehicle", estimate: true)
        #expect(estimate.levelText == "≈ 75\u{00A0}%")
        #expect(estimate.origin == "from the car · 1 h ago")
        #expect(glance("manual", estimate: false).origin == "set by hand · 1 h ago")
        #expect(glance("manual", estimate: false).levelText == "75\u{00A0}%")
        #expect(glance("assumed", estimate: true).origin == "assumed at plug-in")
    }

    /// Until the list is read, and for a car the box cannot name, the
    /// watch keeps the chargers: a visitor's car still gets Charge now.
    @Test func theWatchKeepsAChargerWithNoNamedCar() {
        let t: Double = 1_791_799_200_000
        let visitor = CarEntry.Car(loadpointID: "easee", pluggedIn: true, socPct: nil, socSource: "unknown", socReadAtMs: nil, powerW: 7_000, targetSocPct: nil, holding: false)
        func record(_ entry: CarEntry) -> CacheRecord<CarEntry> { CacheRecord(siteId: "s1", carrier: .relay, srcState: .live, readAtMs: t, value: entry) }
        let unread = WatchGlance.cars(record(CarEntry(cars: [visitor], owned: [], asking: [])), plan: nil, nowMs: t, zone: .current)
        #expect(unread.map(\.loadpointID) == ["easee"])
        #expect(unread.first?.state.hasPrefix("Charging") == true)
        #expect(unread.first?.levelText == nil)
        let away = CarEntry.Owned(id: Self.tesla, name: "Model Y", socPct: 72, source: "vehicle", socReadAtMs: t, socEstimate: false, targetSocPct: nil, loadpointID: nil)
        let both = WatchGlance.cars(record(CarEntry(cars: [visitor], owned: [away], asking: [])), plan: nil, nowMs: t, zone: .current)
        #expect(both.map(\.id) == [Self.tesla, "easee"])
        #expect(both.first(where: \.pluggedIn)?.loadpointID == "easee")
        // A charger whose car is named is the car's row, not a second one.
        var named = visitor
        named.carID = Self.tesla
        let on = CarEntry.Owned(id: Self.tesla, name: "Model Y", socPct: 72, source: "vehicle", socReadAtMs: t, socEstimate: false, targetSocPct: nil, loadpointID: "easee")
        #expect(WatchGlance.cars(record(CarEntry(cars: [named], owned: [on], asking: [])), plan: nil, nowMs: t, zone: .current).count == 1)
    }

    /// A question the phone did not read live says when it did.
    @Test func theWatchDatesAnOldQuestion() {
        let t: Double = 1_791_799_200_000
        let entry = CarEntry(cars: [], owned: nil, asking: [CarEntry.Asking(loadpointID: "easee", session: "s9", choices: [.init(id: Self.tesla, name: "Model Y")])])
        let old = WatchGlance.asking(CacheRecord(siteId: "s1", carrier: .cache, srcState: .stale, readAtMs: t, value: entry), zone: TimeZone(identifier: "UTC")!)
        #expect(old.first?.live == false)
        #expect(old.first?.asOf.hasPrefix("AS OF") == true)
        #expect(WatchGlance.asking(CacheRecord(siteId: "s1", carrier: .relay, srcState: .live, readAtMs: t, value: entry)).first?.live == true)
    }

    /// At launch the buttons come from the row written last.
    @Test func theButtonsAtLaunchComeFromTheLastRow() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("carkeys-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = CloudKeys(directory: dir)
        #expect(keys.lastCars().isEmpty)
        let key = Data([0x04] + [UInt8](repeating: 1, count: 64))
        try keys.write(CloudHome(home: "aaaaaaaaaaaaaaaaaaaaaaaaaa", siteId: "s1", boxKey: key, cars: Self.cars))
        #expect(keys.lastCars() == Self.cars)
        try keys.write(CloudHome(home: "bbbbbbbbbbbbbbbbbbbbbbbbbb", siteId: "s2", boxKey: key))
        #expect(keys.lastCars() == Self.cars)
    }

    /// A record an older build left, before cars, still reads, as the
    /// charger's own.
    @Test func aRecordFromBeforeCarsStillReads() throws {
        let json = #"{"cars":[{"loadpointID":"garage","pluggedIn":true,"socPct":42,"socSource":"assumed","powerW":0}]}"#
        let old = try JSONDecoder().decode(CarEntry.self, from: Data(json.utf8))
        #expect(old.owned == nil && old.asking == nil)
        #expect(old.cars.first?.carID == nil)
        let home = try JSONDecoder().decode(CloudHome.self, from: JSONEncoder().encode(CloudHome(home: "h", siteId: "s1", boxKey: Data())))
        #expect(home.cars == nil)
    }
}
