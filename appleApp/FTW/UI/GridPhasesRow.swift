import FTWKit
import SwiftUI

/// The grid's one extra row: L1, L2 and L3 as 10-cell meters against the
/// main fuse, each with its current, and the phase nearest the fuse a
/// weight heavier. The inverse tag stays the finger's. Absent when the box
/// sends no phases. While they are not live the row keeps its room and
/// shows no number.
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
                // Three on one line at the largest standard size: the
                // decimal goes, never the figure.
                let decimals = typeSize >= .xxxLarge && !typeSize.isAccessibilitySize ? 0 : 1
                ForEach(Array(phases.phases.enumerated()), id: \.offset) { i, phase in
                    PhaseMeter(phase: phase, reading: phases.reading(phase, decimals: decimals), nearest: i == phases.nearest, live: phases.live)
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
/// The name is mono, the current a figure.
private struct PhaseMeter: View {
    let phase: GridPhases.Phase
    let reading: String
    let nearest: Bool
    let live: Bool
    @ScaledMetric(relativeTo: .footnote) private var figure: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: phase.name)
                    .font(Theme.mono(.footnote, weight: nearest ? .bold : .regular))
                    .foregroundStyle(nearest ? Theme.ink : Theme.ink2)
                Text(reading)
                    .font(Theme.figure(figure, weight: nearest ? .semibold : .regular))
                    .foregroundStyle(live ? Theme.ink : Theme.ink3)
                    .contentTransition(.numericText(value: phase.amps ?? 0))
            }
            .lineLimit(1)
            CellMeter(pct: (phase.ofFuse ?? 0) * 100, tint: Theme.grid, live: live)
                .frame(maxWidth: 96, minHeight: 4, maxHeight: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
