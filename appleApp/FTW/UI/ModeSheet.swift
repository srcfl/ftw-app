import FTWKit
import SwiftUI

/// How the home is run: the plan, with its planning style and whether the
/// battery may sell, or one of the manual modes. Each choice goes to the box
/// at once; there is no Save. A tap answers with a haptic, the row waits
/// with a turning mark while the box's mode keeps its tick, and the receipt
/// sits in a bar of fixed height at the foot, so no row moves under the
/// finger. A mode the box applied closes the sheet. The style is a scale
/// with five stops, sent when the finger lets go; the sheet stays, and says
/// what the new plan moved.
struct ModeSheet: View {
    let mode: ModeModel
    /// Opened as the home's settings, from the title's menu: the same
    /// choices, with this phone's own settings under them.
    var app: AppModel?
    /// The plan, to say what a change of style moved.
    var plan: PlanShare?
    /// The owner's cars, on a box that keeps them.
    var cars: CarsModel?
    /// The change the sheet opened on, which is not its own to close for:
    /// a sheet opened again just after a mode was applied stays open.
    @State private var openedOn: ModeModel.Change?
    @Environment(\.dismiss) private var dismiss

    init(mode: ModeModel, app: AppModel? = nil, plan: PlanShare? = nil, cars: CarsModel? = nil) {
        self.mode = mode
        self.app = app
        self.plan = plan
        self.cars = cars
        _openedOn = State(initialValue: mode.change)
    }
    /// The sheet's height for its content, measured once laid out.
    @State private var fitted: CGFloat = 520
    @State private var detent: PresentationDetent = .height(520)

    var body: some View {
        NavigationStack {
            List {
                planSection
                manualSection
                if app != nil, let cars, cars.keepsCars {
                    Section {
                        NavigationLink { CarsSettingsView(cars: cars) } label: {
                            LabeledContent {
                                Text(cars.cars.map(\.shownName).joined(separator: ", "))
                                    .lineLimit(1)
                            } label: {
                                Label(C("Cars"), systemImage: "car.side")
                            }
                        }
                        .accessibilityIdentifier("settings.cars")
                    }
                }
                if let app, let access = app.home?.access {
                    AccessSettingsSection(app: app, access: access)
                }
                if let app, let home = app.home, app.watch.canAdd(home) {
                    WatchSettingsSection(app: app, home: home)
                }
                phoneSection
            }
            .listStyle(.insetGrouped)
            .safeAreaBar(edge: .bottom) { ReceiptBar(mode: mode) }
            .scrollEdgeEffectStyle(.hard, for: .bottom)
            .onScrollGeometryChange(for: CGFloat.self) { g in
                (g.contentSize.height + g.contentInsets.top + g.contentInsets.bottom).rounded()
            } action: { _, height in
                fit(height)
            }
            .animation(Theme.spring, value: mode.pending)
            .animation(Theme.spring, value: mode.shown)
            .navigationTitle(app == nil ? L("Mode") : L("Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .close) { dismiss() }
                        .accessibilityIdentifier("mode.close")
                }
            }
        }
        .presentationDetents([.height(fitted), .large], selection: $detent)
        .presentationDragIndicator(.visible)
        // A command answers once, when the box says what it did.
        .sensoryFeedback(trigger: mode.outcome?.tone) { _, tone in Self.feedback(tone) }
        .task(id: mode.change?.result) { await closeOnceApplied() }
        .onAppear { mode.activate() }
        .onDisappear { mode.deactivate() }
    }

    /// The sheet follows its content, unless the reader pulled it to full
    /// height.
    private func fit(_ height: CGFloat) {
        guard height > 0, abs(height - fitted) > 1 else { return }
        let following = detent != .large
        fitted = height
        if following { detent = .height(height) }
    }

    /// A mode the box applied: the tick has moved and the haptic said so;
    /// a moment later the sheet goes. A style or a sale stays, since the
    /// reader may change the other too.
    private func closeOnceApplied() async {
        guard let change = mode.change, change != openedOn, change.result == .applied, case .mode = change.ask else { return }
        try? await Task.sleep(for: .milliseconds(900))
        guard !Task.isCancelled else { return }
        dismiss()
    }

    /// Whether the plan runs, as the box has it until it answers, so the
    /// plan's settings and their footer hold still while a change waits.
    private var onPlan: Bool { ModeWords.isPlan(mode.pending == nil ? mode.shown : mode.actual) }

    /// The box's mode keeps its tick until the box answers; the row asked
    /// for waits beside it.
    private func ticked(_ isRow: (String?) -> Bool) -> Bool {
        mode.pending == nil ? isRow(mode.shown) : isRow(mode.actual)
    }

