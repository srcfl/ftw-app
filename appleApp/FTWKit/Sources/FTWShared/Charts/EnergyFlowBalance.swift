import Foundation

/// Power at the design study's ports. Grid is positive when buying and
/// battery is positive when charging, as in the box's site convention.
public struct EnergyFlowBalance: Sendable {
    public let solar, grid, battery, car, home: Double

    public init(solar: Double, grid: Double, battery: Double, car: Double, home: Double) {
        func finite(_ value: Double) -> Double { value.isFinite ? value : 0 }
        self.solar = max(0, finite(solar))
        self.grid = finite(grid)
        self.battery = finite(battery)
        self.car = max(0, finite(car))
        self.home = max(0, finite(home))
    }

    public var incoming: Double { solar + max(0, grid) + max(0, -battery) }
    public var outgoing: Double { car + home + max(0, battery) + max(0, -grid) }
    public var destinations: [Double] { [car, home, max(0, battery), max(0, -grid)] }
}
