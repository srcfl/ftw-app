import Foundation
import FTWShared

/// One device function in Core's answer to "Are we in control?", from
/// `control_feedback` in GET /api/status. Core owns every verdict: status,
/// severity, evidence and reason. Missing numbers stay nil, never zero.
public struct ControlRow: Equatable, Sendable, Identifiable {
    public struct Comparison: Equatable, Sendable {
        public var deviceChangeW: Double?
        public var gridChangeW: Double?
        public var otherChangeW: Double?
        public var unexplainedChangeW: Double?
        public var gridBeforeW: Double?
        public var gridAfterW: Double?
        public var samples: Double?
        public var windowS: Double?
        public var toleranceW: Double?
        public var maxSkewMs: Double?
        public var unmeasured: [String] = []
    }

    public var driver: String
    public var kind: String
    public var mode: String
    public var status: String
    public var reason: String
    public var severity: String
    public var evidence: String
    public var readingsFresh: Bool?
    public var requestedW: Double?
    public var sentW: Double?
    public var readbackW: Double?
    public var actualW: Double?
    public var batterySoc: Double?
    public var chargeResumeSoc: Double?
    public var requestedA: Double?
    public var offeredA: Double?
    public var deviceLimitA: Double?
    public var toleranceW: Double?
    public var deviceReason: String?
    public var commandAtMs: Double?
    public var observedAtMs: Double?
    public var confirmedAtMs: Double?
    public var siteConfirmation: String?
    public var siteEvidence: Comparison?

    public var id: String { "\(driver):\(kind)" }

    public init(driver: String, kind: String, mode: String = "", status: String, reason: String, severity: String = "info", evidence: String = "") {
        self.driver = driver
        self.kind = kind
        self.mode = mode
        self.status = status
        self.reason = reason
        self.severity = severity
        self.evidence = evidence
    }

    /// A row as the box sent it; nil for anything without a driver, a
    /// status and a reason.
    public init?(_ j: JSON) {
        guard let driver = j["driver"]?.string, let status = j["status"]?.string, let reason = j["reason"]?.string else { return nil }
        self.init(driver: driver, kind: j["kind"]?.string ?? "device", mode: j["mode"]?.string ?? "", status: status, reason: reason,
                  severity: j["severity"]?.string ?? "info", evidence: j["evidence"]?.string ?? "")
        readingsFresh = j["readings_fresh"]?.bool
        requestedW = j["requested_w"]?.number
        sentW = j["sent_w"]?.number
        readbackW = j["readback_w"]?.number
        actualW = j["actual_w"]?.number
        batterySoc = j["battery_soc"]?.number
        chargeResumeSoc = j["charge_resume_soc"]?.number
        requestedA = j["requested_a"]?.number
        offeredA = j["offered_a"]?.number
        deviceLimitA = j["device_limit_a"]?.number
        toleranceW = j["tolerance_w"]?.number
        deviceReason = j["device_reason"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        commandAtMs = j["command_at_ms"]?.number.flatMap { $0 > 0 ? $0 : nil }
        observedAtMs = j["observed_at_ms"]?.number.flatMap { $0 > 0 ? $0 : nil }
        confirmedAtMs = j["confirmed_at_ms"]?.number.flatMap { $0 > 0 ? $0 : nil }
        siteConfirmation = j["site_confirmation"]?.string
        if let e = j["site_evidence"], e.object != nil {
            siteEvidence = Comparison(
                deviceChangeW: e["device_change_w"]?.number, gridChangeW: e["grid_change_w"]?.number,
                otherChangeW: e["other_change_w"]?.number, unexplainedChangeW: e["unexplained_change_w"]?.number,
                gridBeforeW: e["grid_before_w"]?.number, gridAfterW: e["grid_after_w"]?.number,
                samples: e["samples"]?.number, windowS: e["window_s"]?.number, toleranceW: e["tolerance_w"]?.number,
                maxSkewMs: e["max_skew_ms"]?.number, unmeasured: e["unmeasured_flows"]?.array?.compactMap(\.string) ?? []
            )
        }
    }

    /// Every row in a status document.
    public static func rows(_ status: JSON?) -> [ControlRow] {
        status?["control_feedback"]?.array?.compactMap(ControlRow.init) ?? []
    }
}

/// Core's control feedback in words: the box's web/control-feedback.js, so
/// the phone says what the box's own page says. This only picks words and
/// marks; it never decides a status of its own.
public enum ControlFeedback {
    public enum Tone: Equatable, Sendable { case ok, neutral, warning, alarm, stale }

    public struct Status: Equatable, Sendable {
        public let title: String
        public let text: String
        /// How Core knows, in one sentence; empty when there is none.
        public let proof: String
        /// What the owner can do; empty when there is nothing.
        public let next: String
        public let tone: Tone
    }

    public enum StepState: Equatable, Sendable { case done, wait, fail, none }

