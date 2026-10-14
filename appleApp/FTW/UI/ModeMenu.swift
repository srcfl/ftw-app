import FTWKit
import SwiftUI

/// How the home is run, in the bar beside the title: `Balanced ⌄`. A glass
/// button that opens the mode sheet, sized to its content: the planning
/// style as a scale with five stops, whether the battery may sell, and the
/// manual modes. The title sits at the leading edge, so a longer name moves
/// only the button's own edge; the button sizes to its name rather than
/// holding the longest one's width, which would leave the status line too
/// little room on a small phone.
///
/// The choice shows at once; the status line follows the box's receipt,
/// and the outcome alone plays a haptic. Drawn from the cache, it stays
/// inert until the box has spoken in this session. A phone that may not
/// change the mode sees the name and no button.
struct ModeMenu: View {
    let mode: ModeModel
    var plan: PlanShare?
    @State private var open = false

    var body: some View {
        Group {
            if mode.mayControl {
                Button { open = true } label: {
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
        // A command answers once, when the box says what it did, also when
        // the sheet was closed first. With the sheet open the two play as
        // one.
        .sensoryFeedback(trigger: mode.outcome?.tone) { _, tone in ModeSheet.feedback(tone) }
        .sheet(isPresented: $open) {
            ModeSheet(mode: mode, plan: plan)
        }
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
}
