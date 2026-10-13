import FTWDemo
import FTWKit
import SwiftUI

/// The car: how full it is and who says so, the goal and whether it makes
/// it, and Plan, Charge now and Pause in a bar at the foot, where the thumb
/// is and in the same places whatever the car does. Every tap shows "Sent"
/// at once, then the box's receipt, then the outcome; the screen shows
/// intent at once and a result only once the box has confirmed it.
struct CarView: View {
    let app: AppModel
    let home: HomeModels
    let id: String?
    @State private var editingGoal = false

    private var model: LoadpointsModel { home.loadpoints }

    private var lp: Loadpoint? {
        id.flatMap { want in model.points.first { $0.id == want } } ?? model.points.first
    }

    var body: some View {
        List {
            if let lp {
                StatusSection(lp: lp, model: model, site: home.site)
                LevelSection(lp: lp, model: model, canControl: home.site.canConfigure)
                GoalSection(lp: lp, model: model, site: home.site, canControl: home.site.canConfigure, editing: $editingGoal)
                if app.isDemo { DemoSection(lp: lp, model: model) }
            } else if model.loaded {
                Section { Text(L("This box has no charger.")) }
                    .listRowBackground(Theme.surfaceRaised)
            } else {
                PlaceholderSections()
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.surface)
        .safeAreaBar(edge: .bottom) {
            if let lp, lp.pluggedIn, home.site.canConfigure {
                ControlBar(lp: lp, model: model)
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
            LaunchClock.mark("first content")
        }
        .onDisappear {
            model.unwatchPlan()
            model.deactivate()
        }
        .sheet(isPresented: $editingGoal) {
            if let lp { GoalEditor(model: model, lp: lp) }
        }
    }
}

// MARK: What it does now

private struct StatusSection: View {
    let lp: Loadpoint
    let model: LoadpointsModel
    let site: SiteModel

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(EVText.status(lp, zone: model.zone))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.fg)
                    .contentTransition(.numericText())
                    .fixedSize(horizontal: false, vertical: true)
                if let session = EVText.session(lp) {
                    Hint(session).contentTransition(.numericText())
                }
                if let note {
                    Hint(note.text, tone: note.warn ? Theme.alarm : Theme.fgMuted)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
        .listRowBackground(Theme.surfaceRaised)
    }

    /// When the box said it: plainly when out of date, quietly when it is
    /// only a while ago. The chargers are not read on a timer.
    private var note: (text: String, warn: Bool)? {
        guard let at = model.readAtMs else { return model.stale ? (L("Waiting for your box."), true) : nil }
        if model.stale { return (model.error ?? AppWords.format("Last known %@.", AppWords.clock(at, zone: model.zone)), true) }
        if site.nowMs - at > 60_000 { return (AppWords.format("Read at %@", AppWords.clock(at, zone: model.zone)), false) }
        return nil
    }
}

// MARK: How full is it?

private struct LevelSection: View {
    let lp: Loadpoint
    let model: LoadpointsModel
    let canControl: Bool
    @State private var correcting = false

    var body: some View {
        let level = model.level(lp)
        let assumed = level?.origin == .assumed || level?.origin == .unconfirmed
        Section {
            if let level {
                VStack(alignment: .leading, spacing: 6) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) { figure(level, assumed: assumed) }
                        VStack(alignment: .leading, spacing: 6) { figure(level, assumed: assumed) }
                    }
                    // The badge says FTW assumes; the line says what to do.
                    Text(level.origin == .assumed && canControl ? L("Nobody has told FTW the car's level yet. Choose it below.") : EVText.origin(level, zone: model.zone))
                        .font(.subheadline)
                        .foregroundStyle(assumed ? Theme.fg : Theme.fgDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
                if canControl {
                    if level.origin == .car, !correcting {
                        Button(L("Correct the level")) {
                            withAnimation(Theme.spring) { correcting = true }
                        }
                    } else {
                        LevelChips(current: model.chosenLevel(lp) ?? level.pct) { pct in
                            Task { await model.setLevel(lp, pct: pct) }
                        }
                    }
                }
            } else if !lp.pluggedIn {
                Text(L("Plug in the car to tell FTW its level."))
                    .font(.subheadline)
                    .foregroundStyle(Theme.fg)
            } else {
                Text(L("Level unknown")).font(.headline)
            }
            if let outcome = model.outcome(level: lp) {
                ReceiptView(outcome: outcome)
            }
        } header: {
            Text(L("How full is the car?"))
        } footer: {
            if level?.origin == .car, !correcting, canControl {
                Text(L("Only correct it if the car shows something else."))
            }
        }
        .listRowBackground(Theme.surfaceRaised)
        .sensoryFeedback(.selection, trigger: model.chosenLevel(lp))
        .sensoryFeedback(trigger: model.outcome(level: lp)?.tone) { _, tone in Self.feedback(tone) }
    }

