import Foundation
import Observation

/// The charger sheet. Everything on it is a fact the box served; the
/// controls express intent with an expiry, and the box decides. After any
/// outcome the charger is read again, because the box's account is the
/// truth to repaint from.
@Observable
@MainActor
public final class LoadpointsModel: Activatable {
    public enum Control: Sendable { case hold, boost, soc, surplus }
    public enum Outcome: Sendable { case hold, release, pause, boost, unboost, soc, surplusOn, surplusOff }

    public enum Command: Sendable {
        case idle
        case sending(Control)
        case applied(Control, Outcome)
        case unconfirmed(Control)
        case failed(Control, String)

        public var isSending: Bool { if case .sending = self { return true }; return false }
    }

    public private(set) var points: [Loadpoint] = []
    public private(set) var windows: [String: [Loadpoint.Window]] = [:]
    public private(set) var planMissing = false
    public private(set) var planPending = false
    public private(set) var planOutdated = false
    public private(set) var loading = false
    /// Whether the box has ever answered. No answer is not an empty bay.
    public private(set) var loaded = false
    public private(set) var readAtMs: Double?
    public private(set) var error: String?
    public private(set) var command: Command = .idle
    public private(set) var commandLoadpointID: String?
    /// Applied choices stay on screen until a later read confirms them.
    public private(set) var acceptedSoc: [String: Double] = [:]
    public private(set) var acceptedSurplus: [String: Bool] = [:]

    // The sheet's drafts, held here so a reread never snaps a control from
    // under a finger.
    public var ampsDraft: [String: Int] = [:]
    public var socDraft: [String: Double] = [:]
    public var surplusDraft: [String: Bool] = [:]

    @ObservationIgnored private unowned let site: SiteModel
    @ObservationIgnored private let charging: ChargingWatch?
    @ObservationIgnored private var ask: LiveAsk?
    @ObservationIgnored private var active = 0
    @ObservationIgnored private var token = 0
    @ObservationIgnored private var settle: Cancellable?
    @ObservationIgnored private var inlinePlan = false
    @ObservationIgnored private var reading: Task<Void, Error>?

    public init(site: SiteModel, charging: ChargingWatch?) {
        self.site = site
        self.charging = charging
    }

    public func activate() {
        active += 1
        if ask == nil {
            ask = LiveAsk(site: site, want: { [weak self] in
                guard let self, self.active > 0, self.site.documentVisible, self.site.hasPassthrough else { return nil }
                return "loadpoints \(Int(self.site.nowMs / 5_000))"
            }, ask: { [weak self] in try await self?.load() })
        }
        ask?.evaluate()
    }

    public func deactivate() {
        active = max(0, active - 1)
        ask?.evaluate()
    }

    /// Out of date: the read failed, the stream stopped, or it is old.
    public var stale: Bool {
        error != nil || site.session.phase != .streaming || (readAtMs.map { site.nowMs - $0 >= 15_000 } ?? false)
    }

    // MARK: Reads

    public func loadChargers() async throws {
        if let reading {
            try await reading.value
            return
        }
        let task = Task { @MainActor in try await self.readChargers() }
        reading = task
        defer { reading = nil }
        try await task.value
    }

    private func readChargers() async throws {
        token += 1
        let mine = token
        let socChoices = acceptedSoc
        let surplusChoices = acceptedSurplus
        loading = true
        defer { if mine == token { loading = false } }
        do {
            let wire = try await site.callBox(.get, "/api/loadpoints")
            guard mine == token else { return }
            let list = wire?["loadpoints"]?.array ?? []
            points = list.map(Loadpoint.init)
            inlinePlan = !points.isEmpty && points.allSatisfy(\.inlinePlan)
            if inlinePlan {
                planPending = points.contains { $0.planPending }
                planOutdated = points.contains { $0.planOutdated }
                windows = Dictionary(uniqueKeysWithValues: points.map { ($0.id, $0.planWindows) })
                planMissing = false
            }
            // A read that started before a command cannot confirm its choice.
            acceptedSoc = acceptedSoc.filter { socChoices[$0.key] != $0.value }
            acceptedSurplus = acceptedSurplus.filter { surplusChoices[$0.key] != $0.value }
            loaded = true
            readAtMs = site.scheduler.nowMs
            error = nil
        } catch {
            guard mine == token else { return }
            if let e = error as? BoxAPIError, points.isEmpty {
                self.error = e.help
            } else {
                self.error = "Not up to date — your box is out of reach"
            }
            throw error
        }
    }

