import Charts
import FTWKit
import SwiftUI

/// The curves of a node's view. Each is `Equatable` on the values it draws,
/// so a frame that changed nothing it shows does not redraw it.
///
/// Watts are drawn as the node shows them (solar as what it makes), signed
/// where direction matters: up is into the home's battery or from the grid,
/// down is out. The axis says magnitudes and a word says which way; no
/// minus sign reaches the screen.

private func date(_ ms: Double) -> Date { Date(timeIntervalSince1970: ms / 1000) }

/// "15", on the 24-hour clock FTW uses in both languages: an English phone
/// would otherwise label the afternoon "03".
func hourLabel(_ value: AxisValue) -> some View {
    Text(value.as(Date.self).map { String(format: "%02d", Calendar.current.component(.hour, from: $0)) } ?? "")
        .font(.caption2)
        .foregroundStyle(Theme.fgMuted)
}

/// The largest text a chart's labels take: a chart is a drawing, and its
/// figures are said again in words under it and to VoiceOver.
let chartTextCap = DynamicTypeSize.xxLarge

/// An axis label in a column of one width for the text size, so charts
/// stacked one above the other put the same hour at the same place.
struct AxisText: View {
    let text: String
    @ScaledMetric(relativeTo: .caption2) private var width: CGFloat = 44

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(Theme.fgMuted)
            .lineLimit(1)
            .frame(width: width, alignment: .leading)
    }
}

/// Axis labels as magnitudes: "2 kW" above the line and below it. The zero
/// line speaks for itself.
private func powerAxis() -> some AxisContent {
    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Theme.line)
        AxisValueLabel {
            if let w = value.as(Double.self), w != 0 {
                AxisText(PowerFormat.scale(w))
            }
        }
    }
}

/// How a node's charts draw it: one colour pair for every chart of the
/// node, live, past and ahead, and for a node whose power runs both ways
/// the word for each direction inside the plot.
struct ChartLook: Equatable {
    /// Into the battery, from the grid, or the node's only direction.
    var up: Color
    /// Out of the battery, to the grid.
    var down: Color
    /// The line over the areas.
    var line: Color
    var upWord: String?
    var downWord: String?

    var signed: Bool { upWord != nil }
}

/// "↑ charging" at the top of the plot and "↓ giving power" at its foot, so
/// a signed curve says which way is which where the eye already is.
private struct DirectionWords: ViewModifier {
    let look: ChartLook

    func body(content: Content) -> some View {
        content.chartPlotStyle { plot in
            plot
                .overlay(alignment: .topLeading) { word(look.upWord, "arrow.up") }
                .overlay(alignment: .bottomLeading) { word(look.downWord, "arrow.down") }
        }
    }

