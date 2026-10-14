import FTWDemo
import FTWKit
import SwiftUI

/// The car, in the node view's material: the power now as the hero, with
/// the car's level, its meter and where the level comes from beside it;
/// whether that is live and from which charger; the car's plan for the
/// hours ahead with the price under it; then the level and the goal. Plan,
/// Charge now and Pause sit in a glass bar at the foot, where the thumb is
/// and in the same places whatever the car does, with the receipt log
/// under them: SENT ▸ ACCEPTED ▸ MEASURED ▸ CONFIRMED, each slot lit on
/// its own evidence. The screen shows intent at once and a result only
/// once the box has confirmed it.
struct CarView: View {
    let app: AppModel
    let home: HomeModels
    let id: String?
    @State private var editingGoal = false
    @State private var scrub = ScrubModel()
    @State private var trace = NodeTraceModel()
    @State private var text = PeriodText()

    private var model: LoadpointsModel { home.loadpoints }

    private var lp: Loadpoint? {
        id.flatMap { want in model.points.first { $0.id == want } } ?? model.points.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let lp {
                    // The hours ahead are a plan, not a reading: a finger on
                    // the plan leaves the hero on now.
                    NodeHero(site: home.site, node: .car, home: home, trace: trace, scrub: scrub, timebase: .ahead, text: text)
                        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                        .padding(.horizontal, 20)
                    NodeStatusRow(site: home.site, node: .car)
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                    StatusLines(lp: lp, model: model, site: home.site)
                        .padding(.horizontal, 20)
                        .padding(.top, 6)
                    CarPlan(lp: lp, model: model, home: home, scrub: scrub, text: text)
                        .padding(.top, 24)
                    // Drawn from what the last launch kept; inert until the
                    // box has spoken in this session.
                    LevelBlock(lp: lp, model: model, canControl: home.site.canConfigure)
                        .disabled(!home.site.heardFromBox)
                        .padding(.horizontal, 20)
                        .padding(.top, 28)
                    GoalBlock(lp: lp, model: model, site: home.site, canControl: home.site.canConfigure, editing: $editingGoal)
                        .disabled(!home.site.heardFromBox)
                        .padding(.horizontal, 20)
                        .padding(.top, 28)
                    if app.isDemo {
                        DemoBlock(lp: lp, model: model)
                            .padding(.horizontal, 20)
                            .padding(.top, 28)
                    }
                } else if model.loaded {
                    Text(L("This box has no charger."))
                        .foregroundStyle(Theme.ink2)
                        .padding(20)
                } else {
                    Placeholder()
                        .padding(.horizontal, 20)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.ground)
        .safeAreaBar(edge: .bottom) {
            if let lp, lp.pluggedIn, home.site.canConfigure {
                ControlBar(lp: lp, model: model)
                    .disabled(!home.site.heardFromBox)
            }
        }
        .scrollEdgeEffectStyle(.hard, for: .bottom)
        .animation(Theme.spring, value: model.points)
        .navigationTitle(L("Car"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { try? await model.loadChargers() }
        .onAppear {
            model.activate()
            model.watchPlan()
            home.prices.activate()
            LaunchClock.mark("first content")
        }
        .onDisappear {
            model.unwatchPlan()
            model.deactivate()
            home.prices.deactivate()
        }
        .sheet(isPresented: $editingGoal) {
            if let lp { GoalEditor(model: model, lp: lp) }
        }
    }
}

// MARK: What it does now

/// Under the status line: what the charger does in words, this plug-in's
/// energy, and when the box last said so once that is old.
private struct StatusLines: View {
    let lp: Loadpoint
    let model: LoadpointsModel
    let site: SiteModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(EVText.status(lp, zone: model.zone))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.ink)
                .contentTransition(.opacity)
                .fixedSize(horizontal: false, vertical: true)
            if let session = EVText.session(lp) {
                Text(session)
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink2)
                    .contentTransition(.numericText())
            }
            if let note {
                Text(note.text)
                    .font(.footnote)
                    .foregroundStyle(note.warn ? Theme.alarm : Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// When the box said it: plainly when out of date, quietly when it is
    /// only a while ago. The chargers are not read on a timer.
    private var note: (text: String, warn: Bool)? {
        guard let at = model.readAtMs else { return model.stale ? (L("Waiting for your box."), true) : nil }
        if model.stale { return (model.error ?? AppWords.format("Last known %@.", AppWords.clock(at, zone: model.zone)), true) }
        if site.minuteMs - at > 60_000 { return (AppWords.format("Read at %@", AppWords.clock(at, zone: model.zone)), false) }
        return nil
    }
}

// MARK: The plan

/// The car's plan for the hours ahead, as the car node's Ahead draws it:
/// its charging as ghost bars, the price under the same slots in eight
/// levels, and a finger that reads each slot. Under it, the plan in one
/// sentence, or the slot under the finger.
private struct CarPlan: View {
    let lp: Loadpoint
    let model: LoadpointsModel
    let home: HomeModels
    let scrub: ScrubModel
    let text: PeriodText
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Kicker(L("Plan"))
                .padding(.horizontal, 20)
            AheadChartArea(site: home.site, node: .car, home: home, scrub: scrub, text: text)
                .frame(height: 170)
                .padding(.horizontal, 4)
            ZStack(alignment: .topLeading) {
                Text(verbatim: "\n")
                Text(line).accessibilityIdentifier("car.plan.line")
            }
            .font(.subheadline)
            .foregroundStyle(Theme.ink2)
            .lineLimit(typeSize.isAccessibilitySize ? 5 : 2, reservesSpace: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transaction { $0.animation = nil }
            .padding(.horizontal, 20)
        }
    }

    private var line: String {
        if let under = text.text(scrub) { return under }
        return PlanText.car(model.windows[lp.id] ?? lp.planWindows, nowMs: home.site.minuteMs, zone: model.zone)
    }
}

// MARK: How full is it?

/// How full the car is, told by tap. The level itself is the hero's; here
/// is where it comes from, the chips that tell FTW, and the level's
/// receipt.
private struct LevelBlock: View {
    let lp: Loadpoint
    let model: LoadpointsModel
    let canControl: Bool
    @State private var correcting = false