    /// The chargers, then the plan's windows for a box that reports them
    /// separately. A failed plan read is a note, not a failure.
    public func load() async throws {
        try await loadChargers()
        if inlinePlan { return }
        let mine = token
        do {
            let wire = try await site.callBox(.get, "/api/mpc/plan")
            guard mine == token else { return }
            planPending = wire?["meta"]?["replanning"]?.bool == true
            planOutdated = wire?["meta"]?["outdated"]?.bool == true
            let actions = wire?["plan"]?["actions"]?.array ?? []
            var out = [String: [Loadpoint.Window]]()
            for lp in points {
                out[lp.id] = planPending || planOutdated || lp.planPending || lp.planOutdated ? [] : Self.chargeWindows(actions, loadpointID: lp.id)
            }
            windows = out
            planMissing = false
        } catch {
            guard mine == token else { return }
            planMissing = true
        }
    }

    /// Adjacent charging slots fold into one window; a person asks when it
    /// will charge, not when the reason changes.
    static func chargeWindows(_ actions: [JSON], loadpointID: String) -> [Loadpoint.Window] {
        var out = [Loadpoint.Window]()
        for a in actions {
            guard let start = a["slot_start_ms"]?.number, let len = a["slot_len_min"]?.number,
                  let w = a["loadpoint_power_w"]?[loadpointID]?.number, w > 0 else { continue }
            let end = start + len * 60_000
            if var last = out.last, start <= last.toMs {
                last.toMs = end
                last.peakW = max(last.peakW ?? 0, w)
                out[out.count - 1] = last
            } else {
                out.append(Loadpoint.Window(fromMs: start, toMs: end, peakW: w, energyWh: nil))
            }
        }
        return out
    }

    // MARK: Commands

    /// Charge now: a hold at a chosen current until Stop or an unplug.
    public func chargeNow(_ lp: Loadpoint, amps: Int) async {
        await send(Contract.opLoadpointHold, lp.id, [("id", .text(lp.id)), ("power_w", .number(EVText.watts(lp, amps: amps))), ("hold_s", .int(0)), ("phase_mode", .text(EVText.current(lp).phases == 1 ? "1p" : "3p"))], .hold, .hold, CommandText.help)
    }

    public func pauseCharging(_ lp: Loadpoint) async {
        await send(Contract.opLoadpointHold, lp.id, [("id", .text(lp.id)), ("power_w", .int(0)), ("hold_s", .int(0))], .hold, .pause, CommandText.help)
    }

    /// Release the hold; the plan takes back over.
    public func stopCharging(_ lp: Loadpoint) async {
        await send(Contract.opLoadpointHold, lp.id, [("id", .text(lp.id)), ("clear", .bool(true))], .hold, .release, CommandText.help)
    }

    /// Let the house battery push the car for a bounded while.
    public func boost(_ lp: Loadpoint, reservePct: Int, durationS: Int) async {
        await send(Contract.opLoadpointBoost, lp.id, [("id", .text(lp.id)), ("min_battery_soc_pct", .int(reservePct)), ("duration_s", .int(durationS))], .boost, .boost, CommandText.boostHelp)
    }

    public func stopBoost(_ lp: Loadpoint) async {
        await send(Contract.opLoadpointBoost, lp.id, [("id", .text(lp.id)), ("cancel", .bool(true))], .boost, .unboost, CommandText.boostHelp)
    }

    /// Whole percent from the slider, a fraction to the box.
    public func setSoc(_ lp: Loadpoint, pct: Double) async {
        await send(Contract.opLoadpointSocSet, lp.id, [("id", .text(lp.id)), ("soc", .number(pct / 100))], .soc, .soc, CommandText.socHelp)
    }

