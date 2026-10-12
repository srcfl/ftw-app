import FTWKit
import SwiftUI

/// How the home is run: the plan, with its planning style and whether the
/// battery may sell, or one of the manual modes. Each choice goes to the box
/// at once; there is no Save. A tap answers with a haptic and "Sent", then
/// the box's receipt, then what the box did.
struct ModeSheet: View {
    let mode: ModeModel
    @Environment(\.dismiss) private var dismiss
    @State private var taps = 0

    var body: some View {
        NavigationStack {
            List {
                if let outcome = mode.outcome {
                    Section {
                        ReceiptView(outcome: outcome)
                    }
                    .listRowBackground(Theme.surfaceRaised)
                }
                planSection
                manualSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.surface)
            .animation(Theme.spring, value: mode.outcome)
            .animation(Theme.spring, value: mode.shown)
            .navigationTitle(L("Mode"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sensoryFeedback(.impact(weight: .medium), trigger: taps)
        .sensoryFeedback(trigger: mode.outcome?.tone) { _, tone in Self.feedback(tone) }
        .onAppear { mode.activate() }
        .onDisappear { mode.deactivate() }
    }

    private var onPlan: Bool { ModeWords.isPlan(mode.shown) }

    @ViewBuilder private var planSection: some View {
        Section {
            choice(title: L("Plan"), help: ModeWords.help(mode.info(mode.prefs?.mappedMode ?? ModeModel.planFallback)), selected: onPlan) {
                await mode.usePlan()
            }
            if onPlan {
                Picker(L("Planning style"), selection: styleBinding) {
                    ForEach(ModeModel.styles) { style in
                        Text(L(style.name)).tag(style.key)
                    }
                }
                .pickerStyle(.menu)
                .disabled(mode.sending || mode.prefs == nil)
                Toggle(L("Let the battery sell to the grid when it pays"), isOn: exportBinding)
                    .disabled(mode.sending || mode.prefs == nil)
                    .tint(Theme.accent)
            }
        } header: {
            Text(L("How your home is run"))
        } footer: {
            if onPlan, let style = mode.shownStyle {
                Text(L(style.help))
            }
        }
        .listRowBackground(Theme.surfaceRaised)
    }

    @ViewBuilder private var manualSection: some View {
        if !mode.manualModes.isEmpty {
            Section {
                ForEach(mode.manualModes) { m in
                    choice(title: ModeWords.name(m), help: ModeWords.help(m), selected: mode.shown == m.key) {
                        await mode.set(m.key)
                    }
                }
            } header: {
                Text(L("Manual"))
            } footer: {
                Text(L("A manual mode runs until you choose another. FTW does not plan meanwhile."))
            }
            .listRowBackground(Theme.surfaceRaised)
        }
    }

    private func choice(title: String, help: String, selected: Bool, _ run: @escaping () async -> Void) -> some View {
        Button {
            guard !selected else { return }
            taps += 1
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
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Theme.accent : Theme.fgMuted)
                    .contentTransition(.symbolEffect(.replace))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(mode.sending && !selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var styleBinding: Binding<String> {
        Binding(
            get: { mode.shownStyle?.key ?? ModeModel.styles[2].key },
            set: { key in
                guard let style = ModeModel.styles.first(where: { $0.key == key }) else { return }
                taps += 1
                Task { await mode.setStyle(style) }
            }
        )
    }

    private var exportBinding: Binding<Bool> {
        Binding(
            get: { mode.shownExport ?? false },
            set: { on in
                taps += 1
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