    var body: some View {
        let level = model.level(lp)
        let assumed = level?.origin == .assumed || level?.origin == .unconfirmed
        VStack(alignment: .leading, spacing: 10) {
            Kicker(L("How full is the car?"))
            if let level {
                // The hero says FTW assumes; the line says what to do.
                Text(level.origin == .assumed && canControl ? L("Nobody has told FTW the car's level yet. Choose it below.") : EVText.origin(level, zone: model.zone))
                    .font(.subheadline)
                    .foregroundStyle(assumed ? Theme.ink : Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                if canControl {
                    if level.origin == .car, !correcting {
                        Button(L("Correct the level")) {
                            withAnimation(Theme.spring) { correcting = true }
                        }
                        .buttonStyle(.glass)
                    } else {
                        LevelChips(current: model.chosenLevel(lp) ?? level.pct) { pct in
                            Task { await model.setLevel(lp, pct: pct) }
                        }
                    }
                }
            } else if !lp.pluggedIn {
                Text(L("Plug in the car to tell FTW its level."))
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
            } else {
                Text(L("Level unknown")).font(.headline).foregroundStyle(Theme.ink)
            }
            if let receipt = model.receipt(level: lp), let outcome = model.outcome(level: lp) {
                CommandReceipt(receipt: receipt, outcome: outcome)
                    .transition(.opacity)
            }
            if level?.origin == .car, !correcting, canControl {
                Text(L("Only correct it if the car shows something else."))
                    .font(.footnote)
                    .foregroundStyle(Theme.ink3)
            }
        }
        .animation(Theme.spring, value: model.receipt(level: lp))
        .sensoryFeedback(.selection, trigger: model.chosenLevel(lp))
        .sensoryFeedback(trigger: model.outcome(level: lp)?.tone) { _, tone in Self.feedback(tone) }
    }

    static func feedback(_ tone: EVText.Outcome.Tone?) -> SensoryFeedback? {
        switch tone {
        case .done?: return .success
        case .warning?: return .warning
        case .failed?: return .error
        default: return nil
        }
    }
}

/// 20, 40, 60, 80 and a step of five either way. Each tap goes to the box
/// at once; there is no Save.
struct LevelChips: View {
    let current: Double
    let choose: (Double) -> Void
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        VStack(spacing: 8) {
            // Four across, two at the accessibility sizes: a chip never wraps.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: textSize.isAccessibilitySize ? 2 : 4), spacing: 8) {
                ForEach(EVText.levelPresets, id: \.self) { pct in
                    chip(AppWords.percent(pct), selected: current.rounded() == pct, label: AppWords.percent(pct)) { choose(pct) }
                }
            }
            HStack(spacing: 8) {
                let down = EVText.stepped(current, up: false)
                let up = EVText.stepped(current, up: true)
                chip("−5", selected: false, label: AppWords.format("Set %@", AppWords.percent(down))) { choose(down) }
                chip("+5", selected: false, label: AppWords.format("Set %@", AppWords.percent(up))) { choose(up) }
            }
        }
        .padding(.vertical, 4)
        .animation(Theme.spring, value: current)
    }

