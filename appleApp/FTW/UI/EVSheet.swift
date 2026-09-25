import FTWKit
import SwiftUI

/// The charger sheet. Everything on it is a fact the box served; every
/// control expresses intent with an expiry, and the box decides. After any
/// outcome the charger is read again, because the box's account is the
/// truth to repaint from. Controls are hidden from viewers as presentation;
/// the box's refusal is the actual gate.
struct EVSheet: View {
    let site: SiteModel
    let model: LoadpointsModel
    let loadpointID: String?
    @Environment(\.dismiss) private var dismiss

    struct GoalDraft: Equatable {
        var loadpointID: String
        var time: Date
        var recurring: Bool
        var days: Int
        var socPct: Double
        var surplusUnlockPct: Double
    }

    struct BoostDraft: Equatable {
        var loadpointID: String
        var reservePct: Int
        var durationS: Int
    }

    @State private var goal: GoalDraft?
    @State private var goalRevision = 0
    @State private var saving = false
    @State private var saveError: String?
    @State private var scheduleNote = "Changes apply as you make them."
    @State private var justSavedGoal: String?
    @State private var removedGoal: String?
    @State private var boost: BoostDraft?
    @State private var capacityDraft: [String: String] = [:]
    @State private var capacityNote: [String: String] = [:]
    @State private var capacityFailed: [String: Bool] = [:]
    @State private var capacityBusy: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) { content }
                    .padding(20)
                    .frame(maxWidth: 560, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
            .background(Theme.surface)
            .navigationTitle("EV charger")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 560)
        #endif
        .onAppear { model.activate() }
        .onDisappear { model.deactivate() }
        .onChange(of: goal) { old, new in
            // An edit, not the editor opening or closing.
            guard let old, let new, old.loadpointID == new.loadpointID else { return }
            goalRevision += 1
            saveError = nil
            scheduleNote = "Applying schedule…"
        }
        .task(id: goalRevision) {
            guard goalRevision > 0 else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await saveGoal()
        }
    }

    private var sending: Bool { model.command.isSending }
    private var stale: Bool { model.stale }

    @ViewBuilder private var content: some View {
        if site.session.phase == .streaming, !site.hasPassthrough {
            Hint("Charging controls are not available from this box yet. Open the box's own page to manage charging.")
        } else {
            if site.session.phase != .streaming {
                Hint("Connecting to your box. Charging status will appear here when it answers.")
            }
            if let error = model.error { Hint(error) }
            if !model.loaded, model.error == nil {
                if site.session.phase == .streaming { Hint("Reading your box…") }
            } else {
                if model.loaded, model.error == nil, model.points.isEmpty {
                    Hint("\(site.canConfigure ? "Connect your first charger on your box: open Settings → Chargers, then choose Connect a charger." : "Ask an owner to connect the first charger on the box, under Settings → Chargers.") Once connected and added there, it appears here too.")
                }
                let shown = model.points.filter { loadpointID == nil || $0.id == loadpointID }
                ForEach(shown) { lp in
                    charger(lp)
                    if shown.count > 1 { Divider().overlay(Theme.line) }
                }
                if shown.isEmpty, model.loaded, model.error == nil, !model.points.isEmpty {
                    Hint("This charger is no longer listed. Close this view and choose a charger on the home screen.")
                }
            }
        }
    }

    // MARK: One charger

    @ViewBuilder private func charger(_ lp: Loadpoint) -> some View {
        let canConfigure = site.canConfigure
        Text(stale ? "Waiting for current charger status. The last reading is out of date." : EVText.status(lp, canControl: canConfigure))
            .font(.body.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
        if lp.manualSaveError { Hint(EVText.manualSaveErrorText) }
        if !stale, let plan = planStatus(lp) { Hint(plan) }
        if let seen = lp.charger?.updatedAtMs ?? lp.manual?.chargerUpdatedAtMs {
            Hint("Charger last seen: \(EVText.clock(seen))", tone: Theme.fgMuted)
        }
        if let session = EVText.session(lp) { Text(session).font(.callout) }

        if lp.boostActive {
            Text(EVText.boostActive(lp))
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.storage.opacity(0.18), in: Capsule())
            if canConfigure {
                Button("Stop boost") { Task { await model.stopBoost(lp) } }
                    .buttonStyle(.outline)
                    .disabled(sending)
                outcome(.boost, lp)
            }
        }

        if lp.pluggedIn { battery(lp) }
        if canConfigure, let capacity = lp.vehicleCapacityWh { carBattery(lp, capacityWh: capacity) }
        if canConfigure, lp.pluggedIn { chargeNow(lp) }
        goalSection(lp)
        if canConfigure, lp.pluggedIn { boostSection(lp) }
        if let stopped = EVText.boostStopped(lp) { Hint(stopped) }
        windows(lp)
    }

    private func planStatus(_ lp: Loadpoint) -> String? {
        if (lp.planPending || model.planPending), justSavedGoal == lp.id { return "Goal saved. Updating the plan…" }
        var merged = lp
        merged.planPending = lp.planPending || model.planPending
        merged.planOutdated = lp.planOutdated || model.planOutdated
        return EVText.plan(merged, nowMs: site.nowMs, canControl: site.canConfigure)
    }

    @ViewBuilder private func outcome(_ control: LoadpointsModel.Control, _ lp: Loadpoint) -> some View {
        if let text = model.outcome(for: control, lp) { Hint(text) }
    }

    private func isSending(_ control: LoadpointsModel.Control, _ lp: Loadpoint) -> Bool {
        if case .sending(let c) = model.command, c == control, model.commandLoadpointID == lp.id { return true }
        return false
    }

    // MARK: The car's battery now

    @ViewBuilder private func battery(_ lp: Loadpoint) -> some View {
        let level = model.socShown(lp)
        let unconfirmed = lp.socSource == "assumed" && model.socDraft[lp.id] == nil && model.acceptedSoc[lp.id] == nil
        ControlCard {
            HStack {
                Text("Battery now").font(.subheadline.weight(.semibold))
                Spacer()
                Text(unconfirmed ? "Not confirmed" : "\(Int(level)) %").font(Theme.number(15))
            }
            if site.canConfigure {
                Slider(value: Binding(
                    get: { model.socShown(lp) },
                    set: { model.socDraft[lp.id] = $0.rounded() }
                ), in: 0...100, step: 1) { editing in
                    guard !editing else { return }
                    let chosen = model.socShown(lp)
                    Task {
                        await model.setSoc(lp, pct: chosen)
                        if model.socDraft[lp.id] == chosen { model.socDraft[lp.id] = nil }
                    }
                }
                .disabled(sending)
                .accessibilityLabel("Car's current charge, percent")
            }
            if isSending(.soc, lp) {
                Hint("Sending charge level: \(Int(level)) %…")
            } else if let text = model.outcome(for: .soc, lp) {
                Hint(text)
            } else if site.canConfigure {
                Hint(EVText.socSource(lp))
            } else {
                Hint(lp.socSource == "assumed" ? "Battery level needs confirmation by someone who can control this charger." : lp.socSource == "vehicle" ? "Reported by the car." : "Estimated from energy delivered.")
            }
        }
    }

    // MARK: The car's battery size

    private func carBattery(_ lp: Loadpoint, capacityWh: Double) -> some View {
        DisclosureGroup("Car battery · \(EnergyFormat.short(capacityWh / 1000)) kWh") {
            VStack(alignment: .leading, spacing: 8) {
                Hint(lp.capacitySource == "default" ? "FTW is using a default size. Check it against your car." : "Used for estimates. Check this size if you use another car.")
                HStack {
                    Text("Usable battery size (kWh)").font(.callout)
                    Spacer()
                    TextField("kWh", text: Binding(
                        get: { capacityDraft[lp.id] ?? EnergyFormat.short(capacityWh / 1000) },
                        set: { capacityDraft[lp.id] = $0 }
                    ))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                    .accessibilityLabel("Usable battery size, kWh")
                }
                Button(capacityFailed[lp.id] == true ? "Try battery size again" : "Save battery size") {
                    Task { await setCapacity(lp) }
                }
                .buttonStyle(.outline)
                .disabled(capacityBusy == lp.id)
                Hint("Find the usable size in your car's specifications.", tone: Theme.fgMuted)
                if let note = capacityNote[lp.id] {
                    Hint(note, tone: capacityFailed[lp.id] == true ? Theme.importing : Theme.fgDim)
                }
            }
            .padding(.top, 6)
        }
        .font(.callout)
    }

    private func setCapacity(_ lp: Loadpoint) async {
        guard capacityBusy == nil else { return }
        let typed = (capacityDraft[lp.id] ?? "").replacingOccurrences(of: ",", with: ".")
        guard let kwh = Double(typed), (1...300).contains(kwh) else {
            capacityNote[lp.id] = "Enter the usable battery size from 1 to 300 kWh."
            capacityFailed[lp.id] = true
            return
        }
        capacityBusy = lp.id
        capacityFailed[lp.id] = false
        capacityNote[lp.id] = "Sending battery size…"
        do {
            capacityNote[lp.id] = try await model.setCapacity(lp, kwh: kwh)
            capacityDraft[lp.id] = nil
        } catch {
            capacityFailed[lp.id] = true
            capacityNote[lp.id] = (error as? BoxAPIError)?.help ?? "Battery size is not confirmed. Check the current value before trying again."
        }
        capacityBusy = nil
    }

    // MARK: Charge now

    @ViewBuilder private func chargeNow(_ lp: Loadpoint) -> some View {
        let range = EVText.current(lp)
        let chosen = model.ampsShown(lp)
        let paused = EVText.isPaused(lp)
        let holding = lp.manualActive && !lp.manualRestoreUnconfirmed && !paused
        ControlCard {
            if holding {
                HStack {
                    Text("Charge now is active").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(EVText.readout(lp, amps: chosen)).font(Theme.number(14))
                }
                if range.maxA > range.minA {
                    Slider(value: Binding(
                        get: { Double(model.ampsShown(lp)) },
                        set: { model.ampsDraft[lp.id] = Int($0.rounded()) }
                    ), in: Double(range.minA)...Double(range.maxA), step: 1) { editing in
                        guard !editing else { return }
                        let amps = model.ampsShown(lp)
                        Task {
                            await model.chargeNow(lp, amps: amps)
                            if model.ampsDraft[lp.id] == amps { model.ampsDraft[lp.id] = nil }
                        }
                    }
                    .disabled(sending)
                    .accessibilityLabel("Charging current")
                }
            }
            if lp.manualActive || lp.manualRestoreUnconfirmed {
                Button(paused || lp.manualRestoreUnconfirmed ? "Resume plan" : "Return to plan") {
                    Task { await model.stopCharging(lp) }
                }
                .buttonStyle(.outline)
                .disabled(sending)
            }
            if !lp.manualActive || paused || lp.manualRestoreUnconfirmed {
                Button(isSending(.hold, lp) ? "Sending charge request…" : "Charge now") {
                    Task { await model.chargeNow(lp, amps: chosen) }
                }
                .buttonStyle(.primary)
                .disabled(sending)
            }
            if !paused {
                Button("Pause charging") { Task { await model.pauseCharging(lp) } }
                    .buttonStyle(.quiet)
                    .disabled(sending)
            }
            if lp.manualRestoreUnconfirmed {
                Hint("Choose Charge now to request charging, Resume plan to use your goal, or Pause charging to request a stop.")
            } else if paused {
                Hint("The goal and solar rule wait until you resume the plan. Charge now starts immediately.")
            } else if lp.manualActive {
                Hint("Changes apply when you release the slider. Return to plan restores your schedule and solar settings.")
            } else {
                Hint("Starts at up to \(EVText.readout(lp, amps: chosen)). Ignores the goal and solar rule until you return to the plan or unplug.")
            }
            outcome(.hold, lp)
        }
    }

    // MARK: Your goal

    @ViewBuilder private func goalSection(_ lp: Loadpoint) -> some View {
        ControlCard {
            Text("Your goal").font(.headline)
            if lp.manualActive || lp.manualRestoreUnconfirmed {
                Hint(EVText.isPaused(lp) || lp.manualRestoreUnconfirmed ? "Resume the plan to use this goal. Edits apply then." : "Charge now overrides this goal. Edits apply when you return to the plan.")
            }
            if let draft = goal, draft.loadpointID == lp.id {
                goalEditor(lp)
            } else {
                if removedGoal == lp.id {
                    Hint(model.error != nil ? "Goal removed. Current charging status is unavailable." : "Goal removed.")
                }
                if let sentence = EVText.schedule(lp) {
                    HStack {
                        Text(sentence).font(.callout)
                        Spacer()
                        if site.canConfigure {
                            Button("Change goal") { beginEdit(lp) }.buttonStyle(.quiet)
                        }
                    }
                } else if model.loaded, site.canConfigure {
                    Button("Set a ready time") { beginEdit(lp) }.buttonStyle(.outline)
                }
                if let saveError { Hint(saveError, tone: Theme.importing) }
            }
            surplus(lp)
        }
    }

    @ViewBuilder private func goalEditor(_ lp: Loadpoint) -> some View {
        if let binding = Binding($goal) {
            DatePicker("Ready by", selection: binding.time, displayedComponents: .hourAndMinute)
            Toggle("Repeat on chosen days", isOn: binding.recurring)
            if binding.wrappedValue.recurring {
                HStack(spacing: 6) {
                    ForEach(Array(EVText.dayLabels.enumerated()), id: \.offset) { bit, day in
                        let on = binding.wrappedValue.days & (1 << bit) != 0
                        Button(day) { binding.wrappedValue.days ^= 1 << bit }
                            .font(.caption.weight(.semibold))
                            .padding(.vertical, 5)
                            .padding(.horizontal, 7)
                            .foregroundStyle(on ? Theme.onAccent : Theme.fgDim)
                            .background(on ? Theme.accent : Theme.surfaceSunken, in: Capsule())
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
            HStack {
                Text("Charge to")
                Slider(value: binding.socPct, in: 10...100, step: 5)
                    .accessibilityLabel("Target charge, percent")
                Text("\(Int(binding.wrappedValue.socPct)) %").font(Theme.number(14)).frame(width: 52, alignment: .trailing)
            }
            DisclosureGroup("Solar timing") {
                Toggle("Also use spare solar before the planned hours", isOn: Binding(
                    get: { binding.wrappedValue.surplusUnlockPct > 0 },
                    set: { binding.wrappedValue.surplusUnlockPct = $0 ? 50 : 0 }
                ))
                if binding.wrappedValue.surplusUnlockPct > 0 {
                    Stepper("Keep home battery above \(Int(binding.wrappedValue.surplusUnlockPct)) %", value: binding.surplusUnlockPct, in: 1...100, step: 5)
                }
            }
            .font(.callout)
            if lp.schedule == nil {
                Button("Use \(Int(binding.wrappedValue.socPct)) % by \(binding.wrappedValue.time.formatted(date: .omitted, time: .shortened))") {
                    Task { await saveGoal() }
                }
                .buttonStyle(.primary)
                .disabled(saving)
            }
            HStack {
                Button("Close goal settings") { goal = nil }.buttonStyle(.quiet).disabled(saving)
                Spacer()
                if lp.schedule != nil {
                    Button("Remove") { Task { await removeGoal(lp) } }.buttonStyle(.quiet).disabled(saving)
                }
            }
            Hint(saveError ?? (scheduleNote == "Schedule saved." && model.error != nil ? "Schedule saved. Current charging status is unavailable." : scheduleNote), tone: saveError != nil ? Theme.importing : Theme.fgDim)
            if saveError != nil {
                Button("Try again") { Task { await saveGoal() } }.buttonStyle(.quiet).disabled(saving)
            }
        }
    }

    private func beginEdit(_ lp: Loadpoint) {
        if removedGoal == lp.id { removedGoal = nil }
        saveError = nil
        scheduleNote = lp.schedule != nil ? "Changes apply as you make them." : "No goal set yet. Choose this goal, or change the level or time."
        let clock = lp.schedule.map { EVText.localTime(minuteUTC: $0.timeOfDayMinUTC) } ?? (hour: 7, minute: 0)
        let time = Calendar.current.date(bySettingHour: clock.hour, minute: clock.minute, second: 0, of: Date()) ?? Date()
        let wireDays = lp.schedule?.days ?? 0
        let target = lp.targetSocPct.flatMap { $0 >= 10 ? $0 : nil } ?? 80
        goal = GoalDraft(
            loadpointID: lp.id,
            time: time,
            recurring: lp.schedule?.recurring ?? false,
            days: wireDays == 0 ? 0x7F : wireDays & 0x7F,
            socPct: (lp.schedule?.socPct ?? target).rounded(),
            surplusUnlockPct: lp.schedule?.surplusUnlockPct ?? 0
        )
    }

    private func saveGoal() async {
        guard let draft = goal, !saving, let lp = model.points.first(where: { $0.id == draft.loadpointID }) else { return }
        let revision = goalRevision
        let parts = Calendar.current.dateComponents([.hour, .minute], from: draft.time)
        saving = true
        saveError = nil
        do {
            try await model.saveSchedule(lp, socPct: draft.socPct, hour: parts.hour ?? 7, minute: parts.minute ?? 0, recurring: draft.recurring, days: draft.days, surplusUnlockPct: draft.surplusUnlockPct)
            justSavedGoal = lp.id
            if revision == goalRevision { scheduleNote = "Schedule saved." }
        } catch {
            if revision == goalRevision {
                saveError = (error as? BoxAPIError)?.help ?? "Your box didn't confirm the change. Check the current settings before trying again."
            }
        }
        saving = false
        // An edit that landed while this one was on the wire goes out now.
        if revision != goalRevision, goal != nil { await saveGoal() }
    }

    private func removeGoal(_ lp: Loadpoint) async {
        saving = true
        saveError = nil
        scheduleNote = "Removing goal…"
        do {
            try await model.removeSchedule(lp)
            if justSavedGoal == lp.id { justSavedGoal = nil }
            removedGoal = lp.id
            goal = nil
        } catch {
            saveError = (error as? BoxAPIError)?.help ?? "Your box didn't confirm the change. Check the current settings before trying again."
        }
        saving = false
    }

    // MARK: Only spare solar

    @ViewBuilder private func surplus(_ lp: Loadpoint) -> some View {
        if site.canConfigure {
            let overridden = lp.manualActive || lp.manualRestoreUnconfirmed
            Toggle("Only spare solar", isOn: Binding(
                get: { model.surplusShown(lp) },
                set: { on in
                    model.surplusDraft[lp.id] = on
                    Task {
                        await model.setSurplusOnly(lp, on)
                        model.surplusDraft[lp.id] = nil
                    }
                }
            ))
            .disabled(sending || overridden)
            Hint(overridden
                ? (EVText.isPaused(lp) || lp.manualRestoreUnconfirmed ? "This rule resumes with the plan." : "Charge now overrides this rule. It resumes when you return to the plan.")
                : model.surplusShown(lp) ? "No grid or home battery. Your target may not be reached in time." : "The plan may use grid power to reach your target.")
            if isSending(.surplus, lp) {
                Hint("Asking your box…")
            } else {
                outcome(.surplus, lp)
            }
        } else if lp.surplusOnly {
            Hint("Charges from spare solar only.")
        }
    }

    // MARK: Home battery boost

    private func boostSection(_ lp: Loadpoint) -> some View {
        DisclosureGroup("Home battery boost") {
            VStack(alignment: .leading, spacing: 8) {
                if !lp.boostActive {
                    if let draft = boost, draft.loadpointID == lp.id {
                        Text("Let the house battery charge the car for a while.").font(.callout)
                        Stepper("Keep \(draft.reservePct) % in the house battery", value: Binding(
                            get: { boost?.reservePct ?? EVText.boostReserveDefaultPct },
                            set: { boost?.reservePct = $0 }
                        ), in: EVText.boostReserveMinPct...100, step: 5)
                        .disabled(sending)
                        HStack(spacing: 6) {
                            ForEach(EVText.boostDurations, id: \.seconds) { d in
                                let on = draft.durationS == d.seconds
                                Button(d.label) { boost?.durationS = d.seconds }
                                    .font(.caption.weight(.semibold))
                                    .padding(.vertical, 5)
                                    .padding(.horizontal, 9)
                                    .foregroundStyle(on ? Theme.onAccent : Theme.fgDim)
                                    .background(on ? Theme.accent : Theme.surfaceSunken, in: Capsule())
                                    .buttonStyle(.plain)
                                    .disabled(sending)
                            }
                        }
                        HStack {
                            Button(sending ? "Asking your box…" : "Start boost") {
                                Task {
                                    await model.boost(lp, reservePct: draft.reservePct, durationS: draft.durationS)
                                    if case .applied = model.command { boost = nil }
                                }
                            }
                            .buttonStyle(.primary)
                            .disabled(sending)
                            Button("Cancel") { boost = nil }.buttonStyle(.quiet).disabled(sending)
                        }
                        Hint("Ends when the time is up, the house battery reaches the reserve, or you stop it.")
                    } else if lp.manualActive {
                        Hint("Available after returning to the plan.")
                    } else if model.surplusShown(lp) {
                        Hint("Not while the charger uses spare solar only.")
                    } else {
                        Button("Boost from the house battery") {
                            boost = BoostDraft(loadpointID: lp.id, reservePct: EVText.boostReserveDefaultPct, durationS: EVText.boostDurationDefault)
                        }
                        .buttonStyle(.outline)
                    }
                    outcome(.boost, lp)
                }
            }
            .padding(.top, 6)
        }
        .font(.callout)
    }

    // MARK: Charging ahead

    @ViewBuilder private func windows(_ lp: Loadpoint) -> some View {
        let planReady = !lp.manualActive && !lp.planPending && !model.planPending && !lp.planOutdated && !model.planOutdated
        let ahead = model.windows[lp.id] ?? []
        if planReady, !stale, !ahead.isEmpty {
            ControlCard {
                Kicker("Charging ahead")
                ForEach(ahead) { w in
                    HStack {
                        Text("\(EVText.clock(w.fromMs))–\(EVText.clock(w.toMs))").font(Theme.number(13, weight: .regular))
                        Spacer()
                        if let wh = w.energyWh {
                            Text("\((wh / 1000).formatted(.number.precision(.fractionLength(0...1)))) kWh").font(.footnote)
                        } else if let peak = w.peakW {
                            Text("up to \(PowerFormat.text(peak))").font(.footnote)
                        }
                    }
                }
            }
        } else if planReady, model.planMissing {
            Hint("Charging times aren't readable right now.")
        }
    }
}

/// A group of related controls, set off like a card.
private struct ControlCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.line, lineWidth: 1))
    }
}
