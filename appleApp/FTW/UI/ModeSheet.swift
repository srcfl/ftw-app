import FTWKit
import SwiftUI

/// How the home is run: the plan, with its planning style and whether the
/// battery may sell, or one of the manual modes. Each choice goes to the box
/// at once; there is no Save. A tap answers with a haptic, the row waits
/// with a turning mark while the box's mode keeps its tick, and the receipt
/// sits in a bar of fixed height at the foot, so no row moves under the
/// finger. A mode the box applied closes the sheet.
struct ModeSheet: View {
    let mode: ModeModel
    @Environment(\.dismiss) private var dismiss
    /// The sheet's height for its content, measured once laid out.
    @State private var fitted: CGFloat = 520
    @State private var detent: PresentationDetent = .height(520)

    var body: some View {
        NavigationStack {
            List {
                planSection
                manualSection
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
            .navigationTitle(L("Mode"))
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
        guard let change = mode.change, change.result == .applied, case .mode = change.ask else { return }
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
            // list never changes length under the finger.
            Picker(L("Planning style"), selection: styleBinding) {
                ForEach(ModeModel.styles) { style in
                    Text(L(style.name)).tag(style.key)
                }
            }
            .pickerStyle(.menu)
            .disabled(!canSet || mode.prefs == nil || !onPlan)
            Toggle(L("Let the battery sell to the grid when it pays"), isOn: exportBinding)
                .disabled(!canSet || mode.prefs == nil || !onPlan)
                // On is a state: lime, where the ink tint would hide the knob.
                .tint(Theme.live)
        } header: {
            Text(L("How your home is run"))
        } footer: {
            // The style's own help whatever runs: a footer that changed
            // with the mode would move the rows below it under the finger.
            if let style = mode.shownStyle {
                Text(L(style.help))
                    .contentTransition(.opacity)
            }
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

    private var styleBinding: Binding<String> {
        Binding(
            get: { mode.shownStyle?.key ?? ModeModel.styles[2].key },
            set: { key in
                guard let style = ModeModel.styles.first(where: { $0.key == key }) else { return }
                Task { await mode.setStyle(style) }
            }
        )
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
