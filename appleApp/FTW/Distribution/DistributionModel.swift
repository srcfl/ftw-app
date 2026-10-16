#if DEBUG && targetEnvironment(simulator)
import Foundation
import Observation
import FTWShared

enum DistributionScreen: String, Hashable, CaseIterable, Identifiable {
    case now, car, solar, home, battery, grid, plan, prices, history, box
    case connection, access, invite, notifications, recovery, about, licenses, widgets, pair, scan, offer
    var id: String { rawValue }
    var title: String {
        switch self {
        case .now: "Fastigheten"
        case .car: "Bilen"
        case .solar: "Solen"
        case .home: "Hemmet just nu"
        case .battery: "Hembatteriet"
        case .grid: "Elnätet"
        case .plan: "Plan"
        case .prices: "Elpriset"
        case .history: "Historik"
        case .box: "Ditt hem"
        case .connection: "Anslutning"
        case .access: "Åtkomst"
        case .invite: "Bjud in"
        case .notifications: "Notiser"
        case .recovery: "Återställning"
        case .about: "Om FTW"
        case .licenses: "Källkod & licenser"
        case .widgets: "Widgetar"
        case .pair: "Välkommen"
        case .scan: "Anslut din box"
        case .offer: "Bekräfta boxen"
        }
    }
}

enum DistributionScenario: String, CaseIterable, Identifiable {
    case sun, surplus, battery, night, importing, mixed, offline, stale, viewer
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sun: "Solig dag"
        case .surplus: "Stort överskott"
        case .battery: "Batteriet laddas"
        case .night: "Kväll"
        case .importing: "Köper från nätet"
        case .mixed: "Sol och köpt el"
        case .offline: "Tappad kontakt"
        case .stale: "Gamla mätvärden"
        case .viewer: "Endast läsning"
        }
    }
    var powers: [Double]? {
        switch self {
        case .sun: [1.6, 1.2, 1.0, 0.4]
        case .surplus: [1.2, 1, 0, 3.8]
        case .battery: [2, 1.2, 2.4, 0.4]
        case .night: [0.5, 0.8, 0, 0]
        case .importing: [3.2, 1.4, 0, 0]
        case .mixed: [2.5, 1.3, 0, 0]
        default: nil
        }
    }
}

enum DistributionSheet: String, Identifiable { case goal, level, mode, demo, forget; var id: String { rawValue } }
enum DistributionCommand { case goal(Int, Date, String), level(Int), hold(String), mode(String), revoke(UUID) }

