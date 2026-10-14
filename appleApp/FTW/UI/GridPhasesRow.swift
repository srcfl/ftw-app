import FTWKit
import SwiftUI

/// The grid's one extra row: L1, L2 and L3 as 10-cell meters against the
/// main fuse, each with its current in mono, and the phase nearest the fuse
/// in an inverse tag. Absent when the box sends no phases. While they are
/// not live the row keeps its room and shows no number.
struct GridPhasesRow: View {
    let phases: GridPhases
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        VStack(alignment: .leading, spacing: 6) {
            Text(phases.kicker)
                .font(Theme.mono(.caption2))
                .tracking(0.5)
                .foregroundStyle(Theme.ink3)
            layout {
                ForEach(Array(phases.phases.enumerated()), id: \.offset) { i, phase in
                    PhaseMeter(phase: phase, reading: phases.reading(phase), nearest: i == phases.nearest, live: phases.live)
                }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Theme.spring, value: phases.nearest)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(phases.kicker)
        .accessibilityValue(phases.spoken)
        .accessibilityIdentifier("node.grid.phases")
    }
}

/// One phase: `L2 6,0 A` over its meter, a cell for each tenth of the fuse.
private struct PhaseMeter: View {
    let phase: GridPhases.Phase
    let reading: String
    let nearest: Bool
    let live: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                // Every name keeps the tag's inset, so the mark can move
                // from phase to phase without moving a figure.
                Text(verbatim: phase.name)
                    .padding(.horizontal, 3)
                    .foregroundStyle(nearest ? Theme.ground : Theme.ink2)
                    .background(nearest ? Theme.ink : .clear, in: RoundedRectangle(cornerRadius: 2))
                Text(reading)
                    .foregroundStyle(live ? Theme.ink : Theme.ink3)
                    .contentTransition(.numericText(value: phase.amps ?? 0))
            }
            .font(Theme.mono(.footnote))
            .lineLimit(1)
            CellMeter(pct: (phase.ofFuse ?? 0) * 100, tint: Theme.grid, live: live)
                .frame(maxWidth: 96, minHeight: 4, maxHeight: 4)
                .padding(.leading, 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