    public func setSurplusOnly(_ lp: Loadpoint, _ on: Bool) async {
        await send(Contract.opLoadpointSurplusOnlySet, lp.id, [("id", .text(lp.id)), ("surplus_only", .bool(on))], .surplus, on ? .surplusOn : .surplusOff, CommandText.help)
    }

    private func send(_ op: String, _ id: String, _ args: [(String, CBOR)], _ of: Control, _ did: Outcome, _ help: (CmdResult) -> String) async {
        if command.isSending { return }
        settle?.cancel()
        commandLoadpointID = id
        command = .sending(of)
        do {
            let result = try await site.command(op, args: args)
            switch result.state {
            case .applied:
                command = .applied(of, did)
                if of == .soc, let soc = args.first(where: { $0.0 == "soc" })?.1.double { acceptedSoc[id] = (soc * 100).rounded() }
                if of == .surplus, let on = args.first(where: { $0.0 == "surplus_only" })?.1.bool { acceptedSurplus[id] = on }
            case .unconfirmed:
                command = .unconfirmed(of)
            default:
                command = .failed(of, help(result))
            }
        } catch let e as CommandError {
            command = .failed(of, e.help)
        } catch {
            command = .failed(of, "FTW did not confirm the request. Reading its current state…")
        }
        if case .applied = command {
            settle = site.scheduler.after(6_000) { [weak self] in self?.command = .idle }
        }
        try? await loadChargers()
        charging?.refresh()
    }

    // MARK: Configure routes: schedule, vehicle

    /// Save a goal in one PUT, so it costs one ceremony at most.
    public func saveSchedule(_ lp: Loadpoint, socPct: Double, hour: Int, minute: Int, recurring: Bool, days: Int, surplusUnlockPct: Double, calendar: Calendar = .current) async throws {
        guard let minUTC = EVText.minuteUTC(hour: hour, minute: minute, calendar: calendar) else {
            throw BoxAPIError(code: "E_BAD_TIME", help: "Choose a valid ready time.", status: nil)
        }
        guard !recurring || days != 0 else { throw BoxAPIError(code: "E_NO_DAYS", help: "Choose at least one day.", status: nil) }
        guard (10...100).contains(socPct) else { throw BoxAPIError(code: "E_BAD_SOC", help: "Choose a charge target from 10 to 100 %.", status: nil) }
        guard (0...100).contains(surplusUnlockPct) else { throw BoxAPIError(code: "E_BAD_SOC", help: "Choose a home battery level from 1 to 100 %.", status: nil) }
        _ = try await site.callBox(.put, "/api/loadpoints/\(Self.escape(lp.id))/schedule", body: [
            "soc": .number(socPct / 100),
            "time_of_day_min_utc": .number(Double(minUTC)),
            "recurring": .bool(recurring),
            "days": .number(Double(!recurring || days == 0x7f ? 0 : days & 0x7f)),
            "surplus_unlock_bat_soc": .number(surplusUnlockPct / 100),
        ])
        try? await loadChargers()
        charging?.refresh()
    }

    public func removeSchedule(_ lp: Loadpoint) async throws {
        _ = try await site.callBox(.delete, "/api/loadpoints/\(Self.escape(lp.id))/schedule")
        // The DELETE confirms the removal even if the reread fails.
        if let i = points.firstIndex(where: { $0.id == lp.id }) {
            points[i].schedule = nil
            points[i].targetSocPct = nil
        }
        try? await loadChargers()
        charging?.refresh()
    }

