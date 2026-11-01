import FTWKit
import SwiftUI

/// The three figures for the pass a tap chose, under Now's strip and under
/// the plan: when it runs, what it does to the level, and the price it
/// meets. Each a mono title, a figure and a line, with space between them
/// and no borders. The first title takes the pass's colour; a plan that is
/// old reads in ink3. It swaps with the pass, with no animation, so a tap
/// answers at once.
struct PassFigures: View, Equatable {
    let pass: PlanPass
    var grey = false
    @ScaledMetric(relativeTo: .title3) private var figure: CGFloat = 21

    nonisolated static func == (a: Self, b: Self) -> Bool { a.pass == b.pass && a.grey == b.grey }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(Array(pass.figures.enumerated()), id: \.offset) { i, f in
                VStack(alignment: i == 2 ? .trailing : .leading, spacing: 1) {
                    Text(f.title)
                        .font(Theme.mono())
                        .tracking(0.5)
                        .foregroundStyle(grey ? Theme.ink3 : tint(f.tint))
                        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    Text(f.value)
                        .font(Theme.figure(figure))
                        .foregroundStyle(grey ? Theme.ink3 : Theme.ink)
                        .minimumScaleFactor(0.7)
                    Text(f.sub)
                        .font(.caption)
                        .foregroundStyle(grey ? Theme.ink3 : Theme.ink2)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: i == 2 ? .trailing : .leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pass.spoken)
    }

    private func tint(_ t: PlanPass.Figure.Tint) -> Color {
        switch t {
        case .gives: return Theme.gives
        case .stores: return Theme.stores
        case .car: return Theme.car
        case .ink: return Theme.ink2
        }
    }
}