    @ViewBuilder private func word(_ text: String?, _ symbol: String) -> some View {
        if let text {
            Label(text, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Theme.fgDim)
                .lineLimit(1)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

extension View {
    func directionWords(_ look: ChartLook) -> some View { modifier(DirectionWords(look: look)) }
}

/// A run of points drawn as two areas, the part above zero in one colour of
/// the pair and the part below in the other, under one line.
@ChartContentBuilder
private func signedRun(_ t: Double, _ v: Double, run: Int, look: ChartLook, opacity: (top: Double, bottom: Double), lineWidth: CGFloat) -> some ChartContent {
    AreaMark(x: .value("Time", date(t)), yStart: .value("Zero", 0), yEnd: .value("Power", max(0, v)), series: .value("Run", "\(run)+"))
        .foregroundStyle(LinearGradient(colors: [look.up.opacity(opacity.top), look.up.opacity(opacity.bottom)], startPoint: .top, endPoint: .bottom))
        .interpolationMethod(.monotone)
    if look.signed {
        AreaMark(x: .value("Time", date(t)), yStart: .value("Power", min(0, v)), yEnd: .value("Zero", 0), series: .value("Run", "\(run)-"))
            .foregroundStyle(LinearGradient(colors: [look.down.opacity(opacity.bottom), look.down.opacity(opacity.top)], startPoint: .top, endPoint: .bottom))
            .interpolationMethod(.monotone)
    }
    LineMark(x: .value("Time", date(t)), y: .value("Power", v), series: .value("Run", "\(run)"))
        .foregroundStyle(look.line)
        .lineStyle(StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        .interpolationMethod(.monotone)
}

/// The last five minutes, from the ring buffer lane 0 fills. A break in
/// the stream is a break in the line.
struct LiveChart: View, Equatable {
    let points: [LiveTrace.Point]
    let nowMs: Double
    let look: ChartLook

    var body: some View {
        let runs = LiveTrace.runs(points)
        Chart {
            ForEach(runs.indices, id: \.self) { i in
                let r = runs[i]
                signedRun(r.point.t, r.point.v, run: r.run, look: look, opacity: (0.32, 0.04), lineWidth: 2)
            }
            if look.signed {
                RuleMark(y: .value("Zero", 0)).foregroundStyle(Theme.line).lineStyle(StrokeStyle(lineWidth: 1))
            }
            if let last = runs.last {
                PointMark(x: .value("Time", date(last.point.t)), y: .value("Power", last.point.v))
                    .foregroundStyle(last.point.v < 0 ? look.down : look.line)
                    .symbolSize(28)
            }
        }
        .chartXScale(domain: date(nowMs - LiveTrace.windowMs)...date(max(nowMs, (points.last?.t ?? nowMs))))
        .chartXAxis(.hidden)
        .chartYAxis { powerAxis() }
        .chartYScale(domain: .automatic(includesZero: true))
        .directionWords(look)
        .dynamicTypeSize(...chartTextCap)
        .accessibilityLabel(L("Live, the last five minutes"))
    }
}

/// Today or the last two days, five minutes a point, from the box's tiles.
struct HistoryChart: View, Equatable {
    let samples: [HistorySample]
    let fromMs: Double
    let toMs: Double
    let look: ChartLook
    let strideHours: Int

    var body: some View {
        let points = runs()
        Chart {
            ForEach(points.indices, id: \.self) { i in
                let p = points[i]
                signedRun(p.t, p.v, run: p.run, look: look, opacity: (0.35, 0.05), lineWidth: 1.5)
            }
            if look.signed {
                RuleMark(y: .value("Zero", 0)).foregroundStyle(Theme.line)
            }
        }
        .chartXScale(domain: date(fromMs)...date(toMs))
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: strideHours)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Theme.line)
                AxisValueLabel { hourLabel(value) }
            }
        }
        .chartYAxis { powerAxis() }
        .chartYScale(domain: .automatic(includesZero: true))
        .directionWords(look)
        .dynamicTypeSize(...chartTextCap)
    }

    /// Each sample at the middle of its step, numbered by run so a hole is
    /// a break in the line rather than a line drawn across it.
    private func runs() -> [(t: Double, v: Double, run: Int)] {
        var out = [(t: Double, v: Double, run: Int)]()
        var run = 0
        var open = false
        for s in samples {
            guard let w = s.watts else {
                if open { run += 1; open = false }
                continue
            }
            out.append((max(fromMs, s.startMs + s.stepMs / 2), w, run))
            open = true
        }
        return out
    }
}

/// The car's energy hour by hour, from the box's ledger.
struct CarHoursChart: View, Equatable {
    let hours: [CarEnergyModel.Hour]
    let fromMs: Double
    let toMs: Double
    let strideHours: Int

    var body: some View {
        Chart {
            ForEach(hours.filter { $0.startMs + $0.lenMs > fromMs }) { h in
                RectangleMark(
                    xStart: .value("From", date(max(fromMs, h.startMs))),
                    xEnd: .value("To", date(h.startMs + h.lenMs)),
                    yStart: .value("Zero", 0),
                    yEnd: .value("Energy", h.wh / 1000)
                )
                .foregroundStyle(Theme.mobility)
                .cornerRadius(2)
            }
        }
        .chartXScale(domain: date(fromMs)...date(toMs))
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: strideHours)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Theme.line)
                AxisValueLabel { hourLabel(value) }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Theme.line)
                AxisValueLabel {
                    if let kwh = value.as(Double.self), kwh != 0 {
                        AxisText(AppWords.energy(kwh * 1000))
                    }
                }
            }
        }
        .dynamicTypeSize(...chartTextCap)
    }
}