    public struct Step: Equatable, Sendable, Identifiable {
        public let step: String
        public let value: String
        public let state: StepState
        public var id: String { step }
    }

    public struct Summary: Equatable, Sendable {
        public let title: String
        public let tone: Tone
    }

    // MARK: Small words

    /// "2.2 kW", "640 W", "0 W": the box's own rounding, in the language's
    /// decimal.
    public static func power(_ watts: Double?) -> String {
        guard let watts, watts.isFinite else { return ControlWords.text("unknown") }
        let size = abs(watts)
        if size < 1 { return "0 W" }
        // Halves round up, as the page's toFixed(1) does.
        return size >= 1000 ? "\(AppWords.decimal(String(format: "%.1f", (size / 100).rounded() / 10))) kW" : "\(Int(size.rounded())) W"
    }

    static func amps(_ a: Double?) -> String {
        guard let a, a.isFinite else { return ControlWords.text("the current") }
        return "\(Int(a.rounded())) A"
    }

    static func percent(_ soc: Double?) -> String {
        guard let soc, soc.isFinite else { return ControlWords.text("its current level") }
        return "\(Int((soc * 100).rounded()))\u{00A0}%"
    }

    static func clock(_ ms: Double?, _ zone: TimeZone) -> String? {
        guard let ms, ms > 0 else { return nil }
        return AppWords.clock(ms, zone: zone)
    }

    /// The device as a noun with its article: "the battery", "batteriet".
    static func noun(_ row: ControlRow) -> String {
        switch row.kind {
        case "battery": return ControlWords.text("the battery")
        case "ev", "v2x_charger": return ControlWords.text("the charger")
        case "pv": return ControlWords.text("the solar inverter")
        default: return ControlWords.text("the device")
        }
    }

    /// "the battery’s", "batteriets".
    static func owner(_ row: ControlRow) -> String {
        switch row.kind {
        case "battery": return ControlWords.text("the battery’s")
        case "ev", "v2x_charger": return ControlWords.text("the charger’s")
        case "pv": return ControlWords.text("the solar inverter’s")
        default: return ControlWords.text("the device’s")
        }
    }

    /// What the device is in a list: "battery", "charger".
    public static func kind(_ row: ControlRow) -> String {
        switch row.kind {
        case "battery": return ControlWords.text("battery")
        case "ev", "v2x_charger": return ControlWords.text("charger")
        case "pv": return ControlWords.text("solar")
        default: return ControlWords.text("device")
        }
    }

