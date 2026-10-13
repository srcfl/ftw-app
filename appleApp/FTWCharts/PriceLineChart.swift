import Charts
import FTWShared
import SwiftUI

/// The colours a price chart draws with, given by the app or the widget so
/// each keeps its own palette.
struct PriceChartPalette {
    var cheap: Color
    var flat: Color
    var dear: Color
    /// The now rule and dot.
    var now: Color
    /// The average rule and its label, the hour labels.
    var quiet: Color
    /// Behind a label that sits on the line.
    var labelBackground: Color
}

/// One price slot as the chart draws it: the time it starts, its price in
/// display units (öre, cents), and an id that stays with the slot.
struct PricePoint: Identifiable, Equatable {
    let startMs: Double
    let endMs: Double
    let value: Double
    var id: Double { startMs }
}

/// The price ahead as one stepped line over a soft area, coloured by level:
/// green under the average, grey around it, red above. Now is a thin rule
/// with a dot on the line; the cheapest hours are a soft green band with a
/// small label; the average is a faint rule named at the right edge. No
/// gridlines and few hour labels. The app and the price widget draw the
/// same chart; only the app lets a finger move over it.
struct PriceLineChart: View {
    let points: [PricePoint]
    let nowMs: Double
    let mean: Double?
    let cheapest: ClosedRange<Double>?
    /// "Cheapest", over the band.
    let cheapestLabel: String?
    /// "avg 221", at the right end of the average rule.
    let meanLabel: String?
    let palette: PriceChartPalette
    let zone: TimeZone
    /// Hours between labels on the time axis.
    var labelEveryHours = 6
    /// Where the finger is, drawn as a rule and a dot.
    var selected: Date?
    /// One colour only, for tinted widgets and StandBy at night.
    var monochrome = false

    var body: some View {
        let domain = yDomain
        Chart {
            if let cheapest {
                RectangleMark(
                    xStart: .value("From", date(max(cheapest.lowerBound, start))),
                    xEnd: .value("To", date(min(cheapest.upperBound, end))),
                    yStart: .value("Low", domain.lowerBound),
                    yEnd: .value("High", domain.upperBound)
                )
                .foregroundStyle(palette.cheap.opacity(monochrome ? 0.18 : 0.12))
                .annotation(position: .overlay, alignment: .top, spacing: 0) {
                    if let cheapestLabel {
                        Text(cheapestLabel)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(monochrome ? AnyShapeStyle(.primary) : AnyShapeStyle(palette.cheap))
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.top, 2)
                    }
                }
            }
            // A gradient spans the mark it colours, so each takes its own
            // stops: the area from its base, the line from its own lowest.
            let lineSpan = (points.map(\.value).min() ?? 0)...(points.map(\.value).max() ?? 1)
            let areaSpan = domain.lowerBound...lineSpan.upperBound
            ForEach(drawn) { p in
                AreaMark(x: .value("Time", date(p.startMs)), yStart: .value("Base", domain.lowerBound), yEnd: .value("Price", p.value))
                    .foregroundStyle(level(areaSpan, area: true))
                    .interpolationMethod(.stepEnd)
                LineMark(x: .value("Time", date(p.startMs)), y: .value("Price", p.value))
                    .foregroundStyle(level(lineSpan, area: false))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.stepEnd)
            }
            // After the line, so its label sits on top of it.
            if let mean {
                RuleMark(y: .value("Average", mean))
                    .foregroundStyle(palette.quiet.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [2, 3]))
                    .annotation(position: .top, alignment: .trailing, spacing: 1) {
                        if let meanLabel {
                            Text(meanLabel)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(palette.quiet)
                                .lineLimit(1)
                                .fixedSize()
                                .padding(.horizontal, 3)
                                .background(palette.labelBackground.opacity(0.85), in: Capsule())
                        }
                    }
            }
            if let current = value(at: nowMs) {
                RuleMark(x: .value("Now", date(nowMs)))
                    .foregroundStyle(palette.now.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("Now", date(nowMs)), y: .value("Price", current))
                    .foregroundStyle(palette.now)
                    .symbolSize(36)
            }
            // While a finger is down there is always a slot under it: past
            // either edge the marker stays at that edge, and in a gap it
            // sits on the step the line draws there.
            if let selected, let i = SlotLookup.clamped(points, at: selected.timeIntervalSince1970 * 1000, start: \.startMs) {
                let at = date(min(max(selected.timeIntervalSince1970 * 1000, start), end))
                RuleMark(x: .value("Selected", at))
                    .foregroundStyle(palette.quiet.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("Selected", at), y: .value("Price", points[i].value))
                    .foregroundStyle(palette.now)
                    .symbolSize(64)
            }
        }
        .chartXScale(domain: date(start)...date(end))
        .chartYScale(domain: domain)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: hourTicks) { value in
                AxisValueLabel(anchor: .top) {
                    if let d = value.as(Date.self) {
                        Text(String(format: "%02d", calendar.component(.hour, from: d)))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(palette.quiet)
                    }
                }
            }
        }
        .chartLegend(.hidden)
    }

    // MARK: Geometry

    private var start: Double { points.first?.startMs ?? nowMs }
    private var end: Double { points.last?.endMs ?? nowMs }

    /// The points plus one at the end of the last slot, so a stepped line
    /// draws the last slot's whole width.
    private var drawn: [PricePoint] {
        guard let last = points.last else { return [] }
        return points + [PricePoint(startMs: last.endMs, endMs: last.endMs, value: last.value)]
    }

    /// From zero, or below it when a price is negative, to a little over
    /// the dearest.
    private var yDomain: ClosedRange<Double> {
        let lo = min(0, points.map(\.value).min() ?? 0)
        let hi = max(lo + 1, (points.map(\.value).max() ?? 1) * 1.12)
        return lo...hi
    }

    /// Green under the average, grey around it, red above, by height
    /// within `span`, the values the mark covers. An area is light and
    /// fades toward its base.
    private func level(_ span: ClosedRange<Double>, area: Bool) -> LinearGradient {
        let fill: (Color, Double) -> Color = { c, at in area ? c.opacity(0.04 + 0.16 * at) : c }
        guard !monochrome, let mean, span.upperBound > span.lowerBound else {
            let c = monochrome ? Color.primary : palette.flat
            return LinearGradient(colors: [fill(c, 0), fill(c, 1)], startPoint: .bottom, endPoint: .top)
        }
        let width = span.upperBound - span.lowerBound
        let low = max(0, min(1, (mean * 0.95 - span.lowerBound) / width))
        let high = max(low, min(1, (mean * 1.05 - span.lowerBound) / width))
        return LinearGradient(stops: [
            .init(color: fill(palette.cheap, 0), location: 0),
            .init(color: fill(palette.cheap, low), location: low),
            .init(color: fill(palette.flat, (low + high) / 2), location: (low + high) / 2),
            .init(color: fill(palette.dear, high), location: high),
            .init(color: fill(palette.dear, 1), location: 1),
        ], startPoint: .bottom, endPoint: .top)
    }

    private func value(at ms: Double) -> Double? {
        points.first { $0.startMs <= ms && ms < $0.endMs }?.value
    }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }

    /// Whole hours a few apart, kept clear of the right edge.
    private var hourTicks: [Date] {
        let hour: Double = 3_600_000
        var t = (start / hour).rounded(.up) * hour
        var out: [Date] = []
        while t < end - hour {
            if calendar.component(.hour, from: date(t)) % labelEveryHours == 0 { out.append(date(t)) }
            t += hour
        }
        return out
    }

    private func date(_ ms: Double) -> Date { Date(timeIntervalSince1970: ms / 1000) }
}
