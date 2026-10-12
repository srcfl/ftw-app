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

/// One width for every axis label, so charts stacked one above the other
/// put the same hour at the same place.
private let axisWidth: CGFloat = 44

/// Axis labels as magnitudes: "2 kW" above the line and below it.
private func powerAxis() -> some AxisContent {
    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Theme.line)
        AxisValueLabel {
            if let w = value.as(Double.self) {
                Text(PowerFormat.scale(w)).font(.caption2).foregroundStyle(Theme.fgMuted)
                    .frame(width: axisWidth, alignment: .leading)
            }
        }
    }
}

/// The last five minutes, from the ring buffer lane 0 fills. A break in
/// the stream is a break in the line.
struct LiveChart: View, Equatable {
    let points: [LiveTrace.Point]
    let nowMs: Double
    let color: Color
    let signed: Bool

    var body: some View {
        let runs = LiveTrace.runs(points)
        Chart {
            ForEach(runs.indices, id: \.self) { i in
                let r = runs[i]
                AreaMark(x: .value("Time", date(r.point.t)), y: .value("Power", r.point.v), series: .value("Run", r.run), stacking: .unstacked)
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.32), color.opacity(0.04)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", date(r.point.t)), y: .value("Power", r.point.v), series: .value("Run", r.run))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
            if signed {
                RuleMark(y: .value("Zero", 0)).foregroundStyle(Theme.line).lineStyle(StrokeStyle(lineWidth: 1))
            }
            if let last = runs.last {
                PointMark(x: .value("Time", date(last.point.t)), y: .value("Power", last.point.v))
                    .foregroundStyle(color)
                    .symbolSize(28)
            }
        }
        .chartXScale(domain: date(nowMs - LiveTrace.windowMs)...date(max(nowMs, (points.last?.t ?? nowMs))))
        .chartXAxis(.hidden)
        .chartYAxis { powerAxis() }
        .chartYScale(domain: .automatic(includesZero: true))
        .accessibilityLabel(L("Live, the last five minutes"))
    }
}

/// Today or the last two days, five minutes a point, from the box's tiles.
struct HistoryChart: View, Equatable {
    let samples: [HistorySample]
    let fromMs: Double
    let toMs: Double
    let color: Color
    let signed: Bool
    let strideHours: Int

    var body: some View {
        let points = runs()
        Chart {
            ForEach(points.indices, id: \.self) { i in
                let p = points[i]
                AreaMark(x: .value("Time", date(p.t)), y: .value("Power", p.v), series: .value("Run", p.run), stacking: .unstacked)
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", date(p.t)), y: .value("Power", p.v), series: .value("Run", p.run))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
            }
            if signed {
                RuleMark(y: .value("Zero", 0)).foregroundStyle(Theme.line)
            }
        }
        .chartXScale(domain: date(fromMs)...date(toMs))
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: strideHours)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Theme.line)
                AxisValueLabel(format: .dateTime.hour(.twoDigits(amPM: .omitted))).font(.caption2).foregroundStyle(Theme.fgMuted)
            }
        }
        .chartYAxis { powerAxis() }
        .chartYScale(domain: .automatic(includesZero: true))
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
            AxisMarks(values: .stride(by: .hour, count: strideHours)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Theme.line)
                AxisValueLabel(format: .dateTime.hour(.twoDigits(amPM: .omitted))).font(.caption2).foregroundStyle(Theme.fgMuted)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Theme.line)
                AxisValueLabel {
                    if let kwh = value.as(Double.self) {
                        Text(kwh == 0 ? "0\u{00A0}kWh" : AppWords.energy(kwh * 1000)).font(.caption2).foregroundStyle(Theme.fgMuted)
                            .frame(width: axisWidth, alignment: .leading)
                    }
                }
            }
        }
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
    let color: Color
    /// A second colour for bars below the line: giving power, selling.
    let outColor: Color
    let signed: Bool

    var body: some View {
        let to = nowMs + PlanModel.aheadMs
        VStack(spacing: 4) {
            Chart {
                ForEach(bars) { b in
                    RectangleMark(
                        xStart: .value("From", date(max(nowMs, b.startMs))),
                        xEnd: .value("To", date(min(to, b.endMs))),
                        yStart: .value("Zero", 0),
                        yEnd: .value("Power", b.watts)
                    )
                    .foregroundStyle(b.watts >= 0 ? color : outColor)
                    .cornerRadius(1.5)
                }
                if signed {
                    RuleMark(y: .value("Zero", 0)).foregroundStyle(Theme.line)
                }
            }
            .chartXScale(domain: date(nowMs)...date(to))
            .chartXAxis(.hidden)
            .chartYAxis { powerAxis() }
            .chartYScale(domain: .automatic(includesZero: true))
            if !prices.isEmpty {
                PriceStripChart(prices: prices, currency: currency, fromMs: nowMs, toMs: to)
                    .frame(height: 36)
            }
        }
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
            AxisMarks(preset: .aligned, values: .stride(by: .hour, count: 3)) { _ in
                AxisValueLabel(format: .dateTime.hour(.twoDigits(amPM: .omitted))).font(.caption2).foregroundStyle(Theme.fgMuted)
            }
        }
        .chartYAxis {
            // The dearest hour, in the column the chart above keeps for its
            // own scale: the price's scale, and the hours line up.
            AxisMarks(position: .trailing, values: shown.map(\.minor).max().map { [PriceUnits.display($0, currency)] } ?? []) { value in
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text("\(Int(v.rounded())) \(PriceUnits.unit(currency).label)").font(.caption2).foregroundStyle(Theme.fgMuted)
                            .frame(width: axisWidth, alignment: .leading)
                    }
                }
            }
        }
        .accessibilityLabel(L("Prices ahead"))
    }
}
