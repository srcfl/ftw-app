import Foundation
import FTWShared

/// The car record the widgets and the watch read, built once from the
/// chargers and, on a box that keeps cars, the cars: each charger with the
/// level of the car on it, the owner's cars with their last levels whether
/// or not they are plugged in, and the chargers that ask which car this is.
@MainActor
enum CarShare {
    static func entry(_ points: [Loadpoint], answeredAtMs: Double, level: (Loadpoint) -> Double?, cars: CarsModel?) -> CarEntry {
        let keeps = cars?.keepsCars == true
        let chargers = points.map { lp -> CarEntry.Car in
            var c = CarEntry.Car(
                loadpointID: lp.id,
                pluggedIn: lp.pluggedIn,
                socPct: level(lp) ?? lp.socPct,
                socSource: lp.socSource,
                socReadAtMs: lp.socReadAtMs(answeredAtMs: answeredAtMs),
                powerW: lp.powerW,
                targetSocPct: lp.targetSocPct,
                holding: LoadpointsModel.holding(lp)
            )
            if keeps, let cars, let car = cars.car(on: lp) {
                c.carID = car.id
                c.carName = car.shownName
                let l = cars.level(car)
                c.socPct = l?.pct
                c.socSource = l?.legacySource ?? ""
                c.socReadAtMs = l?.atMs
                c.targetSocPct = car.goal.map { (Double($0.targetPermille) / 10).rounded() } ?? c.targetSocPct
            }
            return c
        }
        guard keeps, let cars else { return CarEntry(cars: chargers) }
        let owned = cars.ordered.map { car -> CarEntry.Owned in
            let l = cars.level(car)
            return CarEntry.Owned(id: car.id, name: car.shownName, socPct: l?.pct, socSource: l?.legacySource ?? "", socReadAtMs: l?.atMs,
                                  socEstimate: l?.estimate ?? false, targetSocPct: car.goal.map { (Double($0.targetPermille) / 10).rounded() },
                                  loadpointID: cars.charger(of: car)?.id)
        }
        let asking = cars.asking.map { lp in
            CarEntry.Asking(loadpointID: lp.id, session: lp.chargerCar?.session ?? "", choices: cars.choices(lp).map { .init(id: $0.id, name: $0.shownName) })
        }
        return CarEntry(cars: chargers, owned: owned, asking: asking)
    }
}