    /// The car's usable battery size, 1 to 300 kWh.
    public func setCapacity(_ lp: Loadpoint, kwh: Double) async throws -> String {
        guard kwh.isFinite, (1...300).contains(kwh) else {
            throw BoxAPIError(code: "E_BAD_CAPACITY", help: "Enter the usable battery size from 1 to 300 kWh.", status: nil)
        }
        let wh = (kwh * 1000).rounded()
        _ = try await site.callBox(.post, "/api/loadpoints/\(Self.escape(lp.id))/vehicle", body: ["capacity_wh": .number(wh)])
        do {
            try await load()
        } catch {
            return "Battery size saved. Current charging status is unavailable."
        }
        charging?.refresh()
        if let active = points.first(where: { $0.id == lp.id })?.vehicleCapacityWh, active != wh {
            return "Saved as the usual battery size. This session uses \(EnergyFormat.short(active / 1000)) kWh."
        }
        return "Battery size saved. The plan uses this size for its estimates."
    }

    static func escape(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id
    }

    // MARK: What the sheet shows

    public func socShown(_ lp: Loadpoint) -> Double {
        socDraft[lp.id] ?? acceptedSoc[lp.id] ?? lp.socPct ?? EVText.socDefaultPct
    }

    public func surplusShown(_ lp: Loadpoint) -> Bool {
        surplusDraft[lp.id] ?? acceptedSurplus[lp.id] ?? lp.surplusOnly
    }

    /// The slider's amps: the draft, else the running hold, else the ceiling.
    public func ampsShown(_ lp: Loadpoint) -> Int {
        let range = EVText.current(lp)
        let held: Int? = lp.manualActive && !lp.manualRestoreUnconfirmed && !EVText.isPaused(lp) ? lp.manualChargeW.map { EVText.amps(lp, watts: $0) } : nil
        return min(range.maxA, max(range.minA, ampsDraft[lp.id] ?? held ?? range.maxA))
    }

    /// One sentence per thing the box did, under the control that asked.
    public func outcomeSentence(_ did: Outcome, _ lp: Loadpoint) -> String {
        switch did {
        case .hold: return stale ? "Waiting for current charger status." : lp.manual != nil ? EVText.status(lp) : "FTW received your charge request. Waiting for charger status."
        case .release: return "The plan decides when to charge."
        case .pause: return EVText.status(lp)
        case .boost: return "Battery boost selected. The power readings show what the house battery supplies."
        case .unboost: return "Boost stopped — the plan decides again."
        case .soc:
            if let v = acceptedSoc[lp.id] { return "Charge level accepted: \(Int(v)) %. Waiting for updated charging status." }
            let pct = Int(lp.socPct ?? socShown(lp))
            let base = lp.socRetention == "error" ? "Charge level updated: \(pct) %. It could not be saved for a box restart." : "Charge level saved: \(pct) %."
            let tail = lp.schedule == nil && !lp.manualActive && !lp.surplusOnly ? " Set a ready time, or choose Charge now." : planMissing ? " Charging times are not available yet." : ""
            return base + tail
        case .surplusOn: return acceptedSurplus[lp.id] != nil ? "Solar rule accepted. Waiting for updated charging status." : "Solar rule saved. The plan uses spare solar only."
        case .surplusOff: return acceptedSurplus[lp.id] != nil ? "Solar rule accepted. Waiting for updated charging status." : "Solar rule saved. The plan may use grid power again."
        }
    }

    /// The outcome line under one control, or nil.
    public func outcome(for control: Control, _ lp: Loadpoint) -> String? {
        guard commandLoadpointID == lp.id else {
            if control == .soc, acceptedSoc[lp.id] != nil { return outcomeSentence(.soc, lp) }
            if control == .surplus, acceptedSurplus[lp.id] != nil { return "Solar rule accepted. Waiting for updated charging status." }
            return nil
        }
        switch command {
        case .applied(let of, let did) where of == control && (of != .hold || did == .release):
            return outcomeSentence(did, lp)
        case .unconfirmed(let of) where of == control:
            return "FTW received the request. Its result is not confirmed yet."
        case .failed(let of, let help) where of == control:
            return help
        default:
            if control == .soc, acceptedSoc[lp.id] != nil { return outcomeSentence(.soc, lp) }
            if control == .surplus, acceptedSurplus[lp.id] != nil { return "Solar rule accepted. Waiting for updated charging status." }
            return nil
        }
    }
}