    static func capital(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    /// Site convention: positive power is drawn into the site.
    static func doing(_ row: ControlRow, _ watts: Double?) -> String {
        ControlWords.text(doingKey(row, watts))
    }

    /// The English word, for choosing a sentence.
    static func doingKey(_ row: ControlRow, _ watts: Double?) -> String {
        if row.kind == "pv" { return "producing" }
        guard let watts, watts.isFinite, abs(watts) >= 100 else { return "idle" }
        return watts > 0 ? "charging" : "discharging"
    }

    /// "2.2 kW discharge", "640 W solar", "idle".
    public static func flow(_ row: ControlRow, _ watts: Double?) -> String {
        guard let watts, watts.isFinite else { return ControlWords.text("unknown") }
        if row.kind == "pv" { return ControlWords.format("%@ solar", power(watts)) }
        if abs(watts) < 100 { return ControlWords.text(row.kind == "ev" ? "no charging" : "idle") }
        return ControlWords.format(watts > 0 ? "%@ charge" : "%@ discharge", power(watts))
    }

    static func target(_ row: ControlRow) -> String {
        guard let sent = row.sentW, sent.isFinite else { return ControlWords.text("the new target") }
        return row.kind == "pv" ? ControlWords.format("a %@ cap", power(sent)) : flow(row, sent)
    }

    static func source(_ row: ControlRow) -> String {
        if row.mode == "manual" { return ControlWords.text("as you asked") }
        if row.mode == "solar" { return ControlWords.text("from spare solar") }
        if row.mode == "plan" || row.mode.hasPrefix("planner") { return ControlWords.text("as planned") }
        return ControlWords.text("as FTW asked")
    }

    static let statusTitles: [String: String] = [
        "following": "Following FTW", "waiting": "Waiting", "limited": "Limited", "not_following": "Not following",
        "no_contact": "No contact", "not_controlled": "Not controlled by FTW",
    ]

    /// A reason's title replaces the status word when the word alone says
    /// too little.
    static let reasonTitles: [String: String] = [
        "waiting_response": "Adjusting", "no_command": "No command yet", "not_connected": "No car connected",
        "no_plan_budget": "Waiting for the plan", "pv_surplus_pause": "Waiting for spare solar", "wake_kick": "Starting the charger",
        "vehicle_complete": "Car is full", "vehicle_limit_completion": "Car reached its limit", "vehicle_not_requesting": "Car not taking power",
        "battery_full": "Battery full", "battery_nearly_full": "Battery nearly full", "battery_nearly_empty": "Battery nearly empty",
        "core_limit": "Limited by FTW", "fuse_limit": "Limited by the main fuse", "fuse_cooldown": "Waiting after a fuse limit",
        "charger_limit": "Limited by FTW’s charger setting", "device_limit": "Charger limit", "offered_current_lower": "Charger offers less current",
        "device_fault": "Device fault", "telemetry_stale": "No fresh readings", "readings_lost": "Lost control",
        "command_failed": "Commands failing", "command_unconfirmed": "Command not confirmed", "default_failed": "Cannot hand back control",
        "response_unknown": "No power reading", "observe_only": "Monitoring only", "disabled": "Disabled", "device_control": "Own control",
        "site_meter_stale": "Paused for safety", "site_phase_currents_stale": "Paused for safety",
    ]

    // MARK: The answer

    static func sentence(_ row: ControlRow, _ zone: TimeZone) -> String {
        let name = noun(row), actual = row.actualW
        let w = ControlWords.self
        switch row.reason {
        case "power_observed", "plan", "manual_hold", "pv_surplus", "idle":
            switch doingKey(row, actual) {
            case "idle": return w.format("Idle %@.", source(row))
            case "charging": return w.format("Charging %@ %@.", power(actual), source(row))
            case "discharging": return w.format("Discharging %@ %@.", power(actual), source(row))
            default: return w.format("Producing %@ %@.", power(actual), source(row))
            }
        case "solar_below_ceiling": return w.format("Producing %@, below %@.", power(actual), target(row))
        case "vehicle_complete": return w.text("Not charging: the car reports that it is full.")
        case "vehicle_limit_completion": return w.text("Not charging: the car reached its own charge limit.")
        case "vehicle_not_requesting": return w.text("The car is not asking for power right now.")
        case "waiting_response":
            return w.format("Moving to %@. %@ usually responds within %@.", target(row), capital(name), w.text(row.kind == "ev" ? "two minutes" : "15 seconds"))
        case "no_command": return w.text("FTW has not sent a command since it started.")
        case "not_connected": return w.text("Plug in a car to charge.")
        case "no_plan_budget": return w.text("The plan has no charging in this period.")
        case "pv_surplus_pause": return w.text("Charging starts when there is enough spare solar.")
        case "wake_kick": return w.text("FTW is waking the charger.")
        case "battery_full":
            return w.format("FTW paused charging at %@. Charging resumes at %@ or lower; discharging works as normal.", percent(row.batterySoc), percent(row.chargeResumeSoc))
        case "battery_nearly_full":
            return w.format("Taking %@ of %@ at %@. A battery charges slower when it is nearly full.", power(actual), power(row.sentW), percent(row.batterySoc))
        case "battery_nearly_empty":
            return w.format("Giving %@ of %@ at %@. A battery limits discharge when it is nearly empty.", power(actual), power(row.sentW), percent(row.batterySoc))
        case "core_limit": return w.format("FTW’s safety limits set the target to %@.", target(row))
        case "fuse_limit": return w.format("FTW lowered the rate to %@ to protect the main fuse. It rises when the house uses less.", target(row))
        case "fuse_cooldown": return w.text("FTW waits a moment after a fuse limit before it raises the rate.")
        case "charger_limit": return w.text("The charger limit in FTW’s settings caps the rate.")
        case "device_limit": return w.format("The charger’s own limit is %@, below the %@ FTW asked for.", amps(row.deviceLimitA), amps(row.requestedA))
        case "offered_current_lower": return w.format("The charger offers %@, below the %@ FTW asked for.", amps(row.offeredA), amps(row.requestedA))
        case "power_below_target", "power_above_target": return w.format("Asked for %@, delivering %@.", target(row), power(actual))
        case "power_wrong_direction": return w.format("Asked for %@, but it is %@ %@.", target(row), doing(row, actual), power(actual))
        case "no_power_response": return w.format("Asked for %@, but it delivers no power.", target(row))
        case "power_while_idle": return w.format("Asked to stay idle, but it is %@ %@.", doing(row, actual), power(actual))
        case "setpoint_changed": return w.format("%@ reports a target of %@, not the %@ FTW sent.", capital(name), flow(row, row.readbackW), target(row))
        case "device_fault":
            if let why = row.deviceReason { return w.format("%@ reports a fault: %@.", capital(name), why) }
            return w.format("%@ reports a fault that stops control.", capital(name))
        case "telemetry_stale": return w.format("FTW has no fresh readings from %@.", name)
        case "readings_lost":
            if let at = clock(row.observedAtMs, zone) {
                return w.format("No usable readings from %@ since %@. FTW cannot see what its commands do.", name, at)
            }
            return w.format("No usable readings from %@. FTW cannot see what its commands do.", name)
        case "command_failed": return w.format("The last command to %@ failed. FTW keeps trying.", name)
        case "command_unconfirmed": return w.format("The last command timed out. It may still have reached %@.", name)
        case "default_failed": return w.format("FTW could not return %@ to its own mode, so it sends no other commands until it can.", name)
        case "response_unknown": return w.format("FTW has no power reading from %@ to compare with its command.", name)
        case "observe_only": return w.format("FTW reads %@ but does not control it.", name)
        case "disabled": return w.text("This device is disabled in FTW’s settings.")
        case "device_control": return w.format("%@ runs its own mode. FTW is not sending commands.", capital(name))
        case "site_meter_stale": return w.text("FTW stopped control because the grid meter readings are out of date.")
        case "site_phase_currents_stale": return w.text("FTW stopped control because it lacks fresh phase currents for the main fuse check.")
        default: return w.format("The box reports “%@”, which this version cannot describe.", row.reason)
        }
    }

    static func nextStep(_ row: ControlRow) -> String {
        let name = noun(row)
        let w = ControlWords.self
        switch row.reason {
        case "power_below_target", "power_above_target", "power_wrong_direction", "no_power_response", "power_while_idle":
            return w.format("%@ has not said why. Check its app or display.", capital(name))
        case "setpoint_changed": return w.text("Another app or controller may be changing it.")
        case "device_fault": return w.format("Check %@.", name)
        case "telemetry_stale", "readings_lost", "command_failed", "default_failed": return w.format("Check the connection to %@.", name)
        case "site_meter_stale", "site_phase_currents_stale": return w.text("Check the grid meter’s connection.")
        case "device_limit": return w.text("Raise the limit in the charger’s app if you want faster charging.")
        case "offered_current_lower": return w.text("Check the charger’s load balancing and limits.")
        case "observe_only": return w.text("Turn on control in the device settings if you want FTW to steer it.")
        default: return ""
        }
    }

    static func proof(_ row: ControlRow, _ zone: TimeZone) -> String {
        if row.evidence == "confirmed", let at = clock(row.confirmedAtMs, zone) { return ControlWords.format("The grid meter confirmed this at %@.", at) }
        if row.evidence == "measured", row.status == "following" { return ControlWords.format("Based on %@ own readings.", owner(row)) }
        return ""
    }

    /// One answer per device function: a title, one sentence and, when the
    /// owner can act, the next step. The tone follows Core's severity.
    public static func status(_ row: ControlRow, live: Bool = true, zone: TimeZone = .current) -> Status {
        guard live else {
            return Status(title: ControlWords.text("Status not current"), text: ControlWords.text("FTW has not reported for a while."), proof: "", next: ControlWords.text("Waiting for a fresh report."), tone: .stale)
        }
        let title = ControlWords.text(reasonTitles[row.reason] ?? statusTitles[row.status] ?? "Checking")
        let tone: Tone = row.severity == "alarm" ? .alarm : row.severity == "warning" ? .warning : row.status == "following" ? .ok : .neutral
        return Status(title: title, text: sentence(row, zone), proof: proof(row, zone), next: nextStep(row), tone: tone)
    }

    static let confirmation: [String: (String, StepState)] = [
        "no_site_meter": ("No grid meter to compare with", .none),
        "independent_source_unknown": ("The grid meter is not a separate sensor", .none),
        "not_controlling": ("Not needed while FTW does not control it", .none),
        "device_response_unconfirmed": ("Waits for the device’s measured response", .wait),
        "waiting_for_meter": ("Waiting for fresh grid meter readings", .wait),
        "no_baseline": ("Waiting for a clear change to compare", .wait),
        "readings_not_aligned": ("Waiting for readings close enough in time", .wait),
        "flows_changing": ("Other loads changed at the same time", .wait),
        "site_change_differs": ("The grid change did not match; another load may have changed", .wait),
        "no_clear_change": ("The change was too small to compare", .wait),
    ]

    static func modeName(_ mode: String) -> String {
        if mode == "manual" { return ControlWords.text("manual") }
        if mode == "solar" { return ControlWords.text("solar only") }
        if mode == "plan" || mode.hasPrefix("planner") { return ControlWords.text("plan") }
        return mode.isEmpty ? "FTW" : mode.replacingOccurrences(of: "_", with: " ")
    }

    /// How FTW knows: each step with its value and state.
    public static func receipt(_ row: ControlRow, live: Bool = true, zone: TimeZone = .current) -> [Step] {
        let w = ControlWords.self
        var steps = [Step]()
        let at = { (ms: Double?) in clock(ms, zone).map { " · \($0)" } ?? "" }
        let sent = row.sentW.flatMap { $0.isFinite ? $0 : nil }
        if let asked = row.requestedW, asked.isFinite, let sent, abs(asked - sent) > max(50, abs(sent) * 0.02) {
            steps.append(Step(step: w.text("Asked"), value: "\(flow(row, asked)) · \(modeName(row.mode))", state: .done))
        }
        steps.append(Step(step: w.text("Sent"), value: sent.map { "\(flow(row, $0))\(at(row.commandAtMs))" } ?? w.text("No command"), state: sent != nil ? .done : .none))
        let failed = ["command_failed", "command_unconfirmed", "default_failed"].contains(row.reason)
        let accepted = ["accepted", "measured", "confirmed"].contains(row.evidence)
        let acceptedValue: String
        if failed {
            acceptedValue = w.text(reasonTitles[row.reason] ?? "")
        } else if accepted {
            acceptedValue = live && row.readbackW?.isFinite == true ? w.format("%@ reports target %@", capital(noun(row)), flow(row, row.readbackW)) : w.text("The driver took the command")
        } else {
            acceptedValue = sent != nil ? w.text("Waiting for the driver") : "—"
        }
        steps.append(Step(step: w.text("Accepted"), value: acceptedValue, state: failed ? .fail : accepted ? .done : sent != nil ? .wait : .none))
        let measured = ["measured", "confirmed"].contains(row.evidence)
        let measuredValue: String
        let measuredState: StepState
        if !live {
            (measuredValue, measuredState) = (w.text("Not current"), .none)
        } else if measured {
            (measuredValue, measuredState) = ("\(flow(row, row.actualW))\(at(row.observedAtMs))", .done)
        } else if row.readingsFresh == false {
            (measuredValue, measuredState) = (w.text("No fresh readings"), sent != nil ? .fail : .none)
        } else {
            (measuredValue, measuredState) = sent != nil ? (w.text("Waiting for fresh readings"), .wait) : ("—", .none)
        }
        steps.append(Step(step: w.text("Measured"), value: measuredValue, state: measuredState))
        let (why, state) = confirmation[row.siteConfirmation ?? ""] ?? ("Waiting for a clear change to compare", .wait)
        let confirmedValue: String
        let confirmedState: StepState
        if !live {
            (confirmedValue, confirmedState) = (w.text("Not current"), .none)
        } else if row.evidence == "confirmed" {
            let change = row.siteEvidence?.deviceChangeW.flatMap { $0.isFinite ? w.format("a %@ change", power($0)) : nil } ?? w.text("the change")
            (confirmedValue, confirmedState) = ("\(w.format("The grid meter matched %@", change))\(at(row.confirmedAtMs))", .done)
        } else {
            (confirmedValue, confirmedState) = (w.text(why), state)
        }
        steps.append(Step(step: w.text("Confirmed"), value: confirmedValue, state: confirmedState))
        return steps
    }

    /// Numbers for experts and support, as label and value.
    public static func numbers(_ row: ControlRow, live: Bool = true) -> [(String, String)] {
        guard live else { return [] }
        let w = ControlWords.self
        var out = [(String, String)]()
        if row.batterySoc?.isFinite == true { out.append((w.text("Battery charge"), percent(row.batterySoc))) }
        if let t = row.toleranceW, t.isFinite { out.append((w.text("Response tolerance"), "±\(power(t))")) }
        if row.requestedA?.isFinite == true { out.append((w.text("Requested current"), amps(row.requestedA))) }
        if row.offeredA?.isFinite == true { out.append((w.text("Charger offer"), amps(row.offeredA))) }
        if row.deviceLimitA?.isFinite == true { out.append((w.text("Charger limit"), amps(row.deviceLimitA))) }
        guard let e = row.siteEvidence else { return out }
        for (label, v) in [("Grid before", e.gridBeforeW), ("Grid after", e.gridAfterW)] {
            if let v, v.isFinite { out.append((w.text(label), w.format(v < 0 ? "%@ export" : "%@ import", power(v)))) }
        }
        if let v = e.deviceChangeW, v.isFinite {
            let words: String
            switch row.kind {
            case "pv": words = w.format(v < 0 ? "%@ more solar" : "%@ less solar", power(v))
            case "ev": words = w.format(v < 0 ? "%@ less charging" : "%@ more charging", power(v))
            default: words = w.format(v < 0 ? "%@ toward discharge" : "%@ toward charge", power(v))
            }
            out.append((w.text("Device change"), words))
        }
        if let v = e.gridChangeW, v.isFinite { out.append((w.text("Grid change"), w.format(v < 0 ? "%@ toward export" : "%@ toward import", power(v)))) }
        for (label, v) in [("Other measured change", e.otherChangeW), ("Unexplained change", e.unexplainedChangeW)] {
            if let v, v.isFinite { out.append((w.text(label), w.format(v < 0 ? "%@ less drawn" : "%@ more drawn", power(v)))) }
        }
        if let n = e.samples, n > 0 {
            out.append((w.text("Compared"), w.format("%@ readings over %@ s", String(Int(n)), String(Int((e.windowS ?? 0).rounded())))))
        }
        if let t = e.toleranceW, t > 0 { out.append((w.text("Match tolerance"), "±\(power(t))")) }
        if !e.unmeasured.isEmpty {
            let kinds = ["battery": "battery", "ev": "car charger", "v2x_charger": "car charger", "pv": "solar", "meter": "meter"]
            let names = e.unmeasured.map { flow -> String in
                let parts = flow.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, let kind = kinds[parts[1]] else { return parts.first ?? flow }
                return "\(parts[0]) (\(w.text(kind)))"
            }
            out.append((w.text("Left in the background"), names.joined(separator: ", ")))
        }
        if let skew = e.maxSkewMs, skew.isFinite, (e.samples ?? 0) > 0 { out.append((w.text("Largest time gap"), "\(Int(skew.rounded())) ms")) }
        return out
    }

    /// The answer for the whole home, over every row.
    public static func summary(_ rows: [ControlRow], live: Bool = true) -> Summary {
        let w = ControlWords.self
        guard live else { return Summary(title: w.text("Status not current"), tone: .stale) }
        let alarms = rows.filter { $0.severity == "alarm" }.count
        let warnings = rows.filter { $0.severity == "warning" }.count
        if alarms > 0 { return Summary(title: w.format(alarms == 1 ? "%@ device needs attention now" : "%@ devices need attention now", String(alarms)), tone: .alarm) }
        if warnings > 0 { return Summary(title: w.format(warnings == 1 ? "%@ device needs a look" : "%@ devices need a look", String(warnings)), tone: .warning) }
        if !rows.contains(where: { $0.status != "not_controlled" }) { return Summary(title: w.text("FTW controls no device right now"), tone: .neutral) }
        return Summary(title: AppWords.text("Yes, FTW is in control"), tone: .ok)
    }
}

/// The control sheet's words in the phone's language. Keyed by the box's
/// English, so a missing entry shows English rather than nothing; a test
/// fails on any word without Swedish.
public enum ControlWords {
    public static func text(_ en: String) -> String {
        AppWords.language == .sv ? (sv[en] ?? NodeWords.text(en)) : en
    }

