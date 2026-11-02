import FTWKit
import SwiftUI

/// The three figures for the pass a tap chose, under Now's strip and under
/// the plan: when it runs, what it does to the level, and the price it
/// meets. Each a mono title, a figure and a line, with space between them
/// and no borders. The first title takes the pass's colour; a plan that is
/// old reads in ink3. It swaps with the pass, with no animation, so a tap
/// answers at once. Where the three do not fit side by side, as at the
/// largest text sizes, they stand one under another rather than end in "…".
struct PassFigures: View, Equatable {
    let pass: PlanPass
    var grey = false
    /// The battery's level now, where a run under way starts from.
    var levelNow: Double?
    @ScaledMetric(relativeTo: .title3) private var figure: CGFloat = 21

    nonisolated static func == (a: Self, b: Self) -> Bool { a.pass == b.pass && a.grey == b.grey && a.levelNow == b.levelNow }

    var body: some View {
        let figures = Array(pass.figures(levelNow: levelNow).enumerated())
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(figures, id: \.offset) { i, f in
                    column(f, trailing: i == 2)
                        .frame(maxWidth: .infinity, alignment: i == 2 ? .trailing : .leading)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(figures, id: \.offset) { _, f in
                    column(f, trailing: false)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pass.spoken)
    }

    private func column(_ f: PlanPass.Figure, trailing: Bool) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 1) {
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

/// The figures with the battery's level now. Only this reads the site, so
/// a reading redraws the figures, and only when the whole percent moves.
struct LevelNowFigures: View {
    let pass: PlanPass
    var grey = false
    var site: SiteModel?

    var body: some View {
        PassFigures(pass: pass, grey: grey, levelNow: site?.socPercent)
            .equatable()
    }
}
