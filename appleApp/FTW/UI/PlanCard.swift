import Charts
import FTWKit
import SwiftUI

/// The plan on Now: one line that says what happens over the next hours,
/// and a calm timeline under it, on the ground with no card. Its height
/// never depends on what the plan says. The car and the battery each have
/// a lane; the prices are the faint background, not the subject. A tap
/// opens the plan's own view.
struct PlanCard: View, Equatable {
    let moment: PlanGlance.Moment
    /// "103", the price now, beside the title. Nil when there is none.
    let priceNow: String?
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Kicker(PlanGlance.title)
                // A plan kept from an earlier launch says when the box made
                // it, until the box answers.
                if let age = moment.ageText {
                    Text(age)
                        .font(.caption2)
                        .foregroundStyle(Theme.fgMuted)
                        .lineLimit(1)
                        .transition(.opacity)
                }
                Spacer(minLength: 8)
                if let priceNow {
                    Text("\(Text(L("Price now")).font(.caption2).foregroundStyle(Theme.fgMuted)) \(Text(AppWords.decimal(priceNow)).font(Theme.figure(13)).foregroundStyle(Theme.fg)) \(Text(unit).font(.caption2).foregroundStyle(Theme.fgMuted))")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .contentTransition(.numericText())
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.fgMuted)
            }
            // Two lines kept whatever the sentence, so the card holds its
            // height when the plan lands. Before the box's first answer
            // the line is a placeholder, not a claim about the plan.
            Text(moment.summary)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(moment.isGrey ? Theme.fgDim : Theme.fg)
                .lineLimit(2, reservesSpace: true)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
                .redacted(reason: moment.placeholder ? .placeholder : [])
                .contentTransition(.opacity)
            PlanLanes(moment: moment, compact: true)
                .frame(height: 50)
        }
        // On the ground, with no card: space separates it from the flow.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .animation(Theme.spring, value: moment.summary)
        .animation(Theme.spring, value: moment.ageText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PlanGlance.title)
        .accessibilityValue([moment.summary, priceNow.map { "\(L("Price now")) \($0) \(unit)" }].compactMap { $0 }.joined(separator: ". "))
        .accessibilityHint(L("Opens the plan."))
        .fitCap(.xLarge)
    }
}

/// The hours ahead as lanes: the car's charging on top, the battery under
/// it (charging one colour, giving power another), the cheapest hours as a
/// thin mark, and the prices as a low strip along the bottom. The price is
/// the ground the plan stands on, not the subject.
struct PlanLanes: View, Equatable {
    let moment: PlanGlance.Moment
    var compact = false

    private static let car = 0.68...0.96
    private static let battery = 0.34...0.62
    private static let cheap = 0.23...0.27
    static let priceFloor = 0.03
    static let priceRise = 0.15

    var body: some View {
        let from = moment.atMs
        let to = from + PlanGlance.horizonMs
        let top = max(1, moment.backdrop.map(\.minor).max() ?? 1)
        let grey = moment.isGrey
        Chart {
            ForEach(moment.backdrop) { bar in
                RectangleMark(
                    xStart: .value("From", date(max(from, bar.startMs))),
                    xEnd: .value("To", date(min(to, bar.endMs))),
                    yStart: .value("Bottom", 0),
                    yEnd: .value("Price", Self.priceFloor + Self.priceRise * max(0, bar.minor) / top)
                )
                .foregroundStyle(grey ? Theme.fgMuted : Theme.price(bar.tone))
                .opacity(0.4)
            }
            ForEach(moment.events) { e in
                let lane = Self.lane(e.kind)
                RectangleMark(
                    xStart: .value("From", date(max(from, e.startMs))),
                    xEnd: .value("To", date(min(to, e.endMs))),
                    yStart: .value("Low", lane.lowerBound),
                    yEnd: .value("High", lane.upperBound)
                )
                .foregroundStyle(grey ? Theme.fgMuted : Self.color(e.kind))
                .cornerRadius(5)
                .annotation(position: .overlay, alignment: .center) {
                    if !compact || e.endMs - e.startMs >= 90 * 60_000, let pct = e.targetPct, e.kind == .car {
                        Text(AppWords.percent(pct))
                            .font(.system(size: 9, weight: .bold).monospacedDigit())
                            .foregroundStyle(Theme.ground)
                    }
                }
            }
            RuleMark(x: .value("Now", date(from)))
                .foregroundStyle(Theme.accentFill)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        .chartXScale(domain: date(from)...date(to))
        .chartYScale(domain: 0...1)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(preset: .aligned, values: .stride(by: .hour, count: 3)) { value in
                AxisValueLabel { hourLabel(value) }
            }
        }
        .accessibilityHidden(true)
    }

    static func lane(_ kind: PlanGlance.Kind) -> ClosedRange<Double> {
        switch kind {
        case .car: return car
        case .charge, .discharge: return battery
        case .cheap: return cheap
        }
    }

    static func color(_ kind: PlanGlance.Kind) -> Color {
        switch kind {
        case .car: return Theme.car
        case .charge: return Theme.stores
        case .discharge: return Theme.gives
        case .cheap: return Theme.ink2
        }
    }

    private func date(_ ms: Double) -> Date { Date(timeIntervalSince1970: ms / 1000) }
}
