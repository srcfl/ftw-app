import Foundation

/// A plan in sentences. The box sends reason codes; every word is decided
/// here. A plan is intent, not prophecy, so the copy says what the box means
/// to do and never promises it.
public enum PlanText {
    public enum Action: Equatable, Sendable { case charge, discharge, idle }

    static let reasons: [String: String] = [
        "cheap_import": "Power is cheap",
        "expensive_import": "Power is expensive",
        "solar_surplus": "Spare solar",
        "peak_shaving": "Holding the grid limit",
        "reserve_held": "Keeping a reserve",
        "export_paid": "Sending to the grid",
        "idle": "Nothing scheduled",
    ]

    /// A reason this app has not heard of is still the box's reason.
    public static func reason(_ code: String) -> String {
        reasons[code] ?? code.replacingOccurrences(of: "_", with: " ").capitalized
    }

    public static func action(_ slot: PlanSlot) -> Action {
        if slot.batteryW > 50 { return .charge }
        if slot.batteryW < -50 { return .discharge }
        return .idle
    }

    /// Mode wording is the box's, from its own catalogue, so the dashboard
    /// and this app never give one setting two names.
    public static func label(_ mode: ModeInfo) -> String { mode.label }
    public static func help(_ mode: ModeInfo) -> String { mode.tooltip }

    public struct Headline: Equatable, Sendable {
        public let text: String
        public let slotIndex: Int?
    }

    /// One sentence about what happens next, which is what a plan is for.
    public static func headline(_ plan: Plan?, nowMs: Double) -> Headline {
        guard let plan else { return Headline(text: "No plan yet.", slotIndex: nil) }
        if plan.stale {
            return Headline(text: "Your box couldn't plan ahead just now, so it's running on safe defaults.", slotIndex: nil)
        }
        guard let current = plan.slots.firstIndex(where: { nowMs >= $0.startMs && nowMs < $0.startMs + $0.durationMs }) else {
            return Headline(text: "No plan for right now.", slotIndex: nil)
        }
        let now = plan.slots[current]
        let nowAction = action(now)
        var next = current + 1
        while next < plan.slots.count, action(plan.slots[next]) == nowAction { next += 1 }
        if next >= plan.slots.count {
            return Headline(text: describe(now, later: false), slotIndex: current)
        }
        let change = plan.slots[next]
        return Headline(text: "\(describe(now, later: false)) Then \(describe(change, later: true)) \(inWords(change.startMs - nowMs)).", slotIndex: current)
    }

    public struct Brief: Equatable, Sendable {
        public enum Tone: Sendable { case active, warn, idle }
        public let stateLabel: String
        public let tone: Tone
        public let action: String
        public let time: String?
        public let reason: String?
        public let constraint: String
    }

    /// The box page's overview card: what, until when, why.
    public static func brief(_ plan: Plan?, nowMs: Double, mode: String?, dispatchBlockedBy: [String], clock: (Double) -> String) -> Brief {
        let planner = mode?.hasPrefix("planner_") ?? false
        guard let plan else {
            return Brief(
                stateLabel: mode != nil && !planner ? "Manual" : "Checking…",
                tone: .idle,
                action: planner || mode == nil ? "Reading the current plan" : "Manual control is active",
                time: nil,
                reason: planner || mode == nil ? nil : "Planning is not controlling the battery",
                constraint: constraint(nil, dispatchBlockedBy, nil)
            )
        }
        if plan.stale {
            return Brief(stateLabel: "Fallback active", tone: .warn, action: "Your box couldn't plan ahead just now", time: nil, reason: "It's running on safe defaults", constraint: constraint(plan, dispatchBlockedBy, nil))
        }
        let (label, tone) = state(mode, hasPlan: true)
        guard let current = plan.slots.firstIndex(where: { nowMs >= $0.startMs && nowMs < $0.startMs + $0.durationMs }) else {
            let (l, t) = state(mode, hasPlan: false)
            return Brief(stateLabel: l, tone: t, action: "No plan for right now", time: nil, reason: nil, constraint: constraint(plan, dispatchBlockedBy, nil))
        }
        let now = plan.slots[current]
        let nowAction = action(now)
        var runEnd = current
        while runEnd + 1 < plan.slots.count, action(plan.slots[runEnd + 1]) == nowAction { runEnd += 1 }
        let untilMs = plan.slots[runEnd].startMs + plan.slots[runEnd].durationMs

        var shown = now
        var time: String? = "Now, until \(clock(untilMs))"
        if nowAction == .idle {
            if let future = plan.slots.enumerated().first(where: { $0.offset > current && action($0.element) != .idle })?.element {
                shown = future
                time = "At \(clock(future.startMs))"
            } else {
                time = nil
            }
        }
        return Brief(stateLabel: label, tone: tone, action: actionLabel(shown), time: time, reason: reason(shown.reason), constraint: constraint(plan, dispatchBlockedBy, shown))
    }