    @ViewBuilder private func chip(_ text: String, selected: Bool, label: String, action: @escaping () -> Void) -> some View {
        let title = Text(text)
            .font(.body.weight(.semibold).monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
        // The chosen one prominent, in ink; the others in plain glass.
        Group {
            if selected {
                Button(action: action) { title.foregroundStyle(Theme.ground) }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.ink)
            } else {
                Button(action: action) { title.foregroundStyle(Theme.ink) }
                    .buttonStyle(.glass)
            }
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: The goal

private struct GoalBlock: View {
    let lp: Loadpoint
    let model: LoadpointsModel
    let site: SiteModel
    let canControl: Bool
    @Binding var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Kicker(L("Goal"))
            if model.fromCache {
                // The cache keeps no goal; say nothing rather than "none".
                Text(EVText.suggestedGoalText())
                    .font(.headline)
                    .redacted(reason: .placeholder)
            } else if let s = lp.schedule {
                Text(EVText.goal(s, at: Date(timeIntervalSince1970: site.minuteMs / 1000), zone: model.zone))
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let next = EVText.nextGoal(lp, nowMs: site.minuteMs, zone: model.zone) {
                    Hint(next, tone: Theme.ink2)
                }
                if lp.pluggedIn, let r = model.readiness(lp) {
                    Readiness(readiness: r, text: EVText.readiness(r, level: model.level(lp), nowMs: site.minuteMs, zone: model.zone))
                }
                if canControl {
                    Button(L("Change")) { editing = true }
                        .buttonStyle(.glass)
                }
            } else {
                Text(L("No goal yet. Without one, FTW only charges from spare solar."))
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if canControl {
                    HStack(spacing: 8) {
                        Button {
                            let g = EVText.suggestedGoal
                            Task { await model.saveGoal(lp, socPct: g.socPct, clock: g.clock, recurring: true, days: g.days, zone: model.zone) }
                        } label: {
                            Text(AppWords.format("Use %@", EVText.suggestedGoalText()))
                                .lineLimit(2)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(Theme.ink)
                        Button(L("Change")) { editing = true }
                            .buttonStyle(.glass)
                    }
                    .controlSize(.large)
                }
            }
            if let save = model.goalSave[lp.id], !editing {
                Hint(LoadpointsModel.goalText(save), tone: { if case .failed = save { return Theme.alarm }; return Theme.ink2 }())
            }
        }
        .sensoryFeedback(trigger: model.goalSave[lp.id]) { _, save in
            switch save {
            case .saved?, .removed?: return .success
            case .failed?: return .error
            default: return nil
            }
        }
    }
}

/// Whether the car makes its goal, in the plan's own numbers.
struct Readiness: View {
    let readiness: EVText.Readiness
    let text: String

    var body: some View {
        Label {
            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            // A plan is not a confirmation: in ink when it makes it, alarm
            // when it does not.
            Image(systemName: short ? "exclamationmark.triangle.fill" : "checkmark.circle")
                .foregroundStyle(short ? Theme.alarm : Theme.ink2)
                .contentTransition(.symbolEffect(.replace))
        }
        .accessibilityElement(children: .combine)
    }

    private var short: Bool {
        if case .short = readiness { return true }
        return false
    }
}

// MARK: Charge now, Pause, Back to the plan

/// Plan · Charge now · Pause, always in these places, in one glass group.
/// The one the box reports is chosen; the one asked for turns while it
/// travels; a tap on the chosen one does nothing. Under them the receipt
/// log has room of its own, reserved, so nothing moves when it arrives.
private struct ControlBar: View {
    let lp: Loadpoint
    let model: LoadpointsModel
    @Environment(\.dynamicTypeSize) private var typeSize

    enum Choice: CaseIterable, Identifiable {
        case plan, chargeNow, pause
        var id: Self { self }

        var title: String {
            switch self {
            case .plan: return L("Plan")
            case .chargeNow: return L("Charge now")
            case .pause: return L("Pause")
            }
        }

        var symbol: String {
            switch self {
            case .plan: return "calendar.badge.clock"
            case .chargeNow: return "bolt.fill"
            case .pause: return "pause.fill"
            }
        }
    }

    /// What the box reports the charger is doing.
    private var current: Choice {
        if EVText.isPaused(lp) { return .pause }
        return lp.manualActive ? .chargeNow : .plan
    }

    /// The choice on its way to the box.
    private var asked: Choice? {
        guard let step = model.holdStep[lp.id], !step.settled else { return nil }
        switch step.ask {
        case .chargeNow: return .chargeNow
        case .pause: return .pause
        case .resume: return .plan
        case .level: return nil
        }
    }

    var body: some View {
        let current = self.current
        let asked = self.asked
        let receipt = model.receipt(hold: lp)
        VStack(alignment: .leading, spacing: 10) {
            // Side by side; at the accessibility sizes one under the other,
            // so no name is cut.
            let stacked = typeSize.isAccessibilitySize
            let layout = stacked ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 8))
            GlassEffectContainer(spacing: 8) {
                layout {
                    ForEach(Choice.allCases) { c in
                        button(c, chosen: asked == nil && c == current, waiting: asked == c, stacked: stacked)
                    }
                }
            }
            ZStack(alignment: .topLeading) {
                ReceiptSpace()
                if let receipt, let outcome = model.outcome(hold: lp) {
                    CommandReceipt(receipt: receipt, outcome: outcome)
                        .transition(.opacity)
                } else {
                    Text(L("Charge now runs until you go back to the plan or unplug."))
                        .font(.footnote)
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .animation(Theme.spring, value: receipt)
        .animation(Theme.spring, value: current)
        // Commands answer once, when the box says what it did.
        .sensoryFeedback(trigger: model.outcome(hold: lp)?.tone) { _, tone in LevelBlock.feedback(tone) }
        // A bar of controls: whole words before the largest letters.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    @ViewBuilder private func button(_ c: Choice, chosen: Bool, waiting: Bool, stacked: Bool) -> some View {
        // The chosen one prominent, in ink; the others in plain glass.
        if chosen {
            plain(c, chosen: true, waiting: waiting, stacked: stacked)
                .buttonStyle(.glassProminent)
                .tint(Theme.ink)
        } else {
            plain(c, chosen: false, waiting: waiting, stacked: stacked)
                .buttonStyle(.glass)
        }
    }

    private func plain(_ c: Choice, chosen: Bool, waiting: Bool, stacked: Bool) -> some View {
        Button {
            guard !chosen, !model.holdSending(lp) else { return }
            Task {
                switch c {
                case .plan: await model.backToPlan(lp)
                case .chargeNow: await model.chargeNow(lp)
                case .pause: await model.pause(lp)
                }
            }
        } label: {
            let layout = stacked ? AnyLayout(HStackLayout(spacing: 10)) : AnyLayout(VStackLayout(spacing: 4))
            layout {
                Image(systemName: waiting ? "circle.dotted" : c.symbol)
                    .symbolEffect(.rotate, options: .repeating, isActive: waiting)
                    .contentTransition(.symbolEffect(.replace))
                // One line in every state, so the chosen button, with its
                // wider padding, is no taller than the others.
                Text(c.title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(chosen ? Theme.ground : Theme.ink)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.vertical, 4)
        }
        .disabled(waiting)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityValue(waiting ? L("Sending to your box…") : "")
        .accessibilityIdentifier("car.control.\(c)")
    }
}

/// The receipt log and one sentence under it: what the box did, or, in
/// alarm red, why not.
struct CommandReceipt: View {
    let receipt: ReceiptLog
    let outcome: EVText.Outcome

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ReceiptRow(receipt: receipt)
                .accessibilityIdentifier("car.receipt")
            Text(outcome.text)
                .font(.footnote.weight(.medium))
                .foregroundStyle(color)
                .contentTransition(.opacity)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch outcome.tone {
        case .working: return Theme.ink2
        case .done: return Theme.live
        case .warning, .failed: return Theme.alarm
        }
    }
}

/// The room a receipt takes, its line and two lines of text, laid out as
/// `CommandReceipt` lays them out and left empty.
private struct ReceiptSpace: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ReceiptRow(receipt: ReceiptLog())
            Text(verbatim: "\n").font(.footnote.weight(.medium))
        }
        .hidden()
        .accessibilityHidden(true)
    }
}

// MARK: The demo's own cable

private struct DemoBlock: View {
    let lp: Loadpoint
    let model: LoadpointsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Kicker(L("Demo"))
            Button(L(lp.pluggedIn ? "Unplug the car" : "Plug in the car")) {
                SimulatedBox.current?.setCarPluggedIn(!lp.pluggedIn)
                model.reread()
            }
            .buttonStyle(.glass)
            Text(L("The demo plugs in a car FTW cannot read, so FTW assumes 20 %."))
                .font(.footnote)
                .foregroundStyle(Theme.ink3)
        }
    }
}

/// Before the first answer and with nothing cached: the shape of the
/// screen, not a spinner.
private struct Placeholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("0,0 kW").font(Theme.figure(60))
            Text("Plugged in · charges at 01:00").font(.subheadline)
            Text("80 % by 07:00 on weekdays").font(.headline)
        }
        .foregroundStyle(Theme.ink3)
        .redacted(reason: .placeholder)
    }
}
