import FTWDemo
import FTWKit
import SwiftUI

/// The car: how full it is and who says so, the goal and whether it makes
/// it, and Charge now, Pause and Back to the plan. Every tap is followed to
/// the box's answer, on screen.
struct CarView: View {
    let app: AppModel
    let home: HomeModels
    let id: String?
    @State private var correcting = false
    @State private var editingGoal = false

    private var model: LoadpointsModel { home.loadpoints }
    private var site: SiteModel { home.site }
    private var canControl: Bool { site.canConfigure }

    private var lp: Loadpoint? {
        id.flatMap { want in model.points.first { $0.id == want } } ?? model.points.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let lp {
                    status(lp)
                    level(lp)
                    goal(lp)
                    if lp.pluggedIn, canControl { controls(lp) }
                    if app.isDemo { demo(lp) }
                } else if model.loaded {
                    Hint(L("This box has no charger."))
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(16)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.surface)
        .navigationTitle(L("Car"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { try? await model.loadChargers() }
        .onAppear {
            model.activate()
            model.watchPlan()
        }
        .onDisappear {
            model.unwatchPlan()
            model.deactivate()
        }
        .sheet(isPresented: $editingGoal) {
            if let lp { GoalEditor(model: model, lp: lp) }
        }
    }

    // MARK: What it does now

    @ViewBuilder private func status(_ lp: Loadpoint) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(EVText.status(lp, zone: model.zone))
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.fg)
                .fixedSize(horizontal: false, vertical: true)
            if let session = EVText.session(lp) { Hint(session) }
            if model.stale {
                Hint(model.error ?? model.readAtMs.map { AppWords.format("Last known %@.", AppWords.clock($0, zone: model.zone)) } ?? L("Waiting for your box."), tone: Theme.generation)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: How full is it?

    @ViewBuilder private func level(_ lp: Loadpoint) -> some View {
        let level = model.level(lp)
        let assumed = level?.origin == .assumed || level?.origin == .unconfirmed
        Card {
            Kicker(L("How full is the car?"))
            if let level {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) { levelFigure(level, assumed: assumed) }
                    VStack(alignment: .leading, spacing: 6) { levelFigure(level, assumed: assumed) }
                }
                // The badge says FTW assumes; the line says what to do.
                Text(level.origin == .assumed && canControl ? L("Nobody has told FTW the car's level yet. Choose it below.") : EVText.origin(level, zone: model.zone))
                    .font(.subheadline)
                    .foregroundStyle(assumed ? Theme.fg : Theme.fgDim)
                    .fixedSize(horizontal: false, vertical: true)
                if canControl {
                    if level.origin == .car, !correcting {
                        Button(L("Correct the level")) { correcting = true }.buttonStyle(.quiet)
                        Hint(L("Only correct it if the car shows something else."))
                    } else {
                        LevelChips(current: level.pct) { pct in
                            Task { await model.setLevel(lp, pct: pct) }
                        }
                    }
                }
            } else if !lp.pluggedIn {
                Text(L("Plug in the car to tell FTW its level."))
                    .font(.subheadline)
                    .foregroundStyle(Theme.fg)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L("Level unknown")).font(.headline)
            }
            if let outcome = model.outcome(level: lp) {
                ReceiptView(outcome: outcome)
            }
        }
        .overlay(alignment: .leading) {
            if assumed {
                UnevenRoundedRectangle(topLeadingRadius: Theme.radius, bottomLeadingRadius: Theme.radius)
                    .fill(Theme.generation)
                    .frame(width: 4)
            }
        }
    }

    @ViewBuilder private func levelFigure(_ level: EVText.Level, assumed: Bool) -> some View {
        Text(AppWords.percent(level.pct))
            .font(Theme.percent(.largeTitle, weight: .bold))
            .foregroundStyle(assumed ? Theme.fgMuted : Theme.fg)
            .contentTransition(.numericText())
        if assumed {
            Text(L("FTW assumes"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Theme.generation, in: Capsule())
                .fixedSize()
        }
    }

    // MARK: The goal

    @ViewBuilder private func goal(_ lp: Loadpoint) -> some View {
        Card {
            Kicker(L("Goal"))
            if let s = lp.schedule {
                Text(EVText.goal(s, at: Date(timeIntervalSince1970: site.nowMs / 1000), zone: model.zone))
                    .font(.headline)
                    .foregroundStyle(Theme.fg)
                    .fixedSize(horizontal: false, vertical: true)
                if let next = EVText.nextGoal(lp, nowMs: site.nowMs, zone: model.zone) {
                    Hint(next)
                }
                if lp.pluggedIn {
                    if let r = model.readiness(lp) {
                        Readiness(readiness: r, text: EVText.readiness(r, level: model.level(lp), nowMs: site.nowMs, zone: model.zone))
                    }
                    if let plan = EVText.plan(lp, windows: model.windows[lp.id] ?? lp.planWindows, nowMs: site.nowMs, zone: model.zone) {
                        Hint(plan)
                    }
                }
                if canControl {
                    Button(L("Change")) { editingGoal = true }.buttonStyle(.outline)
                }
            } else {
                Text(L("No goal yet. Without one, FTW only charges from spare solar."))
                    .font(.subheadline)
                    .foregroundStyle(Theme.fg)
                    .fixedSize(horizontal: false, vertical: true)
                if canControl {
                    Button(AppWords.format("Use %@", EVText.suggestedGoalText())) {
                        let g = EVText.suggestedGoal
                        Task { await model.saveGoal(lp, socPct: g.socPct, clock: g.clock, recurring: true, days: g.days, zone: model.zone) }
                    }
                    .buttonStyle(.primary)
                    Button(L("Change")) { editingGoal = true }.buttonStyle(.quiet)
                }
            }
            if let save = model.goalSave[lp.id], !editingGoal {
                Hint(LoadpointsModel.goalText(save), tone: { if case .failed = save { return Theme.importing }; return Theme.fgDim }())
            }
        }
    }

    // MARK: Charge now, Pause, Back to the plan

    @ViewBuilder private func controls(_ lp: Loadpoint) -> some View {
        let paused = EVText.isPaused(lp)
        let holding = lp.manualActive && !paused
        let busy = model.holdSending(lp)
        Card {
            if holding || paused {
                Button(L("Back to the plan")) { Task { await model.backToPlan(lp) } }
                    .buttonStyle(.primary)
                    .disabled(busy)
            }
            if !holding {
                Button(L("Charge now")) { Task { await model.chargeNow(lp) } }
                    .buttonStyle(paused ? .secondary : .primary)
                    .disabled(busy)
            }
            if !paused {
                Button(L("Pause")) { Task { await model.pause(lp) } }
                    .buttonStyle(.secondary)
                    .disabled(busy)
            }
            Hint(L("Charge now runs until you go back to the plan or unplug."))
            if let outcome = model.outcome(hold: lp) {
                ReceiptView(outcome: outcome)
            }
        }
    }

    // MARK: The demo's own cable

    @ViewBuilder private func demo(_ lp: Loadpoint) -> some View {
        Card {
            Kicker(L("Demo"))
            Button(L(lp.pluggedIn ? "Unplug the car" : "Plug in the car")) {
                SimulatedBox.current?.setCarPluggedIn(!lp.pluggedIn)
                model.reread()
            }
            .buttonStyle(.outline)
            Hint(L("The demo plugs in a car FTW cannot read, so FTW assumes 20 %."))
        }
    }
}

