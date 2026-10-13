import Charts
import FTWShared
import SwiftUI
import WidgetKit

/// One moment of the grid widget, in whichever family it sits. Every
/// sentence and figure comes from `GridGlance`; this file only lays them
/// out.
struct GridTodayView: View {
    let moment: GridGlance.Moment
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .containerBackground(for: .widget) { Rectangle().fill(background) }
    }

    /// Grey when there is nothing for today. The lock screen draws its own,
    /// so the accessory family brings none.
    private var background: AnyShapeStyle {
        switch family {
        case .accessoryRectangular, .accessoryInline, .accessoryCircular: return AnyShapeStyle(.clear)
        default: return AnyShapeStyle(moment.isGrey ? Tone.empty : Tone.surface)
        }
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryRectangular: RectangularGrid(moment: moment)
        case .systemSmall: SmallGrid(moment: moment)
        default: MediumGrid(moment: moment)
        }
    }
}

/// Net on the left and the cost on the right, the line under each, and
/// the day below them.
struct MediumGrid: View {
    let moment: GridGlance.Moment

    var body: some View {
        if moment.state == .today {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    NetFigure(moment: moment, size: 30)
                    Spacer(minLength: 8)
                    CostFigure(moment: moment, size: 22)
                }
                HStack(alignment: .firstTextBaseline) {
                    InOutLine(moment: moment)
                    Spacer(minLength: 8)
                    TimeLine(moment: moment, withNote: true)
                }
                .accessibilityHidden(true)
                GridDayChart(moment: moment, labels: true)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(moment.spoken)
        } else {
            GridEmpty(moment: moment)
        }
    }
}

/// The figures, stacked, over a small day.
struct SmallGrid: View {
    let moment: GridGlance.Moment