    public static func format(_ en: String, _ args: String...) -> String {
        var out = text(en)
        for a in args {
            guard let r = out.range(of: "%@") else { break }
            out.replaceSubrange(r, with: a)
        }
        return out
    }

    static let sv: [String: String] = [
        // The sheet
        "Are we in control?": "Har vi kontroll?",
        "How FTW knows": "Så vet FTW",
        "Numbers": "Siffror",
        "Status not current": "Status inte aktuell",
        "FTW has not reported for a while.": "FTW har inte rapporterat på ett tag.",
        "Waiting for a fresh report.": "Väntar på en ny rapport.",
        "%@ device needs attention now": "%@ enhet behöver åtgärdas nu",
        "%@ devices need attention now": "%@ enheter behöver åtgärdas nu",
        "%@ device needs a look": "%@ enhet behöver ses över",
        "%@ devices need a look": "%@ enheter behöver ses över",
        "FTW controls no device right now": "FTW styr ingen enhet just nu",

        // Devices
        "battery": "batteri", "charger": "laddare", "solar": "sol", "device": "enhet",
        "the battery": "batteriet", "the charger": "laddaren", "the solar inverter": "solväxelriktaren", "the device": "enheten",
        "the battery’s": "batteriets", "the charger’s": "laddarens", "the solar inverter’s": "solväxelriktarens", "the device’s": "enhetens",
        "car charger": "billaddare", "meter": "mätare",

        // Small words
        "unknown": "okänt",
        "the current": "strömmen",
        "its current level": "nuvarande nivå",
        "producing": "producerar", "idle": "vilar", "charging": "laddar", "discharging": "laddar ur",
        "%@ solar": "%@ sol",
        "no charging": "ingen laddning",
        "%@ charge": "%@ laddning",
        "%@ discharge": "%@ urladdning",
        "the new target": "det nya målet",
        "a %@ cap": "ett tak på %@",
        "as you asked": "som du bad om",
        "from spare solar": "från solöverskott",
        "as planned": "enligt planen",
        "as FTW asked": "som FTW bad om",
        "manual": "manuellt", "solar only": "bara sol", "plan": "plan",
        "two minutes": "två minuter", "15 seconds": "15 sekunder",

        // Status titles
        "Following FTW": "Följer FTW", "Waiting": "Väntar", "Limited": "Begränsad", "Not following": "Följer inte",
        "No contact": "Ingen kontakt", "Not controlled by FTW": "Styrs inte av FTW", "Checking": "Kontrollerar",
        "Adjusting": "Ställer om", "No command yet": "Inget kommando än", "No car connected": "Ingen bil ansluten",
        "Waiting for the plan": "Väntar på planen", "Waiting for spare solar": "Väntar på solöverskott", "Starting the charger": "Startar laddaren",
        "Car is full": "Bilen är full", "Car reached its limit": "Bilen nådde sin gräns", "Car not taking power": "Bilen tar inte emot ström",
        "Battery full": "Batteriet är fullt", "Battery nearly full": "Batteriet nästan fullt", "Battery nearly empty": "Batteriet nästan tomt",
        "Limited by FTW": "Begränsad av FTW", "Limited by the main fuse": "Begränsad av huvudsäkringen", "Waiting after a fuse limit": "Väntar efter en säkringsgräns",
        "Limited by FTW’s charger setting": "Begränsad av FTW:s laddarinställning", "Charger limit": "Laddarens gräns", "Charger offers less current": "Laddaren erbjuder mindre ström",
        "Device fault": "Fel i enheten", "No fresh readings": "Inga färska mätvärden", "Lost control": "Tappade kontrollen",
        "Commands failing": "Kommandon misslyckas", "Command not confirmed": "Kommandot ej bekräftat", "Cannot hand back control": "Kan inte lämna tillbaka styrningen",
        "No power reading": "Ingen effektmätning", "Monitoring only": "Bara övervakning", "Disabled": "Avstängd", "Own control": "Egen styrning",
        "Paused for safety": "Pausad för säkerheten",

        // Sentences
        "Idle %@.": "Vilar %@.",
        "Charging %@ %@.": "Laddar %@ %@.",
        "Discharging %@ %@.": "Laddar ur %@ %@.",
        "Producing %@ %@.": "Producerar %@ %@.",
        "Producing %@, below %@.": "Producerar %@, under %@.",
        "Not charging: the car reports that it is full.": "Laddar inte: bilen säger att den är full.",
        "Not charging: the car reached its own charge limit.": "Laddar inte: bilen har nått sin egen laddgräns.",
        "The car is not asking for power right now.": "Bilen ber inte om ström just nu.",
        "Moving to %@. %@ usually responds within %@.": "Går mot %@. %@ svarar oftast inom %@.",
        "FTW has not sent a command since it started.": "FTW har inte skickat något kommando sedan start.",
        "Plug in a car to charge.": "Anslut en bil för att ladda.",
        "The plan has no charging in this period.": "Planen har ingen laddning i den här perioden.",
        "Charging starts when there is enough spare solar.": "Laddningen startar när solöverskottet räcker.",
        "FTW is waking the charger.": "FTW väcker laddaren.",
        "FTW paused charging at %@. Charging resumes at %@ or lower; discharging works as normal.": "FTW pausade laddningen vid %@. Laddningen fortsätter vid %@ eller lägre; urladdning fungerar som vanligt.",
        "Taking %@ of %@ at %@. A battery charges slower when it is nearly full.": "Tar %@ av %@ vid %@. Ett batteri laddar långsammare när det är nästan fullt.",
        "Giving %@ of %@ at %@. A battery limits discharge when it is nearly empty.": "Ger %@ av %@ vid %@. Ett batteri begränsar urladdningen när det är nästan tomt.",
        "FTW’s safety limits set the target to %@.": "FTW:s säkerhetsgränser satte målet till %@.",
        "FTW lowered the rate to %@ to protect the main fuse. It rises when the house uses less.": "FTW sänkte till %@ för att skydda huvudsäkringen. Det ökar när huset använder mindre.",
        "FTW waits a moment after a fuse limit before it raises the rate.": "FTW väntar en stund efter en säkringsgräns innan det höjer igen.",
        "The charger limit in FTW’s settings caps the rate.": "Laddargränsen i FTW:s inställningar begränsar takten.",
        "The charger’s own limit is %@, below the %@ FTW asked for.": "Laddarens egen gräns är %@, under de %@ som FTW bad om.",
        "The charger offers %@, below the %@ FTW asked for.": "Laddaren erbjuder %@, under de %@ som FTW bad om.",
        "Asked for %@, delivering %@.": "Bad om %@, levererar %@.",
        "Asked for %@, but it is %@ %@.": "Bad om %@, men den %@ %@.",
        "Asked for %@, but it delivers no power.": "Bad om %@, men den levererar ingen effekt.",
        "Asked to stay idle, but it is %@ %@.": "Ombedd att vila, men den %@ %@.",
        "%@ reports a target of %@, not the %@ FTW sent.": "%@ rapporterar målet %@, inte de %@ som FTW skickade.",
        "%@ reports a fault: %@.": "%@ rapporterar ett fel: %@.",
        "%@ reports a fault that stops control.": "%@ rapporterar ett fel som stoppar styrningen.",
        "FTW has no fresh readings from %@.": "FTW har inga färska mätvärden från %@.",
        "No usable readings from %@ since %@. FTW cannot see what its commands do.": "Inga användbara mätvärden från %@ sedan %@. FTW ser inte vad dess kommandon gör.",
        "No usable readings from %@. FTW cannot see what its commands do.": "Inga användbara mätvärden från %@. FTW ser inte vad dess kommandon gör.",
        "The last command to %@ failed. FTW keeps trying.": "Senaste kommandot till %@ misslyckades. FTW fortsätter försöka.",
        "The last command timed out. It may still have reached %@.": "Senaste kommandot tog för lång tid. Det kan ändå ha nått %@.",
        "FTW could not return %@ to its own mode, so it sends no other commands until it can.": "FTW kunde inte lämna tillbaka %@ till dess eget läge, så det skickar inga andra kommandon förrän det går.",
        "FTW has no power reading from %@ to compare with its command.": "FTW har ingen effektmätning från %@ att jämföra kommandot med.",
        "FTW reads %@ but does not control it.": "FTW läser av %@ men styr inte.",
        "This device is disabled in FTW’s settings.": "Enheten är avstängd i FTW:s inställningar.",
        "%@ runs its own mode. FTW is not sending commands.": "%@ kör sitt eget läge. FTW skickar inga kommandon.",
        "FTW stopped control because the grid meter readings are out of date.": "FTW stoppade styrningen eftersom elmätarens värden är för gamla.",
        "FTW stopped control because it lacks fresh phase currents for the main fuse check.": "FTW stoppade styrningen eftersom det saknar färska fasströmmar för säkringskontrollen.",
        "The box reports “%@”, which this version cannot describe.": "Boxen rapporterar ”%@”, som den här versionen inte kan beskriva.",

        // Next steps and proof
        "%@ has not said why. Check its app or display.": "%@ har inte sagt varför. Titta i dess app eller display.",
        "Another app or controller may be changing it.": "En annan app eller styrning kan ändra den.",
        "Check %@.": "Kontrollera %@.",
        "Check the connection to %@.": "Kontrollera anslutningen till %@.",
        "Check the grid meter’s connection.": "Kontrollera elmätarens anslutning.",
        "Raise the limit in the charger’s app if you want faster charging.": "Höj gränsen i laddarens app om du vill ladda snabbare.",
        "Check the charger’s load balancing and limits.": "Kontrollera laddarens lastbalansering och gränser.",
        "Turn on control in the device settings if you want FTW to steer it.": "Slå på styrning i enhetens inställningar om du vill att FTW ska styra den.",
        "The grid meter confirmed this at %@.": "Elmätaren bekräftade det här kl. %@.",
        "Based on %@ own readings.": "Bygger på %@ egna mätvärden.",

        // How FTW knows
        "Asked": "Begärt", "Sent": "Skickat", "Accepted": "Mottaget", "Measured": "Mätt", "Confirmed": "Bekräftat",
        "No command": "Inget kommando",
        "%@ reports target %@": "%@ rapporterar målet %@",
        "The driver took the command": "Drivrutinen tog emot kommandot",
        "Waiting for the driver": "Väntar på drivrutinen",
        "Not current": "Inte aktuellt",
        "Waiting for fresh readings": "Väntar på färska mätvärden",
        "a %@ change": "en ändring på %@",
        "the change": "ändringen",
        "The grid meter matched %@": "Elmätaren stämde med %@",
        "No grid meter to compare with": "Ingen elmätare att jämföra med",
        "The grid meter is not a separate sensor": "Elmätaren är ingen separat givare",
        "Not needed while FTW does not control it": "Behövs inte när FTW inte styr den",
        "Waits for the device’s measured response": "Väntar på enhetens uppmätta svar",
        "Waiting for fresh grid meter readings": "Väntar på färska värden från elmätaren",
        "Waiting for a clear change to compare": "Väntar på en tydlig ändring att jämföra",
        "Waiting for readings close enough in time": "Väntar på mätvärden nära nog i tid",
        "Other loads changed at the same time": "Andra laster ändrades samtidigt",
        "The grid change did not match; another load may have changed": "Ändringen mot nätet stämde inte; en annan last kan ha ändrats",
        "The change was too small to compare": "Ändringen var för liten att jämföra",

        // Numbers
        "Battery charge": "Batteriets laddning",
        "Response tolerance": "Svarstolerans",
        "Requested current": "Begärd ström",
        "Charger offer": "Laddarens erbjudande",
        "Grid before": "Nätet före",
        "Grid after": "Nätet efter",
        "%@ export": "%@ export",
        "%@ import": "%@ import",
        "Device change": "Enhetens ändring",
        "%@ more solar": "%@ mer sol",
        "%@ less solar": "%@ mindre sol",
        "%@ less charging": "%@ mindre laddning",
        "%@ more charging": "%@ mer laddning",
        "%@ toward discharge": "%@ mot urladdning",
        "%@ toward charge": "%@ mot laddning",
        "Grid change": "Nätets ändring",
        "%@ toward export": "%@ mot export",
        "%@ toward import": "%@ mot import",
        "Other measured change": "Annan uppmätt ändring",
        "Unexplained change": "Oförklarad ändring",
        "%@ less drawn": "%@ mindre uttag",
        "%@ more drawn": "%@ mer uttag",
        "Compared": "Jämfört",
        "%@ readings over %@ s": "%@ mätvärden under %@ s",
        "Match tolerance": "Matchningstolerans",
        "Left in the background": "Kvar i bakgrunden",
        "Largest time gap": "Största tidsglapp",
    ]
}
