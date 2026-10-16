import CoreGraphics
import Testing
@testable import FTWShared

@Suite("Site landscape")
struct EnergySiteLayoutTests {
    let size = CGSize(width: 402, height: 610)

    @Test func oneGridConnectionReversesWithoutMovingTheBoundary() throws {
        let buying = EnergySiteLayout(size: size, flow: .init(solar: 0, grid: 4, battery: 1, car: 2, home: 1))
        let selling = EnergySiteLayout(size: size, flow: .init(solar: 6, grid: -4, battery: 0, car: 1, home: 1))
        #expect(EnergySiteLayout.Part.allCases.filter { $0 == .grid }.count == 1)
        #expect(buying.center(.grid) == selling.center(.grid))
        let intoSite = buying.stream(.grid), outOfSite = selling.stream(.grid)
        #expect(intoSite.first == outOfSite.last)
        #expect(intoSite.last == buying.junction)
        #expect(outOfSite.first == selling.junction)
        #expect(try #require(outOfSite.last).y > size.height)
    }

    @Test func sunOnlySuppliesAndTheHomeBatteryKeepsItsPlace() {
        let sleepingSun = EnergySiteLayout(size: size, flow: .init(solar: 0, grid: 0, battery: -1.3, car: 0.5, home: 0.8))
        #expect(sleepingSun.stream(.solar).first == sleepingSun.center(.solar))
        #expect(sleepingSun.stream(.solar).last == sleepingSun.junction)
        for power in [-3.0, 0, 2.4] {
            let site = EnergySiteLayout(size: size, flow: .init(solar: 4.2, grid: 0, battery: power, car: 1.6, home: 1.2))
            #expect(site.stream(.solar).first == site.center(.solar))
            #expect(site.stream(.solar).last == site.junction)
            #expect(site.radii(.battery).width >= size.width * 0.30)
            #expect(site.center(.battery) == CGPoint(x: size.width * 0.76, y: size.height * 0.665))
            if power < 0 { #expect(site.stream(.battery).last == site.junction) }
            if power > 0 { #expect(site.stream(.battery).first == site.junction) }
        }
    }

    @Test func morePowerGrowsTheMaterialAndAGripDoesNotChangePower() {
        let slow = EnergySiteLayout(size: size, flow: .init(solar: 2, grid: 0, battery: 0, car: 1, home: 1))
        let fast = EnergySiteLayout(size: size, flow: .init(solar: 5, grid: 0, battery: 0, car: 4, home: 1))
        #expect(fast.radii(.car).width > slow.radii(.car).width)
        #expect(fast.radii(.car).height > slow.radii(.car).height)
        let origin = CGPoint(x: 125, y: 270), finger = CGPoint(x: 240, y: 190)
        let base = fast.contour(.car)
        let pulled = fast.contour(.car, finger: finger, origin: origin, grip: 1)
        #expect(zip(base, pulled).contains { hypot($0.x - $1.x, $0.y - $1.y) > 35 })
        #expect(fast.contour(.car, finger: finger, origin: origin, grip: 0) == base)
        #expect(pulled.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        #expect(fast.signedPower(.car) == 4)
        #expect(fast.flow.incoming == fast.flow.outgoing)
    }

    @Test func movingTheRobotCarriesEveryStreamButKeepsTheGridBoundaryFixed() {
        let site = EnergySiteLayout(size: size, flow: .init(solar: 6, grid: -1, battery: 1, car: 3, home: 1))
        let anchor = CGPoint(x: 290, y: 320)
        for part in EnergySiteLayout.Part.allCases {
            let normal = site.stream(part), moved = site.stream(part, anchor: anchor)
            if site.signedPower(part) < 0 {
                #expect(moved.first == normal.first)
                #expect(moved.last == anchor)
            } else {
                #expect(moved.first == anchor)
                #expect(moved.last == normal.last)
            }
        }
        #expect(site.flow.incoming == site.flow.outgoing)
    }
}
