import Charts
import FTWShared
import SwiftUI
import WidgetKit

/// One moment of the plan widget, in whichever family it sits. Every
/// sentence comes from `PlanGlance`; this file only lays them out.
struct PlanWidgetView: View {
    let moment: PlanGlance.Moment
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .containerBackground(for: .widget) { Rectangle().fill(background) }
    }

    /// Grey when the plan is old, missing, or one the box could not make.
    private var background: AnyShapeStyle {
        switch family {
        case .accessoryRectangular, .accessoryInline, .accessoryCircular: return AnyShapeStyle(.clear)
        default: return AnyShapeStyle(moment.isGrey ? Tone.empty : Tone.surface)
        }
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .systemMedium: MediumPlan(moment: moment)
        case .accessoryRectangular: RectangularPlan(moment: moment)
        default: SmallPlan(moment: moment)
        }
    }
}

/// The next thing FTW does, large, and when it ends.
struct SmallPlan: View {
    let moment: PlanGlance.Moment

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            PlanHeader()
            if let when = moment.nextWhen, let what = moment.nextWhat {
                NextEvent(when: when, what: what, until: moment.nextUntil, kind: moment.next?.kind)
                Spacer(minLength: 2)
                CheapLine(moment: moment)
            } else {
                Spacer(minLength: 4)
                Text(moment.summary)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
            }
            Age(moment: moment)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

/// The next thing on the left, the next twelve hours on the right.
struct MediumPlan: View {
    let moment: PlanGlance.Moment

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                PlanHeader()
                if let when = moment.nextWhen, let what = moment.nextWhat {
                    NextEvent(when: when, what: what, until: moment.nextUntil, kind: moment.next?.kind)
                } else {
                    Text(moment.summary)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 2)
                Age(moment: moment)
            }
            .frame(width: 128, alignment: .leading)
            .accessibilityElement(children: .combine)
            VStack(alignment: .leading, spacing: 4) {
                WidgetLanes(moment: moment)
                if let later = moment.laterText {
                    Text(later)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The lock screen's rectangle: what happens next, until when, and the
/// cheap hours.
struct RectangularPlan: View {
    let moment: PlanGlance.Moment

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let when = moment.nextWhen, let what = moment.nextWhat {
                Text("\(Image(systemName: PlanHeader.symbol)) \(Text(when).font(.headline)) \(what)")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .widgetAccentable()
                Text([moment.nextUntil, moment.cheapText].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Age(moment: moment)
            } else {
                Text("\(Image(systemName: PlanHeader.symbol)) \(PlanGlance.title)")
                    .font(.caption.weight(.semibold))
                    .widgetAccentable()
                Text(moment.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Age(moment: moment)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Parts

struct PlanHeader: View {
    static let symbol = "calendar.day.timeline.left"

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: Self.symbol)
                .imageScale(.small)
                .foregroundStyle(Tone.accent)
                .widgetAccentable()
            Text(PlanGlance.title).foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}

/// "Now" or "02:00", large; what happens; until when.
struct NextEvent: View {
    let when: String
    let what: String
    let until: String?
    let kind: PlanGlance.Kind?

    var body: some View {
        Text(when)
            .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(kind.map { Tone.of($0) } ?? Tone.accent)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .widgetAccentable()
        Text(what)
            .font(.subheadline.weight(.semibold))
            .lineLimit(2)
            .minimumScaleFactor(0.8)
            .fixedSize(horizontal: false, vertical: true)
        if let until {
            Text(until).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

/// "cheapest 02–04", when the hours ahead have a cheap stretch.
struct CheapLine: View {
    let moment: PlanGlance.Moment

    var body: some View {
        if let text = moment.cheapText {
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Tone.cheap)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }
}

/// When the box made the plan; once it is old, that it is.
struct Age: View {
    let moment: PlanGlance.Moment

    var body: some View {
        if let text = moment.ageText {
            Text(text)
                .font(.caption2)
                .foregroundStyle(moment.state == .old ? .secondary : .tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

/// The next twelve hours as lanes: the car on top, the battery under it,
/// the cheapest hours as a thin mark, and the prices as a low strip along
/// the bottom. On tinted and
/// clear home screens it draws in one colour, the lanes solid and the
/// prices faint.
struct WidgetLanes: View {
    let moment: PlanGlance.Moment
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let from = moment.atMs
        let to = from + PlanGlance.horizonMs
        let top = max(1, moment.backdrop.map(\.minor).max() ?? 1)
        let full = renderingMode == .fullColor
        Chart {
            ForEach(moment.backdrop) { bar in
                RectangleMark(
                    xStart: .value("From", date(max(from, bar.startMs))),
                    xEnd: .value("To", date(min(to, bar.endMs))),
                    yStart: .value("Bottom", 0.0),
                    yEnd: .value("Price", Self.priceFloor + Self.priceRise * max(0, bar.minor) / top)
                )
                .foregroundStyle(full ? AnyShapeStyle(moment.isGrey ? Tone.flat : Tone.of(bar.tone)) : AnyShapeStyle(.primary))
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
                .foregroundStyle(full ? AnyShapeStyle(moment.isGrey ? Tone.flat : Tone.of(e.kind)) : AnyShapeStyle(.primary))
                .opacity(moment.isGrey ? 0.45 : 1)
                .cornerRadius(4)
            }
        }
        .chartXScale(domain: date(from)...date(to))
        .chartYScale(domain: 0...1)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(preset: .aligned, values: .stride(by: .hour, count: 3)) { value in
                AxisValueLabel {
                    if let d = value.as(Date.self) { Text(String(format: "%02d", Calendar.current.component(.hour, from: d))) }
                }
            }
        }
        .accessibilityHidden(true)
    }

    static let priceFloor = 0.03
    static let priceRise = 0.15

    static func lane(_ kind: PlanGlance.Kind) -> ClosedRange<Double> {
        switch kind {
        case .car: return 0.68...0.96
        case .charge, .discharge: return 0.34...0.62
        case .cheap: return 0.23...0.27
        }
    }

    private func date(_ ms: Double) -> Date { Date(timeIntervalSince1970: ms / 1000) }
}

extension Tone {
    static let mobility = Pair(0x7F5BB6, 0xCCA8FF)
    static let storage = Pair(0x008FA8, 0x13DCF6)
    static let generation = Pair(0xD48500, 0xFFB000)

    static func of(_ kind: PlanGlance.Kind) -> Pair {
        switch kind {
        case .car: return mobility
        case .charge: return storage
        case .discharge: return generation
        case .cheap: return cheap
        }
    }
}