/// 20, 40, 60, 80 and a step of five either way. Each tap goes to the box
/// at once; there is no Save.
struct LevelChips: View {
    let current: Double
    let choose: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 68), spacing: 8)], spacing: 8) {
                ForEach(EVText.levelPresets, id: \.self) { pct in
                    chip(AppWords.percent(pct), selected: current.rounded() == pct, label: AppWords.percent(pct)) { choose(pct) }
                }
            }
            HStack(spacing: 8) {
                chip("−5", selected: false, label: AppWords.format("Set %@", AppWords.percent(EVText.stepped(current, up: false)))) { choose(EVText.stepped(current, up: false)) }
                chip("+5", selected: false, label: AppWords.format("Set %@", AppWords.percent(EVText.stepped(current, up: true)))) { choose(EVText.stepped(current, up: true)) }
            }
        }
    }

    private func chip(_ text: String, selected: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(Theme.percent(.body))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(selected ? Theme.onAccent : Theme.fg)
                .background(selected ? Theme.accent : Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(Theme.line, lineWidth: selected ? 0 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Whether the car makes its goal, in the plan's own numbers.
struct Readiness: View {
    let readiness: EVText.Readiness
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: short ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(short ? Theme.generation : Theme.exporting)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.fg)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var short: Bool {
        if case .short = readiness { return true }
        return false
    }
}

/// The receipt under a control: sent, received, done, and one sentence.
struct ReceiptView: View {
    let outcome: EVText.Outcome

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { marks }
                VStack(alignment: .leading, spacing: 4) { marks }
            }
            Text(outcome.text)
                .font(.footnote.weight(.medium))
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
        .accessibilityElement(children: .combine)
        .animation(.default, value: outcome)
    }

    @ViewBuilder private var marks: some View {
        mark(L("Sent"), outcome.sent)
        mark(L("Received"), outcome.received)
        mark(L("Done"), outcome.done)
    }

    private func mark(_ label: String, _ state: EVText.Outcome.Mark) -> some View {
        HStack(spacing: 4) {
            switch state {
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.exporting)
            case .active: ProgressView().controlSize(.mini)
            case .waiting: Image(systemName: "circle").foregroundStyle(Theme.fgMuted)
            case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.importing)
            }
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(state == .waiting ? Theme.fgMuted : Theme.fg)
        }
    }

    private var color: Color {
        switch outcome.tone {
        case .working: return Theme.fgDim
        case .done: return Theme.exporting
        case .warning: return Theme.generation
        case .failed: return Theme.importing
        }
    }
}