/// The hours ahead: what the box means each slot to do, as bars, and the
/// price under the same hours, so a plan and its reason sit side by side.
struct AheadChart: View, Equatable {
    struct Bar: Equatable, Identifiable {
        let startMs: Double
        let endMs: Double
        /// Signed as the node shows it.
        let watts: Double
        var id: Double { startMs }
    }

    struct Price: Equatable, Identifiable {
        let startMs: Double
        let endMs: Double
        let minor: Double
        var id: Double { startMs }
    }

    let bars: [Bar]
    let prices: [Price]
    let currency: String
    let nowMs: Double
    let look: ChartLook

    var body: some View {
        let to = nowMs + PlanModel.aheadMs
        VStack(spacing: 8) {
            Chart {
                ForEach(bars) { b in
                    RectangleMark(
                        xStart: .value("From", date(max(nowMs, b.startMs))),
                        xEnd: .value("To", date(min(to, b.endMs))),
                        yStart: .value("Zero", 0),
                        yEnd: .value("Power", b.watts)
                    )
                    .foregroundStyle(b.watts >= 0 ? look.up : look.down)
                    .cornerRadius(1.5)
                }
                if look.signed {
                    RuleMark(y: .value("Zero", 0)).foregroundStyle(Theme.line)
                }
            }
            .chartXScale(domain: date(nowMs)...date(to))
            .chartXAxis(.hidden)
            .chartYAxis { powerAxis() }
            .chartYScale(domain: .automatic(includesZero: true))
            .directionWords(look)
            if !prices.isEmpty {
                PriceStripChart(prices: prices, currency: currency, fromMs: nowMs, toMs: to)
                    .frame(height: 36)
            }
        }
        .dynamicTypeSize(...chartTextCap)
    }
}

/// Prices across the same hours as the chart above, coloured cheap to dear
/// against their own average, with the hours named under them.
struct PriceStripChart: View, Equatable {
    let prices: [AheadChart.Price]
    let currency: String
    let fromMs: Double
    let toMs: Double

    var body: some View {
        let shown = prices.filter { $0.endMs > fromMs && $0.startMs < toMs }
        let mean = shown.isEmpty ? 0 : shown.map(\.minor).reduce(0, +) / Double(shown.count)
        Chart {
            ForEach(shown) { p in
                RectangleMark(
                    xStart: .value("From", date(max(fromMs, p.startMs))),
                    xEnd: .value("To", date(min(toMs, p.endMs))),
                    yStart: .value("Zero", 0),
                    yEnd: .value("Price", PriceUnits.display(p.minor, currency))
                )
                .foregroundStyle(p.minor > mean * 1.05 ? Theme.importing.opacity(0.7) : p.minor < mean * 0.95 ? Theme.exporting.opacity(0.7) : Theme.fgMuted.opacity(0.5))
                .accessibilityLabel(AppWords.clock(p.startMs, zone: .current))
                .accessibilityValue("\(AppWords.decimal(PriceStrip.text(p.minor, currency))) \(PriceUnits.unit(currency).perKwh)")
            }
        }
        .chartXScale(domain: date(fromMs)...date(toMs))
        .chartXAxis {
            AxisMarks(preset: .aligned, values: .stride(by: .hour, count: 3)) { value in
                AxisValueLabel { hourLabel(value) }
            }
        }
        .chartYAxis {
            // The dearest hour, in the column the chart above keeps for its
            // own scale: the price's scale, and the hours line up.
            AxisMarks(position: .trailing, values: shown.map(\.minor).max().map { [PriceUnits.display($0, currency)] } ?? []) { value in
                // Hung below its tick, inside the strip, clear of the scale
                // of the chart above.
                AxisValueLabel(anchor: .topLeading) {
                    if let v = value.as(Double.self) {
                        AxisText("\(Int(v.rounded())) \(PriceUnits.unit(currency).label)")
                    }
                }
            }
        }
        .accessibilityLabel(L("Prices ahead"))
    }
}
