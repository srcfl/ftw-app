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
        default: return AnyShapeStyle(moment.isGrey ? Theme.hairline : Theme.ground)
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

/// Net and its word on the left, the cost on the right, and the day under
/// them with its hours and scale.
struct MediumGrid: View {
    let moment: GridGlance.Moment

    var body: some View {
        if moment.state == .today {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    NetFigure(moment: moment, size: 28)
                    Spacer(minLength: 8)
                    CostFigure(moment: moment, size: 20)
                }
                HStack(alignment: .firstTextBaseline) {
                    NetLine(moment: moment)
                    Spacer(minLength: 8)
                    TimeLine(moment: moment, withNote: true)
                }
                .accessibilityHidden(true)
                GridDayChart(moment: moment, labels: true)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(moment.spoken)
        } else {
            GridEmpty(moment: moment)
        }
    }
}

/// The figures, stacked, around a small day.
struct SmallGrid: View {
    let moment: GridGlance.Moment

    var body: some View {
        if moment.state == .today {
            VStack(alignment: .leading, spacing: 1) {
                NetFigure(moment: moment, size: 24)
                NetLine(moment: moment)
                GridDayChart(moment: moment, labels: false)
                    .padding(.vertical, 4)
                // The time has a line of its own, so a long cost never
                // cuts it short.
                CostFigure(moment: moment, size: 16)
                TimeLine(moment: moment, withNote: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(moment.spoken)
        } else {
            GridEmpty(moment: moment)
        }
    }
}

/// The lock screen's rectangle: net and cost on one line, which way and
/// both sides under it, and the time.
struct RectangularGrid: View {
    let moment: GridGlance.Moment

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if moment.state == .today, let net = moment.netText {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(Text(net).font(.headline.monospacedDigit())) \(Text(moment.unit).font(.caption))")
                        .widgetAccentable()
                    Spacer(minLength: 2)
                    if let cost = moment.costText {
                        Text("\(Text(cost).font(.headline.monospacedDigit())) \(Text(moment.costUnit).font(.caption))")
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                Text([moment.netWord, moment.inOutText].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text([moment.costNote, moment.timeText].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("\(Image(systemName: GridGlance.symbol)) \(GridGlance.title())")
                    .font(.caption.weight(.semibold))
                    .widgetAccentable()
                Text(moment.emptyText ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let time = moment.timeText {
                    Text(time).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(moment.spoken)
    }
}

// MARK: Parts

/// "1,8 kWh": a magnitude, never signed; the word under it says which way.
struct NetFigure: View {
    let moment: GridGlance.Moment
    let size: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(moment.netText ?? "")
                .font(Theme.figure(size))
                .tracking(-0.5)
                .foregroundStyle(Theme.ink)
                .contentTransition(.numericText())
                .widgetAccentable()
            Text(moment.unit)
                .font(.system(size: max(12, size * 0.5), weight: .medium))
                .foregroundStyle(Theme.ink2)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

/// "−4,20 kr", in the grid's colour when the grid paid it.
struct CostFigure: View {
    let moment: GridGlance.Moment
    let size: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(moment.costText ?? "–")
                .font(Theme.figure(size))
                .foregroundStyle(moment.earned ? Theme.grid : Theme.ink)
                .contentTransition(.numericText())
            if moment.costText != nil {
                Text(moment.costUnit)
                    .font(.system(size: max(11, size * 0.6), weight: .medium))
                    .foregroundStyle(Theme.ink2)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

/// "sålt netto · in 6,5 · ut 8,3 kWh": which way in the grid's colour,
/// then both sides, always, so net is never read as the bill.
struct NetLine: View {
    let moment: GridGlance.Moment

    var body: some View {
        Group {
            if let word = moment.netWord, let inOut = moment.inOutText {
                Text("\(Text(word).font(.caption.weight(.semibold)).foregroundStyle(Theme.grid))\(Text(verbatim: " · ").foregroundStyle(Theme.ink3))\(Text(inOut).foregroundStyle(Theme.ink2))")
            } else {
                Text(moment.inOutText ?? "").foregroundStyle(Theme.ink2)
            }
        }
        .font(.caption2)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

/// "delvis · kl 16:55": what time the figures are from, in the terminal
/// layer. A widget always says when, and never glows.
struct TimeLine: View {
    let moment: GridGlance.Moment
    let withNote: Bool

    var body: some View {
        Text((withNote ? [moment.costNote, moment.timeText] : [moment.timeText]).compactMap { $0 }.joined(separator: " · "))
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Theme.ink3)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

/// Nothing for today: say why and when the last figures were from.
struct GridEmpty: View {
    let moment: GridGlance.Moment

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Kicker(text: GridGlance.title())
            Spacer(minLength: 4)
            Text(moment.emptyText ?? "")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let time = moment.timeText {
                Text(time).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.ink3).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

/// The day on a fixed 00–24 axis, as the app draws the grid's Today: one
/// signed line through the slot means with its body, buying above zero and
/// selling below, both in the grid's magenta, and on the medium widget the
/// band of the quarters each slot holds. The line stops where the read
/// does; a hole the box has no record for breaks it and shows as a dotted
/// baseline. Still paths, no glow: a widget is never live.
///
/// Tinted and clear home screens draw in one colour: the line in primary at
/// 0.7, the body fainter, no band.
struct GridDayChart: View {
    let moment: GridGlance.Moment
    /// The hours, the scale and the side words; the small widget has no
    /// room for them.
    let labels: Bool
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geo in
            let frame = labels ? ChartFrame(top: 0, bottom: 14, trailing: 30) : ChartFrame(top: 0, bottom: 0, trailing: 0)
            let plot = frame.plot(in: geo.size)
            let series = moment.series(size: plot.size)
            let base = YMap(domain: series.domain, height: plot.height).baseline
            let px = 1 / max(displayScale, 1)
            let full = renderingMode == .fullColor
            let color: Color = full ? Theme.grid : .primary
            let dark = scheme == .dark
            let shift = CGAffineTransform(translationX: plot.minX, y: plot.minY)
            let above = Path(CGRect(x: plot.minX, y: plot.minY - 4, width: plot.width, height: base + 4))
            let below = Path(CGRect(x: plot.minX, y: plot.minY + base, width: plot.width, height: plot.height - base + 4))
            let body = Path(series.body.cgPath).applying(shift)
            let peak = full ? (dark ? 0.22 : 0.16) : 0.18

            ZStack(alignment: .topLeading) {
                // The body: nothing at zero, `peak` at the scale's edge, on
                // each side.
                body.fill(LinearGradient(colors: [color.opacity(0), color.opacity(peak)], startPoint: UnitPoint(x: 0, y: base / geo.size.height), endPoint: UnitPoint(x: 0, y: plot.minY / geo.size.height)))
                    .clipShape(above)
                body.fill(LinearGradient(colors: [color.opacity(0), color.opacity(peak)], startPoint: UnitPoint(x: 0, y: (plot.minY + base) / geo.size.height), endPoint: UnitPoint(x: 0, y: plot.maxY / geo.size.height)))
                    .clipShape(below)
                if full, labels {
                    Path(series.band.cgPath).applying(shift).fill(color.opacity(dark ? 0.14 : 0.10))
                }
                zero(plot: plot, base: base, px: px)
                    .stroke(Theme.ink.opacity(full ? 0.35 : 0.3), style: StrokeStyle(lineWidth: px))
                missing(series, plot: plot, base: base)
                    .stroke(Theme.ink.opacity(0.35), style: StrokeStyle(lineWidth: px, dash: [1, 3]))
                Path(series.line.cgPath).applying(shift)
                    .stroke(color.opacity(full ? 1 : 0.7), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .widgetAccentable()
                if labels {
                    Axes(moment: moment, series: series, plot: plot, size: geo.size, base: base, full: full)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func zero(plot: CGRect, base: CGFloat, px: CGFloat) -> Path {
        let y = plot.minY + (base / px).rounded() * px + px / 2
        var p = Path()
        p.move(to: CGPoint(x: plot.minX, y: y))
        p.addLine(to: CGPoint(x: plot.maxX, y: y))
        return p
    }

    /// A dotted baseline across each hole the box has no record for.
    private func missing(_ series: ChartSeries, plot: CGRect, base: CGFloat) -> Path {
        var p = Path()
        for r in series.missing {
            p.move(to: CGPoint(x: plot.minX + series.grid.x(atMs: series.grid.startMs(r.lowerBound), width: plot.width), y: plot.minY + base))
            p.addLine(to: CGPoint(x: plot.minX + series.grid.x(atMs: series.grid.endMs(r.upperBound), width: plot.width), y: plot.minY + base))
        }
        return p
    }
}

/// The chart's words in SF Mono 9 ink3, as the app's axes: the hours under
/// it, the scale's ends in the right gutter as magnitudes, and the side
/// words where the scale has that side.
private struct Axes: View {
    let moment: GridGlance.Moment
    let series: ChartSeries
    let plot: CGRect
    let size: CGSize
    let base: CGFloat
    let full: Bool

    var body: some View {
        let map = YMap(domain: series.domain, height: plot.height)
        ZStack(alignment: .topLeading) {
            ForEach(Array(moment.xTicks.enumerated()), id: \.offset) { i, tick in
                label(tick.label)
                    .position(x: min(max(plot.minX + series.grid.x(atMs: tick.value, width: plot.width), plot.minX + 6), plot.maxX - 6), y: size.height - 5)
            }
            ForEach([series.domain.upper, series.domain.lower].filter { $0 != 0 }, id: \.self) { v in
                label(PowerFormat.scale(abs(v)))
                    .position(x: plot.maxX + 16, y: plot.minY + map.y(v) + (v > 0 ? 5 : -5))
            }
            // Each side's word beside its end of the scale, in the corner
            // the hours still to come leave empty, where that side has room.
            if series.domain.upper > 0, base >= Self.wordRoom {
                word(GridGlance.upWord()).offset(x: plot.minX, y: plot.minY)
            }
            if series.domain.lower < 0, plot.height - base >= Self.wordRoom {
                word(GridGlance.downWord()).offset(x: plot.minX, y: plot.maxY - Self.wordRoom + 1)
            }
        }
    }

    /// A side shorter than this has no word: it would sit on zero.
    static let wordRoom: CGFloat = 12

    private func label(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(full ? AnyShapeStyle(Theme.ink3) : AnyShapeStyle(.secondary))
            .lineLimit(1)
    }

    private func word(_ text: String) -> some View {
        label(text).frame(width: max(0, plot.width - 3), alignment: .trailing)
    }
}