    var body: some View {
        if moment.state == .today {
            VStack(alignment: .leading, spacing: 2) {
                NetFigure(moment: moment, size: 26)
                InOutLine(moment: moment)
                GridDayChart(moment: moment, labels: false)
                    .padding(.vertical, 3)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    // The cost keeps its size; the time gives way.
                    CostFigure(moment: moment, size: 17)
                        .layoutPriority(1)
                    Spacer(minLength: 2)
                    TimeLine(moment: moment, withNote: false)
                }
                if let note = moment.costNote {
                    Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(moment.spoken)
        } else {
            GridEmpty(moment: moment)
        }
    }
}

/// The lock screen's rectangle: net and cost on one line, both sides of
/// net under it, and the time.
struct RectangularGrid: View {
    let moment: GridGlance.Moment

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if moment.state == .today, let net = moment.netText {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(arrow)\(Text(net).font(.headline.monospacedDigit())) \(Text(moment.unit).font(.caption))")
                        .widgetAccentable()
                    Spacer(minLength: 2)
                    if let cost = moment.costText {
                        Text("\(Text(cost).font(.headline.monospacedDigit())) \(Text(moment.costUnit).font(.caption))")
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                if let inOut = moment.inOutText {
                    Text(inOut).font(.caption).lineLimit(1).minimumScaleFactor(0.7)
                }
                Text([moment.costNote, moment.timeText].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("\(Image(systemName: GridGlance.symbol)) \(GridGlance.title())")
                    .font(.caption.weight(.semibold))
                    .widgetAccentable()
                Text(moment.emptyText ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let time = moment.timeText {
                    Text(time).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(moment.spoken)
    }

    private var arrow: Text {
        guard let symbol = moment.direction.symbol else { return Text("") }
        return Text("\(Image(systemName: symbol)) ").font(.caption.weight(.bold))
    }
}

// MARK: Parts

/// "↓ 1,8 kWh": the arrow says which way, the figure never carries a sign.
struct NetFigure: View {
    let moment: GridGlance.Moment
    let size: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            if let symbol = moment.direction.symbol {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.62, weight: .bold))
                    .foregroundStyle(moment.direction == .fromGrid ? GridColors.bars : GridColors.curve)
                    .widgetAccentable()
            }
            Text(moment.netText ?? "")
                .font(.system(size: size, weight: .semibold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
                .widgetAccentable()
            Text(moment.unit)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

/// "⚡ 12,40 kr", or "−4,20 kr" in the colour of money earned.
struct CostFigure: View {
    let moment: GridGlance.Moment
    let size: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Image(systemName: GridGlance.symbol)
                .font(.system(size: size * 0.6, weight: .semibold))
                .foregroundStyle(Tone.accent)
                .widgetAccentable()
            Text(moment.costText ?? "–")
                .font(.system(size: size, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(moment.earned ? AnyShapeStyle(GridColors.curve) : AnyShapeStyle(.primary))
                .contentTransition(.numericText())
            if moment.costText != nil {
                Text(moment.costUnit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

/// "in 6,5 · ut 8,3 kWh": both sides, always, so net is never read as the
/// bill.
struct InOutLine: View {
    let moment: GridGlance.Moment

    var body: some View {
        Text(moment.inOutText ?? "")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }
}

/// "delvis · kl 16:55": what time the figures are from.
struct TimeLine: View {
    let moment: GridGlance.Moment
    let withNote: Bool

    var body: some View {
        Text((withNote ? [moment.costNote, moment.timeText] : [moment.timeText]).compactMap { $0 }.joined(separator: " · "))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

/// Nothing for today: say why and when the last figures were from.
struct GridEmpty: View {
    let moment: GridGlance.Moment

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                Image(systemName: GridGlance.symbol)
                    .imageScale(.small)
                    .foregroundStyle(Tone.accent)
                    .widgetAccentable()
                Text(GridGlance.title()).foregroundStyle(.secondary)
            }
            .font(.caption)
            Spacer(minLength: 4)
            Text(moment.emptyText ?? "")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let time = moment.timeText {
                Text(time).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

/// The day on a fixed 00–24 axis: a bar for each quarter hour that bought,
/// a curve with a soft fill below zero for what was sold, nothing for the
/// hours still to come, and a break wherever the box has no record.
///
/// Tinted and clear home screens draw in one colour: there the bars are
/// solid and the curve and its fill fainter, and zero tells them apart.
struct GridDayChart: View {
    let moment: GridGlance.Moment
    /// The hour and power labels; the small widget has no room for them.
    let labels: Bool
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let full = renderingMode == .fullColor
        let inset = GridTodayEntry.quarterMs * 0.12
        Chart {
            RuleMark(y: .value("Zero", 0))
                .foregroundStyle(Color.secondary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 0.5))
            ForEach(moment.bars) { bar in
                RectangleMark(
                    xStart: .value("From", date(bar.startMs + inset)),
                    xEnd: .value("To", date(bar.endMs - inset)),
                    yStart: .value("Zero", 0.0),
                    yEnd: .value("Bought", bar.watts)
                )
                .foregroundStyle(full ? AnyShapeStyle(GridColors.bars) : AnyShapeStyle(.primary))
                .cornerRadius(1)
            }
            ForEach(moment.curve) { p in
                AreaMark(x: .value("Time", date(p.t)), yStart: .value("Sold", p.watts), yEnd: .value("Zero", 0.0), series: .value("Run", "\(p.run)-"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(full ? AnyShapeStyle(GridColors.curve.opacity(0.22)) : AnyShapeStyle(.primary.opacity(0.18)))
                LineMark(x: .value("Time", date(p.t)), y: .value("Sold", p.watts), series: .value("Run", "\(p.run)"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(full ? AnyShapeStyle(GridColors.curve) : AnyShapeStyle(.primary.opacity(0.7)))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
        .chartXScale(domain: date(moment.dayStartMs)...date(moment.dayEndMs))
        .chartYScale(domain: moment.yBottom...moment.yTop)
        .chartXAxis {
            AxisMarks(values: labels ? moment.xTicks.map { date($0.value) } : []) { value in
                AxisValueLabel(anchor: anchor(value.index)) {
                    Text(moment.xTicks[value.index].label)
                }
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(Color.secondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: labels ? moment.yTicks.map(\.value) : []) { value in
                AxisValueLabel {
                    Text(moment.yTicks[value.index].label)
                }
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(Color.secondary)
            }
        }
        .widgetAccentable()
        .accessibilityHidden(true)
    }

    /// The first and last hour labels sit inside the plot, not off its ends.
    private func anchor(_ index: Int) -> UnitPoint {
        index == 0 ? .topLeading : (index == moment.xTicks.count - 1 ? .topTrailing : .top)
    }

    private func date(_ ms: Double) -> Date { Date(timeIntervalSince1970: ms / 1000) }
}