    static func state(_ mode: String?, hasPlan: Bool) -> (String, Brief.Tone) {
        if let mode, mode.hasPrefix("planner_") {
            return hasPlan ? ("Plan active", .active) : ("Checking…", .idle)
        }
        if mode != nil { return ("Manual", .idle) }
        return (hasPlan ? "Plan ready" : "Checking…", .idle)
    }

    static func actionLabel(_ slot: PlanSlot) -> String {
        let amount = PowerFormat.text(slot.batteryW)
        switch action(slot) {
        case .idle: return "Keep the battery steady"
        case .charge: return "Charge battery at \(amount)"
        case .discharge: return "Use battery at \(amount)"
        }
    }

    static func constraint(_ plan: Plan?, _ blocked: [String], _ slot: PlanSlot?) -> String {
        if !blocked.isEmpty { return "Control is paused because a meter stopped reporting." }
        if plan?.stale == true { return "The schedule is old, so FTW is using safe live balancing." }
        if let slot, slot.reason == "peak_shaving", let cap = plan?.ceilingW {
            return "Holding the grid limit at \(PowerFormat.text(cap))."
        }
        return "No active safety adjustment."
    }

    static func describe(_ slot: PlanSlot, later: Bool) -> String {
        let amount = PowerFormat.text(slot.batteryW)
        switch action(slot) {
        case .idle:
            return later ? "it rests" : "The battery is resting — \(reason(slot.reason).lowercased())."
        case .charge:
            return later ? "it charges at \(amount)" : "The battery is charging at \(amount) — \(reason(slot.reason).lowercased())."
        case .discharge:
            return later ? "it covers the house at \(amount)" : "The battery is covering the house at \(amount) — \(reason(slot.reason).lowercased())."
        }
    }

    /// Coarse on purpose: a plan is intent that will be revised.
    static func inWords(_ ms: Double) -> String {
        let minutes = Int((ms / 60_000).rounded())
        if minutes < 1 { return "in a moment" }
        if minutes < 25 { return "in \(minutes) min" }
        if minutes < 50 { return "in about half an hour" }
        let hours = Int((Double(minutes) / 60).rounded())
        if hours <= 1 { return "in about an hour" }
        if hours < 10 { return "in about \(hours) hours" }
        return "later today"
    }
}

/// What to call the number on a price, from the box's price-units.js. Every
/// price is minor units per kWh; only the label and the decimals differ.
public enum PriceUnits {
    public struct Unit: Sendable {
        public let label: String
        public let perKwh: String
        public let scale: Double
        public let decimals: Int
    }

    static let units: [String: Unit] = [
        "SEK": Unit(label: "öre", perKwh: "öre/kWh", scale: 1, decimals: 1),
        "NOK": Unit(label: "øre", perKwh: "øre/kWh", scale: 1, decimals: 1),
        "DKK": Unit(label: "øre", perKwh: "øre/kWh", scale: 1, decimals: 1),
        "EUR": Unit(label: "cent", perKwh: "cent/kWh", scale: 1, decimals: 1),
        "PLN": Unit(label: "gr", perKwh: "gr/kWh", scale: 1, decimals: 1),
        "CHF": Unit(label: "Rp.", perKwh: "Rp./kWh", scale: 1, decimals: 1),
        "CZK": Unit(label: "Kč", perKwh: "Kč/kWh", scale: 0.01, decimals: 2),
        "HUF": Unit(label: "Ft", perKwh: "Ft/kWh", scale: 0.01, decimals: 1),
        "RON": Unit(label: "lei", perKwh: "lei/kWh", scale: 0.01, decimals: 2),
    ]

    public static func unit(_ currency: String?) -> Unit {
        let code = (currency ?? "SEK").isEmpty ? "SEK" : (currency ?? "SEK").uppercased()
        return units[code] ?? Unit(label: code, perKwh: "\(code)/kWh", scale: 0.01, decimals: 3)
    }

    public static func display(_ minor: Double, _ currency: String?) -> Double {
        minor * unit(currency).scale
    }

