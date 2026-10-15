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
/// It opens on the name the cache holds, at its final width, and stays
/// inert until the box has spoken in this session. With nothing kept it
/// holds the shape of a name until one is known, never "Mode" or "Plan"
/// on the way. The choice shows at once; the status line follows the box's
/// receipt, and the outcome alone plays a haptic. A phone that may not
/// change the mode sees the name and no button.
struct ModeMenu: View {
    let mode: ModeModel
    /// Opens the mode sheet. The root view presents it: a sheet held by a
    /// view in the bar does not open again after it closed itself.
    let open: () -> Void

    var body: some View {
        Group {
            if mode.opens {
                Button(action: open) {
                    label(chevron: true)
                }
                .disabled(!mode.canControl)
            } else {
                label(chevron: false)
            }
        }
        .accessibilityLabel(L("Mode"))
        .accessibilityValue(mode.buttonName ?? "")
        .accessibilityHint(mode.mayControl ? L("Change mode") : "")
        .accessibilityIdentifier("now.mode")
        // A command answers once, when the box says what it did, also when
        // the sheet was closed first. With the sheet open the two play as
        // one.
        .sensoryFeedback(trigger: mode.outcome?.tone) { _, tone in ModeSheet.feedback(tone) }
    }

    private func label(chevron: Bool) -> some View {
        let name = mode.buttonName
        return HStack(spacing: 4) {
            // Before a name is known, the default style's word holds the
            // place, unseen, under a bar of its width: a redacted word
            // lays out narrower than the word itself.
            Text(name ?? L(ModeModel.styles[2].name))
                .foregroundStyle(Theme.ink)
                .opacity(name == nil ? 0 : 1)
                .lineLimit(1)
                .fixedSize()
                .overlay {
                    Capsule()
                        .fill(Theme.ink3.opacity(0.35))
                        .frame(height: 9)
                        .opacity(name == nil ? 1 : 0)
                }
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