/// Local design state. No box, session, vault, Keychain or notification API.
@MainActor @Observable
final class DistributionModel {
    var tab: DistributionScreen = .now
    var scenario = DistributionScenario.sun
    var lastSource = DistributionScenario.sun
    var powers: [Double] = [1.6, 1.2, 1.0, 0.4]
    var sheet: DistributionSheet?
    var goal = 80
    var level = 62
    var readyAt: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 7))!
    }()
    var days = "Vardagar"
    var hold = "plan"
    var mode = "Passiv arbitrage"
    var receipt = ""
    var sending = false
    var happy = false
    var playing = false
    var playbackGeneration = 0
    var feedback = 0
    var moment = 0.0
    var priceHour = 13
    var tomorrow = false
    var historyRange = 0
    var historyPower = false
    var energySeries = 0
    var historyHour = 23.0
    var notifications = false
    var notificationRules = [true, true, true]
    var recovery = false
    var members: [UUID] = [UUID()]
    var invited = false
    var paired = true
    var startScreen: DistributionScreen?
    var visibleScreen = DistributionScreen.now
    var gaze = 0.0
    // One daytime solar arch and two broad load periods in the sample day.
    // Both the graph and its readout use these same cached values.
    let historySolar = (0..<24).map { hour in
        max(0, 4.6 * sin(Double(max(6, min(18, hour)) - 6) / 12 * .pi))
    }
    let historyLoad = (0..<24).map { hour in
        let h = Double(hour)
        return 1.2 + 0.8 * exp(-pow((h - 7) / 3.2, 2)) + 1.4 * exp(-pow((h - 19) / 4.0, 2))
    }
    let prices = [24, 18, 18, 20, 25, 33, 45, 82, 94, 78, 62, 48, 42, 44, 39, 45, 68, 98, 112, 104, 78, 60, 44, 31]
    let modes = ["Passiv arbitrage", "Aktiv arbitrage", "Stoppa batterierna", "Egenanvändning, manuell", "Effektgräns", "Ladda"]
    let modeHelp = ["Ladda från billigaste källa. Sälj inte från batteriet.", "Ladda billigt. Batteriet kan också sälja el.", "Håll batterierna vid 0 W. Säkringsskyddet gäller ändå.", "Följ hemmets behov utan prisplan.", "Begränsa köpt effekt till hemmets gräns.", "Ladda batterierna oavsett elpris."]

    init() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: "FTWDistributionScreen"), let screen = DistributionScreen(rawValue: raw) {
            if [.now, .plan, .history, .box].contains(screen) { tab = screen } else { startScreen = screen }
        }
        if let raw = defaults.string(forKey: "FTWDistributionScenario"), let value = DistributionScenario(rawValue: raw) { choose(value) }
    }

    var canControl: Bool { ![.offline, .stale, .viewer].contains(scenario) }
    var frozen: Bool { scenario == .offline || scenario == .stale }
    private var solarSupply: Double {
        switch lastSource {
        case .sun, .offline, .stale, .viewer: 4.2
        case .surplus, .battery: 6
        case .mixed: 1.4
        case .night, .importing: 0
        }
    }
    private var batterySupply: Double { lastSource == .night ? 1.3 : 0 }
    var flow: EnergyFlowBalance {
        let demand = powers[0] + powers[1] + powers[2]
        return EnergyFlowBalance(solar: solarSupply, grid: demand - solarSupply - batterySupply,
                                 battery: powers[2] - batterySupply, car: powers[0], home: powers[1])
    }
    var total: Double { flow.incoming }
    var clock: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        let c = calendar.dateComponents([.hour, .minute], from: readyAt)
        return String(format: "%02d.%02d", c.hour ?? 7, c.minute ?? 0)
    }
    var freshness: String? {
        switch scenario {
        case .offline: "Kontakt saknas · sparade värden, 2 min gamla"
        case .stale: "Kontakt finns · mätvärdena är 3 min gamla"
        case .viewer: "Läsbehörighet · du kan se men inte styra"
        default: nil
        }
    }

    func choose(_ value: DistributionScenario) {
        stop()
        scenario = value
        if let p = value.powers { powers = p; lastSource = value; hold = "plan" }
    }

    func stop() { playing = false; playbackGeneration += 1 }

    func submit(_ command: DistributionCommand) async {
        guard canControl, !sending else { return }
        sending = true
        receipt = "Skickat · väntar på exempelboxen"
        do {
            try await Task.sleep(for: .milliseconds(550))
            receipt = "Mottaget · väntar på bekräftelse"
            try await Task.sleep(for: .milliseconds(650))
        } catch { sending = false; receipt = "Ingen bekräftelse. Senaste läget är kvar."; return }
        guard canControl else { sending = false; receipt = "Ingen bekräftelse. Senaste läget är kvar."; return }
        switch command {
        case let .goal(value, time, repeatDays): goal = value; readyAt = time; days = repeatDays
        case .level(let value): level = value
        case .hold(let value):
            hold = value
            let base = lastSource.powers ?? powers
            let car = value == "paused" ? 0 : value == "now" ? 3.1 : base[0]
            powers = [car, base[1], base[2], max(0, solarSupply + batterySupply - car - base[1] - base[2])]
        case .mode(let value): mode = value
        case .revoke(let id): members.removeAll { $0 == id }
        }
        receipt = "Bekräftat av exempelboxen"
        sending = false
        sheet = nil
        happy = true
        feedback += 1
        try? await Task.sleep(for: .milliseconds(950))
        happy = false
    }
}
#endif