    @ViewBuilder private func figure(_ level: EVText.Level, assumed: Bool) -> some View {
        Text(AppWords.percent(level.pct))
            .font(Theme.percent(.largeTitle, weight: .bold))
            .foregroundStyle(assumed ? Theme.fgMuted : Theme.fg)
            .contentTransition(.numericText(value: level.pct))
            .animation(Theme.spring, value: level.pct)
        if assumed {
            Text(L("FTW assumes"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Theme.ink2, in: Capsule())
                .fixedSize()
        }
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
            .font(Theme.percent(.body))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
        Group {
            if selected {
                Button(action: action) { title.foregroundStyle(Theme.onAccent) }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accentFill)
            } else {
                Button(action: action) { title.foregroundStyle(Theme.fg) }
                    .buttonStyle(.bordered)
                    .tint(Theme.fgMuted)
            }
        }
        .buttonBorderShape(.roundedRectangle(radius: Theme.radiusSmall))
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: The goal

private struct GoalSection: View {
    let lp: Loadpoint
    let model: LoadpointsModel
    let site: SiteModel
    let canControl: Bool
    @Binding var editing: Bool

    var body: some View {
        Section {
            if model.fromCache {
                // The cache keeps no goal; say nothing rather than "none".
                Text(EVText.suggestedGoalText())
                    .font(.headline)
                    .redacted(reason: .placeholder)
            } else if let s = lp.schedule {
                VStack(alignment: .leading, spacing: 4) {
                    Text(EVText.goal(s, at: Date(timeIntervalSince1970: site.nowMs / 1000), zone: model.zone))
                        .font(.headline)
                        .foregroundStyle(Theme.fg)
                        .fixedSize(horizontal: false, vertical: true)
                    if let next = EVText.nextGoal(lp, nowMs: site.nowMs, zone: model.zone) {
                        Hint(next)
                    }
                }
                .padding(.vertical, 2)
                if lp.pluggedIn, let r = model.readiness(lp) {
                    Readiness(readiness: r, text: EVText.readiness(r, level: model.level(lp), nowMs: site.nowMs, zone: model.zone))
                }
                if lp.pluggedIn, let plan = EVText.plan(lp, windows: model.windows[lp.id] ?? lp.planWindows, nowMs: site.nowMs, zone: model.zone) {
                    Hint(plan)
                }
                if canControl {
                    Button(L("Change")) { editing = true }
                }
            } else {
                Text(L("No goal yet. Without one, FTW only charges from spare solar."))
                    .font(.subheadline)
                    .foregroundStyle(Theme.fg)
                    .fixedSize(horizontal: false, vertical: true)
                if canControl {
                    Button {
                        let g = EVText.suggestedGoal
                        Task { await model.saveGoal(lp, socPct: g.socPct, clock: g.clock, recurring: true, days: g.days, zone: model.zone) }
                    } label: {
                        Text(AppWords.format("Use %@", EVText.suggestedGoalText()))
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(Theme.onAccent)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Button(L("Change")) { editing = true }
                }
            }
            if let save = model.goalSave[lp.id], !editing {
                Hint(LoadpointsModel.goalText(save), tone: { if case .failed = save { return Theme.alarm }; return Theme.fgDim }())
            }
        } header: {
            Text(L("Goal"))
        }
        .listRowBackground(Theme.surfaceRaised)
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
                .foregroundStyle(Theme.fg)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: short ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(short ? Theme.alarm : Theme.live)
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

/// Plan · Charge now · Pause, always in these places. The one the box
/// reports is chosen; the one asked for turns while it travels; a tap on
/// the chosen one does nothing. Under them, the receipt has a row of its
/// own, of fixed height, so nothing moves when it arrives.
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
        VStack(alignment: .leading, spacing: 8) {
            // Side by side; at the accessibility sizes one under the other,
            // so no name is cut.
            let stacked = typeSize.isAccessibilitySize
            let layout = stacked ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 8))
            layout {
                ForEach(Choice.allCases) { c in
                    button(c, chosen: asked == nil && c == current, waiting: asked == c, stacked: stacked)
                }
            }
            ZStack(alignment: .topLeading) {
                ReceiptRoom()
                if let outcome = model.outcome(hold: lp) {
                    ReceiptView(outcome: outcome)
                        .transition(.opacity)
                } else {
                    Text(L("Charge now runs until you go back to the plan or unplug."))
                        .font(.footnote)
                        .foregroundStyle(Theme.fgMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .animation(Theme.spring, value: model.outcome(hold: lp))
        .animation(Theme.spring, value: current)
        // Commands answer once, when the box says what it did.
        .sensoryFeedback(trigger: model.outcome(hold: lp)?.tone) { _, tone in LevelSection.feedback(tone) }
        // A bar of controls: whole words before the largest letters.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    @ViewBuilder private func button(_ c: Choice, chosen: Bool, waiting: Bool, stacked: Bool) -> some View {
        // The chosen one in the brand fill; the others in plain glass.
        if chosen {
            plain(c, chosen: true, waiting: waiting, stacked: stacked)
                .buttonStyle(.glassProminent)
                .tint(Theme.accentFill)
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
            .foregroundStyle(chosen ? Theme.onAccent : Theme.fg)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.vertical, 4)
        }
        .disabled(waiting)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityValue(waiting ? L("Sending to your box…") : "")
        .accessibilityIdentifier("car.control.\(c)")
    }
}

// MARK: The demo's own cable

private struct DemoSection: View {
    let lp: Loadpoint
    let model: LoadpointsModel

    var body: some View {
        Section {
            Button(L(lp.pluggedIn ? "Unplug the car" : "Plug in the car")) {
                SimulatedBox.current?.setCarPluggedIn(!lp.pluggedIn)
                model.reread()
            }
        } header: {
            Text(L("Demo"))
        } footer: {
            Text(L("The demo plugs in a car FTW cannot read, so FTW assumes 20 %."))
        }
        .listRowBackground(Theme.surfaceRaised)
    }
}

/// Before the first answer and with nothing cached: the shape of the
/// screen, not a spinner.
private struct PlaceholderSections: View {
    var body: some View {
        Group {
            Section { Text("Plugged in · charges at 01:00").font(.title3.weight(.semibold)) }
            Section { Text("20 %").font(Theme.percent(.largeTitle, weight: .bold)) }
            Section { Text("80 % by 07:00 on weekdays").font(.headline) }
        }
        .listRowBackground(Theme.surfaceRaised)
        .redacted(reason: .placeholder)
    }
}

/// The room a receipt takes, its marks and two lines of text, laid out as
/// `ReceiptView` lays them out and left empty, so a receipt that arrives
/// moves nothing.
struct ReceiptRoom: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { marks }
                VStack(alignment: .leading, spacing: 4) { marks }
            }
            Text(verbatim: "\n")
                .font(.footnote.weight(.medium))
        }
        .padding(.vertical, 4)
        .hidden()
        .accessibilityHidden(true)
    }