    /// "17.4", in the chart's unit and precision.
    public static func text(_ minor: Double?, _ currency: String?) -> String? {
        guard let minor, minor.isFinite else { return nil }
        return PowerFormat.fixed(display(minor, currency), unit(currency).decimals)
    }

    /// Whether a price window misses hours rather than ending early: a head
    /// that starts after the window asked for, or a hole in the middle.
    public static func hasHole(_ slots: [PriceSlot], fromMs: Double) -> Bool {
        guard let first = slots.first else { return false }
        if first.startMs > fromMs { return true }
        for i in slots.indices.dropFirst() where slots[i - 1].startMs + slots[i - 1].durationMs < slots[i].startMs {
            return true
        }
        return false
    }
}

/// The box's compact savings card, from GET /api/savings/daily.
public enum Savings {
    public struct Day: Equatable, Sendable {
        public let day: String
        public let savedOre: Double
        public let resolution: String
    }

    public struct Period: Equatable, Sendable {
        public let savedMinor: Double
        public let pricedDays: Int
        public let totalDays: Int
        public var available: Bool { pricedDays > 0 }
        public var complete: Bool { totalDays > 0 && pricedDays == totalDays }
    }

    public struct Periods: Equatable, Sendable {
        public let today: Period
        public let week: Period
        public let month: Period
    }

    public static func day(_ row: JSON) -> Day? {
        guard let d = row["day"]?.string, d.count == 10, d.dropFirst(4).first == "-" else { return nil }
        return Day(day: d, savedOre: row["saved_ore"]?.number ?? 0, resolution: row["resolution"]?.string ?? "slot")
    }

    static func summarize(_ rows: [Day]) -> Period {
        let priced = rows.filter { $0.resolution != "no_prices" }
        return Period(savedMinor: priced.reduce(0) { $0 + $1.savedOre }, pricedDays: priced.count, totalDays: rows.count)
    }

    public static func periods(_ days: [Day]) -> Periods {
        let rows = days.sorted { $0.day < $1.day }
        let month = rows.last.map { String($0.day.prefix(7)) } ?? ""
        return Periods(
            today: summarize(Array(rows.suffix(1))),
            week: summarize(Array(rows.suffix(7))),
            month: summarize(month.isEmpty ? [] : rows.filter { $0.day.hasPrefix(month + "-") })
        )
    }

    /// Signed major units: "+12.4", "−3.10". The currency sits in the heading.
    public static func compact(_ minor: Double) -> String {
        let major = minor / 100
        let a = abs(major)
        let digits = a >= 100 ? 0 : a >= 10 ? 1 : 2
        return (major >= 0 ? "+" : "−") + PowerFormat.fixed(a, digits)
    }
}

/// Sentences for a command's fate. One table for every op: the codes are
/// about the door, not about what was asked.
public enum CommandText {
    public static func help(_ r: CmdResult) -> String {
        switch r.errorCode {
        case "E_PRECONDITION": return "Your home changed while that was sending. Have another go."
        case "E_CONFLICT": return "Something else changed the setting first. Try again."
        case "E_SCOPE_DENIED": return "You don't have permission to change how this home runs."
        case "E_CMD_EXPIRED": return "That took too long to reach your box. Try again."
        case "E_BOOTING": return "Your box is still starting. Give it a minute."
        case "E_UNAVAILABLE":
            if r.errorArgs["op"]?.string == Contract.opLoadpointSurplusOnlySet { return "Solar rule not saved. Your previous choice is unchanged. Try again." }
            return "Your box can't reach the charger right now. Try again shortly."
        default: return "That didn't go through. Try again."
        }
    }

    /// The boost's own refusals before the door's.
    public static func boostHelp(_ r: CmdResult) -> String {
        if r.errorCode == "E_UNAVAILABLE", r.errorArgs["op"]?.string != nil {
            return "Your box won't boost right now — the house battery or the site isn't ready for it."
        }
        if r.errorCode == "E_UNKNOWN_OP", r.errorArgs["arg"]?.string == "lease" {
            return "Your box refused that reserve and time. Try other values."
        }
        return help(r)
    }

    /// A level for a car that is not on the cable is refused by name.
    public static func socHelp(_ r: CmdResult) -> String {
        if r.errorCode == "E_UNAVAILABLE", r.errorArgs["reason"]?.string == "unplugged" {
            return "Plug the car in first — your box has no car to set a level for."
        }
        return help(r)
    }
}
