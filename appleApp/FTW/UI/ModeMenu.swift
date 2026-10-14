import FTWKit
import SwiftUI

/// How the home is run, in the bar beside the title: `Balanced ⌄`. A glass
/// menu with the plan, its planning style and whether the battery may sell,
/// and the manual modes. The title sits at the leading edge, so a longer
/// name moves only the button's own edge; the button sizes to its name
/// rather than holding the longest one's width, which would leave the status
/// line too little room on a small phone.
///
/// The choice shows at once; the status line follows the box's receipt,
/// and the outcome alone plays a haptic. Drawn from the cache, it stays
/// inert until the box has spoken in this session. A phone that may not
/// change the mode sees the name and no menu.
struct ModeMenu: View {
    let mode: ModeModel

    var body: some View {
        Group {
            if mode.mayControl {
                Menu {
                    choices
                } label: {
                    label(chevron: true)
                }
                .disabled(!mode.canControl)
            } else {
                label(chevron: false)
            }
        }
        .accessibilityLabel(L("Mode"))
        .accessibilityValue(name ?? "")
        .accessibilityHint(mode.mayControl ? L("Change mode") : "")
        .accessibilityIdentifier("now.mode")
        // A command answers once, when the box says what it did.
        .sensoryFeedback(trigger: mode.outcome?.tone) { _, tone in ModeSheet.feedback(tone) }
    }

    /// The name on the button: the planning style while the plan runs, else
    /// the manual mode's name.
    private var name: String? {
        guard let key = mode.shown else { return nil }
        if ModeWords.isPlan(key), let style = mode.shownStyle { return L(style.name) }
        return ModeWords.name(mode.info(key))
    }

    private func label(chevron: Bool) -> some View {
        HStack(spacing: 4) {
            Text(name ?? L("Mode"))
                .foregroundStyle(name == nil ? Theme.ink3 : Theme.ink)
                .contentTransition(.opacity)
                .lineLimit(1)
            if chevron {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.ink2)
            }
        }
        .font(.subheadline.weight(.semibold))
        .animation(Theme.spring, value: name)
        // Chrome: the bar holds its shape at every text size.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }

    @ViewBuilder private var choices: some View {
        Section(L("How your home is run")) {
            choice(L("Plan"), help: ModeWords.help(mode.info(mode.prefs?.mappedMode ?? ModeModel.planFallback)), selected: ModeWords.isPlan(mode.shown ?? ""), id: "plan") {
                await mode.usePlan()
            }
            Picker(selection: styleBinding) {
                ForEach(ModeModel.styles) { style in
                    Text(L(style.name)).tag(style.key)
                }
            } label: {
                Label(L("Planning style"), systemImage: "slider.horizontal.3")
                Text(mode.shownStyle.map { L($0.name) } ?? "")
            }
            .pickerStyle(.menu)
            .disabled(mode.prefs == nil || !ModeWords.isPlan(mode.shown ?? ""))
            Toggle(isOn: exportBinding) {
                Label(L("Let the battery sell to the grid when it pays"), systemImage: "arrow.up.forward")
            }
            .disabled(mode.prefs == nil || !ModeWords.isPlan(mode.shown ?? ""))
        }
        if !mode.manualModes.isEmpty {
            Section(L("Manual")) {
                ForEach(mode.manualModes) { m in
                    choice(ModeWords.name(m), help: ModeWords.help(m), selected: mode.shown == m.key, id: m.key) {
                        await mode.set(m.key)
                    }
                }
            }
        }
    }

    private func choice(_ title: String, help: String, selected: Bool, id: String, _ run: @escaping () async -> Void) -> some View {
        Button {
            guard !selected, !mode.sending else { return }
            Task { await run() }
        } label: {
            if selected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
            if !help.isEmpty { Text(help) }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("mode.menu.\(id)")
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
            set: { on in Task { await mode.setExport(on) } }
        )
    }
}