    @ViewBuilder private var planSection: some View {
        Section {
            choice(
                title: L("Plan"),
                help: ModeWords.help(mode.info(mode.prefs?.mappedMode ?? ModeModel.planFallback)),
                selected: ticked { ModeWords.isPlan($0) },
                waiting: mode.pending.map { ModeWords.isPlan($0) } ?? false,
                id: "plan"
            ) {
                await mode.usePlan()
            }
            // The plan's own settings stay in place whatever runs, so the
            // list never changes length under the finger. The scale rests
            // by itself while a manual mode runs.
            StyleScale(mode: mode, moved: plan?.moved)
                .padding(.vertical, 6)
            Toggle(L("Let the battery sell to the grid when it pays"), isOn: exportBinding)
                .disabled(!canSet || mode.prefs == nil || !onPlan)
                // On is a state: lime, where the ink tint would hide the knob.
                .tint(Theme.live)
        } header: {
            Text(L("How your home is run"))
        }
    }

    @ViewBuilder private var manualSection: some View {
        if !mode.manualModes.isEmpty {
            Section {
                ForEach(mode.manualModes) { m in
                    choice(
                        title: ModeWords.name(m),
                        help: ModeWords.help(m),
                        selected: ticked { $0 == m.key },
                        waiting: mode.pending == m.key,
                        id: m.key
                    ) {
                        await mode.set(m.key)
                    }
                }
            } header: {
                Text(L("Manual"))
            } footer: {
                Text(L("A manual mode runs until you choose another. FTW does not plan meanwhile."))
            }
        }
    }

    /// FTW Cloud and removing this phone, for a paired home. The demo has
    /// neither.
    @ViewBuilder private var phoneSection: some View {
        if let app, !app.isDemo {
            Section(AboutWords.text("This phone")) {
                NavigationLink { CloudSettingsView(app: app) } label: {
                    Label(CloudWords.text("FTW Cloud"), systemImage: "cloud")
                }
                if AboutView.canRemove(app) {
                    NavigationLink { RemovePhoneView(app: app) { dismiss() } } label: {
                        Text(AboutWords.text("Remove this phone")).foregroundStyle(Theme.alarm)
                    }
                }
            }
        }
    }

    /// A change can go: the stream is up and nothing else is on its way.
    private var canSet: Bool { mode.connected && !mode.sending }

    private func choice(title: String, help: String, selected: Bool, waiting: Bool, id: String, _ run: @escaping () async -> Void) -> some View {
        Button {
            guard !selected, canSet else { return }
            Task { await run() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(Theme.fg)
                    if !help.isEmpty {
                        Text(help).font(.footnote).foregroundStyle(Theme.fgDim).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: waiting ? "circle.dotted" : (selected ? "checkmark.circle.fill" : "circle"))
                    .foregroundStyle(selected || waiting ? Theme.accent : Theme.fgMuted)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.rotate, options: .repeating, isActive: waiting)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The running mode never greys out; the others rest while a change
        // is on its way or the box is out of reach, and the bar says why.
        .disabled(!selected && !waiting && !canSet)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(waiting ? L("Sending to your box…") : "")
        .accessibilityIdentifier("mode.choice.\(id)")
    }

    private var exportBinding: Binding<Bool> {
        Binding(
            get: { mode.shownExport ?? false },
            set: { on in
                Task { await mode.setExport(on) }
            }
        )
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

/// The foot of the sheet: why the choices rest, the receipt of the last
/// change, or how the sheet works. Its height is held for the longest
/// receipt, so nothing above it moves when one arrives.
private struct ReceiptBar: View {
    let mode: ModeModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The room a receipt needs, at any text size.
            ReceiptRoom()
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .animation(Theme.spring, value: mode.outcome)
        .animation(Theme.spring, value: mode.connected)
        .accessibilityIdentifier("mode.receipt")
        // A bar at the foot of the sheet: it must leave the choices room at
        // the largest text, so it stops growing before them.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    @ViewBuilder private var content: some View {
        if let outcome = mode.outcome {
            ReceiptView(outcome: outcome)
                .transition(.opacity)
        } else if !mode.connected {
            Label(L("Waiting for your box. You can choose when it answers."), systemImage: "wifi.exclamationmark")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.fgDim)
                .transition(.opacity)
        } else {
            Text(L("Each choice goes to your box at once."))
                .font(.footnote)
                .foregroundStyle(Theme.fgMuted)
                .transition(.opacity)
        }
    }
}