    @ViewBuilder private var marks: some View {
        ForEach([L("Sent"), L("Received"), L("Done")], id: \.self) { label in
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                Text(label).font(.caption.weight(.semibold))
            }
        }
    }
}

/// The receipt under a control: sent, received, done, and one sentence.
struct ReceiptView: View {
    let outcome: EVText.Outcome

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { marks }
                VStack(alignment: .leading, spacing: 4) { marks }
            }
            Text(outcome.text)
                .font(.footnote.weight(.medium))
                .foregroundStyle(color)
                .contentTransition(.opacity)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .animation(Theme.spring, value: outcome)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var marks: some View {
        mark(L("Sent"), outcome.sent)
        mark(L("Received"), outcome.received)
        mark(L("Done"), outcome.done)
    }

    private func mark(_ label: String, _ state: EVText.Outcome.Mark) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol(state))
                .foregroundStyle(tint(state))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.pulse, options: .repeating, isActive: state == .active)
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(state == .waiting ? Theme.fgMuted : Theme.fg)
        }
    }

    private func symbol(_ state: EVText.Outcome.Mark) -> String {
        switch state {
        case .done: return "checkmark.circle.fill"
        case .active: return "circle.dotted.circle"
        case .waiting: return "circle"
        case .failed: return "xmark.circle.fill"
        }
    }

    private func tint(_ state: EVText.Outcome.Mark) -> Color {
        switch state {
        case .done: return Theme.live
        case .active: return Theme.accent
        case .waiting: return Theme.fgMuted
        case .failed: return Theme.alarm
        }
    }

    private var color: Color {
        switch outcome.tone {
        case .working: return Theme.fgDim
        case .done: return Theme.live
        case .warning: return Theme.alarm
        case .failed: return Theme.alarm
        }
    }
}
